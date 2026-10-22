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
