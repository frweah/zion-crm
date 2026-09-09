-- ─────────────────────────────────────────────────────────────
-- 0036 — today, in Utah.
--
-- current_date on Supabase is a date in UTC. Every date in this system means a
-- day in Utah: the day a visit happened, the day somebody was hired, the day a
-- reminder is due. Between six in the evening and midnight the two disagree,
-- and everything stamped in that window has been landing on tomorrow.
--
-- Found while wiring the job reminders, which stamp dates the same way. The
-- application half is fixed in lib/constants.ts; this is the database half.
-- ─────────────────────────────────────────────────────────────

create or replace function public.practice_today()
returns date language sql stable as $$
  select (now() at time zone 'America/Denver')::date;
$$;

comment on function public.practice_today() is
  'The current date where the practice is, which is not where the server is.';

grant execute on function public.practice_today() to authenticated, service_role;

-- The reminder helper stamps a completion date; it should be the day the
-- person pressed the button, in their own evening.
create or replace function public.answer_reminder(
  p_task_id uuid,
  p_status  text,
  p_outcome text default ''
)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_match uuid;
begin
  if public.current_staff_id() is null then
    raise exception 'You are not signed in.' using errcode = 'insufficient_privilege';
  end if;

  select source_match_id into v_match from public.tasks where id = p_task_id;
  if v_match is null then
    raise exception 'That task did not come from a job.' using errcode = 'check_violation';
  end if;

  if p_status is not null and p_status <> '' then
    update public.lead_matches
       set status  = p_status,
           outcome = case when coalesce(p_outcome, '') = '' then outcome else p_outcome end
     where id = v_match;
  elsif coalesce(p_outcome, '') <> '' then
    update public.lead_matches set outcome = p_outcome where id = v_match;
  end if;

  update public.tasks
     set status = 'Done', done_at = public.practice_today()
   where id = p_task_id;
end;
$$;

revoke execute on function public.answer_reminder(uuid, text, text) from public;
grant execute on function public.answer_reminder(uuid, text, text) to authenticated;
