-- Zion Vocational Rehab CRM — a day is made of segments
--
-- The owner's time clock order, 14 November 2026. It extends the clock
-- shipped on 5 November (0293) and applies to everybody.
--
-- ── what was already true ────────────────────────────────────
--
-- Reported before this ran, from the 104 session rows:
--
--   A segment is already a row. `work_sessions` carries started_at, ended_at
--   and break_seconds per clock-in, and a second clock-in on the same day
--   already writes a second row against the same `worked_on`. Four days
--   already have two rows, all of them typed in from paper rather than
--   clocked.
--
--   `worked_on` is already taken from the **start** of the segment in Denver
--   time, so a segment that crosses midnight already belongs to the day it
--   started. No row has crossed one yet.
--
--   The break already sits inside the segment and is already excluded from
--   the hours.
--
-- So this migration is not about how a day is stored. It is about the day
-- being a thing the practice can see and account for: its totals, its
-- account, and what happens when there is not one.
--
-- ── what this adds ───────────────────────────────────────────
--
--   `work_days`, which is the day as a row: its segments, what was worked,
--   what was on break, when it started and finished, and whether anybody has
--   said what it was.
--
--   A clock-out that asks. What a person writes becomes that day's End of
--   day entry - one line per clock-out, appended - and the file they attach
--   goes with it. Not required: a person at six in the evening is not held
--   at a form. But a day nobody accounted for is flagged until somebody does.
--
--   And a day over twelve worked hours tells their manager, which is a
--   different question from the ten-hour notice: that one asks whether a
--   segment was left open, this one asks whether somebody worked too long.
--
-- ── the flag starts today ────────────────────────────────────
--
-- 65 of the 96 worked days on file have no End of day at all - `staff_days`
-- only begins on 19 October, and the nine days anybody has clocked carry no
-- description, because until today the clock-out button asked for nothing.
-- A flag with no start date would light up all of them at once, on every
-- person's My day and every manager's, on the morning it shipped. So the
-- flag has a start date, it is today, and the days before it are what they
-- always were.

begin;

-- ── the file a day's account carries ─────────────────────────
--
-- Two columns because there are two kinds of file and they live in different
-- places for a reason. A PDF, a Word file or a photo of a day's work is the
-- person's own and goes to their staff file. A recording is about a client
-- and goes on that client's record, where `attachments.client_id` is not
-- null, the restricted-by-default rule applies to it and the recordings
-- pipeline can find it. One nullable column each, and a day's account may
-- carry either.

alter table public.staff_day_lines
  add column if not exists staff_file_id uuid references public.staff_files(id) on delete set null,
  add column if not exists attachment_id uuid references public.attachments(id) on delete set null,
  add column if not exists from_clock_out boolean not null default false;

comment on column public.staff_day_lines.from_clock_out is
  'Written by a clock-out rather than typed on the End of day form. A day''s account is what the person said at clock out; a line carried forward from yesterday is not one.';

-- ── where the flag starts ────────────────────────────────────

alter table public.org_settings
  add column if not exists clock_accounts_from date;

update public.org_settings
   set clock_accounts_from = coalesce(clock_accounts_from, public.practice_today());

grant select (clock_accounts_from) on public.org_settings to authenticated;
grant update (clock_accounts_from) on public.org_settings to authenticated;

-- ── the day, as a row ────────────────────────────────────────

-- Replaced rather than dropped: 0354's `staff_hours_summary` reads this one,
-- so a drop would either fail or take that view with it.
create or replace view public.work_days
with (security_invoker = true) as
  /*
   * One row per person per day they worked.
   *
   * The sum of the segments, which is what the day is. `hours_count` decides
   * which segments are real - not voided, and approved where an approval was
   * needed - so a correction waiting on a manager does not move the day's
   * total until somebody decides it, exactly as the totals have always
   * worked.
   *
   * `accounted_for` is the question the flag asks: did anybody say what this
   * day was? A line the person wrote at clock out counts. A line carried
   * forward from yesterday does not - it is what they did not finish, not an
   * account of today - which is why `from_clock_out` exists. Writing the day
   * up on the End of day form counts too, because that form is the place to
   * edit and a day written up there is a day accounted for.
   */
  select
    w.staff_id,
    s.name as staff_name,
    s.role as staff_role,
    -- The same coalesce `hours_by_week` uses: somebody with no employment row
    -- is a contractor, which is how this practice started.
    coalesce(e.employment_type, 'Contractor') as employment_type,
    w.worked_on as day,
    count(*) as segments,
    sum(w.hours) as worked_hours,
    sum(w.break_seconds) as break_seconds,
    min(w.started_at) as first_in,
    max(w.ended_at) as last_out,
    bool_or(w.started_at is not null) as from_the_clock,
    bool_or(w.auto_closed and w.confirmed_at is null) as waiting_to_be_confirmed,
    exists (
      select 1
        from public.staff_days d
        left join public.staff_day_lines l on l.day_id = d.id
       where d.staff_id = w.staff_id
         and d.day = w.worked_on
         and (
           coalesce(btrim(d.actions_taken), '') <> ''
           or coalesce(btrim(d.bottlenecks), '') <> ''
           or (l.id is not null and l.carried_from is null and coalesce(btrim(l.description), '') <> '')
         )
    ) as accounted_for,
    /*
     * Whether this day is one somebody is being asked about.
     *
     * The whole rule in one column, so that four screens asking "which days
     * need an account" cannot answer it four ways. A day needs one when it
     * has time on the clock, it is not today, nobody has said what it was,
     * and it falls on or after the day the flag started - which exists
     * because 65 of the 96 worked days on file have no End of day at all and
     * a flag without a start date would have lit every one of them up at
     * once on the morning it shipped.
     */
    bool_or(w.started_at is not null)
      and w.worked_on >= coalesce(
        (select o.clock_accounts_from from public.org_settings o limit 1),
        public.practice_today())
      and w.worked_on < public.practice_today()
      and not exists (
        select 1
          from public.staff_days d
          left join public.staff_day_lines l on l.day_id = d.id
         where d.staff_id = w.staff_id
           and d.day = w.worked_on
           and (
             coalesce(btrim(d.actions_taken), '') <> ''
             or coalesce(btrim(d.bottlenecks), '') <> ''
             or (l.id is not null and l.carried_from is null and coalesce(btrim(l.description), '') <> '')
           )
      ) as needs_an_account
  from public.work_sessions w
  join public.staff s on s.id = w.staff_id
  left join public.staff_employment e on e.staff_id = w.staff_id
 where public.hours_count(w.*)
 group by w.staff_id, s.name, s.role, e.employment_type, w.worked_on;

-- Supabase grants a new view everything to `authenticated`, so a revoke
-- that names only public and anon leaves it writable (verify_view_grants).
revoke all on public.work_days from public, anon, authenticated;
grant select on public.work_days to authenticated;

-- ── the figures a person reads ───────────────────────────────
--
-- The same view as before with the day's shape added: how many segments, and
-- the break for the week as well as the day and the period. A person who
-- clocked in three times wants to see three, because that is the number they
-- can check against their own memory of the day.

-- Dropped rather than replaced: `create or replace view` cannot put a column
-- in the middle of one, and these belong beside the figures they qualify
-- rather than in an appendix at the end. The drop is bare on purpose - no
-- cascade - so that anything depending on this view stops the migration and
-- is dealt with rather than quietly dropped with it.
drop view if exists public.my_hours_summary;

create view public.my_hours_summary
with (security_invoker = true) as
  select
    staff_id,
    coalesce(sum(hours) filter (where worked_on = public.practice_today()), 0::numeric) as today_hours,
    coalesce(sum(break_seconds) filter (where worked_on = public.practice_today()), 0::bigint) as today_break_seconds,
    count(*) filter (where worked_on = public.practice_today()) as today_segments,
    coalesce(sum(hours) filter (
      where worked_on >= (public.practice_today() - (extract(isodow from public.practice_today())::integer - 1))
        and worked_on <= public.practice_today()), 0::numeric) as week_hours,
    coalesce(sum(break_seconds) filter (
      where worked_on >= (public.practice_today() - (extract(isodow from public.practice_today())::integer - 1))
        and worked_on <= public.practice_today()), 0::bigint) as week_break_seconds,
    count(*) filter (
      where worked_on >= (public.practice_today() - (extract(isodow from public.practice_today())::integer - 1))
        and worked_on <= public.practice_today()) as week_segments,
    coalesce(sum(hours) filter (
      where worked_on >= date_trunc('month', public.practice_today()::timestamptz)::date
        and worked_on <= public.practice_today()), 0::numeric) as month_hours,
    coalesce(sum(hours) filter (
      where worked_on >= public.period_start(public.practice_today())
        and worked_on <= public.period_end(public.practice_today())), 0::numeric) as period_hours,
    coalesce(sum(break_seconds) filter (
      where worked_on >= public.period_start(public.practice_today())
        and worked_on <= public.period_end(public.practice_today())), 0::bigint) as period_break_seconds,
    count(*) filter (
      where worked_on >= public.period_start(public.practice_today())
        and worked_on <= public.period_end(public.practice_today())) as period_segments,
    public.period_start(public.practice_today()) as period_start,
    public.period_end(public.practice_today()) as period_end,
    count(*) filter (where auto_closed and confirmed_at is null) as to_confirm,
    /*
     * Days with segments on them that nobody has accounted for, from the day
     * the flag started. Counted here because the header and My day both ask
     * it on every load, and a second round trip for one integer is a second
     * round trip on every page.
     */
    count(distinct worked_on) filter (
      where started_at is not null
        and worked_on >= coalesce((select o.clock_accounts_from from public.org_settings o limit 1),
                                  public.practice_today())
        and worked_on < public.practice_today()
        and not exists (
          select 1 from public.staff_days d
           left join public.staff_day_lines l on l.day_id = d.id
           where d.staff_id = w.staff_id and d.day = w.worked_on
             and (coalesce(btrim(d.actions_taken), '') <> ''
                  or coalesce(btrim(d.bottlenecks), '') <> ''
                  or (l.id is not null and l.carried_from is null
                      and coalesce(btrim(l.description), '') <> ''))
        )) as days_to_account_for
  from public.work_sessions w
 where public.hours_count(w.*) or (auto_closed and confirmed_at is null)
 group by staff_id;

-- Supabase grants a new view everything to `authenticated`, so a revoke
-- that names only public and anon leaves it writable (verify_view_grants).
revoke all on public.my_hours_summary from public, anon, authenticated;
grant select on public.my_hours_summary to authenticated;

commit;
