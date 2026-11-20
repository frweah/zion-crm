-- 0377 — The reports board: one row per client-month-report
--
-- The owner's rulings of 20 November 2026, after the survey in
-- docs/timing/reports.md found there was no Reports screen at all: nineteen
-- October drafts, every one of them past its date, and no screen anywhere
-- that could say so. "Which reports are overdue and whose are they" was not
-- answerable by anybody from any screen; the only thing that said it was the
-- Friday email, once a week, to each person about their own.
--
-- Five things change here, and the first two are the ones that needed his
-- say-so because they are about who may do what.
--
-- **Ruling 1 — anybody may write a report; fewer may sign one.** The update
-- policy was `is_admin() or owner_id = me`, so the sixteen October drafts
-- belonging to the Job Search owner could not be touched by the reports
-- manager whose job it is to get them out. Now every active staff member can
-- open, edit, assemble and mark Reviewed on any monthly report - in the
-- policy, not on the screen - and signing, sending and taking a signature
-- back are Reports', Admin's and the writer's. The signature has always named
-- whoever pressed the button (`signed_by`, and the image is fetched by their
-- own id), and `report_hands` below writes an access-log line whenever
-- somebody changes a report that is not theirs, so widening who may write
-- does not cost the record of who did.
--
-- What did *not* widen: a Personal note is still kept out of a report by
-- category, in `buildPeriodContent`, which is a rule about what a counselor
-- is told and not about who may press a button.
--
-- **Ruling 2 — Reports can file anybody's item.** `to_file_is_mine` let an
-- item be filed by its owner or by Admin. Of the 147 items waiting, 41 were
-- the reports manager's and 106 were somebody else's, and an unfiled
-- appointment is a line missing from a month she is the one being asked
-- about. Reports joins Admin.
--
-- **Rulings 3, 4 and 5 — the board's rows.** `report_board_rows` is the
-- screen in one call, the way `clients_board_rows` is: one row per (client,
-- month, template), built from the caseload rather than from the table, so
-- the current month has rows on the 1st instead of on the 1st of the next.
-- A row nobody has started is a row all the same, with the status "Not
-- started" and no id.
--
-- The thing to be careful about: a row that is *owed* and a row that is
-- merely *available*. The practice owes one monthly report per client per
-- month - that is what the scheduler drafts and what goes with the invoice.
-- The narrower reports are written when a counselor asks for one. So the
-- board offers a Job Coaching Update row for every client getting coaching
-- that month, and does not call it overdue when nobody has written one:
-- `owed` is the column that says which is which, and Overdue reads it. Eleven
-- clients hold a coaching authorization; a board that called eleven
-- unrequested reports late would have been eleven lies on day one.
--
-- And `service_family` is the second copy of a map that already exists in
-- `lib/report-shape.ts`. Two copies in two languages is a map that drifts, so
-- `check-reports-board.mjs` runs one against the other before every build.

begin;

-- ── the service a kind of work belongs to ────────────────────
--
-- The same fifteen rows as `FAMILY_OF` in lib/report-shape.ts. Immutable: it
-- is a statement about the names of services, not about the practice's data.
create or replace function public.service_family(p_service text)
returns text
language sql
immutable
as $$
  select case p_service
    when 'WSA Tier 1' then 'assessment'
    when 'WSA Tier 2' then 'assessment'
    when 'HQ Indicator' then 'assessment'
    when 'Job Development' then 'development'
    when 'Job Development + HQ Indicator' then 'development'
    when 'Job Placement' then 'placement'
    when 'Job Placement (SE)' then 'placement'
    when 'Job Coaching' then 'coaching'
    when 'Follow-Along' then 'coaching'
    when 'Supported Employment' then 'coaching'
    when 'Life Skills' then 'life'
    when 'CRP Group Training' then 'life'
    when 'Job Readiness' then 'life'
    when 'Temporary Work Experience' then 'life'
    else null
  end
$$;

comment on function public.service_family(text) is
  'The service family a service type belongs to. The SQL half of FAMILY_OF in lib/report-shape.ts; check-reports-board.mjs holds the two together.';

/**
 * The report a family has of its own, or nothing.
 *
 * Two of the five templates are a service's own report: a client getting job
 * development may be asked for a Job Development Update, one getting coaching
 * for a Job Coaching Update. The monthly client report is owed by everybody
 * and so is not in here; the job search report covers two families at once
 * and would double the development row; the weekly job search update has a
 * Monday for a period and cannot be a month's row at all.
 *
 * So this returns a template for two families and null for the other three,
 * and the board shows the remaining templates only where somebody has
 * actually made one.
 */
create or replace function public.report_template_for_family(p_family text)
returns text
language sql
immutable
as $$
  select case p_family
    when 'development' then 'Job Development Update'
    when 'coaching' then 'Job Coaching Update'
    else null
  end
$$;

comment on function public.report_template_for_family(text) is
  'The template a service family has a report of its own for, or null.';

-- ── who may do what to a report ──────────────────────────────

drop policy if exists client_monthly_reports_read on public.client_reports;
create policy client_monthly_reports_read on public.client_reports
  for select using ((select public.is_active_staff()));

drop policy if exists client_monthly_reports_update on public.client_reports;
create policy client_monthly_reports_update on public.client_reports
  for update using ((select public.is_active_staff()))
  with check ((select public.is_active_staff()));

comment on column public.client_reports.visible_roles is
  'Kept for the record of what a report was narrowed to when it was drafted. Since 0377 the read policy is every active staff member, so this no longer decides who sees a row.';

/*
 * A ninth thing the access log can be about.
 *
 * `access_log.subject` is a closed list, which is the right shape for it: the
 * log is read by the owner on Admin → System and a free-text subject would
 * turn eight readable kinds into however many strings somebody typed. The
 * ninth is a report somebody who is not its writer changed, which only became
 * possible above - until today only Admin and the writer could touch one, so
 * there was nothing to record.
 */
alter table public.access_log drop constraint if exists access_log_subject_check;
alter table public.access_log add constraint access_log_subject_check
  check (subject in (
    'Client restricted details',
    'Client intake',
    'Contractor tax number',
    'Signed tax form',
    'Staff document',
    'Records request',
    'Staff personal details',
    'The books',
    'Somebody else''s report'
  ));

/**
 * The narrower hands, and the log.
 *
 * The policy above says everybody may write a report. These are the three
 * things that are not everybody's, and they are here rather than in the
 * policy because they are about which column changed rather than about which
 * row:
 *
 *   signing, sending, and taking a signature back - Reports, Admin, or the
 *   writer. Putting the practice's name on a document that goes to a
 *   counselor is narrower than drafting it, and so is unsigning one.
 *
 *   the writer - Reports and Admin, which is how the sixteen October drafts
 *   get moved without anybody being able to quietly hand their own work to
 *   somebody else.
 *
 *   and a line in the access log whenever somebody changes a report that is
 *   not theirs, which is the half of ruling 1 that keeps the widening
 *   honest: "the log keeps who edited what".
 *
 * Nobody signed in is the scheduler, which drafts and redrafts every month
 * at six in the morning. It is not a person whose hands these rules are
 * about, and a log line for each of its nineteen redrafts would bury the
 * ones that matter.
 */
create or replace function public.report_hands()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_me   uuid := public.current_staff_id();
  v_role text := coalesce(public.current_staff_role(), '');
  v_may  boolean;
begin
  if v_me is null then
    return new;
  end if;

  v_may := v_role in ('Admin', 'Reports') or old.owner_id = v_me;

  if new.status is distinct from old.status
     and (new.status in ('Signed', 'Sent') or old.status = 'Signed')
     and not v_may then
    raise exception 'A report is signed and sent by its writer, by Reports or by Admin.'
      using errcode = 'insufficient_privilege';
  end if;

  if new.owner_id is distinct from old.owner_id
     and v_role not in ('Admin', 'Reports') then
    raise exception 'The writer is set by Reports or by Admin.'
      using errcode = 'insufficient_privilege';
  end if;

  if old.owner_id is distinct from v_me then
    perform public.log_access(
      'Somebody else''s report',
      new.client_id,
      null,
      format(
        '%s, %s — %s',
        new.template,
        to_char(new.period, 'FMMonth YYYY'),
        case
          when new.status is distinct from old.status
            then format('%s to %s', old.status, new.status)
          when new.owner_id is distinct from old.owner_id then 'writer changed'
          when new.due_on is distinct from old.due_on then 'due date changed'
          when new.content is distinct from old.content then 'assembled again'
          else 'edited'
        end));
  end if;

  return new;
end;
$$;

comment on function public.report_hands() is
  'Signing, sending and the writer are narrower than writing (0377), and a change to somebody else''s report is logged.';

drop trigger if exists report_hands on public.client_reports;
create trigger report_hands
  before update on public.client_reports
  for each row execute function public.report_hands();

-- ── Reports files anybody's item ─────────────────────────────
create or replace function public.to_file_is_mine(p_item uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select exists (
    select 1 from public.to_file f
     where f.id = p_item
       and (f.staff_id = public.current_staff_id()
            -- Admin answers for the practice and can clear somebody's inbox
            -- while they are away. Reports joins them on 20 November 2026:
            -- of the 147 items waiting, 106 were somebody else's, and every
            -- one of those is a line missing from a month she is the person
            -- being asked about. Nobody else can: an item is a person's own
            -- judgment about their own day.
            or public.current_staff_role() in ('Admin', 'Reports'))
  )
$$;

-- ── the board ────────────────────────────────────────────────

drop function if exists public.report_board_rows(date);

create function public.report_board_rows(p_period date default null)
returns table (
  row_key text,
  client_id uuid,
  client_name text,
  client_no integer,
  counselor text,
  office text,
  period date,
  template text,
  report_id uuid,
  status text,
  writer_id uuid,
  writer text,
  due_on date,
  days_left integer,
  signed_at timestamptz,
  sent_at timestamptz,
  sent_to text,
  owed boolean,
  services text[],
  hourly boolean,
  notes integer,
  contacts integer,
  hours numeric,
  weeks_confirmed integer,
  weeks_total integer,
  first_unconfirmed_week date,
  applications integer,
  placements integer
)
language sql
stable
security definer
set search_path to 'public'
as $$
  with asked as (
    select date_trunc('month',
             coalesce(p_period, public.practice_today())::timestamp)::date as period
  ),
  span as (
    select period,
           (period + interval '1 month' - interval '1 day')::date as last_day,
           public.practice_today() as today
      from asked
  ),
  -- Active or On hold, the same caseload the scheduler drafts for. Read
  -- behind is_active_staff() rather than behind a role: every active staff
  -- member may open any report (0377), and the board is how they open one.
  caseload as (
    select c.id, c.name, c.client_no, c.counselor_id, c.referring_office
      from public.clients c
     where public.is_active_staff()
       and c.status in ('Active', 'On hold')
       and c.merged_into is null
  ),
  /*
   * And whoever already has a report in the month, caseload or not.
   *
   * Three of October's nineteen drafts belong to clients who have since been
   * made Inactive. The first version of this joined the caseload at the end
   * and those three disappeared off the board - three drafts in somebody's
   * name, still unsent, that no screen showed. A client who is closed is owed
   * nothing further, so they get no Not-started row; what was already written
   * about them is still the practice's to finish.
   */
  named as (
    select id, name, client_no, counselor_id, referring_office from caseload
    union
    select c.id, c.name, c.client_no, c.counselor_id, c.referring_office
      from public.clients c
      join public.client_reports r on r.client_id = c.id
      cross join span
     where public.is_active_staff()
       and r.period = span.period
       and c.merged_into is null
  ),
  -- The services the client held in the month, by the same open-ended rule
  -- buildPeriodContent uses: a missing date is an end the record does not
  -- have, not a service that had finished.
  live as (
    select a.client_id, a.service_type, a.rate_type, a.id
      from public.authorizations a
      join named cl on cl.id = a.client_id
      cross join span
     where a.status <> 'Closed'
       and (a.start_date is null or a.start_date <= span.last_day)
       and (a.end_date is null or a.end_date >= span.period)
  ),
  served as (
    select l.client_id,
           array_agg(distinct l.service_type) as services,
           bool_or(l.rate_type = 'Hourly') as hourly
      from live l
     group by l.client_id
  ),
  families as (
    select distinct l.client_id, public.service_family(l.service_type) as family
      from live l
     where public.service_family(l.service_type) is not null
  ),
  -- One row per client per report the month could hold. The monthly client
  -- report is owed; a service's own report is offered.
  wanted as (
    select cl.id as client_id, 'Monthly client report'::text as template, true as owed
      from caseload cl
    union all
    select f.client_id, public.report_template_for_family(f.family), false
      from families f
     where public.report_template_for_family(f.family) is not null
  ),
  made as (
    select r.id, r.client_id, r.template, r.status, r.owner_id, r.due_on,
           r.signed_at, r.sent_at, r.sent_to
      from public.client_reports r
      join named cl on cl.id = r.client_id
      cross join span
     where r.period = span.period
  ),
  -- A full join, so a report somebody assembled that the board would not
  -- have offered - a job search report, a month after the client was closed -
  -- is a row rather than a thing that quietly is not there.
  lines as (
    select coalesce(m.client_id, w.client_id) as client_id,
           coalesce(m.template, w.template) as template,
           m.id as report_id,
           coalesce(m.status, 'Not started') as status,
           m.owner_id, m.due_on, m.signed_at, m.sent_at, m.sent_to,
           coalesce(w.owed, false) as owed
      from wanted w
      full join made m
        on m.client_id = w.client_id and m.template = w.template
  ),
  -- What the month holds, per client. The same five things the drafter reads
  -- and no others: a text is in a report once somebody logged it as a
  -- contact, and a recording once it was confirmed, so neither is counted
  -- here as a thing of its own (ruling 5).
  noted as (
    select n.client_id, count(*)::int as n
      from public.notes n
      join named cl on cl.id = n.client_id
      cross join span
     where n.at between span.period and span.last_day
       and coalesce(n.category, '') <> 'Personal'
     group by n.client_id
  ),
  spoke as (
    select g.client_id, count(*)::int as n
      from public.contact_log g
      join named cl on cl.id = g.client_id
      cross join span
     where g.date between span.period and span.last_day
       and coalesce(g.category, '') <> 'Personal'
     group by g.client_id
  ),
  logged as (
    select l.client_id, round(sum(e.hours), 2) as hours
      from public.service_entries e
      join live l on l.id = e.auth_id
      cross join span
     where e.date between span.period and span.last_day
       and not e.non_billable
     group by l.client_id
  ),
  -- Rei's weeks: the weeks whose Monday falls inside the month, which is how
  -- the board's chip counts them. A month is assembled from the weeks that
  -- overlap it, five times a year one more than this - the chip is about
  -- whose weeks are waiting to be confirmed, not about the month's arithmetic.
  weeks as (
    select w.client_id,
           count(*)::int as all_weeks,
           count(*) filter (where w.status = 'Confirmed')::int as sure,
           min(w.week_start) filter (where w.status <> 'Confirmed') as first_open
      from public.client_weekly_reports w
      join named cl on cl.id = w.client_id
      cross join span
     where w.week_start between span.period and span.last_day
     group by w.client_id
  ),
  applied as (
    select m.client_id, count(*)::int as n
      from public.lead_matches m
      join named cl on cl.id = m.client_id
      cross join span
     where m.applied_on between span.period and span.last_day
     group by m.client_id
  ),
  placed as (
    select p.client_id, count(*)::int as n
      from public.placements p
      join named cl on cl.id = p.client_id
      cross join span
     where p.start_date between span.period and span.last_day
     group by p.client_id
  )
  select ln.client_id::text || '|' || ln.template,
         ln.client_id,
         cl.name,
         cl.client_no,
         co.name,
         nullif(btrim(coalesce(cl.referring_office, '')), ''),
         span.period,
         ln.template,
         ln.report_id,
         ln.status,
         ln.owner_id,
         st.name,
         /*
          * A report nobody has started still has a date it is wanted by, if
          * it is one the practice owes: the 5th of the month after, which is
          * what the scheduler stamps on the row it makes on the 1st. Read
          * from the same function, so the board and the draft cannot differ
          * by a day.
          *
          * The narrower reports are written when a counselor asks, so an
          * unstarted one has no date and is not late. This is the whole use
          * of `owed`: eleven clients hold a coaching authorization and the
          * board would otherwise have opened with eleven reports overdue
          * that nobody had asked for.
          */
         coalesce(ln.due_on,
                  case when ln.owed then public.monthly_report_due_on(span.period) end),
         case
           when coalesce(ln.due_on,
                         case when ln.owed then public.monthly_report_due_on(span.period) end) is null
             then null
           else (coalesce(ln.due_on,
                          public.monthly_report_due_on(span.period)) - span.today)::int
         end,
         ln.signed_at,
         ln.sent_at,
         ln.sent_to,
         ln.owed,
         coalesce(sv.services, '{}'::text[]),
         coalesce(sv.hourly, false),
         coalesce(nt.n, 0),
         coalesce(sp.n, 0),
         coalesce(lg.hours, 0)::numeric,
         coalesce(wk.sure, 0),
         coalesce(wk.all_weeks, 0),
         wk.first_open,
         coalesce(ap.n, 0),
         coalesce(pl.n, 0)
    from lines ln
    cross join span
    join named cl on cl.id = ln.client_id
    left join public.counselors co on co.id = cl.counselor_id
    left join public.staff st on st.id = ln.owner_id
    left join served sv on sv.client_id = ln.client_id
    left join noted nt on nt.client_id = ln.client_id
    left join spoke sp on sp.client_id = ln.client_id
    left join logged lg on lg.client_id = ln.client_id
    left join weeks wk on wk.client_id = ln.client_id
    left join applied ap on ap.client_id = ln.client_id
    left join placed pl on pl.client_id = ln.client_id
   order by cl.name, ln.template;
$$;

comment on function public.report_board_rows(date) is
  'The reports board in one call (0377): one row per client, month and report, built from the caseload so the current month has rows from the 1st.';

revoke all on function public.report_board_rows(date) from public, anon;
grant execute on function public.report_board_rows(date) to authenticated;

revoke all on function public.service_family(text) from public, anon;
grant execute on function public.service_family(text) to authenticated;
revoke all on function public.report_template_for_family(text) from public, anon;
grant execute on function public.report_template_for_family(text) to authenticated;

commit;
