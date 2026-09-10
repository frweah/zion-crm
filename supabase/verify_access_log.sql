-- Zion Vocational Rehab CRM — the read-access log
--
-- The claim this makes is unusually strong for a log: not "we record reads"
-- but "a restricted field cannot be read without a record". That claim is
-- only worth anything if the tables really are sealed, so most of what
-- follows is an attempt to get at them some other way.
--
-- The rest is about the log itself. A log that can be edited, deleted, or
-- written by hand proves nothing — it would just be a table somebody could
-- arrange to say whatever was needed.
--
-- Runs inside a transaction that is rolled back. Nothing here is left behind.

begin;

do $$
declare
  v_admin   uuid;
  v_adm_uid uuid;
  v_other   uuid;
  v_oth_uid uuid;
  v_client  uuid;
  v_mine    uuid;
  v_before  bigint;
  v_count   int;
  -- Columns, not records. A record variable takes the rowtype of the first
  -- thing put in it and keeps it, so the second call to a set-returning
  -- function fails with "structure of query does not match function result
  -- type" — an error that names the function and not the variable, and sends
  -- you looking in the wrong file. Naming the columns sidesteps it entirely.
  v_dob     date;
  v_addr    text;
  v_allowed boolean;
  v_accom   text;
  e         record;  -- an access_log entry, which is only ever one shape
  failures  text[] := '{}';
begin
  select id, user_id into v_admin, v_adm_uid from public.staff
   where role = 'Admin' and active order by created_at limit 1;
  select id, user_id into v_other, v_oth_uid from public.staff
   where active and id <> v_admin order by created_at limit 1;

  -- A client belonging to somebody else, so a refusal can be provoked.
  insert into public.clients (name, stage, status, assigned_staff_id)
  values ('ZZ Access Test', 'Referral', 'Active', v_admin)
  returning id into v_client;

  insert into public.client_private (client_id, dob, address)
  values (v_client, date '1990-05-05', '1 ZZ Street, Salt Lake City');

  -- ── the table is sealed ────────────────────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);

  begin
    perform 1 from public.client_private where client_id = v_client;
    failures := failures || 'FAILED: client_private can still be read directly'::text;
  exception when insufficient_privilege then
    raise notice 'ok  nobody signed in can read client_private directly, Admin included';
  end;

  begin
    perform 1 from public.intakes where client_id = v_client;
    failures := failures || 'FAILED: intakes can still be read directly'::text;
  exception when insufficient_privilege then
    raise notice 'ok  and the same for intakes';
  end;

  -- ── the door writes the log ────────────────────────────────
  select count(*) into v_before from public.access_log;

  select dob, allowed into v_dob, v_allowed
    from public.read_client_private(v_client, 'ZZ shown on the client record');
  if v_dob is distinct from date '1990-05-05' or not v_allowed then
    failures := failures || 'FAILED: the reader did not return the row to somebody allowed it'::text;
  else
    raise notice 'ok  somebody who may see it, does';
  end if;

  if (select count(*) from public.access_log) <> v_before + 1 then
    failures := failures || 'FAILED: reading restricted details wrote no log entry'::text;
  else
    raise notice 'ok  and reading it wrote an entry, as part of handing it over';
  end if;

  select * into e from public.access_log order by id desc limit 1;
  if e.subject <> 'Client restricted details' or e.client_id is distinct from v_client then
    failures := failures || 'FAILED: the entry does not say what was read, or whose'::text;
  elsif e.staff_name = '' or e.staff_role = '' then
    failures := failures || 'FAILED: the entry does not say who read it'::text;
  elsif e.purpose <> 'ZZ shown on the client record' then
    failures := failures || format('FAILED: the purpose reads "%s"', e.purpose);
  else
    raise notice 'ok  it says who, what, whose and why';
  end if;

  -- ── a refusal is recorded too ──────────────────────────────
  -- Somebody opening a file they have no business in is the entry most worth
  -- having, and the one a log built only on successes would miss.
  -- Anybody whose role is not Admin or Reports, and who is not assigned this
  -- client, is refused — that is what can_see_restricted says.
  select id, user_id into v_other, v_oth_uid from public.staff
   where active and role not in ('Admin', 'Reports') and id <> v_admin
   order by created_at limit 1;

  if v_other is not null then
    perform set_config('request.jwt.claims',
                       json_build_object('sub', v_oth_uid, 'role', 'authenticated')::text, true);

    -- Counted as Admin on both sides. Counting it as them would always read
    -- zero — they cannot see the log — and the check would pass by accident
    -- while proving nothing.
    perform set_config('request.jwt.claims',
                       json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);
    select count(*) into v_count from public.access_log;

    perform set_config('request.jwt.claims',
                       json_build_object('sub', v_oth_uid, 'role', 'authenticated')::text, true);
    select address, allowed into v_addr, v_allowed
      from public.read_client_private(v_client, 'ZZ tried it on');

    perform set_config('request.jwt.claims',
                       json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);

    if v_allowed then
      failures := failures || 'FAILED: somebody without access was given the details'::text;
    elsif (select count(*) from public.access_log) <> v_count + 1 then
      failures := failures || 'FAILED: a refused read left no trace'::text;
    else
      raise notice 'ok  a refused read is recorded, which is the entry that matters most';
    end if;
  else
    raise notice 'note  every active account is Admin or Intake & Reports, so no refusal could be provoked';
  end if;

  -- ── an intake is the same ──────────────────────────────────
  perform public.save_intake(v_client, '{"phone": "801-555-0000", "accommodations": "ZZ quiet room"}'::jsonb);

  select count(*) into v_count from public.access_log;
  select accommodations into v_accom
    from public.read_client_intake(v_client, 'ZZ opened the intake tab');
  if v_accom is distinct from 'ZZ quiet room' then
    failures := failures || 'FAILED: the intake reader did not return the intake'::text;
  elsif (select count(*) from public.access_log) <> v_count + 1 then
    failures := failures || 'FAILED: reading an intake wrote no log entry'::text;
  else
    raise notice 'ok  an intake reads the same way, and writes the same entry';
  end if;

  -- Saving one is not reading one: writing an entry every time somebody typed
  -- into the form would bury the reads that matter.
  select count(*) into v_count from public.access_log;
  perform public.save_intake(v_client, '{"phone": "801-555-0001"}'::jsonb);
  if (select count(*) from public.access_log) <> v_count then
    failures := failures || 'FAILED: saving an intake counted as reading one'::text;
  else
    raise notice 'ok  saving an intake is not reading one';
  end if;

  -- ── the log cannot be arranged ─────────────────────────────
  begin
    perform public.log_access('Client intake', v_client, null, 'ZZ written by hand');
    failures := failures || 'FAILED: an entry can be written by hand'::text;
  exception when insufficient_privilege then
    raise notice 'ok  nobody can write an entry by hand — a log that can be is evidence of nothing';
  end;

  begin
    insert into public.access_log (staff_name, subject, purpose)
    values ('ZZ', 'Client intake', 'ZZ straight in');
    failures := failures || 'FAILED: an entry was inserted straight into the table'::text;
  exception when insufficient_privilege then
    raise notice 'ok  and there is no insert policy to go round it with';
  end;

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  begin
    update public.access_log set purpose = 'ZZ rewritten' where id = (select max(id) from public.access_log);
    failures := failures || 'FAILED: an entry was edited'::text;
  exception when check_violation then
    raise notice 'ok  an entry cannot be edited, even by the owner';
  end;

  begin
    delete from public.access_log where id = (select max(id) from public.access_log);
    failures := failures || 'FAILED: an entry was deleted'::text;
  exception when check_violation then
    raise notice 'ok  and cannot be deleted';
  end;

  -- ── who may read the log ───────────────────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_oth_uid, 'role', 'authenticated')::text, true);

  select count(*) into v_count from public.access_log;
  if v_count <> 0 then
    failures := failures || format('FAILED: somebody who is not Admin can read %s entries', v_count);
  else
    raise notice 'ok  only Admin reads the log';
  end if;

  -- ── who it says did it ─────────────────────────────────────
  -- The name is kept beside the id because a person who leaves is deactivated
  -- and may one day be deleted, and "who read this file" must survive that.
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  if exists (select 1 from public.access_log where staff_name = '') then
    failures := failures || 'FAILED: an entry does not carry the name of who made it'::text;
  else
    raise notice 'ok  every entry carries the name, not only the link to a row that may go';
  end if;

  if failures = '{}' then
    raise notice '';
    raise notice '--- READ-ACCESS LOG VERIFIED ---';
  else
    raise notice '';
    raise notice '%  PROBLEM(S):', array_length(failures, 1);
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
