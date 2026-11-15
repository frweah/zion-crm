-- Zion Vocational Rehab CRM - a day knows which period it is in
--
-- Admin -> Hours showed September days under "this pay period". The weeks
-- table filters on each row's own period_start, which `hours_by_week`
-- carries; the days table had no such column and reached for one arbitrary
-- row of `work_session_totals` instead, which is a grouped view and answers
-- with whichever period that row happened to be in.
--
-- Found by looking at the screen with real days on it.

begin;

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
,
    /*
     * The pay period and the week the day falls in.
     *
     * At the end of the list rather than beside the date, because
     * `staff_hours_summary` reads this view and `create or replace` cannot
     * put a column in the middle of one - so a tidier order would mean
     * dropping two views on a database that is already serving them.
     *
     * Carried on the row the way `hours_by_week` carries them: a screen
     * filtering days by "this pay period" otherwise has to find the period
     * somewhere else, and the somewhere else it reached for was one
     * arbitrary row of a grouped view, which is why Admin -> Hours was
     * showing September days under "this pay period".
     */
    public.period_start(w.worked_on) as period_start,
    public.period_end(w.worked_on) as period_end,
    (w.worked_on - (extract(isodow from w.worked_on)::integer - 1)) as week_start
  from public.work_sessions w
  join public.staff s on s.id = w.staff_id
  left join public.staff_employment e on e.staff_id = w.staff_id
 where public.hours_count(w.*)
 group by w.staff_id, s.name, s.role, e.employment_type, w.worked_on;

commit;
