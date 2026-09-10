-- Zion Vocational Rehab CRM — certifications and clearances
--
-- The thing this has to get right is the boundary between valid and not, on
-- a particular day. "Expiring" that comes too late is the same as no warning
-- at all, and "Expired" that arrives a day early has somebody chasing a card
-- that is still good.
--
-- The other half is who is required to hold what. A job coach who does not
-- drive should never appear on a list of people missing vehicle insurance,
-- and an administrator who does should.
--
-- Runs inside a transaction that is rolled back. Nothing here is left behind.

begin;

do $$
declare
  v_admin   uuid;
  v_adm_uid uuid;
  v_other   uuid;
  v_oth_uid uuid;
  v_state   text;
  v_days    int;
  v_hours   numeric;
  v_count   int;
  failures  text[] := '{}';
begin
  select id, user_id into v_admin, v_adm_uid from public.staff
   where role = 'Admin' and active order by created_at limit 1;
  select id, user_id into v_other, v_oth_uid from public.staff
   where active and id <> v_admin order by created_at limit 1;

  -- ── nothing on file is missing, not valid ──────────────────
  select state into v_state from public.staff_credential_status
   where staff_id = v_admin and type_key = 'cpr';
  if v_state <> 'Missing' then
    failures := failures || format('FAILED: with no CPR card on file the state reads "%s"', v_state);
  else
    raise notice 'ok  a credential nobody has recorded is Missing, not Valid';
  end if;

  -- ── the boundary, on both sides of it ──────────────────────
  -- A card that runs out today is still good today.
  insert into public.staff_credentials (staff_id, type_key, issued_on, expires_on, created_by)
  values (v_admin, 'cpr', public.practice_today() - 700, public.practice_today(), v_admin);

  select state, days_left into v_state, v_days from public.staff_credential_status
   where staff_id = v_admin and type_key = 'cpr';
  if v_state = 'Expired' then
    failures := failures || 'FAILED: a card that runs out today reads as already expired'::text;
  elsif v_days <> 0 then
    failures := failures || format('FAILED: a card expiring today has %s days left', v_days);
  else
    raise notice 'ok  a card that runs out today is still good today';
  end if;

  -- And yesterday's is not.
  update public.staff_credentials set expires_on = public.practice_today() - 1
   where staff_id = v_admin and type_key = 'cpr';

  select state into v_state from public.staff_credential_status
   where staff_id = v_admin and type_key = 'cpr';
  if v_state <> 'Expired' then
    failures := failures || format('FAILED: a card that ran out yesterday reads as "%s"', v_state);
  else
    raise notice 'ok  and yesterday''s is expired';
  end if;

  -- ── the warning arrives before the day ─────────────────────
  -- CPR warns at 60 days: 59 days out is Expiring, 61 is still just Valid.
  update public.staff_credentials set expires_on = public.practice_today() + 59
   where staff_id = v_admin and type_key = 'cpr';
  select state into v_state from public.staff_credential_status
   where staff_id = v_admin and type_key = 'cpr';
  if v_state <> 'Expiring' then
    failures := failures || format('FAILED: 59 days from expiry reads as "%s"', v_state);
  else
    raise notice 'ok  two months out, it starts saying so';
  end if;

  update public.staff_credentials set expires_on = public.practice_today() + 61
   where staff_id = v_admin and type_key = 'cpr';
  select state into v_state from public.staff_credential_status
   where staff_id = v_admin and type_key = 'cpr';
  if v_state <> 'Valid' then
    failures := failures || format('FAILED: 61 days from expiry reads as "%s"', v_state);
  else
    raise notice 'ok  and before that it does not nag';
  end if;

  -- ── a renewal is a new row, and the newer one wins ─────────
  insert into public.staff_credentials (staff_id, type_key, issued_on, expires_on, created_by)
  values (v_admin, 'cpr', public.practice_today(), public.practice_today() + 730, v_admin);

  select state, count(*) over () into v_state, v_count
    from public.staff_credential_status
   where staff_id = v_admin and type_key = 'cpr';
  if v_state <> 'Valid' then
    failures := failures || format('FAILED: after renewing, CPR reads "%s"', v_state);
  else
    raise notice 'ok  a renewal is recorded beside the old card and is the one that counts';
  end if;

  if (select count(*) from public.staff_credentials
       where staff_id = v_admin and type_key = 'cpr') <> 2 then
    failures := failures || 'FAILED: the superseded card did not stay on file'::text;
  else
    raise notice 'ok  and the old one stays — "were they covered in March" needs both';
  end if;

  -- ── one line per credential, however many are on file ──────
  if (select count(*) from public.staff_credential_status
       where staff_id = v_admin and type_key = 'cpr') <> 1 then
    failures := failures || 'FAILED: two cards produced two rows on the status view'::text;
  else
    raise notice 'ok  two cards, one line — a caseload screen has room for one answer';
  end if;

  -- ── a credential that does not expire ──────────────────────
  insert into public.staff_credentials (staff_id, type_key, issued_on, created_by)
  values (v_admin, 'acre', public.practice_today() - 3000, v_admin);

  select state into v_state from public.staff_credential_status
   where staff_id = v_admin and type_key = 'acre';
  if v_state <> 'Valid' then
    failures := failures || format('FAILED: an ACRE certificate from 2018 reads as "%s"', v_state);
  else
    raise notice 'ok  a certificate that does not expire does not expire';
  end if;

  -- ── who has to hold what ───────────────────────────────────
  if exists (
    select 1 from public.staff_credential_status
     where staff_id = v_admin and type_key = 'insurance'
  ) then
    failures := failures || 'FAILED: somebody who does not drive is asked for insurance'::text;
  else
    raise notice 'ok  somebody who does not transport clients is not asked for insurance';
  end if;

  insert into public.staff_employment (staff_id, transports_clients)
  values (v_admin, true)
  on conflict (staff_id) do update set transports_clients = true;

  select state into v_state from public.staff_credential_status
   where staff_id = v_admin and type_key = 'insurance';
  if v_state is distinct from 'Missing' then
    failures := failures || format('FAILED: a driver''s insurance reads as "%s"', coalesce(v_state, 'absent'));
  else
    raise notice 'ok  and the moment they do, a licence and insurance are required of them';
  end if;

  -- ── something held but not required still shows ────────────
  update public.staff_employment set transports_clients = false where staff_id = v_admin;
  insert into public.staff_credentials (staff_id, type_key, issued_on, expires_on, created_by)
  values (v_admin, 'insurance', public.practice_today(), public.practice_today() + 365, v_admin);

  select state, required into v_state, v_count from (
    select state, case when required then 1 else 0 end as required
      from public.staff_credential_status
     where staff_id = v_admin and type_key = 'insurance'
  ) x;
  if v_state is null then
    failures := failures || 'FAILED: a credential somebody holds vanished because nobody requires it'::text;
  elsif v_count <> 0 then
    failures := failures || 'FAILED: insurance is still marked required of a non-driver'::text;
  else
    raise notice 'ok  something held without being required stays on the record, marked as such';
  end if;

  -- ── hours, which are not a card ────────────────────────────
  insert into public.ce_entries (staff_id, on_date, hours, topic, created_by)
  values (v_admin, public.practice_today(), 12, 'ZZ supported employment', v_admin);

  select state, hours_this_year into v_state, v_hours
    from public.staff_credential_status where staff_id = v_admin and type_key = 'ce';
  if v_hours <> 12 then
    failures := failures || format('FAILED: 12 hours logged reads as %s', v_hours);
  elsif v_state <> 'Outstanding' then
    failures := failures || format('FAILED: 12 of 20 hours reads as "%s"', v_state);
  else
    raise notice 'ok  hours accumulate, and 12 of 20 is still outstanding';
  end if;

  insert into public.ce_entries (staff_id, on_date, hours, topic, created_by)
  values (v_admin, public.practice_today(), 8, 'ZZ ethics', v_admin);

  select state into v_state from public.staff_credential_status
   where staff_id = v_admin and type_key = 'ce';
  if v_state <> 'Met' then
    failures := failures || format('FAILED: 20 of 20 hours reads as "%s"', v_state);
  else
    raise notice 'ok  and 20 of 20 is met';
  end if;

  -- Last year's hours are last year's.
  insert into public.ce_entries (staff_id, on_date, hours, topic, created_by)
  values (v_admin, date_trunc('year', public.practice_today())::date - 30, 40,
          'ZZ last year', v_admin);

  select hours_this_year into v_hours from public.staff_credential_status
   where staff_id = v_admin and type_key = 'ce';
  if v_hours <> 20 then
    failures := failures || format('FAILED: last year''s hours counted towards this year (%s)', v_hours);
  else
    raise notice 'ok  last year''s training does not count towards this year';
  end if;

  -- ── whose business it is ───────────────────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_oth_uid, 'role', 'authenticated')::text, true);

  select count(*) into v_count from public.staff_credentials where staff_id = v_admin;
  if v_count <> 0 then
    failures := failures || format('FAILED: a colleague can see %s of somebody else''s credentials', v_count);
  else
    raise notice 'ok  a colleague cannot see somebody else''s CPR card';
  end if;

  begin
    insert into public.staff_credentials (staff_id, type_key, expires_on, created_by)
    values (v_other, 'cpr', public.practice_today() + 365, v_other);
    failures := failures || 'FAILED: somebody recorded their own credential'::text;
  exception when insufficient_privilege then
    raise notice 'ok  nobody records their own credential — that is not a check, it is a claim';
  end;

  -- But their own hours are theirs to log.
  insert into public.ce_entries (staff_id, on_date, hours, topic, created_by)
  values (v_other, public.practice_today(), 3, 'ZZ own hours', v_other);
  raise notice 'ok  their own training hours are theirs to log — they were the one in the room';

  begin
    insert into public.ce_entries (staff_id, on_date, hours, topic, created_by)
    values (v_admin, public.practice_today(), 3, 'ZZ somebody else''s', v_other);
    failures := failures || 'FAILED: somebody logged hours against a colleague'::text;
  exception when insufficient_privilege then
    raise notice 'ok  and not against somebody else';
  end;

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  -- ── the attention list is ordered by urgency ───────────────
  if exists (
    select 1 from public.credential_attention where state not in
      ('Expired', 'Missing', 'Expiring', 'Outstanding')
  ) then
    failures := failures || 'FAILED: something valid is on the list of things needing attention'::text;
  else
    raise notice 'ok  the attention list holds only what needs attention';
  end if;

  if failures = '{}' then
    raise notice '';
    raise notice '--- CERTIFICATIONS VERIFIED ---';
  else
    raise notice '';
    raise notice '%  PROBLEM(S):', array_length(failures, 1);
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
