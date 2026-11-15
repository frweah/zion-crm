-- Zion Vocational Rehab CRM — a warrant is Admin's alone
--
-- The owner's ruling (14 November 2026): everything warrant-related moves to
-- Admin. Billing cannot see a warrant stub, a warrant line, a voucher number
-- or a warrant total anywhere; it still sees the outcome - Paid or Short-paid,
-- the day, the amount. Enforced in the database, not on the screens.
--
-- ── what the survey found ────────────────────────────────────
--
-- Three tables were gated: warrant_lines, warrant_pages, warrant_documents,
-- read by Admin, Billing, or anybody with a billing view grant.
--
-- Nothing else was. The warrant and voucher numbers also live on `payments`,
-- `invoices` and `authorizations`, whose read policy is `is_active_staff()` -
-- so asked through RLS as each real role, a Job Search session and a Case
-- Manager session both read all 159 warrant numbers, all 159 vouchers, all
-- 161 invoice warrants and all 146 authorization warrants. The screens never
-- showed them. The database never refused them.
--
-- So this is not a tab moving. The columns close, and they close for everybody
-- including Admin - a column grant is to the `authenticated` database role,
-- which is who every signed-in person is. Admin reaches warrant data the way a
-- manager reaches a day's hours: through a definer function that answers one
-- question, not through a widened policy.
--
-- ── the shape ────────────────────────────────────────────────
--
--   1. warrant_hands()  - the rule, in one place.
--   2. the three warrant tables: Admin alone.
--   3. the columns: SELECT granted by name, and the warrant ones left out.
--   4. the four views that carried a warrant: rebuilt without it.
--   5. payments_for_billing() - the payment as Billing sees it: what, when,
--      how much, who recorded it. The date is `warrant_date`, which is the day
--      the money arrived (0305, and `record_payment` writes it as such), so
--      Billing gets the date it is owed under the name it is owed it.
--   6. the correction log keeps the warrant, and Admin reads it.
--
-- The functions are in 0361 and the notes in 0362: 282 of them carry a warrant
-- number in prose, which no column grant can close.

begin;

-- ── 1. the rule, once ────────────────────────────────────────

/*
 * Who may see or touch a warrant.
 *
 * Admin by role, and nothing else - not a billing grant, which is how a CPA
 * and Margaret are let into the money without being let into Admin. The whole
 * point of the ruling is that the billing grant stops carrying warrants with
 * it, so this must not ask `staff_has_area('billing', ...)`.
 */
create or replace function public.warrant_hands()
returns boolean
language sql
stable
set search_path to 'public'
as $fn$
  select public.current_staff_role() = 'Admin';
$fn$;

comment on function public.warrant_hands is
  'Whether the caller may see or touch warrant data. Admin by role, and no grant widens it.';

revoke all on function public.warrant_hands() from public, anon;
grant execute on function public.warrant_hands() to authenticated, service_role;

-- ── 2. the three warrant tables ──────────────────────────────

drop policy if exists warrant_lines_read on public.warrant_lines;
create policy warrant_lines_read on public.warrant_lines
  for select using ((select public.warrant_hands()));

drop policy if exists warrant_pages_read on public.warrant_pages;
create policy warrant_pages_read on public.warrant_pages
  for select using ((select public.warrant_hands()));

drop policy if exists warrant_documents_read on public.warrant_documents;
create policy warrant_documents_read on public.warrant_documents
  for select using ((select public.warrant_hands()));

-- ── 3. the columns ───────────────────────────────────────────

/*
 * A table-level SELECT grant covers every column, and revoking one column back
 * out of it does nothing - Postgres says so and carries on. So the table grant
 * goes and the columns are granted by name.
 *
 * Which means every column has to be listed, and a column added later arrives
 * unreadable. `verify_warrants` asserts the closed set is exactly the warrant
 * columns and nothing else, so a new column nobody granted shows up as a
 * failure rather than as an empty screen.
 */

/*
 * `warrant_date` stays open, and is the one warrant-named column that does.
 *
 * It holds the day the money arrived - `record_payment` writes the received
 * date into it, and a line read off a stub writes the day the warrant was
 * issued - and "paid on" is on the owner's list of what Billing still sees. It
 * is also what a dozen views date a payment by: `client_activity`,
 * `client_last_activity`, `invoice_month`, `billing_overview`. Closing it took
 * all of those down and told Admin it could no longer read a client's
 * activity, for no gain - a date is not a stub, a line, a voucher or a total.
 */
revoke select on public.payments from authenticated;
grant select (
  id, auth_id, amount, warrant_date, source, recorded_by, recorded_by_name,
  created_at, claim, invoice_id
) on public.payments to authenticated;
-- closed: warrant_no, voucher, warrant_line_id

revoke select on public.invoices from authenticated;
grant select (
  id, number, client_id, auth_id, claim, submitted_on, submitted_by, office_id,
  sent_to, amount, report_id, status, paid_on, amount_paid, source, note,
  created_at, updated_at
) on public.invoices to authenticated;
-- closed: warrant, voucher

revoke select on public.authorizations from authenticated;
grant select (
  id, legacy_id, client_id, number, service_type, funding_source, total_hours,
  carried_used, rate_type, rate, start_date, end_date, status, requires_forms,
  note, created_at, updated_at, dates_from_ocr, followup_owner, followup_action,
  followup_due, followup_set_at, followup_set_by, received_on, bill_by,
  stale_date, stale_reason, stale_changed_by, stale_changed_at, first_work_day,
  service_start, service_end, submitted_on, submitted_by, recipient, paid_on,
  paid_amount, correction_note, closed_reason, closed_at, closed_by, parent_id,
  period, zero_hours_confirmed_by, zero_hours_confirmed_at, is_placeholder,
  has_usor_number, delivered_on, delivered_by, delivered_at
) on public.authorizations to authenticated;
-- closed: warrant

/*
 * And the write, by the same list. A signed-in person may update an
 * authorization directly - the status moves, the stale date, the service dates
 * - so the column list has to be repeated for UPDATE, or the warrant becomes a
 * field Billing cannot read and can still set.
 */
revoke update on public.authorizations from authenticated;
grant update (
  id, legacy_id, client_id, number, service_type, funding_source, total_hours,
  carried_used, rate_type, rate, start_date, end_date, status, requires_forms,
  note, created_at, updated_at, dates_from_ocr, followup_owner, followup_action,
  followup_due, followup_set_at, followup_set_by, received_on, bill_by,
  stale_date, stale_reason, stale_changed_by, stale_changed_at, first_work_day,
  service_start, service_end, submitted_on, submitted_by, recipient, paid_on,
  paid_amount, correction_note, closed_reason, closed_at, closed_by, parent_id,
  period, zero_hours_confirmed_by, zero_hours_confirmed_at, is_placeholder,
  has_usor_number, delivered_on, delivered_by, delivered_at
) on public.authorizations to authenticated;

-- ── 4. the views that carried a warrant ──────────────────────

/*
 * Four views selected a warrant column. Two of them run as the invoker, so
 * they would fail outright once the column closed; `authorization_record` runs
 * as its owner, so it would have gone on answering - a definer view is a door
 * a column grant does not shut. Either way the column comes out of the view.
 *
 * Nothing else is built on top of these four, so each is dropped and rebuilt
 * rather than patched around.
 */

drop view if exists public.authorization_record;
create view public.authorization_record as
  select a.id,
    a.client_id,
    c.name as client_name,
    c.client_no,
    a.parent_id,
    p.number as parent_number,
    coalesce(nullif(a.number, ''), p.number, '') as number,
    a.is_placeholder,
    a.service_type,
    a.funding_source,
    a.period,
    a.status,
    a.rate_type,
    a.rate,
    a.total_hours,
    coalesce(pp.total_hours, a.total_hours) as authorized_hours,
    a.carried_used,
    a.start_date,
    a.end_date,
    a.service_start,
    a.service_end,
    a.first_work_day,
    a.received_on,
    a.bill_by,
    a.stale_date,
    a.stale_reason,
    a.submitted_on,
    a.submitted_by,
    sb.name as submitted_by_name,
    a.recipient,
    a.paid_on,
    a.paid_amount,
    a.correction_note,
    a.followup_due,
    a.closed_reason,
    a.closed_at,
    a.note,
    a.zero_hours_confirmed_at,
    k.name as counselor_name,
    k.email as counselor_email,
    bo.billing_office_id,
    bo.billing_office as billing_office_name,
    b.billing_email as billing_office_email,
    public.authorization_amount(a.id) as amount,
    coalesce((select sum(e.hours) from public.service_entries e
               where e.auth_id = a.id and not e.non_billable), 0::numeric) as hours_logged,
    coalesce((select sum(e.hours) from public.service_entries e
               join public.authorizations ch on ch.id = e.auth_id
              where not e.non_billable
                and (ch.id = coalesce(a.parent_id, a.id)
                     or ch.parent_id = coalesce(a.parent_id, a.id))), 0::numeric)
      as hours_on_the_authorization,
    public.authorization_can_submit(a.id) as can_submit,
    public.authorization_gate_met(a.id) as gate_met,
    public.authorization_missing_forms(a.id) as missing_forms,
    t.attention,
    t.urgency,
    a.delivered_on,
    sd.name as delivered_by_name,
    public.authorization_amount_basis(a.id) as amount_basis,
    (exists (select 1 from public.authorizations ch where ch.parent_id = a.id)) as has_months
   from public.authorizations a
     join public.clients c on c.id = a.client_id
     left join public.authorizations p on p.id = a.parent_id
     left join public.authorizations pp on pp.id = a.parent_id
     left join public.counselors k on k.id = c.counselor_id
     left join public.client_billing_office bo on bo.client_id = c.id
     left join public.billing_offices b on b.id = bo.billing_office_id
     left join public.staff sb on sb.id = a.submitted_by
     left join public.staff sd on sd.id = a.delivered_by
     cross join lateral public.authorization_attention(a.id) t(attention, urgency);

revoke all on public.authorization_record from public, anon, authenticated;
grant select on public.authorization_record to authenticated;

drop view if exists public.client_authorizations;
create view public.client_authorizations
with (security_invoker = true) as
  select id,
    client_id,
    number,
    has_usor_number,
    service_type,
    status,
    period,
    start_date,
    end_date,
    received_on,
    paid_on,
    paid_amount,
    closed_reason,
    rate_type,
    rate,
    total_hours,
    is_placeholder,
    parent_id,
    funding_source,
    bill_by,
    service_start,
    service_end,
    recipient,
    requires_forms,
    note,
    public.authorization_amount(id) as amount,
    case
      when status = any (array['Paid', 'Closed']) then 'Past'
      when start_date is not null and start_date > public.practice_today() then 'Upcoming'
      else 'Current'
    end as bucket
   from public.authorizations a
  where (select public.reader_may_answer());

revoke all on public.client_authorizations from public, anon, authenticated;
grant select on public.client_authorizations to authenticated;

drop view if exists public.billed_work;
create view public.billed_work
with (security_invoker = true) as
  select id as auth_id,
    client_id,
    service_type,
    number,
    period,
    status,
    coalesce(submitted_on, paid_on) as billed_on,
    public.authorization_amount(id) as amount,
    paid_on,
    paid_amount,
    status = 'Submitted' as outstanding,
    status = 'Paid' as paid
   from public.authorizations a
  where (status = any (array['Submitted', 'Paid']))
    and not (exists (select 1 from public.authorizations c where c.parent_id = a.id));

revoke all on public.billed_work from public, anon, authenticated;
grant select on public.billed_work to authenticated;

/*
 * The payments still waiting for a warrant: the "Warrant not on file" list,
 * which is now a question only Admin asks. It reads the closed columns, so it
 * runs as its owner with the rule inside it rather than as the invoker - and
 * `warrant_hands()` in the where clause means anybody else gets no rows, which
 * is the right answer to a question about warrants asked by somebody who may
 * not see one.
 */
drop view if exists public.payment_waiting_for_its_warrant;
create view public.payment_waiting_for_its_warrant as
  select p.id as payment_id,
    p.auth_id,
    a.client_id,
    c.name as client_name,
    coalesce(nullif(a.number, ''), a.service_type) as about,
    a.service_type,
    a.status as authorization_status,
    p.amount,
    p.warrant_date,
    p.voucher,
    p.source,
    p.recorded_by_name,
    p.invoice_id,
    p.created_at,
    public.practice_today() - p.warrant_date as days
   from public.payments p
     join public.authorizations a on a.id = p.auth_id
     join public.clients c on c.id = a.client_id
  where coalesce(p.warrant_no, '') = ''
    and coalesce(a.funding_source, 'Utah VR') = 'Utah VR'
    and (select public.warrant_hands());

revoke all on public.payment_waiting_for_its_warrant from public, anon, authenticated;
grant select on public.payment_waiting_for_its_warrant to authenticated;

-- ── 5. the payment, as Billing sees it ───────────────────────

/*
 * Billing reads a payment through this and nowhere else.
 *
 * `payments.warrant_date` is two things wearing one name: the date printed on
 * a warrant, and - for a payment recorded by hand, which is what
 * `record_payment` writes - the day the money arrived. The owner's list says
 * Billing sees "paid on", so the date comes back as `paid_on`. One definition
 * of the date, in one place, and no second column holding the same day.
 *
 * No warrant number, no voucher, no stub page. A payment's warrant is read on
 * Admin -> Warrants.
 */
create or replace function public.payments_for_billing(p_auths uuid[])
returns table (
  id uuid,
  auth_id uuid,
  amount numeric,
  paid_on date,
  source text,
  recorded_by_name text)
language sql
stable
security definer
set search_path to 'public'
as $fn$
  select y.id, y.auth_id, y.amount, y.warrant_date, y.source,
         coalesce(y.recorded_by_name, '')
    from public.payments y
   where y.auth_id = any (coalesce(p_auths, '{}'::uuid[]))
     and (select public.is_active_staff())
   order by y.warrant_date desc nulls last, y.created_at desc;
$fn$;

comment on function public.payments_for_billing is
  'The payments on the given authorizations as Billing sees them: the amount, the day it arrived, and who recorded it. No warrant, no voucher.';

revoke all on function public.payments_for_billing(uuid[]) from public, anon, authenticated;
grant execute on function public.payments_for_billing(uuid[]) to authenticated;

/*
 * And the month's payments, for the figure on Billing -> Overview beside the
 * list it comes from.
 *
 * A separate function rather than a defaulted argument on the one above: a
 * default makes a second function in Postgres, and the second one arrives
 * granted to everybody because nobody thought to revoke a signature they did
 * not know they had created (0272). Two names, two grants, two things said out
 * loud.
 *
 * Bounded by the two dates it is given, so it cannot become the read of every
 * payment the practice has ever taken.
 */
create or replace function public.payments_paid_between(p_from date, p_to date)
returns table (
  id uuid,
  auth_id uuid,
  amount numeric,
  paid_on date)
language sql
stable
security definer
set search_path to 'public'
as $fn$
  select y.id, y.auth_id, y.amount, y.warrant_date
    from public.payments y
   where y.warrant_date >= p_from
     and y.warrant_date < p_to
     and (select public.is_active_staff())
   order by y.warrant_date desc nulls last, y.created_at desc;
$fn$;

comment on function public.payments_paid_between is
  'The payments that arrived between two days, as Billing sees them. No warrant, no voucher.';

revoke all on function public.payments_paid_between(date, date) from public, anon, authenticated;
grant execute on function public.payments_paid_between(date, date) to authenticated;

-- ── the warrants bucket ──────────────────────────────────────

/*
 * The stub images. The policy named Admin and Billing, so a Billing session
 * could sign a link to a page image whatever the screens offered - which is
 * the same door the columns just closed, one layer down.
 */
drop policy if exists "zion read warrant pages" on storage.objects;
create policy "zion read warrant pages" on storage.objects
  for select using (
    bucket_id = 'warrants' and (select public.warrant_hands())
  );

-- ── 6. the correction log keeps the warrant, Admin reads it ──

/*
 * A change to a warrant number is logged as it always was. What changes is who
 * may read that row: dropping the field from the log to close the leak would
 * trade an audit trail for a permission, and the audit trail is what the log
 * is for.
 *
 * `field` holds the label a person reads - 'Warrant' - and not the column name
 * 'warrant'. The first version of this policy compared the column name, so it
 * matched nothing and hid nothing, and every assertion around it passed
 * because the fixture it was tested with had been written the same wrong way.
 * The constraint on the column is the list of labels, which is what caught it.
 */
drop policy if exists authorization_corrections_read on public.authorization_corrections;
create policy authorization_corrections_read on public.authorization_corrections
  for select using (
    (select public.is_active_staff())
    and (field <> 'Warrant' or (select public.warrant_hands()))
  );

commit;
