-- Zion Vocational Rehab CRM — categories on work sessions
--
-- A time record is evidence. Adding a field to it is a chance to quietly
-- weaken that: if a category can be changed after the fact, then so can the
-- story the record tells, and the append-only rule becomes a rule about some
-- of the columns.
--
-- One door is open on purpose. Work logged before categories existed has none,
-- and a blank may be filled in. It may never be changed to something else.
--
-- Runs inside a transaction that is rolled back. Nothing here is left behind.

begin;

do $$
declare
  v_staff  uuid;
  v_uid    uuid;
  v_id     uuid;
  v_hours  numeric;
  v_count  int;
  failures text[] := '{}';
begin
  select id, user_id into v_staff, v_uid from public.staff
   where role = 'Admin' and active order by created_at limit 1;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);

  -- ── a category is optional ─────────────────────────────────
  -- An hour without one is still an hour. Refusing it would lose the hour and
  -- gain nothing.
  insert into public.work_sessions (staff_id, worked_on, hours, description, created_by)
  values (v_staff, public.practice_today(), 2, 'ZZ uncategorised', v_staff)
  returning id into v_id;
  raise notice 'ok  an hour with no category is still logged';

  -- ── a blank may be filled in ───────────────────────────────
  -- Asserted on the value rather than on an exception: work_sessions has no
  -- general update policy, so a refused update changes nothing and raises
  -- nothing. An "is distinct from" here, because a null compared with a string
  -- is neither equal nor unequal, and a check written the obvious way passes
  -- while the update does nothing at all. That is how this script first
  -- reported a door open that was shut.
  update public.work_sessions set category = 'direct' where id = v_id;
  if (select category from public.work_sessions where id = v_id) is distinct from 'direct' then
    failures := failures || 'FAILED: a blank category could not be filled in'::text;
  else
    raise notice 'ok  a blank category can be filled in later — the one door left open';
  end if;

  -- ── and never changed afterwards ───────────────────────────
  update public.work_sessions set category = 'admin' where id = v_id;
  if (select category from public.work_sessions where id = v_id) is distinct from 'direct' then
    failures := failures || 'FAILED: a category was changed after it was set'::text;
  else
    raise notice 'ok  once set, a category cannot be changed by the person who set it';
  end if;

  update public.work_sessions set hours = 5 where id = v_id;
  if (select hours from public.work_sessions where id = v_id) is distinct from 2 then
    failures := failures || 'FAILED: hours became editable'::text;
  else
    raise notice 'ok  the hours are still not editable — 0047 did not loosen that';
  end if;

  -- ── and the trigger refuses even without RLS in the way ────
  -- The policy decides which rows may be touched; the trigger decides what may
  -- change. Checked separately, because a rule enforced only by the first
  -- would evaporate the day anything runs as an owner.
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  begin
    update public.work_sessions set category = 'admin' where id = v_id;
    failures := failures || 'FAILED: the trigger allowed a category to be rewritten'::text;
  exception when check_violation then
    raise notice 'ok  the trigger refuses it too, not only the policy';
  end;

  begin
    update public.work_sessions set hours = 5 where id = v_id;
    failures := failures || 'FAILED: the trigger allowed the hours to be edited'::text;
  exception when check_violation then
    raise notice 'ok  and still refuses an edit to the hours themselves';
  end;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);

  -- ── only a real category ───────────────────────────────────
  begin
    insert into public.work_sessions (staff_id, worked_on, hours, description, category, created_by)
    values (v_staff, public.practice_today(), 1, 'ZZ invented', 'sunbathing', v_staff);
    failures := failures || 'FAILED: an invented category was accepted'::text;
  exception when foreign_key_violation then
    raise notice 'ok  a category has to be one that exists';
  end;

  -- ── the roll-up counts what is there ───────────────────────
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  insert into public.work_sessions (staff_id, worked_on, hours, description, category, created_by)
  values (v_staff, public.practice_today(), 3, 'ZZ travel', 'travel', v_staff),
         (v_staff, public.practice_today(), 1, 'ZZ nothing said', null, v_staff);

  select hours into v_hours from public.work_hours_by_category
   where staff_id = v_staff
     and month = to_char(public.practice_today(), 'YYYY-MM')
     and category = 'uncategorised';
  if coalesce(v_hours, 0) < 1 then
    failures := failures || 'FAILED: hours with no category vanished from the roll-up'::text;
  else
    raise notice 'ok  hours with no category are grouped as uncategorised, not dropped';
  end if;

  select billable into v_count from (
    select case when billable then 1 else 0 end as billable
      from public.work_hours_by_category
     where staff_id = v_staff
       and month = to_char(public.practice_today(), 'YYYY-MM')
       and category = 'travel'
  ) x;
  if v_count <> 0 then
    failures := failures || 'FAILED: travel is counted as time that reaches a client'::text;
  else
    raise notice 'ok  travel is paid time that does not reach a client, and says so';
  end if;

  -- ── a correction takes its category with it ────────────────
  -- The superseded row stops counting, so its category must stop counting too,
  -- or a corrected afternoon shows up in two categories at once.
  insert into public.work_sessions (staff_id, worked_on, hours, description, category,
                                    corrects_id, correction_reason, created_by)
  values (v_staff, public.practice_today(), 2, 'ZZ uncategorised', 'documentation',
          v_id, 'ZZ it was writing up, not a visit', v_staff);

  select count(*) into v_count from public.work_session_values where id = v_id;
  if v_count <> 0 then
    failures := failures || 'FAILED: a superseded session still counts towards the split'::text;
  else
    raise notice 'ok  a corrected session leaves the split entirely — no hour in two categories';
  end if;

  select hours into v_hours from public.work_hours_by_category
   where staff_id = v_staff
     and month = to_char(public.practice_today(), 'YYYY-MM')
     and category = 'direct';
  if coalesce(v_hours, 0) <> 0 then
    failures := failures || format('FAILED: the corrected direct hours still read as %s', v_hours);
  else
    raise notice 'ok  and the correction lands in the category it was corrected to';
  end if;

  -- ── statements still add up ────────────────────────────────
  -- 0047 rebuilt work_session_values, and contractor_statement_totals reads it.
  if not exists (
    select 1 from information_schema.views
     where table_schema = 'public' and table_name = 'contractor_statement_totals'
  ) then
    failures := failures || 'FAILED: statement totals did not survive the view rebuild'::text;
  else
    raise notice 'ok  statement totals survived the rebuild of the view underneath them';
  end if;

  if failures = '{}' then
    raise notice '';
    raise notice '--- HOUR CATEGORIES VERIFIED ---';
  else
    raise notice '';
    raise notice '%  PROBLEM(S):', array_length(failures, 1);
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
