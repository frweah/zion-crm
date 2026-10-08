-- Zion Vocational Rehab CRM — the authorization is the bill
-- (Billing Simplification Brief, §§1-5, 7)
--
-- One record instead of two. The billing item was a second row carrying a
-- copy of the authorization's service, rate, hours, amount and dates, kept
-- in step by triggers; the duplication audit found six facts stored twice
-- that way and agreeing only because nobody had yet edited one side. This
-- folds the item back into the authorization it was always about.
--
-- What the authorization gains: a status that means something to Margaret
-- (Authorized, Due, Submitted, Paid, Closed), the date the form was
-- received, the date we mean to bill by, the date past which it is stale,
-- and the payment. What it loses: nothing.
--
-- Three things worth reading before the SQL.
--
--   Received on is the anchor, not the created date. A form that arrives
--   late is entered late, and bill-by has to move with the form rather than
--   with the typing. §2: "set earlier when the form arrived late."
--
--   Bill-by is ours and stale is USOR's. Bill-by is an internal target that
--   moves freely; the stale date is the authorization's end date, and past
--   it nothing can be submitted without a new authorization. Conflating the
--   two is how a practice bills against an expired authorization.
--
--   Job Coaching is a parent with a child per month (§5). The child is a
--   real authorization with its own bill-by, forms, status and payment; the
--   parent holds the hours. One authorization in production already has two
--   monthly items, and it becomes the first parent.
--
-- This migration changes shape and moves data. It does not change any rule
-- about who may do what, and it leaves every existing row readable: the
-- verify script holds it to equal counts and equal paid totals.

-- ─────────────────────────────────────────────────────────────
-- §3. When we mean to bill, by service. Admin-editable.
-- ─────────────────────────────────────────────────────────────
create table if not exists public.bill_by_defaults (
  service text primary key references public.billing_service_rules(service)
    on update cascade on delete cascade,
  /**
   * What the days are counted from.
   *
   *   received      the day the authorization form reached the practice
   *   month_end     the month a coaching child covers, plus the days
   *   first_work_day  Job Placement: four weeks after the client started
   *   placement     HQI riding on a placement: the placement's own bill-by
   */
  anchor text not null check (anchor in ('received', 'month_end', 'first_work_day', 'placement')),
  days integer not null check (days >= 0),
  note text not null default '',
  updated_at timestamptz not null default now()
);

comment on table public.bill_by_defaults is
  'How long after the anchor we mean to bill each service (§3). Rows, because the owner adjusts these.';

drop trigger if exists bill_by_defaults_updated_at on public.bill_by_defaults;
create trigger bill_by_defaults_updated_at before update on public.bill_by_defaults
  for each row execute function public.set_updated_at();

insert into public.bill_by_defaults (service, anchor, days, note) values
  ('WSA Tier 1',                     'received',       7,  'USOR 94/98'),
  ('WSA Tier 2',                     'received',       7,  'USOR 94/98'),
  ('Life Skills',                    'received',       14, ''),
  ('Job Development',                'received',       14, ''),
  ('Job Development + HQ Indicator', 'received',       14, ''),
  ('Job Search',                     'received',       14, ''),
  ('Job Readiness',                  'received',       14, ''),
  ('CRP Group Training',             'received',       14, ''),
  ('Supported Employment',           'received',       14, ''),
  ('Job Placement',                  'first_work_day', 28, 'USOR 60 + 92, four weeks after the first day of work'),
  ('Job Placement (SE)',             'first_work_day', 28, 'USOR 60 + 92'),
  ('Job Coaching',                   'month_end',      7,  'Each month, seven days after the month ends'),
  ('Other',                          'received',       14, '')
on conflict (service) do nothing;

-- ─────────────────────────────────────────────────────────────
-- §2. The fields an authorization carries now
-- ─────────────────────────────────────────────────────────────
alter table public.authorizations
  -- The anchor for bill-by. Defaults to the day it was entered, and is
  -- meant to be corrected when the form arrived before somebody typed it.
  add column if not exists received_on date,
  add column if not exists bill_by date,
  -- = the authorization's end date, changeable with a reason that is kept.
  add column if not exists stale_date date,
  add column if not exists stale_reason text not null default '',
  add column if not exists stale_changed_by uuid references public.staff(id) on delete set null,
  add column if not exists stale_changed_at timestamptz,
  -- Job Placement's clock starts here rather than at the authorization.
  add column if not exists first_work_day date,
  /**
   * When the work actually happened.
   *
   * §8: "Service dates never inherit authorization dates." They answer
   * different questions - the authorization says what USOR allowed and
   * when, the service dates say what was done and when - and the submit
   * gate compares the two, which it cannot do if one is a copy of the
   * other. So these stay empty until somebody records them.
   */
  add column if not exists service_start date,
  add column if not exists service_end date,
  -- The submission, and what came back.
  add column if not exists submitted_on date,
  add column if not exists submitted_by uuid references public.staff(id) on delete set null,
  add column if not exists recipient text,
  add column if not exists paid_on date,
  add column if not exists paid_amount numeric(10, 2),
  add column if not exists warrant text,
  add column if not exists correction_note text,
  add column if not exists followup_due date,
  add column if not exists closed_reason text,
  add column if not exists closed_at timestamptz,
  add column if not exists closed_by uuid references public.staff(id) on delete set null,
  -- §5: a coaching month hangs off its coaching authorization.
  add column if not exists parent_id uuid references public.authorizations(id) on delete cascade,
  -- The month a coaching child covers. Null on everything else.
  add column if not exists period date,
  add column if not exists zero_hours_confirmed_by uuid references public.staff(id) on delete set null,
  add column if not exists zero_hours_confirmed_at timestamptz;

comment on column public.authorizations.received_on is
  'The day the authorization form reached the practice, which is the anchor for bill-by (§2). Not the day somebody typed it in.';
comment on column public.authorizations.bill_by is
  'When we mean to have billed it (§2). Ours, and moves freely; nothing is blocked by it.';
comment on column public.authorizations.stale_date is
  'The authorization''s end date (§2). Past it nothing is submitted without a new authorization; changing it needs a reason, which is kept.';
comment on column public.authorizations.parent_id is
  'The coaching authorization this month hangs off (§5). The parent holds the hours; the child has its own bill-by, forms, status and payment.';
comment on column public.authorizations.service_start is
  'When the work actually started (§8). Never copied from the authorization: the submit gate compares the two.';
comment on column public.authorizations.period is
  'The month a coaching child covers (§5). Null on every other kind of authorization.';

create index if not exists authorizations_parent_idx on public.authorizations (parent_id)
  where parent_id is not null;
create index if not exists authorizations_bill_by_idx on public.authorizations (bill_by);

/**
 * A coaching month has no hours of its own.
 *
 * The existing rule is that an hourly authorization names its hours. That
 * holds for every authorization somebody enters, and cannot hold for a
 * coaching child: §5 puts the hours on the parent, where they are authorized
 * once and drawn down by the months. So a child is exempt, and only a child.
 */
alter table public.authorizations drop constraint if exists authorizations_hourly_needs_hours;
alter table public.authorizations
  add constraint authorizations_hourly_needs_hours
  check (parent_id is not null or rate_type <> 'Hourly' or total_hours is not null);

-- A coaching parent has one child per month, and a child is not its own parent.
create unique index if not exists authorizations_one_child_per_month
  on public.authorizations (parent_id, period) where parent_id is not null;

alter table public.authorizations
  drop constraint if exists authorizations_child_has_a_period;
alter table public.authorizations
  add constraint authorizations_child_has_a_period
  check (parent_id is null or period is not null);

alter table public.authorizations
  drop constraint if exists authorizations_not_its_own_parent;
alter table public.authorizations
  add constraint authorizations_not_its_own_parent
  check (parent_id is null or parent_id <> id);

-- ─────────────────────────────────────────────────────────────
-- §3. What bill-by should be, given the service
-- ─────────────────────────────────────────────────────────────
create or replace function public.bill_by_for(
  p_service text,
  p_received_on date,
  p_period date default null,
  p_first_work_day date default null
) returns date language sql stable set search_path = public as $$
  select case d.anchor
           when 'month_end' then
             -- The month it covers, plus the days. A coaching child with no
             -- month yet falls back to the received date so it is never null.
             case when p_period is null then p_received_on + d.days
                  else (date_trunc('month', p_period) + interval '1 month - 1 day')::date + d.days end
           when 'first_work_day' then
             -- No first day of work yet means no clock yet; the received
             -- date keeps it visible rather than hiding it from the list.
             coalesce(p_first_work_day, p_received_on) + d.days
           else p_received_on + d.days
         end
    from public.bill_by_defaults d
   where d.service = p_service
   union all
   -- A service with no row of its own still gets a target.
   select p_received_on + 14
   where not exists (select 1 from public.bill_by_defaults d2 where d2.service = p_service)
   limit 1;
$$;

comment on function public.bill_by_for is
  'The bill-by date §3 implies for a service, from whichever anchor that service counts from.';

revoke all on function public.bill_by_for(text, date, date, date) from anon, authenticated;
grant execute on function public.bill_by_for(text, date, date, date) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- §7. Fold each billing item into its authorization
--
-- Done before the status constraint changes, so the old values are still
-- legal while they are being read, and in one statement per fact so the
-- mapping is visible rather than buried in a loop.
-- ─────────────────────────────────────────────────────────────

-- The old constraint allowed Open, Paid and Closed only, and the fold below
-- writes Authorized, Due and Submitted. It goes first; the new one is added
-- once every row has been mapped, so there is no moment where a row could
-- hold a status nothing allows.
alter table public.authorizations drop constraint if exists authorizations_status_check;

-- The one authorization that already has several monthly items becomes a
-- parent, and each of its items becomes a child authorization. Done first,
-- because the single-item fold below must not see these.
do $$
declare
  v_parent record;
  v_item   record;
  v_child  uuid;
begin
  for v_parent in
    select auth_id from public.billing_items
     where auth_id is not null
     group by auth_id having count(*) > 1
  loop
    for v_item in
      select * from public.billing_items where auth_id = v_parent.auth_id order by period nulls first
    loop
      insert into public.authorizations (
        client_id, number, service_type, funding_source, rate_type, rate,
        total_hours, carried_used, start_date, end_date, requires_forms, note,
        parent_id, period, received_on, first_work_day, service_start, service_end,
        status, submitted_on, submitted_by, recipient,
        paid_on, paid_amount, warrant, correction_note, followup_due,
        closed_reason, closed_at, closed_by
      )
      select a.client_id,
             /**
              * The child carries no number of its own.
              *
              * It is the same USOR authorization, for one month of it, and
              * §11 says a fact lives in one place: the number is the
              * parent's and is read from there. The uniqueness index already
              * exempts a blank, so this needs no new rule - and searching by
              * number finds the authorization rather than twelve copies of
              * it.
              */
             '', a.service_type, a.funding_source, a.rate_type,
             coalesce(v_item.rate, a.rate),
             -- Hours live on the parent (§5); the child carries none.
             null, 0,
             a.start_date, a.end_date, a.requires_forms, coalesce(v_item.notes, ''),
             a.id, v_item.period,
             coalesce(v_item.created_at::date, a.created_at::date),
             v_item.first_work_day, v_item.service_start, v_item.service_end,
             case v_item.status
               when 'Referral received'        then 'Authorized'
               when 'Authorization received'   then 'Authorized'
               when 'Service in progress'      then 'Authorized'
               when 'Service period complete'  then 'Due'
               when 'Ready for billing'        then 'Due'
               when 'Billing review'           then 'Due'
               when 'Submitted'                then 'Submitted'
               when 'Pending'                  then 'Submitted'
               when 'Correction needed'        then 'Submitted'
               when 'Paid'                     then 'Paid'
               when 'Closed'                   then 'Closed'
               else 'Authorized'
             end,
             v_item.submitted_at::date, v_item.submitted_by, v_item.recipient,
             v_item.paid_on, v_item.paid_amount, v_item.warrant,
             v_item.correction_note, v_item.followup_due,
             v_item.closed_reason, v_item.closed_at, v_item.closed_by
        from public.authorizations a where a.id = v_parent.auth_id
      returning id into v_child;

      -- Everything that pointed at the item now points at the child.
      update public.service_entries set auth_id = v_child
       where auth_id = v_parent.auth_id
         and v_item.period is not null
         and date_trunc('month', date)::date = v_item.period;
    end loop;

    -- The parent itself is the hours, and is never billed directly.
    update public.authorizations
       set status = 'Authorized',
           received_on = coalesce(received_on, created_at::date)
     where id = v_parent.auth_id;
  end loop;
end $$;

-- Every other item folds straight onto its authorization.
update public.authorizations a
   set received_on = coalesce(a.received_on, i.created_at::date, a.created_at::date),
       first_work_day = coalesce(a.first_work_day, i.first_work_day),
       service_start = coalesce(a.service_start, i.service_start),
       service_end = coalesce(a.service_end, i.service_end),
       submitted_on = coalesce(a.submitted_on, i.submitted_at::date),
       submitted_by = coalesce(a.submitted_by, i.submitted_by),
       recipient = coalesce(a.recipient, i.recipient),
       paid_on = coalesce(a.paid_on, i.paid_on),
       paid_amount = coalesce(a.paid_amount, i.paid_amount),
       warrant = coalesce(a.warrant, nullif(i.warrant, '')),
       correction_note = coalesce(a.correction_note, i.correction_note),
       followup_due = coalesce(a.followup_due, i.followup_due),
       closed_reason = coalesce(a.closed_reason, i.closed_reason),
       closed_at = coalesce(a.closed_at, i.closed_at),
       closed_by = coalesce(a.closed_by, i.closed_by),
       period = coalesce(a.period, i.period)
  from public.billing_items i
 where i.auth_id = a.id
   and a.parent_id is null
   and not exists (
     select 1 from public.billing_items j
      where j.auth_id = a.id group by j.auth_id having count(*) > 1);

-- ─────────────────────────────────────────────────────────────
-- §4. The four working states, and Closed
--
-- The old values were Open, Paid and Closed. Open becomes Authorized, or
-- Due where the item it came from had got that far, which is why the fold
-- above runs first.
-- ─────────────────────────────────────────────────────────────
update public.authorizations a
   set status = coalesce(
     (select case i.status
               when 'Referral received'       then 'Authorized'
               when 'Authorization received'  then 'Authorized'
               when 'Service in progress'     then 'Authorized'
               when 'Service period complete' then 'Due'
               when 'Ready for billing'       then 'Due'
               when 'Billing review'          then 'Due'
               when 'Submitted'               then 'Submitted'
               when 'Pending'                 then 'Submitted'
               when 'Correction needed'       then 'Submitted'
               when 'Paid'                    then 'Paid'
               when 'Closed'                  then 'Closed'
             end
        from public.billing_items i where i.auth_id = a.id limit 1),
     case a.status when 'Open' then 'Authorized'
                   when 'Paid' then 'Paid'
                   when 'Closed' then 'Closed'
                   else a.status end)
 where a.parent_id is null;

-- A parent is never billed, so it sits at Authorized until its hours run out.
update public.authorizations set status = 'Authorized'
 where parent_id is null
   and id in (select parent_id from public.authorizations where parent_id is not null)
   and status not in ('Closed');

alter table public.authorizations
  add constraint authorizations_status_check
  check (status in ('Authorized', 'Due', 'Submitted', 'Paid', 'Closed'));

alter table public.authorizations alter column status set default 'Authorized';

comment on column public.authorizations.status is
  'Authorized, Due, Submitted, Paid, or Closed (§4). The old Service in progress, Service period complete, Ready for billing, Billing review and Pending are gone: Pending is the follow-up task, and an authorization is simply Submitted until it is Paid.';

-- ─────────────────────────────────────────────────────────────
-- The dates every row now needs
-- ─────────────────────────────────────────────────────────────
update public.authorizations
   set received_on = coalesce(received_on, created_at::date),
       stale_date = coalesce(stale_date, end_date);

update public.authorizations
   set bill_by = coalesce(
     bill_by,
     public.bill_by_for(service_type, received_on, period, first_work_day));

-- Closed needs its reason, like everything else that closes in this system.
update public.authorizations
   set closed_reason = coalesce(nullif(closed_reason, ''), 'Carried over from the billing item')
 where status = 'Closed';

alter table public.authorizations
  drop constraint if exists authorizations_service_dates_in_order;
alter table public.authorizations
  add constraint authorizations_service_dates_in_order
  check (service_start is null or service_end is null or service_end >= service_start);

alter table public.authorizations
  drop constraint if exists authorizations_closed_has_reason;
alter table public.authorizations
  add constraint authorizations_closed_has_reason
  check (status <> 'Closed' or coalesce(btrim(closed_reason), '') <> '');

alter table public.authorizations
  drop constraint if exists authorizations_paid_has_payment;
alter table public.authorizations
  add constraint authorizations_paid_has_payment
  check (status <> 'Paid' or paid_on is not null);

/**
 * Submitted means we know when. Paid does not have to.
 *
 * Every one of the 139 paid rows carried over from the workbook has no
 * submission date at all - the spreadsheet recorded the payment and never
 * the sending. The obvious fix is to backfill it from the payment date, and
 * it would be a lie with teeth: ledger_payment_lag() measures how long USOR
 * actually takes to pay by the gap between those two dates, so filling one
 * from the other would tell the practice USOR pays on the day of billing and
 * quietly wreck the cash forecast built on it.
 *
 * So the rule is only about the state that needs it. Submitted starts the
 * 14-day follow-up clock (§4) and cannot exist without a date. Paid from the
 * workbook is history, and history is allowed to be incomplete as long as it
 * is not invented. Anything submitted through the new flow gets its date
 * from the submit action, so Paid rows made from here on have one.
 */
alter table public.authorizations
  drop constraint if exists authorizations_submitted_has_a_date;
alter table public.authorizations
  add constraint authorizations_submitted_has_a_date
  check (status <> 'Submitted' or submitted_on is not null);

alter table public.authorizations alter column received_on set not null;
alter table public.authorizations alter column received_on set default current_date;
