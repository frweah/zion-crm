-- Zion Vocational Rehab CRM — the retention schedule
--
-- Everything in 10.3 is a safety property, so this script spends almost all
-- of its effort trying to get a record reported as due for destruction when
-- it should not be. Each of the following has to be impossible:
--
--   Due under a period nobody has checked.
--   Due while a legal hold stands.
--   Due on a guessed closure date.
--   Destroyed recorded against any of the above.
--   A disposal record edited or removed afterwards.
--
-- And one thing has to be true rather than impossible: that this feature
-- deletes nothing. There is no job, no trigger, and no cascade — checked
-- here, because "we chose not to" is exactly the kind of decision that gets
-- undone by somebody who did not know it was one.
--
-- Runs inside a transaction that is rolled back. Nothing here is left behind,
-- and no real client record is touched.

begin;

do $$
declare
  v_admin    uuid;
  v_adm_uid  uuid;
  v_other    uuid;
  v_oth_uid  uuid;
  v_role     text;
  v_old      uuid;   -- closed long ago
  v_recent   uuid;   -- closed last week
  v_undated  uuid;   -- closed, but nothing says when
  v_hold     uuid;
  v_due      boolean;
  v_until    date;
  v_count    int;
  v_id       bigint;
  failures   text[] := '{}';
begin
  select id, user_id into v_admin, v_adm_uid from public.staff
   where role = 'Admin' and active order by created_at limit 1;
  select id, user_id, role into v_other, v_oth_uid, v_role from public.staff
   where active and role <> 'Admin' order by created_at limit 1;

  -- Three closed records, arranged rather than assumed: the live data has
  -- 22 closed clients and none of them is near its period, so a test that
  -- read the real rows would assert nothing.
  -- Setting the stage writes the stage history itself, so these back-date
  -- what the trigger wrote rather than adding a second entry. Adding one was
  -- the first attempt, and it read back as closed today: the view takes the
  -- most recent closure, which is the right rule and made the fixture wrong.
  insert into public.clients (name, stage, status, assigned_staff_id)
  values ('ZZ Retention Old', 'Closed', 'Closed', v_admin) returning id into v_old;
  update public.client_stage_history
     set at = (public.practice_today() - interval '9 years')::date
   where client_id = v_old;

  insert into public.clients (name, stage, status, assigned_staff_id)
  values ('ZZ Retention Recent', 'Closed', 'Closed', v_admin) returning id into v_recent;
  update public.client_stage_history
     set at = (public.practice_today() - interval '7 days')::date
   where client_id = v_recent;

  -- Closed, with no entry saying when. The workbook import produced records
  -- like this and there will be more.
  insert into public.clients (name, stage, status, assigned_staff_id)
  values ('ZZ Retention Undated', 'Closed', 'Closed', v_admin) returning id into v_undated;
  delete from public.client_stage_history where client_id = v_undated;

  -- ── nothing is due under an unchecked period ───────────────
  update public.retention_policies
     set confirmed = false, confirmed_by = null, confirmed_at = null
   where key = 'client-record';

  select due into v_due from public.client_retention where client_id = v_old;
  if coalesce(v_due, false) then
    failures := failures || 'FAILED: a record is due under a period nobody has confirmed'::text;
  else
    raise notice 'ok  a record nine years closed is not due while the period is unconfirmed';
  end if;

  -- ── once checked, the period applies ───────────────────────
  update public.retention_policies
     set confirmed = true, confirmed_by = v_admin, confirmed_at = now()
   where key = 'client-record';

  select due, keep_until into v_due, v_until
    from public.client_retention where client_id = v_old;
  if not coalesce(v_due, false) then
    failures := failures || 'FAILED: a confirmed period never makes anything due, so the schedule does nothing'::text;
  else
    raise notice 'ok  once somebody has confirmed the period, a record past it is due (kept until %)', v_until;
  end if;

  select due into v_due from public.client_retention where client_id = v_recent;
  if coalesce(v_due, false) then
    failures := failures || 'FAILED: a record closed last week is due for destruction'::text;
  else
    raise notice 'ok  and a record closed last week is not';
  end if;

  -- ── a guessed date is not a date ───────────────────────────
  select due, keep_until into v_due, v_until
    from public.client_retention where client_id = v_undated;
  if coalesce(v_due, false) or v_until is not null then
    failures := failures || 'FAILED: a record with no closure date was given one'::text;
  else
    raise notice 'ok  a record closed on no known date has no clock — it is never due';
  end if;

  -- ── open records are not a retention question ──────────────
  if exists (select 1 from public.client_retention r
              join public.clients c on c.id = r.client_id
             where c.status = 'Active' and c.stage <> 'Closed') then
    failures := failures || 'FAILED: an open client record is listed against the schedule'::text;
  else
    raise notice 'ok  records still in use are not on the list at all';
  end if;

  -- ── a hold outranks the schedule ───────────────────────────
  insert into public.legal_holds (client_id, reason, placed_by, placed_by_name)
  values (v_old, 'Records request from the client''s attorney', v_admin, 'ZZ Admin')
  returning id into v_hold;

  select due into v_due from public.client_retention where client_id = v_old;
  if coalesce(v_due, false) then
    failures := failures || 'FAILED: a record under legal hold is still reported as due'::text;
  else
    raise notice 'ok  a legal hold takes a record off the list entirely, period or no period';
  end if;

  if (select hold_reason from public.client_retention where client_id = v_old) is null then
    failures := failures || 'FAILED: the list does not say why a held record is held'::text;
  else
    raise notice 'ok  — and says why, so nobody has to go looking';
  end if;

  -- ── recording a destruction ────────────────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);

  begin
    v_id := public.record_disposition(v_old, 'Destroyed', 'Shredded the paper file');
    failures := failures || 'FAILED: a destruction was recorded against a record under legal hold'::text;
  exception when check_violation then
    raise notice 'ok  a destruction under legal hold is refused by the database, not by a screen';
  end;

  begin
    v_id := public.record_disposition(v_recent, 'Destroyed', 'Tidying up');
    failures := failures || 'FAILED: a destruction was recorded against a record inside its period'::text;
  exception when check_violation then
    raise notice 'ok  and so is one against a record that is not past its period';
  end;

  -- Lifting the hold puts it back on the list, which is the point of lifting.
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
  update public.legal_holds
     set lifted_at = now(), lifted_by = v_admin, lifted_reason = 'The request was answered'
   where id = v_hold;

  select due into v_due from public.client_retention where client_id = v_old;
  if not coalesce(v_due, false) then
    failures := failures || 'FAILED: lifting a hold did not return the record to the schedule'::text;
  else
    raise notice 'ok  lifting a hold puts the record back on the list';
  end if;

  -- The hold itself survives being lifted. That it was placed is part of the
  -- record: an auditor asking why nothing happened for eight months needs an
  -- answer, and a deleted hold is not one.
  if not exists (select 1 from public.legal_holds where id = v_hold) then
    failures := failures || 'FAILED: lifting a hold destroyed the evidence that it existed'::text;
  else
    raise notice 'ok  and the hold survives being lifted, with both reasons';
  end if;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);

  v_id := public.record_disposition(v_old, 'Destroyed', 'Paper file shredded, CRM record kept');
  if v_id is null then
    failures := failures || 'FAILED: a proper destruction could not be recorded at all'::text;
  else
    raise notice 'ok  a destruction that is past its period and unheld is recorded';
  end if;

  if (select decided_by_name from public.retention_dispositions where id = v_id) = '' then
    failures := failures || 'FAILED: the record does not name who authorised it'::text;
  else
    raise notice 'ok  — naming who authorised it, beside the id, so it survives them leaving';
  end if;

  -- ── the record of it cannot be rewritten ───────────────────
  update public.retention_dispositions set reason = 'Something else' where id = v_id;
  get diagnostics v_count = row_count;
  if v_count <> 0 then
    failures := failures || 'FAILED: a disposal record was edited'::text;
  else
    raise notice 'ok  a disposal record cannot be edited, including by Admin';
  end if;

  delete from public.retention_dispositions where id = v_id;
  get diagnostics v_count = row_count;
  if v_count <> 0 then
    failures := failures || 'FAILED: a disposal record was deleted'::text;
  else
    raise notice 'ok  and cannot be deleted — a schedule with a deletable trail proves nothing';
  end if;

  -- ── who does any of this ───────────────────────────────────
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_oth_uid, 'role', 'authenticated')::text, true);

  begin
    v_id := public.record_disposition(v_recent, 'Kept longer', 'Because I say so');
    failures := failures || format('FAILED: %s recorded a retention decision', v_role);
  exception when insufficient_privilege then
    raise notice 'ok  only Admin records a decision';
  end;

  update public.retention_policies set keep_years = 1 where key = 'client-record';
  get diagnostics v_count = row_count;
  if v_count <> 0 then
    failures := failures || format('FAILED: %s shortened a retention period', v_role);
  else
    raise notice 'ok  and only Admin changes a period';
  end if;

  begin
    insert into public.legal_holds (client_id, reason) values (v_recent, 'mine');
    failures := failures || format('FAILED: %s placed a legal hold', v_role);
  exception when insufficient_privilege then
    raise notice 'ok  and only Admin places a hold';
  end;

  -- Reading it, though, is for everybody: a counselor asked how long a
  -- client's file is kept should be able to answer without asking the owner.
  select count(*) into v_count from public.retention_policies;
  if v_count = 0 then
    failures := failures || format('FAILED: %s cannot read the schedule at all', v_role);
  else
    raise notice 'ok  but anybody can read the schedule';
  end if;

  -- ── nothing here deletes anything ──────────────────────────
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  select count(*) into v_count from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
     and not t.tgisinternal
     and c.relname in ('retention_policies', 'retention_dispositions', 'legal_holds')
     and t.tgname not like '%updated_at%';
  if v_count <> 0 then
    failures := failures || format('FAILED: %s trigger(s) fire off the retention tables', v_count);
  else
    raise notice 'ok  no trigger fires from any of this — nothing acts on a schedule';
  end if;

  select count(*) into v_count from cron.job where command ilike '%retention%'
      or command ilike '%disposition%';
  if v_count <> 0 then
    failures := failures || format('FAILED: %s scheduled job(s) touch retention', v_count);
  else
    raise notice 'ok  and nothing is scheduled — destroying a record stays something a person does';
  end if;

  -- The client whose destruction was just recorded is still entirely there.
  -- Recording a decision is not carrying it out, and if that ever changes it
  -- should change loudly.
  if not exists (select 1 from public.clients where id = v_old) then
    failures := failures || 'FAILED: recording a disposal deleted the client record'::text;
  else
    raise notice 'ok  the record recorded as destroyed is still there — writing it down is not doing it';
  end if;

  if failures = '{}' then
    raise notice '';
    raise notice '--- RETENTION VERIFIED ---';
  else
    raise notice '';
    raise notice '%  PROBLEM(S):', array_length(failures, 1);
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
