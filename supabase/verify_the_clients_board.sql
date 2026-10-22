-- Zion Vocational Rehab CRM — the clients board (0223)
--
-- The five things the owner asked to be sure of, and one more that is the
-- reason the first is written the way it is.
--
-- The note is asserted against a *direct update*, not against move_client.
-- If it were only checked in the function then the rule would be the
-- function's, and anything else that writes the column - an import, a sweep,
-- the agent, a hand-typed UPDATE at two in the morning - would walk straight
-- past it. It is the trigger's, so there is no way round it, and that is what
-- the first assertion proves.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_staff   uuid;
  v_uid     uuid;
  v_client  uuid;
  v_auth    uuid;
  v_stage   text;
  v_note    text;
  v_from    text;
  v_who     uuid;
  v_at      timestamptz;
  v_n       integer;
  v_off     uuid;
  v_off2    uuid;
  v_js      uuid;
  v_js_uid  uuid;
  v_msg     text;
  failures  text[] := '{}';
begin
  -- A person to act as, because every one of these records who did it.
  select s.id, s.user_id into v_staff, v_uid from public.staff s
   where s.active and s.user_id is not null and s.role = 'Admin'
   order by s.created_at limit 1;
  if v_staff is null then raise exception 'No Admin to act as.'; end if;

  insert into public.clients (name, status, stage) values ('ZZ Board Person', 'Active', 'Intake')
  returning id into v_client;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_uid::text, 'role', 'authenticated')::text, true);

  -- ── 1. a move is refused without a note ───────────────────
  begin
    update public.clients set stage = 'Assessment' where id = v_client;
    failures := failures ||
      'FAILED: a stage was changed with no note. The rule is the trigger''s or it is nobody''s.'::text;
  exception when check_violation then
    raise notice 'ok  a move with no note is refused, by the column and not by the form';
  end;

  select stage into v_stage from public.clients where id = v_client;
  if v_stage <> 'Intake' then
    failures := failures || 'FAILED: the refused move moved them anyway'::text;
  else
    raise notice 'ok  and they did not move';
  end if;

  -- The function refuses it too, in words a person can read.
  begin
    perform public.move_client(v_client, 'Assessment', '   ', null);
    failures := failures || 'FAILED: move_client accepted a note of spaces'::text;
  exception when check_violation then
    raise notice 'ok  move_client refuses a note of nothing but spaces';
  end;

  -- ── 2. a move is logged with person, time and both stages ─
  perform public.move_client(v_client, 'Assessment', 'The WSA is booked for Tuesday.', null);

  select h.from_stage, h.note, h.staff_id, h.at_time
    into v_from, v_note, v_who, v_at
    from public.client_stage_history h
   where h.client_id = v_client and h.stage = 'Assessment'
   order by h.at_time desc limit 1;

  if v_from is distinct from 'Intake' then
    failures := failures || format('FAILED: the move recorded it came from %s, not Intake', coalesce(v_from,'nothing'))::text;
  elsif v_note is distinct from 'The WSA is booked for Tuesday.' then
    failures := failures || 'FAILED: the note was not kept with the move'::text;
  elsif v_who is distinct from v_staff then
    failures := failures || 'FAILED: the move does not say who made it'::text;
  elsif v_at is null or v_at < now() - interval '1 minute' then
    failures := failures || 'FAILED: the move does not say when'::text;
  else
    raise notice 'ok  the move is on the record: from, to, who and when, with the note';
  end if;

  -- And in the client's own log, where the calls and the visits are.
  select count(*) into v_n from public.contact_log l
   where l.client_id = v_client and l.method = 'Stage change'
     and l.outcome = 'The WSA is booked for Tuesday.';
  if v_n <> 1 then
    failures := failures || format('FAILED: the contact log has %s lines for the move, not 1', v_n)::text;
  else
    raise notice 'ok  and it reads in the contact log beside everything else';
  end if;

  -- ── 3. Close refuses while an authorization is with USOR ──
  -- Written as postgres: an authorization is Billing's to create, and this fixture is nobody's work.
  perform set_config('role', 'postgres', true);
  insert into public.authorizations
    (client_id, service_type, rate_type, number, status, rate, submitted_on)
  values (v_client, 'Job Coaching', 'Flat Fee', 'VZZB00001', 'Submitted', 1.00, public.practice_today() - 3)
  returning id into v_auth;
  perform set_config('role', 'authenticated', true);


  begin
    perform public.close_client(v_client, 'Moved out of state.');
    failures := failures ||
      'FAILED: a client was closed with an authorization still submitted and unpaid'::text;
  exception when check_violation then
    get stacked diagnostics v_msg = message_text;
    if position('VZZB00001' in v_msg) = 0 then
      failures := failures || format('FAILED: the refusal does not name the authorization: %s', v_msg)::text;
    else
      raise notice 'ok  closing is refused while money is out, and the refusal names it';
    end if;
  end;

  select status into v_stage from public.clients where id = v_client;
  if v_stage <> 'Active' then
    failures := failures || 'FAILED: the refused close deactivated them anyway'::text;
  else
    raise notice 'ok  and they are still active';
  end if;

  -- Paid, and now it closes - taking the open ones with it.
  -- Written as postgres: the same reason.
  perform set_config('role', 'postgres', true);
  update public.authorizations set status = 'Paid', paid_on = public.practice_today() where id = v_auth;
  insert into public.authorizations
    (client_id, service_type, rate_type, number, status, rate)
  values (v_client, 'Job Coaching', 'Flat Fee', 'VZZB00002', 'Due', 1.00);
  perform set_config('role', 'authenticated', true);


  select c.closed_authorizations into v_n from public.close_client(v_client, 'The work is finished.') c;
  if v_n <> 1 then
    failures := failures || format('FAILED: closing took %s open authorizations with it, not 1', v_n)::text;
  else
    raise notice 'ok  closing takes the open authorizations with it';
  end if;

  select status into v_stage from public.clients where id = v_client;
  if v_stage <> 'Inactive' then
    failures := failures || format('FAILED: a closed client is %s, not Inactive', v_stage)::text;
  else
    raise notice 'ok  and the client is Inactive';
  end if;

  -- ── 5. an inactive client is never on the board ───────────
  select count(*) into v_n from public.clients_board() b where b.client_id = v_client;
  if v_n <> 0 then
    failures := failures || 'FAILED: an inactive client is on the board'::text;
  else
    raise notice 'ok  an inactive client is not on the board';
  end if;

  -- ── 4. Reactivate puts them back, in the stage chosen ─────
  perform public.reactivate_client(v_client, 'Assessment', 'They are back and ready to restart.');

  select stage, status into v_stage, v_note from public.clients where id = v_client;
  if v_stage <> 'Assessment' then
    failures := failures || format('FAILED: reactivated into %s, not the stage asked for', v_stage)::text;
  elsif v_note <> 'Active' then
    failures := failures || format('FAILED: reactivated but the status is %s', v_note)::text;
  else
    raise notice 'ok  reactivating restores the stage they were asked back into';
  end if;

  select count(*) into v_n from public.clients_board() b where b.client_id = v_client;
  if v_n <> 1 then
    failures := failures || 'FAILED: a reactivated client is not back on the board'::text;
  else
    raise notice 'ok  and they are back on the board';
  end if;

  -- ── off the board, which is not the same as closed ────────
  --
  -- Making somebody inactive is a filing decision and closing them ends the
  -- work. The two are one click apart on the panel, so what separates them
  -- is asserted rather than assumed: who may do each, and what each leaves
  -- behind.
  insert into public.clients (name, status, stage) values ('ZZ Off Board', 'Active', 'Intake')
  returning id into v_off;

  perform set_config('role', 'postgres', true);
  insert into public.authorizations
    (client_id, service_type, rate_type, number, status, rate)
  values (v_off, 'Job Coaching', 'Flat Fee', 'VZZB00003', 'Due', 1.00);
  perform set_config('role', 'authenticated', true);

  begin
    perform public.deactivate_client(v_off, '   ');
    failures := failures || 'FAILED: a client was taken off the board with no note'::text;
  exception when check_violation then
    raise notice 'ok  taking a client off the board without a note is refused';
  end;

  perform public.deactivate_client(v_off, 'Not working with us this term.');

  select status into v_stage from public.clients where id = v_off;
  if v_stage <> 'Inactive' then
    failures := failures || format('FAILED: made inactive and the status is %s', v_stage)::text;
  else
    raise notice 'ok  making somebody inactive takes them off the board';
  end if;

  -- The whole point of it: nothing else moves.
  select count(*) into v_n from public.authorizations
   where client_id = v_off and status = 'Due';
  if v_n <> 1 then
    failures := failures ||
      'FAILED: making somebody inactive touched their authorizations. That is what Close is for.'::text;
  else
    raise notice 'ok  and leaves their authorizations exactly where they were';
  end if;

  select count(*) into v_n from public.contact_log l
   where l.client_id = v_off and l.method = 'Off the board'
     and l.outcome = 'Not working with us this term.'
     and l.staff_id = v_staff and l.date = public.practice_today();
  if v_n <> 1 then
    failures := failures ||
      format('FAILED: the contact log has %s lines for it, with the note, the person and the day', v_n)::text;
  else
    raise notice 'ok  with who, when and the note in the contact log';
  end if;

  -- The change log is not asserted here, and the reason is worth writing
  -- down rather than leaving as a gap: directory_change_log skips any record
  -- whose name is a fixture name, deliberately, so that a verification run
  -- does not fill the practice's audit trail with ZZ people. Every client in
  -- this script is a ZZ person, so the log is silent about all of them by
  -- design. What it carries for a real client is the status change with the
  -- reason on it, which is the same setting deactivate_client writes.
  --
  -- So the thing asserted is that the silence is the rule and not an
  -- accident: if is_fixture_name ever stops recognising these names, the
  -- log would start filling with them and this would say so.
  if not public.is_fixture_name('ZZ Off Board') then
    failures := failures ||
      'FAILED: ZZ names are no longer recognised as fixtures, so verification runs are now writing to the practice''s change log'::text;
  else
    raise notice 'ok  the change log skips fixture names, which is why it is silent here';
  end if;

  select count(*) into v_n from public.clients_board() b where b.client_id = v_off;
  if v_n <> 0 then
    failures := failures || 'FAILED: somebody made inactive is still on the board'::text;
  else
    raise notice 'ok  and their card is gone from the board';
  end if;

  -- ── and a Job Search member of staff may do one, not both ─
  --
  -- The owner's rule: everybody who can move a card can take one off the
  -- board; ending the work stays with Admin, Intake & Client Reports and
  -- Billing. Asserted as the role itself, not as what a screen renders.
  select s.id, s.user_id into v_js, v_js_uid from public.staff s
   where s.role = 'Job Search' and s.active and s.user_id is not null limit 1;

  if v_js_uid is null then
    raise notice '--  no Job Search member of staff to act as, so the role split was not tried';
  else
    insert into public.clients (name, status, stage) values ('ZZ Off Board Two', 'Active', 'Intake')
    returning id into v_off2;

    perform set_config('request.jwt.claims',
      json_build_object('sub', v_js_uid::text, 'role', 'authenticated')::text, true);

    begin
      perform public.close_client(v_off2, 'ZZ probe');
      failures := failures ||
        'FAILED: a Job Search member of staff closed a client, which is Admin''s, Reports'' or Billing''s'::text;
    exception when insufficient_privilege then
      raise notice 'ok  a Job Search member of staff cannot close a client';
    end;

    begin
      perform public.deactivate_client(v_off2, 'Their card is in the way.');
      raise notice 'ok  — and can still take one off the board';
    exception when others then
      get stacked diagnostics v_msg = message_text;
      failures := failures ||
        format('FAILED: a Job Search member of staff could not make a client inactive: %s', v_msg)::text;
    end;

    select status into v_stage from public.clients where id = v_off2;
    if v_stage <> 'Inactive' then
      failures := failures || 'FAILED: the Job Search deactivation did not take'::text;
    end if;

    perform set_config('request.jwt.claims',
      json_build_object('sub', v_uid::text, 'role', 'authenticated')::text, true);
  end if;

  -- ── and the board holds nothing it should not ─────────────
  select count(*) into v_n from public.clients_board() b
    join public.clients c on c.id = b.client_id
   where c.status <> 'Active' or c.merged_into is not null;
  if v_n > 0 then
    failures := failures || format('FAILED: %s cards belong to clients who are not active', v_n)::text;
  else
    raise notice 'ok  every card on the board is an active, unmerged client';
  end if;

  select count(*) into v_n from public.clients_board() b
   where b.stage not in ('Intake','Assessment','Job Development','Job Search','Life Skills','Job Placement','Job Coaching');
  if v_n > 0 then
    failures := failures || format('FAILED: %s cards are in a stage that is not one of the seven', v_n)::text;
  else
    raise notice 'ok  and every card is in one of the seven columns';
  end if;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('role', 'postgres', true);

  -- ── anon cannot touch any of it ───────────────────────────
  if has_function_privilege('anon', 'public.clients_board(date)', 'execute')
     or has_function_privilege('anon', 'public.move_client(uuid, text, text, uuid)', 'execute')
     or has_function_privilege('anon', 'public.close_client(uuid, text)', 'execute')
     or has_function_privilege('anon', 'public.reactivate_client(uuid, text, text)', 'execute') then
    failures := failures || 'FAILED: anon may read or move the board'::text;
  else
    raise notice 'ok  anon can neither read the board nor move anything on it';
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- THE CLIENTS BOARD VERIFIED ---';
end $$;

rollback;
