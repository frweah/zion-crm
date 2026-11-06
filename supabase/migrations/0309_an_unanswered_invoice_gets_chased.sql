-- Zion Vocational Rehab CRM — the invoice ledger (Phase 3, part four)
--
-- Two rules, both written as functions the nightly sweep calls rather than as
-- logic inside a route, because a rule in SQL can be tried in a transaction
-- that is rolled back and a rule in a route cannot.
--
-- ── chasing what was sent ─────────────────────────────────────
--
-- Submitted and unpaid after thirty days goes to the intake desk; after
-- forty-five it goes to the owner as well, and the earlier one stays, because
-- the person chasing it has not stopped chasing it. Short-paid goes to the
-- intake desk with the difference, on the day it happens rather than after
-- thirty, because a short payment is an answer and an answer can be queried.
--
-- The thresholds are days since the invoice was sent, not since the
-- authorization was marked submitted. Phase 2 is the reason: V1037901 was
-- invoiced on 6 October and the CRM had no idea it had been sent at all, and
-- V1045641 was invoiced on 27 October while its authorization sat as
-- Authorized. Counting from the invoice is counting from the thing that
-- actually went to the state.
--
-- ── the deadline for sending one ──────────────────────────────
--
-- Work logged against an authorization and no invoice covering it by the 5th
-- of the following month is late, and the USOR forms say so themselves: "This
-- form is due by end of business on the 15th day of the following month." The
-- 5th gives ten days to act on being told.
--
-- It goes to the person carrying the client and to the intake desk, which is
-- the shape the report-due rule already has - the sister rule this one was
-- asked to match.

begin;

-- ── the four kinds these rules raise ─────────────────────────
--
-- tasks.source_kind is a closed list, which is right: a My day item whose
-- kind is a typo is an item nothing can find again. Four kinds are added
-- rather than one, because they are four different things to be told and
-- notify_person keys its deduplication on the kind - chasing at thirty and
-- escalating at forty-five have to be able to coexist on the same invoice,
-- and they cannot if they share a kind.
alter table public.tasks drop constraint if exists tasks_source_kind_check;
alter table public.tasks add constraint tasks_source_kind_check
  check (source_kind = any (array[
    'Interview prep', 'Interview day', 'Follow-up', 'billing_item',
    'text_unanswered', 'intake', 'authorization_received', 'authorization_missing',
    'authorization_ending', 'placement_authorization', 'portal_upload',
    'portal_resume', 'mail_reply', 'clock_not_closed', 'clock_running_long',
    'clock_not_started', 'hours_correction',
    -- Phase 3: an invoice unanswered at thirty days, the same at forty-five,
    -- one paid short, and work logged that nothing has billed.
    'invoice_unpaid', 'invoice_unpaid_45', 'invoice_short_paid', 'invoice_due']));

create or replace function public.chase_invoices(p_today date default null)
returns table(staff_name text, email text, message text, task_id uuid)
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_day      date := coalesce(p_today, public.practice_today());
  v_intake   uuid;
  v_owner    uuid;
  r          record;
begin
  select intake_staff_id into v_intake from public.org_settings limit 1;
  select id into v_owner from public.staff
   where role = 'Admin' and active and not is_system order by created_at limit 1;

  for r in
    select i.id, i.number, i.amount, i.amount_paid, i.status, i.client_id, i.submitted_on,
           (v_day - i.submitted_on) as days,
           coalesce(nullif(a.number, ''), a.service_type) as about,
           coalesce(b.name, nullif(i.sent_to, ''), 'USOR') as office
      from public.invoices i
      left join public.authorizations a on a.id = i.auth_id
      left join public.billing_offices b on b.id = i.office_id
     where i.status in ('Submitted', 'Short-paid')
       and i.submitted_on is not null
     order by i.submitted_on, i.number
  loop
    -- ── short-paid, which is an answer rather than a silence ──
    if r.status = 'Short-paid' then
      if v_intake is not null then
        return query
          select n.staff_name, n.email, n.message, n.task_id from public.notify_person(
            v_intake, 'invoice_short_paid',
            format('Invoice %s to %s was paid $%s of $%s - $%s short. %s.',
                   r.number, r.office,
                   to_char(coalesce(r.amount_paid, 0), 'FM999999.00'),
                   to_char(coalesce(r.amount, 0), 'FM999999.00'),
                   to_char(coalesce(r.amount, 0) - coalesce(r.amount_paid, 0), 'FM999999.00'),
                   r.about),
            r.id::text, '/billing/invoices?invoice=' || r.id::text, r.client_id,
            format('Invoice %s short by $%s', r.number,
                   to_char(coalesce(r.amount, 0) - coalesce(r.amount_paid, 0), 'FM999999.00')),
            v_day, 'bad', r.id) n;
      end if;
      continue;
    end if;

    -- ── thirty days, then forty-five ─────────────────────────
    if r.days >= 30 and v_intake is not null then
      return query
        select n.staff_name, n.email, n.message, n.task_id from public.notify_person(
          v_intake, 'invoice_unpaid',
          format('Invoice %s to %s has been unpaid %s days - $%s for %s, sent %s.',
                 r.number, r.office, r.days,
                 to_char(coalesce(r.amount, 0), 'FM999999.00'), r.about,
                 to_char(r.submitted_on, 'FMDD FMMonth')),
          r.id::text, '/billing/invoices?invoice=' || r.id::text, r.client_id,
          format('Chase %s for invoice %s, $%s', r.office, r.number,
                 to_char(coalesce(r.amount, 0), 'FM999999.00')),
          v_day, 'warn', r.id) n;
    end if;

    if r.days >= 45 and v_owner is not null then
      return query
        select n.staff_name, n.email, n.message, n.task_id from public.notify_person(
          v_owner, 'invoice_unpaid_45',
          format('Invoice %s to %s is %s days unpaid - $%s for %s. The intake desk has had it since day thirty.',
                 r.number, r.office, r.days,
                 to_char(coalesce(r.amount, 0), 'FM999999.00'), r.about),
          r.id::text, '/billing/invoices?invoice=' || r.id::text, r.client_id,
          format('%s has not paid invoice %s in %s days', r.office, r.number, r.days),
          v_day, 'bad', r.id) n;
    end if;
  end loop;
end $$;

revoke execute on function public.chase_invoices(date) from anon, authenticated;

-- ── work done and not billed ─────────────────────────────────
create or replace function public.invoices_due(p_today date default null)
returns table(staff_name text, email text, message text, task_id uuid)
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_day    date := coalesce(p_today, public.practice_today());
  v_intake uuid;
  r        record;
begin
  select intake_staff_id into v_intake from public.org_settings limit 1;

  for r in
    select a.id as auth_id, a.client_id,
           coalesce(nullif(a.number, ''), a.service_type) as about,
           date_trunc('month', e.date)::date as month,
           sum(e.hours) as hours,
           c.assigned_staff_id
      from public.service_entries e
      join public.authorizations a on a.id = e.auth_id
      join public.clients c on c.id = a.client_id
     where not e.non_billable
       and not exists (select 1 from public.invoice_lines l where l.entry_id = e.id)
       and a.status <> 'Closed'
       -- The 5th of the month after the work. date_trunc plus a month plus
       -- four days is the 5th; the comparison is "we are past it".
       and v_day >= (date_trunc('month', e.date) + interval '1 month' + interval '4 days')::date
     group by a.id, a.client_id, a.number, a.service_type, date_trunc('month', e.date), c.assigned_staff_id
     order by month, about
  loop
    -- Whoever carries the client, and the intake desk. Two items rather than
    -- one: notify_person keys on the assignee as well as the source, so the
    -- same month's work can be on both lists without either taking the other's
    -- row.
    if r.assigned_staff_id is not null then
      return query
        select n.staff_name, n.email, n.message, n.task_id from public.notify_person(
          r.assigned_staff_id, 'invoice_due',
          format('%s hours were logged on %s in %s and nothing has been invoiced. It was due by the 5th.',
                 to_char(r.hours, 'FM999990.99'), r.about, to_char(r.month, 'FMMonth')),
          r.auth_id::text || ':' || to_char(r.month, 'YYYY-MM'),
          '/billing/authorizations/' || r.auth_id::text, r.client_id,
          format('Invoice due: %s, %s', r.about, to_char(r.month, 'FMMonth')),
          v_day, 'warn', r.auth_id) n;
    end if;

    if v_intake is not null and v_intake is distinct from r.assigned_staff_id then
      return query
        select n.staff_name, n.email, n.message, n.task_id from public.notify_person(
          v_intake, 'invoice_due',
          format('%s hours were logged on %s in %s and nothing has been invoiced. It was due by the 5th.',
                 to_char(r.hours, 'FM999990.99'), r.about, to_char(r.month, 'FMMonth')),
          r.auth_id::text || ':' || to_char(r.month, 'YYYY-MM'),
          '/billing/authorizations/' || r.auth_id::text, r.client_id,
          format('Invoice due: %s, %s', r.about, to_char(r.month, 'FMMonth')),
          v_day, 'warn', r.auth_id) n;
    end if;
  end loop;
end $$;

revoke execute on function public.invoices_due(date) from anon, authenticated;

-- ── what the home tile reads ─────────────────────────────────
--
-- One row, four numbers, read from the ledger rather than kept beside it.
create or replace view public.invoice_month as
  select
    coalesce((select sum(i.amount) from public.invoices i
               where i.submitted_on >= date_trunc('month', public.practice_today())::date), 0) as invoiced_this_month,
    coalesce((select sum(p.amount) from public.payments p
               where p.warrant_date >= date_trunc('month', public.practice_today())::date), 0) as paid_this_month,
    coalesce((select sum(i.amount) from public.invoices i
               where i.status in ('Submitted', 'Short-paid')), 0) as outstanding,
    coalesce((select sum(i.amount) from public.invoices i
               where i.status in ('Submitted', 'Short-paid')
                 and i.submitted_on is not null
                 and public.practice_today() - i.submitted_on >= 30), 0) as overdue,
    (select count(*) from public.invoices i
      where i.status in ('Submitted', 'Short-paid')) as open_invoices,
    (select count(*) from public.invoices i
      where i.status in ('Submitted', 'Short-paid')
        and i.submitted_on is not null
        and public.practice_today() - i.submitted_on >= 30) as overdue_invoices;

alter view public.invoice_month set (security_invoker = on);
revoke all on public.invoice_month from anon, authenticated;
grant select on public.invoice_month to authenticated;

commit;
