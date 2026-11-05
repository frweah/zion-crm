-- The clock says when, not only how long
--
-- The Time clock has been a task timer. `work_session_timers` holds one
-- running timer per person - staff_id, started_at, a note - and stopping it
-- writes a `work_sessions` row of `worked_on` and `hours`. The record says how
-- long somebody worked and has never said **when**, so there was nothing for a
-- break to sit inside, nothing to be over ten hours, and nothing to auto-close.
--
-- Extended rather than replaced, and `work_sessions` stays the one hours
-- record: the contractor statements draft from it, End of day reads it, the
-- period totals sum it. What it gains is the clock - when the session started,
-- when it ended, how much of it was a break, and whether a person or the
-- fourteen-hour rule ended it.
--
-- Three things were already here and are left alone:
--
--   * **One open session per person** is the primary key on
--     `work_session_timers`. It was always structurally true and the brief
--     asks for it; nothing new is needed.
--   * **Corrections** void the old row and write a new one carrying
--     `corrects_id` and a reason, with an append-only guard over the top. What
--     they lacked is approval.
--   * **'Employee'** is already a value `employment_type` accepts. Nobody is
--     one, which is why the employee rules have had nothing to apply to.
--
-- Everyone clocks: contractors, employees and the owner. The clock, the
-- breaks, the totals, the ten and fourteen hour rules and corrections are the
-- same for all of them. `employment_type` decides two things only - whether
-- clocking is required and what the hours are for afterwards - and those are
-- 0294's business, not this file's.

-- ─────────────────────────────────────────────────────────────
-- The session, open

alter table public.work_session_timers
  add column if not exists break_started_at timestamptz,
  add column if not exists break_seconds integer not null default 0,
  add column if not exists last_seen_at timestamptz not null default now();

comment on column public.work_session_timers.break_started_at is
  'Set while the person is on a break, null while they are working. A break sits inside the session rather than ending it.';
comment on column public.work_session_timers.break_seconds is
  'Break time taken so far in this session, in seconds, not counting a break in progress.';
comment on column public.work_session_timers.last_seen_at is
  'The last time the practice saw this person do anything. Where the fourteen-hour rule closes the session, it closes it here.';

alter table public.work_session_timers
  drop constraint if exists work_session_timers_break_inside;
alter table public.work_session_timers
  add constraint work_session_timers_break_inside
  check (break_started_at is null or break_started_at >= started_at);

alter table public.work_session_timers
  drop constraint if exists work_session_timers_break_seconds;
alter table public.work_session_timers
  add constraint work_session_timers_break_seconds check (break_seconds >= 0);

-- ─────────────────────────────────────────────────────────────
-- The session, closed
--
-- On the hours row, because that is the row everything downstream reads. A
-- row typed in by hand has no clock on it and these stay null, which is how a
-- screen tells a clocked session from an entered one.

alter table public.work_sessions
  add column if not exists started_at   timestamptz,
  add column if not exists ended_at     timestamptz,
  add column if not exists break_seconds integer not null default 0,
  add column if not exists auto_closed  boolean not null default false,
  add column if not exists confirmed_at timestamptz,
  add column if not exists confirmed_by uuid references public.staff(id) on delete set null;

comment on column public.work_sessions.auto_closed is
  'True where the fourteen-hour rule ended the session rather than a person. The row needs confirming or correcting before it is believed.';
comment on column public.work_sessions.confirmed_at is
  'When the person agreed an auto-closed session is right. Null on an auto-closed row means nobody has looked yet.';

alter table public.work_sessions drop constraint if exists work_sessions_clock_both_ends;
alter table public.work_sessions add constraint work_sessions_clock_both_ends
  -- Either the clock recorded it or somebody typed it. Half a clock is a bug.
  check ((started_at is null and ended_at is null) or (started_at is not null and ended_at is not null));

alter table public.work_sessions drop constraint if exists work_sessions_clock_runs_forward;
alter table public.work_sessions add constraint work_sessions_clock_runs_forward
  check (ended_at is null or ended_at >= started_at);

alter table public.work_sessions drop constraint if exists work_sessions_break_inside;
alter table public.work_sessions add constraint work_sessions_break_inside
  -- A break cannot be longer than the session it sat inside.
  check (break_seconds >= 0 and (started_at is null
         or break_seconds <= extract(epoch from (ended_at - started_at))::integer));

alter table public.work_sessions drop constraint if exists work_sessions_auto_close_is_clocked;
alter table public.work_sessions add constraint work_sessions_auto_close_is_clocked
  -- Only the clock auto-closes. A row somebody typed was never open.
  check (not auto_closed or started_at is not null);

-- ─────────────────────────────────────────────────────────────
-- A correction somebody has to agree to
--
-- The existing correction is kept exactly: the old row is voided, a new one
-- carries `corrects_id` and the reason, and nothing is edited in place. What
-- is added is who has to agree, and the answer depends on who is correcting.
--
--   An **employee** correcting their hours needs their manager to approve it -
--   `staff.manager_id`, and Admin where there is none. Until then the
--   correction is on the record and out of the totals, because an hours figure
--   nobody has agreed to is not an hours figure payroll can use.
--
--   A **contractor** correcting their own hours on the same day needs nobody,
--   which is how it works today and has been working.
--
--   A contractor correcting a day that has closed, or hours on a statement
--   that is already Approved, is refused with the reason said out loud. The
--   second of those was already refused; the first was not.

alter table public.work_sessions
  add column if not exists approval        text not null default 'Not needed',
  add column if not exists approver_id     uuid references public.staff(id) on delete set null,
  add column if not exists decided_at      timestamptz,
  add column if not exists decided_by      uuid references public.staff(id) on delete set null,
  add column if not exists decision_reason text not null default '';

alter table public.work_sessions drop constraint if exists work_sessions_approval_known;
alter table public.work_sessions add constraint work_sessions_approval_known
  check (approval in ('Not needed', 'Waiting', 'Approved', 'Declined'));

alter table public.work_sessions drop constraint if exists work_sessions_decision_is_recorded;
alter table public.work_sessions add constraint work_sessions_decision_is_recorded
  -- A decision has somebody and a time on it; a declined one has a reason.
  check ((approval not in ('Approved', 'Declined'))
         or (decided_at is not null and decided_by is not null));

alter table public.work_sessions drop constraint if exists work_sessions_decline_says_why;
alter table public.work_sessions add constraint work_sessions_decline_says_why
  check (approval <> 'Declined' or decision_reason <> '');

alter table public.work_sessions drop constraint if exists work_sessions_approval_is_a_correction;
alter table public.work_sessions add constraint work_sessions_approval_is_a_correction
  -- Only a correction waits on anybody. First entries stand on their own.
  check (approval = 'Not needed' or corrects_id is not null);

comment on column public.work_sessions.approval is
  'Not needed, Waiting, Approved or Declined. Only a correction ever waits, and only an employee''s.';

-- ─────────────────────────────────────────────────────────────
-- When somebody is expected to work
--
-- Item 6 of the brief needs a schedule and the practice had none: nothing held
-- a person's work days, their start time or their expected hours. A reminder
-- fifteen minutes after start cannot exist without a start.
--
-- One row per person, the days as a list of ISO weekdays so Monday is 1 and a
-- four-day week is four numbers.

create table if not exists public.staff_schedule (
  staff_id      uuid primary key references public.staff(id) on delete cascade,
  work_days     integer[] not null default '{}',
  starts_at     time,
  weekly_hours  numeric(5,2),
  note          text not null default '',
  updated_at    timestamptz not null default now(),
  updated_by    uuid references public.staff(id) on delete set null
);

comment on table public.staff_schedule is
  'When somebody is expected to work: the days, the start time and the hours a week. Read by the late-clock-in reminder and by the over-forty flag.';

alter table public.staff_schedule drop constraint if exists staff_schedule_days_are_days;
alter table public.staff_schedule add constraint staff_schedule_days_are_days
  check (work_days <@ array[1,2,3,4,5,6,7]);

alter table public.staff_schedule drop constraint if exists staff_schedule_hours_are_plausible;
alter table public.staff_schedule add constraint staff_schedule_hours_are_plausible
  check (weekly_hours is null or (weekly_hours > 0 and weekly_hours <= 80));

alter table public.staff_schedule enable row level security;
revoke all on table public.staff_schedule from anon, authenticated;
grant select on table public.staff_schedule to authenticated;

drop policy if exists staff_schedule_read on public.staff_schedule;
create policy staff_schedule_read on public.staff_schedule
  -- Everybody sees the practice's shifts: who is in on a Tuesday is not
  -- private, and a screen that hides it makes people ask each other instead.
  for select using ((select public.is_active_staff()));

select public.apply_system_read_only('staff_schedule');

-- ─────────────────────────────────────────────────────────────
-- The words the clock uses when it tells somebody something
--
-- `notify_person` raises a My day item when it is given a title, and
-- `tasks.source_kind` is a closed list. Four new kinds, named here rather than
-- discovered when the first forgotten session tried to tell anybody - which is
-- how verify_time_clock found it.

alter table public.tasks drop constraint if exists tasks_source_kind_check;
alter table public.tasks add constraint tasks_source_kind_check
  check (source_kind = any (array[
    'Interview prep', 'Interview day', 'Follow-up', 'billing_item',
    'text_unanswered', 'intake', 'authorization_received',
    'authorization_missing', 'authorization_ending', 'placement_authorization',
    'portal_upload', 'portal_resume', 'mail_reply',
    -- 0293: the clock
    'clock_not_closed', 'clock_running_long', 'clock_not_started', 'hours_correction'
  ]));

-- ─────────────────────────────────────────────────────────────
-- Clocking in, out, and the break in between
--
-- In functions rather than in the screens, because the arithmetic has to agree
-- wherever it is asked: the button in the top bar, My day, the Time clock
-- screen and the fourteen-hour sweep all have to reach the same figure for the
-- same session, and four copies of "elapsed minus breaks" is four chances to
-- disagree.

create or replace function public.clock_in(p_note text default '', p_client uuid default null)
returns timestamptz
language plpgsql security definer set search_path = public as $$
declare v_me uuid := public.current_staff_id();
begin
  if v_me is null then
    raise exception 'Only staff clock in.' using errcode = 'insufficient_privilege';
  end if;
  if exists (select 1 from public.work_session_timers where staff_id = v_me) then
    raise exception 'You are already clocked in.'
      using hint = 'Clock out first, or start a break.', errcode = 'unique_violation';
  end if;

  insert into public.work_session_timers (staff_id, started_at, note, client_id, last_seen_at)
  values (v_me, now(), coalesce(btrim(p_note), ''), p_client, now());

  return now();
end $$;

create or replace function public.start_break()
returns timestamptz
language plpgsql security definer set search_path = public as $$
declare v_me uuid := public.current_staff_id(); t public.work_session_timers;
begin
  select * into t from public.work_session_timers where staff_id = v_me;
  if t.staff_id is null then
    raise exception 'You are not clocked in.' using errcode = 'no_data_found';
  end if;
  if t.break_started_at is not null then
    raise exception 'You are already on a break.' using errcode = 'check_violation';
  end if;

  update public.work_session_timers
     set break_started_at = now(), last_seen_at = now()
   where staff_id = v_me;
  return now();
end $$;

create or replace function public.end_break()
returns integer
language plpgsql security definer set search_path = public as $$
declare v_me uuid := public.current_staff_id(); t public.work_session_timers; v_took integer;
begin
  select * into t from public.work_session_timers where staff_id = v_me;
  if t.staff_id is null then
    raise exception 'You are not clocked in.' using errcode = 'no_data_found';
  end if;
  if t.break_started_at is null then
    raise exception 'You are not on a break.' using errcode = 'check_violation';
  end if;

  v_took := greatest(0, extract(epoch from (now() - t.break_started_at))::integer);
  update public.work_session_timers
     set break_seconds = break_seconds + v_took,
         break_started_at = null,
         last_seen_at = now()
   where staff_id = v_me;

  return t.break_seconds + v_took;
end $$;

/**
 * Clock out, and the session becomes the hours row everything else reads.
 *
 * The hours are the clock less the breaks, rounded to a hundredth, which is
 * what `work_sessions.hours` has always been. A break still running at
 * clock-out ends with the session rather than being lost - somebody who walks
 * away at lunch and clocks out from their phone at six should not be paid for
 * the afternoon they did not work.
 */
create or replace function public.clock_out(
  p_description text default '',
  p_category    text default null,
  p_at          timestamptz default null
)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_me    uuid := public.current_staff_id();
  t       public.work_session_timers;
  v_end   timestamptz;
  v_break integer;
  v_hours numeric;
  v_id    uuid;
begin
  select * into t from public.work_session_timers where staff_id = v_me;
  if t.staff_id is null then
    raise exception 'You are not clocked in.' using errcode = 'no_data_found';
  end if;

  v_end := coalesce(p_at, now());
  v_break := t.break_seconds
             + case when t.break_started_at is null then 0
                    else greatest(0, extract(epoch from (v_end - t.break_started_at))::integer) end;

  v_hours := round(
    greatest(0, extract(epoch from (v_end - t.started_at))::numeric - v_break) / 3600.0, 2);

  if v_hours <= 0 then
    raise exception 'That session comes to nothing once the breaks are taken off.'
      using hint = 'Discard it rather than logging nothing.', errcode = 'check_violation';
  end if;

  insert into public.work_sessions
    (staff_id, worked_on, hours, description, category, client_id, created_by,
     started_at, ended_at, break_seconds)
  values (v_me,
          (t.started_at at time zone 'America/Denver')::date,
          v_hours, coalesce(btrim(p_description), ''),
          p_category, t.client_id, v_me,
          t.started_at, v_end, v_break)
  returning id into v_id;

  delete from public.work_session_timers where staff_id = v_me;
  return v_id;
end $$;

revoke all on function public.clock_in(text, uuid) from anon, authenticated;
revoke all on function public.start_break() from anon, authenticated;
revoke all on function public.end_break() from anon, authenticated;
revoke all on function public.clock_out(text, text, timestamptz) from anon, authenticated;
grant execute on function public.clock_in(text, uuid) to authenticated;
grant execute on function public.start_break() to authenticated;
grant execute on function public.end_break() to authenticated;
grant execute on function public.clock_out(text, text, timestamptz) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- Forgot to clock out
--
-- Ten hours: the person and their manager are told, and the session stays open
-- because somebody genuinely working a long day should not have it taken off
-- them.
--
-- Fourteen hours: closed at the last thing the practice saw them do, flagged,
-- and left for them to confirm or correct. Not at fourteen hours - that would
-- pay for four hours nobody worked - and not discarded either, because a day
-- that happened should not vanish for being badly recorded.

create or replace function public.clock_lapse_hours()
returns table(warn_after integer, close_after integer)
language sql immutable as $$
  -- One place, so the sweep, the screens and the sentence a person reads
  -- cannot disagree about the numbers.
  select 10, 14
$$;

create or replace function public.close_forgotten_sessions()
returns integer
language plpgsql security definer set search_path = public as $$
declare
  r        record;
  v_warn   integer;
  v_close  integer;
  v_closed integer := 0;
  v_end    timestamptz;
  v_mgr    uuid;
  v_admin  uuid;
begin
  select warn_after, close_after into v_warn, v_close from public.clock_lapse_hours();
  select intake_staff_id into v_admin from public.org_settings limit 1;

  for r in
    select t.*, s.name as staff_name, s.manager_id
      from public.work_session_timers t
      join public.staff s on s.id = t.staff_id
     where t.started_at < now() - make_interval(hours => v_warn)
  loop
    -- The last thing the practice saw them do, which is the honest end of a
    -- session nobody closed. Their own last activity, not the clock's: the
    -- clock stopped telling the truth hours ago.
    select greatest(
             r.last_seen_at,
             coalesce((select max(a.at) from public.access_log a where a.staff_id = r.staff_id), r.started_at),
             coalesce((select max(w.created_at) from public.work_sessions w where w.staff_id = r.staff_id), r.started_at)
           ) into v_end;
    if v_end <= r.started_at then v_end := r.started_at + interval '1 minute'; end if;

    if r.started_at < now() - make_interval(hours => v_close) then
      -- Closed, flagged, and theirs to confirm.
      insert into public.work_sessions
        (staff_id, worked_on, hours, description, client_id, created_by,
         started_at, ended_at, break_seconds, auto_closed)
      values (r.staff_id,
              (r.started_at at time zone 'America/Denver')::date,
              greatest(0.01, round(
                greatest(0, extract(epoch from (v_end - r.started_at))::numeric - r.break_seconds) / 3600.0, 2)),
              '', r.client_id, r.staff_id,
              r.started_at, v_end, r.break_seconds, true);

      delete from public.work_session_timers where staff_id = r.staff_id;
      v_closed := v_closed + 1;

      perform public.notify_person(
        r.staff_id, 'clock_not_closed',
        format('Your session from %s was still open after %s hours, so it was closed at %s - the last thing you did in the CRM. Confirm it or correct it.',
               to_char(r.started_at at time zone 'America/Denver', 'FMDay FMDD FMMon, FMHH12:MIam'),
               v_close,
               to_char(v_end at time zone 'America/Denver', 'FMHH12:MIam')),
        r.staff_id::text || ':' || to_char(r.started_at, 'YYYYMMDDHH24MI'),
        '/time-clock', null,
        'Confirm or correct the session that was closed for you',
        public.practice_today(), 'bad', r.staff_id);
    else
      -- Ten hours: said once, to them and to whoever they answer to.
      v_mgr := coalesce(r.manager_id, v_admin);

      perform public.notify_person(
        r.staff_id, 'clock_running_long',
        format('You have been clocked in since %s. Clock out when you finish, or it will be closed for you after %s hours.',
               to_char(r.started_at at time zone 'America/Denver', 'FMHH12:MIam'), v_close),
        r.staff_id::text || ':' || to_char(r.started_at, 'YYYYMMDDHH24MI'),
        '/time-clock', null, null, null, 'warn', r.staff_id);

      if v_mgr is not null and v_mgr <> r.staff_id then
        perform public.notify_person(
          v_mgr, 'clock_running_long',
          format('%s has been clocked in since %s.', r.staff_name,
                 to_char(r.started_at at time zone 'America/Denver', 'FMHH12:MIam')),
          v_mgr::text || ':' || r.staff_id::text || ':' || to_char(r.started_at, 'YYYYMMDDHH24MI'),
          '/admin/hours', null, null, null, 'warn', r.staff_id);
      end if;
    end if;
  end loop;

  return v_closed;
end $$;

revoke all on function public.close_forgotten_sessions() from anon, authenticated;

create or replace function public.confirm_auto_closed_session(p_session uuid)
returns uuid
language plpgsql security definer set search_path = public as $$
declare v_me uuid := public.current_staff_id(); w public.work_sessions;
begin
  select * into w from public.work_sessions where id = p_session;
  if w.id is null then
    raise exception 'That session is not on file.' using errcode = 'no_data_found';
  end if;
  if w.staff_id <> v_me then
    raise exception 'Only the person who worked it confirms it.' using errcode = 'insufficient_privilege';
  end if;
  if not w.auto_closed then
    raise exception 'That session was not closed for you, so there is nothing to confirm.'
      using errcode = 'check_violation';
  end if;

  update public.work_sessions
     set confirmed_at = now(), confirmed_by = v_me
   where id = p_session;
  return p_session;
end $$;

revoke all on function public.confirm_auto_closed_session(uuid) from anon, authenticated;
grant execute on function public.confirm_auto_closed_session(uuid) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- A correction, and who has to agree to it
--
-- The original is not voided when the correction is asked for. It is voided
-- when the correction is **approved**, and until then the original is the
-- figure that counts. That matters: a correction waiting on a manager must not
-- take hours out of a total, or a week's pay would drop the moment somebody
-- queried a punch and come back only when the manager got round to it.

-- The existing correction trigger learns to wait
--
-- `work_sessions_apply_correction` has voided the corrected row the moment a
-- correction was inserted, which was right while no correction waited on
-- anybody. It is wrong now: an employee's correction that voids the original
-- before the manager has seen it takes the hours out of the week and puts
-- nothing back until somebody gets round to it.
--
-- So it voids the original only when the correction needs nobody. Where it
-- does, `decide_hours_correction` voids it on approval, and a decline leaves
-- the original standing - which is what verify_time_clock caught on its first
-- run, before anybody had seen this file.

create or replace function public.work_sessions_apply_correction()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.corrects_id is not null and new.approval in ('Not needed', 'Approved') then
    update public.work_sessions set voided = true where id = new.corrects_id;
  end if;
  return new;
end $$;

create or replace function public.hours_correction_needs_approval(p_staff uuid, p_worked_on date)
returns boolean
language sql stable security definer set search_path = public as $$
  -- An employee's correction needs their manager. A contractor correcting
  -- their own hours on the day stays as it has always worked, and the owner
  -- answers to nobody by definition.
  select coalesce((select e.employment_type from public.staff_employment e
                    where e.staff_id = p_staff), 'Contractor') = 'Employee'
$$;

comment on function public.hours_correction_needs_approval is
  'Whether a correction to these hours waits on somebody. True for an employee, false for a contractor or the owner.';

create or replace function public.request_hours_correction(
  p_session     uuid,
  p_hours       numeric,
  p_description text,
  p_reason      text
)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_me    uuid := public.current_staff_id();
  w       public.work_sessions;
  v_type  text;
  v_needs boolean;
  v_mgr   uuid;
  v_admin uuid;
  v_new   uuid;
  v_stmt  text;
begin
  if v_me is null then
    raise exception 'Only staff correct hours.' using errcode = 'insufficient_privilege';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'Say why these hours are being corrected.'
      using hint = 'The reason is what somebody reads a year from now.', errcode = 'check_violation';
  end if;
  if p_hours is null or p_hours <= 0 or p_hours > 24 then
    raise exception 'Hours are between nothing and twenty-four.' using errcode = 'check_violation';
  end if;

  select * into w from public.work_sessions where id = p_session;
  if w.id is null then
    raise exception 'Those hours are not on file.' using errcode = 'no_data_found';
  end if;
  if w.voided then
    raise exception 'Those hours have already been corrected.' using errcode = 'check_violation';
  end if;
  if w.staff_id <> v_me and public.current_staff_role() <> 'Admin' then
    raise exception 'Those are somebody else''s hours.' using errcode = 'insufficient_privilege';
  end if;

  -- Hours on an approved statement are settled. This was already refused, and
  -- it is said here as well so a person reads it before they type a reason
  -- rather than after.
  select cs.status into v_stmt
    from public.contractor_statements cs where cs.id = w.statement_id;
  if v_stmt = 'Approved' then
    raise exception 'Those hours are on an approved statement, so they cannot be corrected.'
      using hint = 'Ask Admin to reopen the statement first.', errcode = 'check_violation';
  end if;

  v_type := coalesce((select e.employment_type from public.staff_employment e
                       where e.staff_id = w.staff_id), 'Contractor');
  v_needs := public.hours_correction_needs_approval(w.staff_id, w.worked_on);

  -- A contractor correcting a day that has closed is refused, with the reason
  -- said out loud. Their own day, their own figure, while the day is still
  -- theirs to change.
  if not v_needs and v_type <> 'Owner' and w.worked_on < public.practice_today() then
    raise exception 'That day has closed, so it is not yours to change now.'
      using hint = 'Ask Admin, or put it on your next statement with a note.',
            errcode = 'check_violation';
  end if;

  select intake_staff_id into v_admin from public.org_settings limit 1;
  select manager_id into v_mgr from public.staff where id = w.staff_id;
  if v_needs and coalesce(v_mgr, v_admin) is null then
    raise exception 'There is nobody to approve this: no manager on the record and no Admin set.'
      using errcode = 'check_violation';
  end if;

  insert into public.work_sessions
    (staff_id, worked_on, hours, description, category, client_id, created_by,
     corrects_id, correction_reason,
     approval, approver_id,
     started_at, ended_at, break_seconds)
  values (w.staff_id, w.worked_on, p_hours,
          coalesce(nullif(btrim(p_description), ''), w.description),
          w.category, w.client_id, v_me,
          w.id, btrim(p_reason),
          case when v_needs then 'Waiting' else 'Not needed' end,
          case when v_needs then coalesce(v_mgr, v_admin) end,
          w.started_at, w.ended_at, w.break_seconds)
  returning id into v_new;

  if v_needs then
    -- The original stands until somebody agrees to the change.
    perform public.notify_person(
      coalesce(v_mgr, v_admin), 'hours_correction',
      format('%s is asking to change %s hours on %s to %s. Reason: %s',
             (select name from public.staff where id = w.staff_id),
             w.hours, to_char(w.worked_on, 'FMDD FMMon'), p_hours, btrim(p_reason)),
      v_new::text, '/admin/hours', null,
      format('Approve or decline %s''s correction for %s',
             (select name from public.staff where id = w.staff_id),
             to_char(w.worked_on, 'FMDD FMMon')),
      public.practice_today(), 'warn', v_new);
  else
    -- Nobody to ask: the correction takes effect and the original is kept,
    -- voided, exactly as it has worked.
    update public.work_sessions set voided = true where id = w.id;
  end if;

  return v_new;
end $$;

create or replace function public.decide_hours_correction(
  p_correction uuid,
  p_approve    boolean,
  p_reason     text default ''
)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_me   uuid := public.current_staff_id();
  v_role text := public.current_staff_role();
  c      public.work_sessions;
begin
  select * into c from public.work_sessions where id = p_correction;
  if c.id is null then
    raise exception 'That correction is not on file.' using errcode = 'no_data_found';
  end if;
  if c.approval <> 'Waiting' then
    raise exception 'That correction is already %.', lower(c.approval) using errcode = 'check_violation';
  end if;
  if v_me is null or (v_me <> c.approver_id and coalesce(v_role, '') <> 'Admin') then
    raise exception 'Only the manager it was sent to, or Admin, decides this.'
      using errcode = 'insufficient_privilege';
  end if;
  if not p_approve and coalesce(btrim(p_reason), '') = '' then
    raise exception 'Say why it is being declined.'
      using hint = 'The person reads this, and it is the whole answer they get.',
            errcode = 'check_violation';
  end if;

  update public.work_sessions
     set approval = case when p_approve then 'Approved' else 'Declined' end,
         decided_at = now(), decided_by = v_me,
         decision_reason = btrim(coalesce(p_reason, ''))
   where id = p_correction;

  if p_approve then
    -- Now the original gives way. Kept, voided, with the correction pointing
    -- at it - which is how this has always worked.
    update public.work_sessions set voided = true where id = c.corrects_id;
  end if;

  perform public.notify_person(
    c.staff_id, 'hours_correction',
    case when p_approve
         then format('Your correction to %s is approved.', to_char(c.worked_on, 'FMDD FMMon'))
         else format('Your correction to %s was declined: %s',
                     to_char(c.worked_on, 'FMDD FMMon'), btrim(coalesce(p_reason, ''))) end,
    p_correction::text || ':decided', '/time-clock', null, null, null,
    -- 'warn' either way: the level says how much attention a line wants, not
    -- whether the news is welcome, and the practice has only 'warn' and 'bad'.
    -- An approval still wants reading - the hours on the record changed.
    case when p_approve then 'warn' else 'bad' end, p_correction);

  return case when p_approve then 'Approved' else 'Declined' end;
end $$;

revoke all on function public.hours_correction_needs_approval(uuid, date) from anon, authenticated;
revoke all on function public.request_hours_correction(uuid, numeric, text, text) from anon, authenticated;
revoke all on function public.decide_hours_correction(uuid, boolean, text) from anon, authenticated;
-- Not granted to a screen: it says whether a named person is an employee,
-- which is nobody's business but Admin's and the function's that asks it.
-- `request_hours_correction` calls it from inside, where it needs no grant.
-- verify_portal_rls caught the grant before it ever shipped.
grant execute on function public.request_hours_correction(uuid, numeric, text, text) to authenticated;
grant execute on function public.decide_hours_correction(uuid, boolean, text) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- The schedule, set by Admin

create or replace function public.set_staff_schedule(
  p_staff   uuid,
  p_days    integer[],
  p_starts  time,
  p_hours   numeric,
  p_note    text default ''
)
returns uuid
language plpgsql security definer set search_path = public as $$
declare v_me uuid := public.current_staff_id();
begin
  if coalesce(public.current_staff_role(), '') <> 'Admin' then
    raise exception 'Only Admin sets who works when.' using errcode = 'insufficient_privilege';
  end if;
  if not exists (select 1 from public.staff where id = p_staff and active and not is_system) then
    raise exception 'That is not somebody on the staff.' using errcode = 'no_data_found';
  end if;

  insert into public.staff_schedule (staff_id, work_days, starts_at, weekly_hours, note,
                                     updated_at, updated_by)
  values (p_staff, coalesce(p_days, '{}'), p_starts, p_hours, coalesce(btrim(p_note), ''),
          now(), v_me)
  on conflict (staff_id) do update
    set work_days = excluded.work_days,
        starts_at = excluded.starts_at,
        weekly_hours = excluded.weekly_hours,
        note = excluded.note,
        updated_at = now(),
        updated_by = v_me;

  return p_staff;
end $$;

revoke all on function public.set_staff_schedule(uuid, integer[], time, numeric, text) from anon, authenticated;
grant execute on function public.set_staff_schedule(uuid, integer[], time, numeric, text) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- Nobody has clocked in and they were expected
--
-- To them only, as asked. Fifteen minutes is late enough to be worth saying
-- and early enough to be useful; an hour later is an accusation rather than a
-- reminder.

create or replace function public.remind_to_clock_in()
returns integer
language plpgsql security definer set search_path = public as $$
declare r record; v_n integer := 0; v_now timestamptz := now();
begin
  for r in
    select s.id, s.name, sc.starts_at,
           (v_now at time zone 'America/Denver')::date as today_local
      from public.staff s
      join public.staff_schedule sc on sc.staff_id = s.id
     where s.active and not s.is_system
       and sc.starts_at is not null
       and extract(isodow from (v_now at time zone 'America/Denver')::date)::integer = any(sc.work_days)
       -- Fifteen minutes past their start, and not so late that this is
       -- yesterday's reminder arriving.
       and (v_now at time zone 'America/Denver')::time
             between sc.starts_at + interval '15 minutes' and sc.starts_at + interval '4 hours'
       and not exists (select 1 from public.work_session_timers t where t.staff_id = s.id)
       and not exists (
         select 1 from public.work_sessions w
          where w.staff_id = s.id
            and w.worked_on = (v_now at time zone 'America/Denver')::date
            and not w.voided)
  loop
    perform public.notify_person(
      r.id, 'clock_not_started',
      format('You were due to start at %s and have not clocked in.',
             to_char(r.starts_at, 'FMHH12:MIam')),
      r.id::text || ':' || to_char(r.today_local, 'YYYYMMDD'),
      '/time-clock', null, null, null, 'warn', r.id);
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

revoke all on function public.remind_to_clock_in() from anon, authenticated;

-- ─────────────────────────────────────────────────────────────
-- What the totals count
--
-- `not voided` was enough while every row stood on its own. A correction
-- waiting on a manager is a row that exists and must not be counted yet, and a
-- declined one must never be counted at all - so the filter is now "not
-- voided, and either it needed nobody or somebody said yes".
--
-- The original is not voided until the correction is approved, so the hours
-- never go missing in between: before the decision the original counts, after
-- an approval the correction does, after a decline the original still does.

create or replace function public.hours_count(w public.work_sessions)
returns boolean
language sql immutable as $$
  select not w.voided and w.approval in ('Not needed', 'Approved')
$$;

comment on function public.hours_count is
  'Whether a work session counts towards a total: not superseded, and not waiting on or refused by anybody.';

-- Dropped and recreated rather than replaced: a replace can only append
-- columns, and these gain the week, the month and the break time in the
-- middle. Every reader asks by name and the grants are restated below.
drop view if exists public.my_hours_summary;
create view public.my_hours_summary
  with (security_invoker = true) as
  select w.staff_id,
         coalesce(sum(w.hours) filter (where w.worked_on = public.practice_today()), 0) as today_hours,
         coalesce(sum(w.break_seconds) filter (where w.worked_on = public.practice_today()), 0) as today_break_seconds,
         coalesce(sum(w.hours) filter (
           where w.worked_on >= public.practice_today() - ((extract(isodow from public.practice_today())::integer - 1))
             and w.worked_on <= public.practice_today()), 0) as week_hours,
         coalesce(sum(w.hours) filter (
           where w.worked_on >= date_trunc('month', public.practice_today())::date
             and w.worked_on <= public.practice_today()), 0) as month_hours,
         coalesce(sum(w.hours) filter (
           where w.worked_on >= public.period_start(public.practice_today())
             and w.worked_on <= public.period_end(public.practice_today())), 0) as period_hours,
         coalesce(sum(w.break_seconds) filter (
           where w.worked_on >= public.period_start(public.practice_today())
             and w.worked_on <= public.period_end(public.practice_today())), 0) as period_break_seconds,
         public.period_start(public.practice_today()) as period_start,
         public.period_end(public.practice_today()) as period_end,
         count(*) filter (where w.auto_closed and w.confirmed_at is null) as to_confirm
    from public.work_sessions w
   where public.hours_count(w)
      or (w.auto_closed and w.confirmed_at is null)
   group by w.staff_id;

revoke all on table public.my_hours_summary from anon, authenticated;
grant select on table public.my_hours_summary to authenticated;

drop view if exists public.work_session_totals;
create view public.work_session_totals
  with (security_invoker = true) as
  select w.staff_id,
         public.period_start(w.worked_on) as period_start,
         public.period_end(w.worked_on) as period_end,
         sum(w.hours) as total_hours,
         sum(w.break_seconds) as break_seconds,
         count(*) as session_count
    from public.work_sessions w
   where public.hours_count(w)
   group by w.staff_id, public.period_start(w.worked_on), public.period_end(w.worked_on);

revoke all on table public.work_session_totals from anon, authenticated;
grant select on table public.work_session_totals to authenticated;

-- ─────────────────────────────────────────────────────────────
-- Admin -> Hours: everybody, by week and by period
--
-- The over-forty flag is a week's figure and the pay period may be a
-- fortnight, so the week is its own column rather than something a screen
-- works out. Flagged for employees only, as asked - a contractor over forty
-- hours is a contractor who was busy, not a payroll question.

drop view if exists public.hours_by_week;
create view public.hours_by_week
  with (security_invoker = true) as
  select w.staff_id,
         s.name as staff_name,
         s.role as staff_role,
         coalesce(e.employment_type, 'Contractor') as employment_type,
         (w.worked_on - ((extract(isodow from w.worked_on)::integer - 1))) as week_start,
         public.period_start(w.worked_on) as period_start,
         public.period_end(w.worked_on) as period_end,
         sum(w.hours) as hours,
         sum(w.break_seconds) as break_seconds,
         count(*) as sessions,
         sum(w.hours) > 40
           and coalesce(e.employment_type, 'Contractor') = 'Employee' as over_forty
    from public.work_sessions w
    join public.staff s on s.id = w.staff_id
    left join public.staff_employment e on e.staff_id = w.staff_id
   where public.hours_count(w)
   group by w.staff_id, s.name, s.role, e.employment_type,
            (w.worked_on - ((extract(isodow from w.worked_on)::integer - 1))),
            public.period_start(w.worked_on), public.period_end(w.worked_on);

revoke all on table public.hours_by_week from anon, authenticated;
grant select on table public.hours_by_week to authenticated;

comment on view public.hours_by_week is
  'Everybody''s hours a week at a time, with the pay period they fall in and the over-forty flag for employees. Admin -> Hours reads this.';

-- ─────────────────────────────────────────────────────────────
-- What this file promises

do $$
declare r record; v_n integer;
begin
  -- The clock, end to end, on a made-up person inside a block that rolls back.
  declare
    v_uid uuid := gen_random_uuid();
    v_staff uuid; v_id uuid; v_hours numeric; v_break integer;
  begin
    insert into public.staff (name, email, role, active)
    values ('ZZ Clock Testperson', 'zz-clock@example.test', 'Job Search', true) returning id into v_staff;
    insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    values (v_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'zz-clock@example.test', '{}', '{}', now(), now());
    update public.staff set user_id = v_uid where id = v_staff;

    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims',
                       json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);

    perform public.clock_in('ZQ a morning');
    if (select count(*) from public.work_session_timers where staff_id = v_staff) <> 1 then
      raise exception 'clocking in did not open a session';
    end if;

    begin
      perform public.clock_in('ZQ again');
      raise exception 'a second session opened while one was already running'
        using errcode = 'raise_exception';
    exception when unique_violation then null;
    end;

    -- Backdate it so there is something to measure, then a break inside it.
    perform set_config('role', 'postgres', true);
    update public.work_session_timers
       set started_at = now() - interval '3 hours', last_seen_at = now()
     where staff_id = v_staff;
    perform set_config('role', 'authenticated', true);

    perform public.start_break();
    perform set_config('role', 'postgres', true);
    update public.work_session_timers
       set break_started_at = now() - interval '30 minutes' where staff_id = v_staff;
    perform set_config('role', 'authenticated', true);
    v_break := public.end_break();
    if v_break < 1700 or v_break > 1900 then
      raise exception 'a half-hour break measured % seconds', v_break;
    end if;

    v_id := public.clock_out('ZQ the morning', null);
    perform set_config('role', 'postgres', true);

    select hours, break_seconds into v_hours, v_break from public.work_sessions where id = v_id;
    if v_hours < 2.4 or v_hours > 2.6 then
      raise exception 'three hours less a half-hour break came to %', v_hours;
    end if;
    if (select started_at from public.work_sessions where id = v_id) is null
       or (select ended_at from public.work_sessions where id = v_id) is null then
      raise exception 'the session was recorded without saying when it was';
    end if;
    if exists (select 1 from public.work_session_timers where staff_id = v_staff) then
      raise exception 'clocking out left the session open';
    end if;

    raise notice 'ok  one session at a time, a break inside it, and the hours are the clock less the break';
    raise exception 'ZQ rolling the fixture back' using errcode = 'check_violation';
  exception when check_violation then null;
  end;

  if exists (select 1 from public.staff where email = 'zz-clock@example.test') then
    raise exception 'the fixture outlived the check';
  end if;

  -- The numbers are one answer in one place, and the sentence a person reads
  -- is built from the same two.
  for r in select warn_after, close_after from public.clock_lapse_hours() loop
    if r.warn_after >= r.close_after then
      raise exception 'the warning at % hours is not before the close at %', r.warn_after, r.close_after;
    end if;
    raise notice 'ok  told at % hours, closed at %, from one function', r.warn_after, r.close_after;
  end loop;

  -- And nothing in the practice is waiting on a correction nobody can decide.
  if exists (
    select 1 from public.work_sessions w
     where w.approval = 'Waiting' and w.approver_id is null
  ) then
    raise exception 'a correction is waiting on nobody';
  end if;

  select count(*) into v_n from public.work_sessions w where not public.hours_count(w);
  raise notice 'ok  % row(s) are out of the totals: superseded, waiting, or refused', v_n;
end $$;
