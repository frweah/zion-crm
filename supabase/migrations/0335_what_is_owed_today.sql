-- Zion Vocational Rehab CRM — four things somebody has to do, asked of the
-- database rather than remembered
--
-- The owner's rulings of 9 November 2026, the parts that are somebody's job
-- rather than a rule:
--
--   "Replace the placeholder numbers on the open invoices with the real ones
--   from her records (task for Margaret listing them)."
--
--   "For open hourly authorizations only, Margaret enters hours from the
--   paper 95s — one task. No backfill of closed ones."
--
--   "Jonathan Gustamantes has no phone — task for Margaret."
--
--   "The seven flat-fee rows: no tasks to Margaret; instead ask the assigned
--   staff member on each to set delivered or leave waiting."
--
-- Each is a question with an answer that changes by itself as the work is
-- done, so each is a function rather than four tasks typed once. The chase
-- route raises them daily and `notify_person` makes sure a person has one
-- line about each thing rather than one a day.
--
-- The last of the four is addressed per row to whoever works the client,
-- which is the whole point of it: a delivery date is something the person who
-- did the work knows, and a list of eight of them on Margaret's day is a list
-- she cannot answer.

begin;

-- ── the task kinds ───────────────────────────────────────────

alter table public.tasks drop constraint if exists tasks_source_kind_check;
alter table public.tasks add constraint tasks_source_kind_check
  check (source_kind = any (array[
    'Interview prep', 'Interview day', 'Follow-up', 'billing_item',
    'text_unanswered', 'intake', 'authorization_received', 'authorization_missing',
    'authorization_ending', 'placement_authorization', 'portal_upload',
    'portal_resume', 'mail_reply', 'clock_not_closed', 'clock_running_long',
    'clock_not_started', 'hours_correction', 'invoice_unpaid', 'invoice_unpaid_45',
    'invoice_short_paid', 'invoice_due',
    -- 0335, from the owner's rulings of 9 November 2026.
    'invoice_number_missing', 'service_hours_from_paper', 'client_has_no_phone',
    'service_not_delivered']));

-- ── an invoice whose number nobody has read ──────────────────

create or replace function public.invoices_without_a_number()
returns table(invoice_id uuid, client_id uuid, client_name text, auth_number text,
              amount numeric, submitted_on date)
language sql
stable
security definer
set search_path to 'public'
as $$
  select * from (
    select i.id, i.client_id, c.name,
           coalesce(nullif(a.number, ''), ''), i.amount, i.submitted_on
      from public.invoices i
      left join public.clients c on c.id = i.client_id
      left join public.authorizations a on a.id = i.auth_id
     where i.number is null
     order by i.submitted_on nulls last, i.amount desc
  ) as rows_for_staff
   where public.reader_may_answer();
$$;

comment on function public.invoices_without_a_number is
  'Invoices that went to USOR before the CRM numbered them, whose number '
  'nobody has read off the copy that was sent. Not a mistake to fix in the '
  'CRM: the number is on paper somewhere and has to be typed in.';

revoke all on function public.invoices_without_a_number() from public, anon;
grant execute on function public.invoices_without_a_number() to authenticated, service_role;

-- ── hourly work with no hours anywhere ───────────────────────

create or replace function public.hourly_work_without_hours()
returns table(auth_id uuid, client_id uuid, client_name text, number text,
              service_type text, total_hours numeric, rate numeric, status text)
language sql
stable
security definer
set search_path to 'public'
as $$
  select * from (
    select a.id, a.client_id, c.name,
           coalesce(nullif(a.number, ''), ''), a.service_type,
           a.total_hours, a.rate, a.status
      from public.authorizations a
      join public.clients c on c.id = a.client_id
     where a.rate_type = 'Hourly'
       and a.status in ('Authorized', 'Due', 'Submitted')
       and a.parent_id is null
       and c.status <> 'Closed'
       -- Nothing logged on it, nor on any month of it. A family is one job of
       -- data entry, not one per month.
       and not exists (
         select 1 from public.service_entries e
           join public.authorizations ch on ch.id = e.auth_id
          where (ch.id = a.id or ch.parent_id = a.id) and not e.non_billable)
       -- And a coaching authorization whose every month is settled is not
       -- waiting for hours: it is a parent nobody closed, which is a
       -- different thing and not data entry. V1037991 is one of those - its
       -- two months are Closed - and it was on this list until somebody read
       -- it and asked why.
       and (not exists (select 1 from public.authorizations ch where ch.parent_id = a.id)
            or exists (select 1 from public.authorizations ch
                        where ch.parent_id = a.id
                          and ch.status in ('Authorized', 'Due', 'Submitted')))
     order by c.name
  ) as rows_for_staff
   where public.reader_may_answer();
$$;

comment on function public.hourly_work_without_hours is
  'Open hourly authorizations with no hours logged against them or any month '
  'of them. The hours are on the paper USOR 95s; until they are entered, what '
  'the work comes to is a ceiling rather than a figure. Open ones only — the '
  'owner ruled against backfilling what is already settled.';

revoke all on function public.hourly_work_without_hours() from public, anon;
grant execute on function public.hourly_work_without_hours() to authenticated, service_role;

-- ── a client nobody can ring ─────────────────────────────────

create or replace function public.clients_without_a_number()
returns table(client_id uuid, client_name text, status text, stage text,
              assigned_staff_id uuid, reason text)
language sql
stable
security definer
set search_path to 'public'
as $$
  select * from (
    select c.id, c.name, c.status, c.stage, c.assigned_staff_id,
           coalesce(c.no_phone_reason, '')
      from public.clients c
     where c.status = 'Active'
       and c.merged_into is null
       and public.normalize_phone(c.phone) is null
       -- A client with no number may have a reason on file (0314), and a
       -- reason is an answer. This is the ones with neither.
       and coalesce(btrim(c.no_phone_reason), '') = ''
       -- Nor anybody reachable through somebody else: a client whose partner
       -- answers the phone is not a client nobody can ring.
       and not exists (
         select 1 from public.client_contacts t
          where t.client_id = c.id and t.active and t.phone is not null)
     order by c.name
  ) as rows_for_staff
   where public.reader_may_answer();
$$;

comment on function public.clients_without_a_number is
  'Active clients with no number, no reason for having none, and no contact '
  'who answers for them. Nobody can ring them and nothing can be texted to '
  'them, and neither fact shows anywhere else.';

revoke all on function public.clients_without_a_number() from public, anon;
grant execute on function public.clients_without_a_number() to authenticated, service_role;

-- ── work that may or may not be done ─────────────────────────

create or replace function public.authorizations_waiting_for_delivery()
returns table(auth_id uuid, client_id uuid, client_name text, number text,
              service_type text, bill_by date, owner_id uuid, days_open integer)
language sql
stable
security definer
set search_path to 'public'
as $$
  select * from (
    select a.id, a.client_id, c.name,
           coalesce(nullif(a.number, ''), ''), a.service_type, a.bill_by,
           coalesce(c.assigned_staff_id, c.billing_staff_id),
           (public.practice_today() - a.start_date)::integer
      from public.authorizations a
      join public.clients c on c.id = a.client_id
     where a.status in ('Authorized', 'Due')
       and a.delivered_on is null
       and not a.is_placeholder
       and c.status <> 'Closed'
       -- A coaching authorization is not delivered; its months are, and a
       -- month with no hours is asked about by its own flow.
       and not exists (select 1 from public.authorizations ch where ch.parent_id = a.id)
       -- Something has to have been expected by now, or this is a row nobody
       -- is late on and nobody needs asking about.
       and (a.bill_by is null or a.bill_by <= public.practice_today())
     order by a.bill_by nulls last, c.name
  ) as rows_for_staff
   where public.reader_may_answer();
$$;

comment on function public.authorizations_waiting_for_delivery is
  'Authorizations whose bill-by date has come with no day recorded for the '
  'service being delivered. Not late: nobody knows yet whether the work is '
  'done, and the person who does know is the one who did it.';

revoke all on function public.authorizations_waiting_for_delivery() from public, anon;
grant execute on function public.authorizations_waiting_for_delivery() to authenticated, service_role;

commit;
