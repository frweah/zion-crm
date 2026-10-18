-- Zion Vocational Rehab CRM — submitting locks the day last
-- (owner, 18 Oct 2026)
--
-- submit_staff_day set submitted_at, then walked the client lines writing
-- each one to that client's contact log and noting on the line which entry it
-- wrote. That last step is an update to a line on a day that had just been
-- locked, so the lock refused it and submitting a day with a client on it
-- failed with "That day has been submitted. Reopen it first if it needs
-- changing." - the day's own guard, refusing the day's own submission.
--
-- Found by verify_end_of_day.sql on the first run, which is what it is for.
--
-- The order is the fix: do the work while the day is still open, and close it
-- last. Nothing else changes.

create or replace function public.submit_staff_day(p_day_id uuid)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_me   uuid := public.current_staff_id();
  v_day  public.staff_days%rowtype;
  v_n    integer;
  r      record;
  v_log  uuid;
begin
  select * into v_day from public.staff_days where id = p_day_id for update;
  if not found then
    raise exception 'That day is not on file.' using errcode = 'no_data_found';
  end if;
  if v_day.staff_id is distinct from v_me then
    raise exception 'A day is submitted by the person whose day it is.'
      using errcode = 'insufficient_privilege';
  end if;
  if v_day.submitted_at is not null then
    raise exception 'That day has already been submitted.' using errcode = 'check_violation';
  end if;

  select count(*) into v_n from public.staff_day_lines where day_id = p_day_id;
  if v_n = 0 then
    raise exception 'A day needs at least one line before it is submitted.'
      using errcode = 'check_violation';
  end if;

  -- Every line about a client, on that client's record - while the day is
  -- still open, because noting the entry on the line is itself a change to
  -- the line.
  for r in
    select l.id, l.client_id, l.status, l.description, l.notes
      from public.staff_day_lines l
     where l.day_id = p_day_id
       and l.client_id is not null
       and l.contact_log_id is null
     order by l.sort_order
  loop
    insert into public.contact_log (client_id, date, method, topic, outcome, staff_id)
    values (r.client_id, v_day.day, 'End of day report',
            r.description,
            case when nullif(r.notes, '') is null then r.status
                 else r.status || ' - ' || r.notes end,
            v_me)
    returning id into v_log;

    update public.staff_day_lines set contact_log_id = v_log where id = r.id;
  end loop;

  -- And now it is closed. The role and the manager are kept as they are
  -- today, so the report reads the way it read when it was written.
  update public.staff_days sd
     set submitted_at = now(),
         role_at_time = coalesce(nullif(sd.role_at_time, ''), s.role),
         manager_id   = coalesce(sd.manager_id, s.manager_id)
    from public.staff s
   where sd.id = p_day_id and s.id = sd.staff_id;

  insert into public.staff_day_events (day_id, action, by_staff) values (p_day_id, 'Submitted', v_me);

  perform public.notify_staff_day(p_day_id);

  return public.staff_day_summary(p_day_id);
end;
$$;

revoke all on function public.submit_staff_day(uuid) from anon, authenticated;
grant execute on function public.submit_staff_day(uuid) to authenticated;

do $$
begin
  raise notice 'ok  a day is locked after its lines are filed, not before';
end $$;
