-- Zion Vocational Rehab CRM — authorized is not delivered, and the row says
-- what was invoiced
--
-- Two rulings of 9 November 2026, which are the same ruling about one column.
--
-- ── what the row is worth ────────────────────────────────────
--
-- "Billing row amount = invoiced where an invoice exists, else rate x logged
-- units, else authorized amount with 'no work logged yet'."
--
-- The amount came from the rate and the hours logged, and no hours have ever
-- been logged in this practice: `service_entries` is empty, practice-wide,
-- for every client, for all time. So every hourly row valued at $0.00 — seven
-- of the twenty-two on the Billing tab, including two that USOR has already
-- been invoiced for and one it has already paid. The hours are on the paper
-- USOR 95s, and Phase 3 answered the same gap in October by making the
-- invoice a record of its own. The Billing tab was never changed to read it.
--
-- So the figure now comes from the strongest evidence there is for it, in
-- order: what was invoiced, what has been logged, what was authorized. An
-- amount sent to the state is a fact. An amount worked out from an empty
-- table is a guess, and it was being shown as though it were a fact.
--
-- Measured over all 173 authorizations before changing anything: 35 figures
-- move, every one of them from $0.00 to a real number, and not one row begins
-- to read "paid more than authorized". The 26 settled ones get the figure the
-- state actually paid; the 9 open ones get what their authorization allows,
-- said out loud as "no work logged yet" so nobody reads it as work done.
--
-- ── and what it is waiting for ───────────────────────────────
--
-- "'Due' is not 'late'. Separate authorized from delivered."
--
-- `bill_by` is the day an authorization ought to be invoiced by, and a row
-- past it read "Overdue - meant to be billed by 12 October" in red. For seven
-- flat-fee rows that was simply wrong: nobody is late, because the service has
-- not been delivered yet. A WSA report is billed when the report is finished,
-- a placement when the client is hired, a coaching month when the month
-- closes. Until that day there is nothing to invoice and nothing to chase.
--
-- So an authorization now carries the day its service was delivered, set by
-- the person who did the work. Three sentences follow from it:
--
--   nothing delivered    "Waiting for service", and no colour on it
--   delivered, no invoice "Delivered 3 Nov, not invoiced" — this is the
--                        Needs billing list
--   14 days of that      the one chase there is
--
-- `bill_by` stays on the row and on the screen, because a counselor asks for
-- the report by a date and that date is worth knowing. It stops being a
-- deadline the practice judges itself against.

begin;

-- ── the day the work was done ────────────────────────────────

alter table public.authorizations
  add column if not exists delivered_on date,
  add column if not exists delivered_by uuid references public.staff(id) on delete set null,
  add column if not exists delivered_at timestamptz;

comment on column public.authorizations.delivered_on is
  'The day the service on this authorization was delivered — the report '
  'finished, the client hired, the coaching month closed. Set by the person '
  'who did the work. Until it is set there is nothing to bill.';

-- The service cannot have been delivered before it was authorized to start,
-- and it cannot have been delivered tomorrow.
alter table public.authorizations
  drop constraint if exists authorizations_delivered_when_it_could_be;
alter table public.authorizations
  add constraint authorizations_delivered_when_it_could_be
  check (delivered_on is null
         or start_date is null
         or delivered_on >= start_date);

create index if not exists authorizations_delivered_idx
  on public.authorizations (delivered_on)
  where delivered_on is not null;

create or replace function public.set_service_delivered(p_auth uuid, p_on date, p_reason text)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_staff uuid := public.current_staff_id();
  v_auth  public.authorizations%rowtype;
  v_had   date;
begin
  if v_staff is null then
    raise exception 'You are not signed in.' using errcode = 'insufficient_privilege';
  end if;

  select * into v_auth from public.authorizations where id = p_auth for update;
  if not found then
    raise exception 'That authorization does not exist.' using errcode = 'no_data_found';
  end if;

  -- A coaching authorization is not delivered; its months are (§5). The
  -- parent is never invoiced, so a delivery date on it would say that
  -- something was ready to bill when nothing was.
  if exists (select 1 from public.authorizations ch where ch.parent_id = p_auth) then
    raise exception 'A coaching authorization is not delivered — its months are.'
      using errcode = 'check_violation',
            hint = 'Set the month that closed, not the authorization above it.';
  end if;

  if p_on is not null and p_on > public.practice_today() then
    raise exception 'That day has not happened yet.' using errcode = 'check_violation';
  end if;

  v_had := v_auth.delivered_on;
  if v_had is not null and p_on is distinct from v_had
     and coalesce(btrim(p_reason), '') = '' then
    raise exception 'This already says the service was delivered on %. Say why that is being changed.',
      to_char(v_had, 'FMMon FMDD, YYYY')
      using errcode = 'check_violation';
  end if;

  if coalesce(btrim(p_reason), '') <> '' then
    perform set_config('zion.correction_reason', btrim(p_reason), true);
  end if;

  update public.authorizations
     set delivered_on = p_on,
         delivered_by = case when p_on is null then null else v_staff end,
         delivered_at = case when p_on is null then null else now() end
   where id = p_auth;

  perform set_config('zion.correction_reason', '', true);
end;
$$;

comment on function public.set_service_delivered is
  'The day the service on an authorization was delivered, set by the person '
  'who did the work. Clearing it is passing null; changing a day already '
  'there needs a reason, which goes in the correction log.';

revoke all on function public.set_service_delivered(uuid, date, text) from public, anon, authenticated;
grant execute on function public.set_service_delivered(uuid, date, text) to authenticated;

-- ── the correction log knows about it ────────────────────────
-- Two halves: the trigger decides what is logged, and the table decides what
-- a field may be called. The second is easy to miss - the first attempt at
-- this wrote a correction nothing could insert, and the verify script caught
-- it with a Postgres sentence about a check constraint.

alter table public.authorization_corrections
  drop constraint if exists authorization_corrections_field_check;
alter table public.authorization_corrections
  add constraint authorization_corrections_field_check
  check (field = any (array[
    'Service', 'Client', 'Number', 'Document', 'Funding source', 'Authorized hours',
    'Rate type', 'Rate', 'Amount paid', 'Starts', 'Ends', 'Received', 'Bill by',
    'Paid on', 'Warrant', 'Recipient', 'Forms required', 'Closed reason', 'Note',
    'Status', 'Service delivered']));

-- Replaced from the definition the database had, with one row added to the
-- list of fields. 'yes' means a change to a day already recorded needs a
-- reason; a first entry never does, which the trigger decides for itself.

CREATE OR REPLACE FUNCTION public.authorization_correction_log()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  -- field, the name a person reads, whether a change to it needs a reason
  k_fields constant text[][] := array[
    ['number',         'Number',          'yes'],
    ['service_type',   'Service',         'no' ],
    ['funding_source', 'Funding source',  'no' ],
    ['total_hours',    'Authorized hours','yes'],
    ['rate_type',      'Rate type',       'yes'],
    ['rate',           'Rate',            'yes'],
    -- 'no' since 0292: paid_amount is derived from the payment rows and is not
    -- a field anybody edits any more. It is still logged - a total changing is
    -- worth seeing - but demanding a reason for it would mean demanding one
    -- from the trigger that recomputes it, which has nothing to say beyond
    -- "the payments changed". The reason now belongs on the payment: see
    -- remove_payment, which writes one.
    ['paid_amount',    'Amount paid',     'no' ],
    ['start_date',     'Starts',          'no' ],
    ['end_date',       'Ends',            'no' ],
    ['received_on',    'Received',        'no' ],
    ['bill_by',        'Bill by',         'no' ],
    -- Likewise: no payments, no paid date, decided by the same trigger.
    ['paid_on',        'Paid on',         'no' ],
    ['warrant',        'Warrant',         'no' ],
    ['recipient',      'Recipient',       'no' ],
    ['requires_forms', 'Forms required',  'no' ],
    ['closed_reason',  'Closed reason',   'no' ],
    -- Status, added with the reopen (0315). 'no' means an ordinary step
    -- through the flow is not logged - only a change somebody gave a reason
    -- for, which is what a reopen and a payment on an unsubmitted
    -- authorization both do.
    ['status',         'Status',          'no' ],
    -- The day the work was done (0325). A first entry is somebody writing
    -- down what they did; a change to a day already there is a different
    -- claim about when a service was delivered, and the bill follows from
    -- it, so somebody will ask which of the two was right.
    ['delivered_on',   'Service delivered', 'yes'],
    ['note',           'Note',            'no' ]
  ];
  v_old    jsonb := to_jsonb(old);
  v_new    jsonb := to_jsonb(new);
  v_reason text := coalesce(btrim(nullif(current_setting('zion.correction_reason', true), '')), '');
  v_staff  uuid := public.current_staff_id();
  v_name   text;
  v_col    text;
  v_label  text;
  v_needs  boolean;
  v_was    text;
  v_now    text;
  v_rows   jsonb := '[]'::jsonb;
  n        integer;
begin
  for n in 1 .. array_length(k_fields, 1) loop
    v_col   := k_fields[n][1];
    v_label := k_fields[n][2];
    v_needs := k_fields[n][3] = 'yes';

    if (v_old -> v_col) is distinct from (v_new -> v_col) then
      v_was := coalesce(v_old ->> v_col, '');
      v_now := coalesce(v_new ->> v_col, '');

      /**
       * A reason for a correction, not for a first entry.
       *
       * Filling in a number that was blank, or an amount paid that was null,
       * is recording what the paperwork says - there is nothing to explain.
       * Changing a number that was already there is a correction, and
       * somebody will ask which of the two was right.
       *
       * This distinction is load-bearing: warrant reconciliation writes
       * paid_amount where there was none, and requiring a reason for that
       * would have stopped every payment the warrant reader records.
       */
      if v_needs and v_was <> '' and v_reason = '' then
        raise exception 'Changing % from % to % needs a reason',
          lower(v_label), v_was, coalesce(nullif(v_now, ''), 'nothing')
          using hint = 'Somebody will ask which of the two was right.',
                errcode = 'check_violation';
      end if;

      /**
       * And it is logged when it is a correction.
       *
       * Which is: a change to one of the fields somebody will be asked
       * about, where there was already a value - or any change somebody
       * gave a reason for, because a reason means they meant it to be read.
       *
       * Everything else is left to the record itself. A correction log that
       * also holds every date the flow stamped buries the four rows somebody
       * opened it to find, and - since the table requires a reason and those
       * writes have none - could not hold them anyway.
       */
      if (v_needs and v_was <> '') or v_reason <> '' then
        v_rows := v_rows || jsonb_build_object('field', v_label, 'was', v_was, 'new', v_now);
      end if;
    end if;
  end loop;

  if v_rows = '[]'::jsonb then
    return null;
  end if;

  select name into v_name from public.staff where id = v_staff;

  insert into public.authorization_corrections
    (auth_id, auth_number, field, was_value, new_value, reason, staff_id, staff_name)
  select new.id, old.number, r ->> 'field', r ->> 'was', r ->> 'new',
         v_reason, v_staff, coalesce(v_name, 'the system')
    from jsonb_array_elements(v_rows) as r;

  return null;
end;
$function$;

-- ── what the authorization is worth ──────────────────────────
-- A column is added to what comes back, so the function is dropped and
-- written again; the grants go with it and are put back below.

drop function if exists public.authorization_amount_for(uuid[]);

create function public.authorization_amount_for(p_auths uuid[])
returns table(auth_id uuid, amount numeric, basis text)
language sql
stable
set search_path to 'public'
as $$
  with invoiced as (
    -- Every claim raised against it. USOR takes one authorization as several
    -- claims often enough - V1002111 went out as four - and what the practice
    -- billed is all of them, not the last one.
    select i.auth_id, sum(i.amount) as amount
      from public.invoices i
     where i.auth_id = any(p_auths) and i.amount is not null
     group by i.auth_id
  ),
  logged as (
    select e.auth_id, sum(e.hours) as hours
      from public.service_entries e
     where e.auth_id = any(p_auths)
       and e.non_billable = false
     group by e.auth_id
  )
  select a.id,
         case
           when v.amount is not null then round(v.amount, 2)
           when l.hours is not null then round(l.hours * coalesce(a.rate, 0), 2)
           when a.rate_type = 'Flat Fee' then round(coalesce(a.rate, 0), 2)
           -- Nothing invoiced, nothing logged, and paid by the hour: what the
           -- authorization allows. It is the only figure there is, and
           -- `basis` says so rather than letting it pass as work done.
           --
           -- A coaching month has no hours of its own - the hours are on the
           -- authorization above it, drawn down month by month - so the
           -- ceiling is the parent's. It overstates a month where the
           -- authorization runs over several, which is why it is never shown
           -- without "no work logged yet" beside it. Reading 0.00 there was
           -- worse: it said a month was worth nothing.
           else round(coalesce(a.rate, 0) * coalesce(a.total_hours, p.total_hours, 0), 2)
         end,
         case
           when v.amount is not null then 'Invoiced'
           when l.hours is not null then 'Logged'
           when a.rate_type = 'Flat Fee' then 'Flat fee'
           else 'Authorized'
         end
    from public.authorizations a
    left join public.authorizations p on p.id = a.parent_id
    left join invoiced v on v.auth_id = a.id
    left join logged l on l.auth_id = a.id
   where a.id = any(p_auths);
$$;

comment on function public.authorization_amount_for is
  'What each authorization comes to, and on what evidence: what was invoiced '
  'for it, else the hours logged against it at its rate, else a flat fee, '
  'else what it authorizes with nothing logged.';

revoke all on function public.authorization_amount_for(uuid[]) from public, anon;
grant execute on function public.authorization_amount_for(uuid[]) to authenticated, service_role;

CREATE OR REPLACE FUNCTION public.authorization_amount(p_auth uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  select amount from public.authorization_amount_for(array[p_auth]);
$function$;

create or replace function public.authorization_amount_basis(p_auth uuid)
returns text
language sql
stable
set search_path to 'public'
as $$
  select basis from public.authorization_amount_for(array[p_auth]);
$$;

revoke all on function public.authorization_amount_basis(uuid) from public, anon;
grant execute on function public.authorization_amount_basis(uuid) to authenticated, service_role;

-- ── what it is waiting for ───────────────────────────────────

CREATE OR REPLACE FUNCTION public.authorization_attention_for(p_auths uuid[], p_today date DEFAULT NULL::date)
 RETURNS TABLE(auth_id uuid, attention text, urgency integer, blocked boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select * from (
    with me as (select coalesce(p_today, public.practice_today()) as today),
      settings as (
        select stale_grace_days, stale_soon_days from public.org_settings where id
      ),
      r as (
        select a.id,
               a.status, a.bill_by, a.stale_date, a.submitted_on, a.followup_due,
               a.delivered_on,
               coalesce(p.total_hours, a.total_hours) as authorized,
               u.used,
               exists (select 1 from public.invoices i where i.auth_id = a.id) as invoiced,
               public.authorization_blocked_from(a.stale_date) is not null
                 and public.authorization_blocked_from(a.stale_date) < (select today from me)
                 and a.status not in ('Submitted', 'Paid') as is_blocked,
               a.stale_date is not null and a.stale_date < (select today from me)
                 and (public.authorization_blocked_from(a.stale_date) is null
                      or public.authorization_blocked_from(a.stale_date) >= (select today from me))
                 and a.status not in ('Submitted', 'Paid') as is_expired,
               a.stale_date is null and a.status not in ('Submitted', 'Paid') as no_end_date,
               a.status = 'Submitted'
                 and ((a.followup_due is not null and a.followup_due <= (select today from me))
                      or (a.submitted_on is not null
                          and (select today from me) - a.submitted_on >= 14)) as needs_chasing,
               a.stale_date is not null and a.status not in ('Submitted', 'Paid')
                 and a.stale_date >= (select today from me)
                 and a.stale_date <= (select today from me) + (select stale_soon_days from settings)
                 as stale_soon
          from public.authorizations a
          left join public.authorizations p on p.id = a.parent_id
          left join public.authorization_hours_used(p_auths) u on u.auth_id = a.id
         where a.id = any(p_auths)
      ),
      h as (
        select r.*,
               -- Paid more than the authorization allows (0292). Two genuine
               -- payments from two warrants against a $585 authorization is
               -- not a mistake the practice can fix on its own: it is a
               -- question for USOR, and until somebody asks it the figure sits
               -- on the books unexplained. Flagged rather than corrected -
               -- nothing here knows which of the two is wrong.
               public.authorization_paid_total(r.id) >
                 public.authorization_amount(r.id) + 0.005
                 and public.authorization_amount(r.id) > 0 as paid_over,
               r.authorized is not null and r.authorized - r.used <= 0
                 and r.status not in ('Paid', 'Closed') as out_of_hours,
               r.authorized is not null and r.authorized - r.used > 0
                 and r.authorized - r.used <= r.authorized * 0.1
                 and r.status not in ('Paid', 'Closed') as hours_low,
               /*
                * Delivered and not invoiced: the one thing on this list that
                * is somebody's job today (0325).
                *
                * The row that used to say "Overdue - meant to be billed by
                * 12 October" said it of seven flat-fee authorizations where
                * the service had not been delivered yet. Nobody was late. The
                * only row that is late is one where the work is done and the
                * invoice has not gone out, and 14 days of that is the only
                * chase there is.
                */
               r.delivered_on is not null and not r.invoiced
                 and r.status in ('Authorized', 'Due') as needs_billing,
               r.delivered_on is not null and not r.invoiced
                 and r.status in ('Authorized', 'Due')
                 and (select today from me) - r.delivered_on >= 14 as billing_late,
               -- And the row that is simply not ready: authorized, nothing
               -- delivered. `bill_by` is what the counselor asked for, not a
               -- deadline this practice has missed.
               r.delivered_on is null and r.status in ('Authorized', 'Due') as waiting_for_service
          from r
      )
      select h.id,
             case
               when h.paid_over then 'Paid more than authorized - '
                 || to_char(public.authorization_paid_total(h.id), 'FM999999.00')
                 || ' against ' || to_char(public.authorization_amount(h.id), 'FM999999.00')
                 || '. Raise it with USOR.'
               when h.is_blocked then 'Cannot be submitted - ended ' || h.stale_date
                                      || ', more than ' || (select stale_grace_days from settings)
                                      || ' days ago'
               when h.out_of_hours then 'No hours left - request more before any further service'
               when h.needs_chasing then 'Submitted ' || h.submitted_on || ', no payment after 14 days'
               when h.billing_late then 'Delivered ' || h.delivered_on || ', still not invoiced after 14 days'
               when h.hours_low then 'Under a tenth of the hours left ('
                                      || public.fmt_hours(h.authorized - h.used) || ' of '
                                      || public.fmt_hours(h.authorized) || ')'
               when h.is_expired then 'Past its end date (' || h.stale_date || ') - can still be submitted until '
                                      || public.authorization_blocked_from(h.stale_date)
               when h.needs_billing then 'Delivered ' || h.delivered_on || ', not invoiced'
               when h.stale_soon then 'Ends ' || h.stale_date
               when h.no_end_date then 'No end date on the authorization'
               when h.waiting_for_service then 'Waiting for service'
               else ''
             end,
             case
               when h.paid_over then 0
               when h.is_blocked then 0
               when h.out_of_hours then 1
               when h.needs_chasing then 2
               when h.billing_late then 3
               when h.hours_low then 4
               when h.is_expired then 5
               when h.needs_billing then 6
               when h.stale_soon then 6
               when h.no_end_date then 7
               when h.waiting_for_service then 9
               else 10
             end,
             -- The same `is_blocked` the first branch above is chosen by, said
             -- plainly so a screen never has to read the sentence to know.
             coalesce(h.is_blocked, false)
        from h
  ) as rows_for_staff
   where public.reader_may_answer();
$function$;

-- ── and the row on the screen ────────────────────────────────

drop function if exists public.billing_worklist(date, uuid);

create function public.billing_worklist(p_today date DEFAULT NULL::date, p_client uuid DEFAULT NULL::uuid)
returns table(id uuid, client_id uuid, client_name text, number text, service_type text,
              period date, status text, bill_by date, stale_date date, submitted_on date,
              followup_due date, amount numeric, basis text, delivered_on date,
              invoiced boolean, parent_id uuid, attention text, urgency integer, blocked boolean)
language sql
stable
set search_path to 'public'
as $$
  with live as (
    select a.id, a.client_id, c.name as client_name,
           coalesce(nullif(a.number, ''), p.number, '') as number,
           a.service_type, a.period, a.status, a.bill_by, a.stale_date,
           a.submitted_on, a.followup_due, a.delivered_on, a.parent_id,
           exists (select 1 from public.invoices i where i.auth_id = a.id) as invoiced
      from public.authorizations a
      join public.clients c on c.id = a.client_id
      left join public.authorizations p on p.id = a.parent_id
     where a.status not in ('Paid', 'Closed')
       -- A coaching parent is not a bill; its months are.
       and a.id not in (select parent_id from public.authorizations where parent_id is not null)
       -- A kept placeholder is history, not work (§9).
       and not a.is_placeholder
       -- And nothing belonging to a client the practice has closed.
       and c.status <> 'Closed'
       -- One client's rows, when one client is asked for.
       and (p_client is null or a.client_id = p_client)
  ),
  ids as (select array(select id from live) as all_ids),
  amt as (
    select * from public.authorization_amount_for((select all_ids from ids))
  ),
  att as (
    select * from public.authorization_attention_for((select all_ids from ids), p_today)
  )
  select live.id, live.client_id, live.client_name, live.number, live.service_type,
         live.period, live.status, live.bill_by, live.stale_date, live.submitted_on,
         live.followup_due, amt.amount, amt.basis, live.delivered_on, live.invoiced,
         live.parent_id, att.attention, att.urgency,
         coalesce(att.blocked, false)
    from live
    left join amt on amt.auth_id = live.id
    left join att on att.auth_id = live.id
   order by att.urgency, live.bill_by nulls last, live.client_name;
$$;

comment on function public.billing_worklist is
  'Every authorization waiting to be billed, chased or paid, with what it '
  'comes to, on what evidence, whether the service has been delivered, and '
  'the one thing it is waiting for.';

revoke all on function public.billing_worklist(date, uuid) from public, anon;
grant execute on function public.billing_worklist(date, uuid) to authenticated, service_role;

commit;
