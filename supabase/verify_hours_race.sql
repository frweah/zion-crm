-- Zion Vocational Rehab CRM — two people logging hours at once (0208)
--
-- The bug: check_entry_hours counted the hours used and then decided whether
-- one more entry fitted, with nothing holding the authorization still in
-- between. Two people logging at the same moment both read the same figure,
-- both found room, and both got in - and the practice ended up with hours it
-- cannot bill, discovered at submission, after the work was done.
--
-- What this script can and cannot say, plainly:
--
--   It cannot reproduce the race. A race needs two sessions and this suite
--   runs in one, and a single session never waits for itself.
--
--   It cannot watch the lock either. The obvious trick - a row locked by
--   this transaction carries its id in xmax - does not work here, because
--   inserting a service entry takes a FOR KEY SHARE lock on its
--   authorization for the foreign key anyway. xmax is set either way, so an
--   assertion built on it passes whether the fix is present or not. That
--   version of this script was written, passed, and was thrown away.
--
-- So the race itself is proved behaviourally, with two real connections, by
-- scripts/check-hours-race.mjs - which also checks that two sessions working
-- on *different* authorizations do not wait for each other, so the waiting
-- it sees is about the authorization and not about contention in general.
--
-- What is left for here is the part that is about the rule rather than the
-- mechanism, plus one structural assertion that is honestly labelled as one:
--
--   The cap holds at its boundary, in both directions.
--
--   It is counted across the coaching family, so two months cannot each fill
--   the same parent.
--
--   And the authorization is locked *before* its hours are counted rather
--   than after, which is the whole of the fix. That is read from the
--   function's own text, because the behaviour needs the second session.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_client  uuid;
  v_staff   uuid;
  v_auth    uuid;
  v_parent  uuid;
  v_month   uuid;
  v_month2  uuid;
  v_def     text;
  v_lock    integer;
  v_count   integer;
  v_used    numeric;
  failures  text[] := '{}';
begin
  insert into public.staff (name, email, role, active)
  values ('ZZ Race Admin', 'zz-race@example.test', 'Admin', true) returning id into v_staff;
  insert into public.clients (name, stage, status) values ('ZZ Race Client', 'Placement', 'Active')
  returning id into v_client;

  -- ── the lock is taken, and taken before the counting ──────
  v_def := lower(pg_get_functiondef('public.check_entry_hours()'::regprocedure));
  v_lock := position('for update' in v_def);
  v_count := position('authorization_hours_used' in v_def);

  if v_lock = 0 then
    failures := failures || 'FAILED: check_entry_hours does not hold the authorization at all'::text;
  elsif v_count = 0 then
    failures := failures || 'FAILED: check_entry_hours no longer counts through authorization_hours_used'::text;
  elsif v_lock > v_count then
    failures := failures ||
      'FAILED: check_entry_hours counts the hours before it holds the authorization, which is the race it is meant to close'::text;
  else
    raise notice 'ok  the authorization is held before its hours are counted, not after';
  end if;

  -- ── the cap, at its boundary, both ways ───────────────────
  insert into public.authorizations (client_id, number, service_type, rate_type, rate,
                                     total_hours, start_date, end_date, received_on)
  values (v_client, 'ZZ-R-1', 'WSA Tier 1', 'Hourly', 50, 10,
          public.practice_today() - 10, public.practice_today() + 10, public.practice_today() - 10)
  returning id into v_auth;

  insert into public.service_entries (auth_id, date, hours, staff_id, notes)
  values (v_auth, public.practice_today() - 1, 10, v_staff, 'ZZ exactly the cap');
  raise notice 'ok  an entry that fills the authorization exactly goes in';

  begin
    insert into public.service_entries (auth_id, date, hours, staff_id, notes)
    values (v_auth, public.practice_today() - 1, 0.25, v_staff, 'ZZ one quarter hour over');
    failures := failures || 'FAILED: a quarter of an hour went in on an authorization with nothing left'::text;
  exception when check_violation then
    raise notice 'ok  and a quarter of an hour more is refused';
  end;

  -- ── counted across the family, so two months cannot each fill the parent ──
  insert into public.authorizations (client_id, number, service_type, rate_type, rate,
                                     total_hours, start_date, end_date, received_on)
  values (v_client, 'ZZ-R-2', 'Job Coaching', 'Hourly', 45, 12,
          public.practice_today() - 70, public.practice_today() + 70, public.practice_today() - 65)
  returning id into v_parent;

  insert into public.authorizations (client_id, parent_id, service_type, rate_type, rate,
                                     period, start_date, end_date, received_on)
  values (v_client, v_parent, 'Job Coaching', 'Hourly', 45,
          date_trunc('month', public.practice_today())::date,
          public.practice_today() - 20, public.practice_today() + 20, public.practice_today() - 20)
  returning id into v_month;

  insert into public.authorizations (client_id, parent_id, service_type, rate_type, rate,
                                     period, start_date, end_date, received_on)
  values (v_client, v_parent, 'Job Coaching', 'Hourly', 45,
          (date_trunc('month', public.practice_today()) - interval '1 month')::date,
          public.practice_today() - 50, public.practice_today() - 21, public.practice_today() - 50)
  returning id into v_month2;

  insert into public.service_entries (auth_id, date, hours, staff_id, notes)
  values (v_month, public.practice_today() - 1, 8, v_staff, 'ZZ this month');

  select used into v_used from public.authorization_hours_used(array[v_month2]) u;
  if coalesce(v_used, -1) <> 8 then
    failures := failures || format('FAILED: the other month sees %s hours used, not the family''s 8', v_used)::text;
  else
    raise notice 'ok  a second month sees the hours already logged on the first';
  end if;

  begin
    insert into public.service_entries (auth_id, date, hours, staff_id, notes)
    values (v_month2, public.practice_today() - 30, 5, v_staff, 'ZZ last month, over the family cap');
    failures := failures ||
      'FAILED: 8 hours on one month and 5 on another went in under a 12-hour parent'::text;
  exception when check_violation then
    raise notice 'ok  and cannot fill the same parent a second time through another month';
  end;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- HOURS RACE VERIFIED (the race itself: scripts/check-hours-race.mjs) ---';
end $$;

rollback;
