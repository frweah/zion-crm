-- Zion Vocational Rehab CRM — the agent account writes no days
-- (owner, 18 Oct 2026)
--
-- The system account reads so the automations can work and writes nothing a
-- person would be accountable for. Three new tables arrived with the end of
-- the day and none of them had been told, which verify_system_account.sql
-- caught on the first run after they were added - as it did for
-- staff_record_changes in 0199 and client_document_events in 0202.
--
-- An end-of-day report is a person writing about their own work. It is the
-- last thing an account with no person behind it should be able to file.

select public.apply_system_read_only('staff_days');
select public.apply_system_read_only('staff_day_lines');
select public.apply_system_read_only('staff_day_events');

do $$
declare v_n integer;
begin
  select count(*) into v_n from pg_policies
   where schemaname = 'public'
     and tablename in ('staff_days', 'staff_day_lines', 'staff_day_events')
     and policyname like 'system_read_only_%';
  if v_n <> 9 then
    raise exception 'Expected nine restrictive policies across the three tables, found %.', v_n;
  end if;
  raise notice 'ok  the system account cannot write a day, a line or an event';
end $$;
