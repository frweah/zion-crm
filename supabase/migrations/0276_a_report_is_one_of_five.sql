-- A report is one of five
--
-- `client_monthly_reports` (0263) already held the whole lifecycle the owner
-- asked for on 30 October: Draft, Reviewed, Signed, Sent, with the constraints
-- that say a Sent report has a PDF, an address and a signature, the trigger
-- that refuses a step out of order, and the rule that a counselor only ever
-- receives a signed one. It had nought rows in it.
--
-- So the brief's `client_reports` is that table with one column added and a
-- better name. Five tables would have been five copies of a lifecycle that
-- took a migration and a verification script to get right once.
--
--   Monthly client report · Weekly job search update · Job search report
--   Job Development Update · Job Coaching Update
--
-- Renamed rather than kept as "monthly": a table called
-- `client_monthly_reports` holding weekly job search updates is the kind of
-- name that costs somebody an afternoon in a year's time. Nought rows, so
-- nothing moves - what changes is thirteen files, two functions and two
-- verification scripts, all of which say the new name in the same commit.
--
-- `client_weekly_reports` is left alone. It is not one of the five: it is the
-- week-by-week draft the monthly report is assembled from (0260), and nothing
-- is ever sent from it.

alter table public.client_monthly_reports rename to client_reports;
alter table public.client_reports rename column month to period;

comment on table public.client_reports is
  'A report on a client for a period: one of the five templates, drafted, signed and sent to the counselor. Was client_monthly_reports until 0276.';

-- ─────────────────────────────────────────────────────────────
-- Which of the five
--
-- Defaulted to the monthly report, which is what every row would have been
-- and what the screens made until today. A default on a column added to a
-- table with rows in it would be a guess; on an empty one it is the dull case.
-- ─────────────────────────────────────────────────────────────
alter table public.client_reports
  add column if not exists template text not null default 'Monthly client report';

alter table public.client_reports drop constraint if exists client_reports_template;
alter table public.client_reports add constraint client_reports_template
  check (template in (
    'Monthly client report',
    'Weekly job search update',
    'Job search report',
    'Job Development Update',
    'Job Coaching Update'
  ));

comment on column public.client_reports.template is
  'One of the five in lib/report-shape.ts REPORT_TEMPLATES. check-client-reports asserts the two lists match (0276).';

-- ─────────────────────────────────────────────────────────────
-- One per client, per template, per period
--
-- The old key was (client_id, month), which would have let one month hold one
-- report and refused the Job Coaching Update for the same month.
-- ─────────────────────────────────────────────────────────────
alter table public.client_reports
  drop constraint if exists client_monthly_reports_client_id_month_key;
drop index if exists client_reports_client_template_period_idx;
create unique index client_reports_client_template_period_idx
  on public.client_reports (client_id, template, period);

-- ─────────────────────────────────────────────────────────────
-- What a period may be
--
-- The weekly template's period is a Monday; the other four start a month.
-- Replacing the old "day of month is 1" check, which the weekly template
-- would have failed every week of the year except the first.
-- ─────────────────────────────────────────────────────────────
alter table public.client_reports drop constraint if exists client_monthly_reports_first_of_month;
alter table public.client_reports drop constraint if exists client_reports_period_starts;
alter table public.client_reports add constraint client_reports_period_starts
  check (
    case when template = 'Weekly job search update'
      then extract(isodow from period) = 1
      else extract(day from period) = 1
    end
  );

-- ─────────────────────────────────────────────────────────────
-- The constraints that were named after the old table
--
-- Renamed rather than left: a constraint called
-- `client_monthly_reports_sent` on a table called `client_reports` is the
-- error message somebody reads when a save is refused, and it should name the
-- thing it is about.
-- ─────────────────────────────────────────────────────────────
do $$
declare r record;
begin
  for r in select conname from pg_constraint
            where conrelid = 'public.client_reports'::regclass
              and conname like 'client_monthly_reports%'
  loop
    execute format('alter table public.client_reports rename constraint %I to %I',
                   r.conname, replace(r.conname, 'client_monthly_reports', 'client_reports'));
  end loop;
end $$;

-- ─────────────────────────────────────────────────────────────
-- A step out of order is still refused
--
-- Renamed, not rewritten. The first draft of this file retyped the rule from
-- reading it, and lost three things in the retyping: that reopening a signed
-- report requires a reason and stamps who reopened it and when, that a report
-- is signed from the draft or the review and not from anywhere else, and the
-- separate wording for a sent report that is edited without its status
-- changing. Renaming keeps the body exactly, which is the only version of this
-- that cannot lose a rule.
--
-- The trigger follows the function without being touched, but it is named
-- after the old table, so it is renamed too.
do $$
begin
  if exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'monthly_report_moves_forward'
  ) then
    alter function public.monthly_report_moves_forward() rename to report_moves_forward;
  end if;
end $$;

do $$
begin
  if exists (
    select 1 from pg_trigger
     where tgrelid = 'public.client_reports'::regclass
       and tgname = 'monthly_report_moves_forward'
  ) then
    alter trigger monthly_report_moves_forward on public.client_reports
      rename to report_moves_forward;
  end if;
end $$;

-- ─────────────────────────────────────────────────────────────
-- The two functions that named the old table
-- ─────────────────────────────────────────────────────────────
-- The live body, with the table and the column renamed and the template
-- named. The first draft of this file wrote the rule out again as
-- "the month this week is in", and that is not what it says: a week can
-- straddle two months, and the overlap test below is why a week in the last
-- days of October is frozen by October's report rather than only by
-- November's. Retyping it would have unfrozen every week that crosses a
-- month boundary.
--
-- `template` is the one thing added. A signed Job Coaching Update is not a
-- reason to stop somebody writing up the week's job search, and without this
-- it would have been.
create or replace function public.weekly_report_is_frozen(p_client uuid, p_week date)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1
      from public.client_reports m
     where m.client_id = p_client
       and m.template = 'Monthly client report'
       and m.status in ('Signed', 'Sent')
       -- The week overlaps the month: it starts before the month ends and
       -- ends on or after the month starts.
       and m.period <= p_week + 6
       and (date_trunc('month', m.period::timestamp) + interval '1 month')::date > p_week
  );
$$;

-- Not granted to anybody. It is asked by the triggers that freeze a week,
-- which are SECURITY DEFINER and do not need a grant, and nothing on any
-- screen calls it. Granting it would have put it on verify_portal_rls's list
-- of elevated functions a signed-in person can call with no check of who is
-- calling - which is where this was found.
revoke all on function public.weekly_report_is_frozen(uuid, date) from anon, authenticated;

-- ─────────────────────────────────────────────────────────────
-- A report in a records request says which of the five it is
--
-- The section was called 'monthly_reports' and every row in it was one. Now
-- that four more templates share the table, a bundle that did not say which
-- would disclose five different reports as though they were all the monthly
-- one - and the one thing a records request must not do is misdescribe what
-- it hands over.
--
-- The live definition with the table and the column renamed. verify_records_
-- request asserts the section exists, so renaming it here without renaming it
-- there would fail before anybody sent a bundle.
create or replace function public.records_request_bundle(p_client uuid, p_purpose text default 'Records request')
returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare
  v_bundle jsonb;
begin
  v_bundle := public.records_request_bundle_before_reports(p_client, p_purpose);

  return v_bundle
    || jsonb_build_object(
      'weekly_reports', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'week_from', w.week_start,
                 'week_to', w.week_start + 6,
                 'status', w.status,
                 'kept_by', (select nullif(s.name, '') from public.staff s where s.id = w.owner_id),
                 'confirmed_by', (select nullif(s.name, '') from public.staff s where s.id = w.confirmed_by),
                 'confirmed_at', w.confirmed_at,
                 'what_staff_wrote', nullif(w.note, ''),
                 'what_the_record_showed', w.content
               ) order by w.week_start), '[]'::jsonb)
          from public.client_weekly_reports w where w.client_id = p_client
      ),
      'reports', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'report', m.template,
                 'period', m.period,
                 'status', m.status,
                 'due_on', m.due_on,
                 'kept_by', (select nullif(s.name, '') from public.staff s where s.id = m.owner_id),
                 'signed_by', (select nullif(s.name, '') from public.staff s where s.id = m.signed_by),
                 'signed_at', m.signed_at,
                 'sent_at', m.sent_at,
                 'sent_to', nullif(m.sent_to, ''),
                 'reopened_because', nullif(m.reopen_reason, ''),
                 'what_staff_wrote', nullif(m.note, ''),
                 'what_the_record_showed', m.content,
                 'document', (select a.filename from public.attachments a
                               where a.id = m.pdf_attachment_id)
               ) order by m.period, m.template), '[]'::jsonb)
          from public.client_reports m where m.client_id = p_client
      ));
end;
$$;

revoke all on function public.records_request_bundle(uuid, text) from anon, authenticated;
grant execute on function public.records_request_bundle(uuid, text) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- The month in a cover note
--
-- `mail_template_for` gains the period, so the progress report cover note can
-- say which month it covers instead of leaning on the authorization's dates -
-- a report for October attached to a note about an authorization running to
-- December reads as the wrong document.
--
-- Dropped and recreated rather than given a fourth defaulted parameter. A
-- defaulted parameter does not extend a function in Postgres: it makes a
-- second one, with whatever grants a new function gets, and leaves the
-- three-argument calls ambiguous between the two.
-- ─────────────────────────────────────────────────────────────
drop function if exists public.mail_template_for(text, uuid, uuid);

create or replace function public.mail_template_for(
  p_key           text,
  p_client        uuid default null,
  p_authorization uuid default null,
  p_period        date default null
)
returns table(subject text, body text)
language plpgsql stable security definer set search_path = public as $$
declare
  t    public.mail_templates;
  c    public.clients;
  k    public.counselors;
  a    public.authorizations;
  v_me text;
  v_sig  text;
  fill   text;
  fields jsonb;
  field  text;
  value  text;
begin
  if not (select public.is_active_staff()) then
    raise exception 'Only a member of staff reads the templates.' using errcode = 'insufficient_privilege';
  end if;

  select * into t from public.mail_templates where key = p_key and active;
  if not found then
    raise exception 'There is no template called %.', p_key using errcode = 'no_data_found';
  end if;

  if p_client is not null then
    select * into c from public.clients where id = p_client;
    if c.counselor_id is not null then
      select * into k from public.counselors where id = c.counselor_id;
    end if;
  end if;

  -- The authorization asked for, or the client's latest if the screen did not
  -- say which.
  if p_authorization is not null then
    select * into a from public.authorizations where id = p_authorization;
  elsif p_client is not null then
    select * into a from public.authorizations
     where client_id = p_client and status in ('Authorized', 'Due')
     order by coalesce(end_date, start_date) desc nulls last
     limit 1;
  end if;

  select s.name into v_me from public.staff s where s.id = public.current_staff_id();
  select o.mail_signature into v_sig from public.org_settings o limit 1;

  -- A gap somebody can see. A sentence that reads perfectly with the date
  -- missing is a sentence that gets sent with the date missing.
  fill := '——';

  fields := jsonb_build_object(
    '{client}',        coalesce(nullif(c.name, ''), fill),
    '{client_no}',     coalesce('#' || c.client_no::text, ''),
    '{counselor}',     coalesce(nullif(k.name, ''), 'Hello'),
    '{authorization}', coalesce(nullif(a.number, ''), fill),
    '{service}',       coalesce(nullif(a.service_type, ''), fill),
    '{issued}',        coalesce(to_char(a.start_date, 'FMMon FMDD, YYYY'), fill),
    '{ends}',          coalesce(to_char(a.end_date, 'FMMon FMDD, YYYY'), fill),
    -- The period the report covers (0276). The same gap as the rest when
    -- nothing was passed, so a cover note sent without one says so.
    '{month}',         coalesce(to_char(p_period, 'FMMonth YYYY'), fill),
    '{me}',            coalesce(nullif(v_me, ''), ''),
    '{signature}',     coalesce(nullif(v_sig, ''), '')
  );

  subject := t.subject;
  body    := t.body;
  for field, value in select * from jsonb_each_text(fields)
  loop
    subject := replace(subject, field, value);
    body    := replace(body, field, value);
  end loop;

  subject := btrim(regexp_replace(subject, '\s+', ' ', 'g'));
  return next;
end;
$$;

revoke all on function public.mail_template_for(text, uuid, uuid, date) from anon, authenticated;
grant execute on function public.mail_template_for(text, uuid, uuid, date) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- And the cover note says which period it covers
-- ─────────────────────────────────────────────────────────────
update public.mail_templates
   set subject = 'Progress report — {client} {client_no}',
       body = '{counselor},' || E'\n\n'
         || 'The progress report for {client} is attached, covering {month}.' || E'\n\n'
         || 'It is a summary of the work and where they are. Anything in it you want to go through, say so and we will.'
         || E'\n\n' || '{me}' || E'\n' || '{signature}'
 where key = 'progress_report';

-- ─────────────────────────────────────────────────────────────
-- It is still the same table to everything that reads it
-- ─────────────────────────────────────────────────────────────
do $$
declare v_n integer;
begin
  select count(*) into v_n from public.client_reports;
  if v_n <> 0 then
    raise exception 'client_reports has % rows and the rename was written for an empty table', v_n;
  end if;

  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.client_reports'::regclass and conname = 'client_reports_status'
  ) then
    raise exception 'the status constraint did not survive the rename';
  end if;

  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'mail_template_for') <> 1 then
    raise exception 'mail_template_for exists at more than one signature';
  end if;

  raise notice 'ok  client_reports holds % rows, the five templates, and one report per client per template per period', v_n;
  raise notice 'ok  mail_template_for takes the period and exists once';
end $$;
