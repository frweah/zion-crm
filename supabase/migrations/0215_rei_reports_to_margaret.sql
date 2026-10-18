-- Zion Vocational Rehab CRM — Rei reports to Margaret
-- (owner, 18 Oct 2026)
--
-- The first manager the staff list has had. Until now manager_id was empty on
-- everybody, so every end-of-day summary went to Admin alone.
--
-- What it does, so it is not a surprise:
--
--   Rei's day summaries go to Margaret as well as to Admin, on her bell and
--   on her My day.
--
--   Margaret can read Rei's days - the ones he has submitted and the one he
--   is part way through - because day_is_mine_to_see (0211) lets a manager
--   read the days of the people who report to them. Nothing else about Rei's
--   record opens to her.
--
--   Margaret gets "End of day — team" in her sidebar under HR, which she did
--   not have, because she now manages somebody. Her role is Reports and that
--   has not changed.
--
-- Matched by name against the active staff list, and refused if either of
-- them is not there or is not unique - a migration that silently does nothing
-- is worse than one that stops.

do $$
declare
  v_rei      uuid;
  v_margaret uuid;
begin
  select id into strict v_rei from public.staff
   where name = 'Rei Ruzzel' and active and not is_system;

  select id into strict v_margaret from public.staff
   where name = 'Margaret Paasa' and active and not is_system;

  update public.staff set manager_id = v_margaret where id = v_rei;

  raise notice 'ok  % reports to %',
    (select name from public.staff where id = v_rei),
    (select name from public.staff where id = v_margaret);
exception
  when no_data_found then
    raise exception 'One of them is not on the active staff list; nothing was changed.';
  when too_many_rows then
    raise exception 'That name is on the staff list more than once; nothing was changed.';
end $$;

do $$
declare v_n integer;
begin
  select count(*) into v_n from public.staff r
    join public.staff m on m.id = r.manager_id
   where r.name = 'Rei Ruzzel' and m.name = 'Margaret Paasa';
  if v_n <> 1 then
    raise exception 'The manager did not take.';
  end if;
  -- And nobody manages themselves, here or anywhere.
  select count(*) into v_n from public.staff where manager_id = id;
  if v_n > 0 then
    raise exception '% person(s) are their own manager.', v_n;
  end if;
  raise notice 'ok  and nobody on the list is their own manager';
end $$;
