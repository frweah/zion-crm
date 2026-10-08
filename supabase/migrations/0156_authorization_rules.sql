-- Zion Vocational Rehab CRM — the rules the new flow needs
-- (Billing Simplification Brief, §§4-6, 13.8)
--
-- 0155 changed the shape. This is what the shape has to refuse.
--
--   A status moves the way the work moves. Authorized to Due to Submitted
--   to Paid, Closed from anywhere with a reason. Backwards is allowed where
--   reality goes backwards - a submission returned for correction, a payment
--   undone - and only there, because the ledger reverses its postings off
--   exactly those moves and a status that could jump anywhere would post
--   nonsense.
--
--   Nothing is submitted past its stale date. §4: "submitting is blocked
--   until a new authorization is entered or the stale date is changed with a
--   reason." That is the one hard block in the flow, because billing against
--   an expired authorization is the mistake that costs the practice a
--   payment and its standing with USOR at once.
--
--   Every change of status is written down. The billing item had an event
--   log and the authorization did not; folding the two without carrying the
--   log would lose the answer to "who moved this, and when" - which is the
--   question a correction six weeks later always starts with.
--
--   A coaching month makes itself, and closes itself when it is empty.

-- ─────────────────────────────────────────────────────────────
-- The numbers the owner adjusts
--
-- §4, revised by the owner on 7 Oct: an expired authorization is a warning,
-- not a wall. Submitting after the end date is allowed and flagged; it is
-- only refused once it is 90 days past, and that 90 is theirs to change.
--
-- The reason for the change is worth recording. On the migrated data, 13 of
-- 21 live authorizations were already past their end date - median 16 days,
-- worst 311 - and 7 more had no end date at all. A hard block would have
-- stopped the October close on day one over data the practice inherited
-- rather than over anything it did wrong. A warning tells Margaret the same
-- thing without standing in front of her.
-- ─────────────────────────────────────────────────────────────
alter table public.org_settings
  add column if not exists stale_grace_days integer not null default 90,
  add column if not exists stale_soon_days integer not null default 14;

alter table public.org_settings
  drop constraint if exists org_settings_grace_is_sane;
alter table public.org_settings
  add constraint org_settings_grace_is_sane
  check (stale_grace_days between 0 and 3650 and stale_soon_days between 0 and 365);

comment on column public.org_settings.stale_grace_days is
  'How long past its end date an authorization may still be submitted (§4, owner 7 Oct). Past this it is refused. Zero makes the end date a hard wall again.';
comment on column public.org_settings.stale_soon_days is
  'How long before the end date the "goes stale soon" warning starts (§6).';

/**
 * The day an authorization stops being submittable at all.
 *
 * Null where there is no end date: §4 as revised says a missing end date
 * warns and never blocks, because the practice cannot be stopped by a field
 * USOR left empty.
 */
create or replace function public.authorization_blocked_from(p_stale date)
returns date language sql stable set search_path = public as $$
  select case when p_stale is null then null
              else p_stale + (select stale_grace_days from public.org_settings where id) end;
$$;

comment on function public.authorization_blocked_from is
  'The day submitting is refused: the stale date plus the grace the owner set (§4). Null when there is no end date, which never blocks.';

revoke all on function public.authorization_blocked_from(date) from anon, authenticated;
grant execute on function public.authorization_blocked_from(date) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- What happened to it, and who did it
-- ─────────────────────────────────────────────────────────────
create table if not exists public.authorization_events (
  id uuid primary key default gen_random_uuid(),
  auth_id uuid not null references public.authorizations(id) on delete cascade,
  at timestamptz not null default now(),
  staff_id uuid references public.staff(id) on delete set null,
  staff_name text,
  was text,
  became text,
  note text
);

comment on table public.authorization_events is
  'Every move from one status to the next, with who and when (§4). Replaces billing_item_events, which went with the billing item.';

create index if not exists authorization_events_auth_idx
  on public.authorization_events (auth_id, at desc);

alter table public.authorization_events enable row level security;

drop policy if exists authorization_events_read on public.authorization_events;
create policy authorization_events_read on public.authorization_events
  for select to authenticated
  using ((select public.is_admin()) or (select public.staff_has_area('billing')));

grant select on public.authorization_events to authenticated;

-- ─────────────────────────────────────────────────────────────
-- §4. The moves the flow allows
-- ─────────────────────────────────────────────────────────────
create or replace function public.authorization_transition()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_staff uuid := public.current_staff_id();
  v_name  text;
  v_legal boolean;
begin
  if tg_op = 'UPDATE' and new.status is distinct from old.status then
    -- Forward, or Closed, or the two ways reality goes backwards.
    v_legal := case
      when new.status = 'Closed' then true
      when old.status = 'Authorized' and new.status = 'Due' then true
      when old.status = 'Due' and new.status = 'Submitted' then true
      when old.status = 'Submitted' and new.status = 'Paid' then true
      -- Returned for correction: the submission did not stand.
      when old.status = 'Submitted' and new.status = 'Due' then true
      -- A payment undone, which the ledger reverses off this very move.
      when old.status = 'Paid' and new.status = 'Submitted' then true
      -- Reopened from Closed, which is Admin's doing and recorded below.
      when old.status = 'Closed' then true
      -- Due back to Authorized: somebody marked it due too early.
      when old.status = 'Due' and new.status = 'Authorized' then true
      else false
    end;

    if not v_legal then
      raise exception 'An authorization does not go from % to %', old.status, new.status
        using hint = 'Authorized, Due, Submitted, Paid, and Closed from any of them.',
              errcode = 'check_violation';
    end if;

    -- Reopening a closed authorization is Admin's.
    if old.status = 'Closed' and public.current_staff_role() is distinct from 'Admin' then
      raise exception 'Only an Admin reopens a closed authorization'
        using errcode = 'check_violation';
    end if;

    /**
     * What stops a submission, and what only warns (§4, owner 7 Oct).
     *
     * Hard: the work has to have happened inside the authorization's own
     * period. That is the rule USOR actually enforces, and billing work
     * done outside the authorized dates is the mistake that gets a whole
     * submission returned.
     *
     * Hard: more than the grace past the end date. Ninety days by default,
     * and the owner's to change.
     *
     * Warning only: past the end date but inside the grace, and a missing
     * end date. Both go on the record and the worklist; neither stands in
     * front of the person billing. A wall built on inherited data stops the
     * close over something nobody at the practice did.
     */
    if new.status = 'Submitted' then
      if new.start_date is not null and new.service_start is not null
         and new.service_start < new.start_date then
        raise exception 'The work started % and the authorization starts %',
          new.service_start, new.start_date
          using hint = 'Service dates have to sit inside the authorized period.',
                errcode = 'check_violation';
      end if;
      if new.end_date is not null and new.service_end is not null
         and new.service_end > new.end_date then
        raise exception 'The work ran to % and the authorization ends %',
          new.service_end, new.end_date
          using hint = 'Service dates have to sit inside the authorized period.',
                errcode = 'check_violation';
      end if;
      -- A coaching month is its own service period.
      if new.period is not null and new.end_date is not null
         and new.period > date_trunc('month', new.end_date)::date then
        raise exception 'That month is after the authorization ends on %', new.end_date
          using errcode = 'check_violation';
      end if;

      if public.authorization_blocked_from(new.stale_date) is not null
         and public.authorization_blocked_from(new.stale_date) < public.practice_today() then
        raise exception 'That authorization ended % and is more than % days past it',
          new.stale_date,
          (select stale_grace_days from public.org_settings where id)
          using hint = 'Enter the new authorization, or move the end date and say why.',
                errcode = 'check_violation';
      end if;
    end if;

    -- The stamps the flow is defined by, so no screen has to remember them.
    if new.status = 'Submitted' and new.submitted_on is null then
      new.submitted_on := public.practice_today();
    end if;
    if new.status = 'Submitted' then
      new.submitted_by := coalesce(new.submitted_by, v_staff);
      -- §6: fourteen days, then it is chased.
      new.followup_due := coalesce(new.followup_due, public.practice_today() + 14);
    end if;
    if new.status = 'Paid' then
      new.paid_on := coalesce(new.paid_on, public.practice_today());
      new.followup_due := null;
    end if;
    if new.status = 'Closed' then
      new.closed_at := coalesce(new.closed_at, now());
      new.closed_by := coalesce(new.closed_by, v_staff);
      new.followup_due := null;
    end if;

    select name into v_name from public.staff where id = v_staff;
    insert into public.authorization_events (auth_id, staff_id, staff_name, was, became, note)
    values (new.id, v_staff, v_name, old.status, new.status,
            case when new.status = 'Closed' then new.closed_reason
                 when new.status = 'Paid' then nullif(new.warrant, '')
                 else nullif(new.correction_note, '') end);
  end if;

  /**
   * Changing the stale date is a decision, and decisions are written down.
   *
   * §2: "yes, with logged reason". The reason is required at the moment the
   * date moves, not asked for afterwards, because afterwards nobody
   * remembers and the field stays empty forever.
   */
  if tg_op = 'UPDATE' and new.stale_date is distinct from old.stale_date then
    if coalesce(btrim(new.stale_reason), '') = '' then
      raise exception 'Moving the stale date needs a reason'
        using hint = 'Somebody will ask why this was billed after it expired.',
              errcode = 'check_violation';
    end if;
    new.stale_changed_by := coalesce(v_staff, new.stale_changed_by);
    new.stale_changed_at := now();
    select name into v_name from public.staff where id = v_staff;
    insert into public.authorization_events (auth_id, staff_id, staff_name, was, became, note)
    values (new.id, v_staff, v_name, 'stale ' || coalesce(old.stale_date::text, 'none'),
            'stale ' || coalesce(new.stale_date::text, 'none'), new.stale_reason);
  end if;

  return new;
end;
$$;

comment on function public.authorization_transition is
  'The moves §4 allows, the stale block on submitting, the stamps each state implies, and the event row for every change.';

drop trigger if exists authorizations_transition on public.authorizations;
create trigger authorizations_transition before update on public.authorizations
  for each row execute function public.authorization_transition();

-- ─────────────────────────────────────────────────────────────
-- §4. Due arrives on its own
-- ─────────────────────────────────────────────────────────────
create or replace function public.authorizations_fall_due(p_today date default null)
returns integer language plpgsql security definer set search_path = public as $$
declare
  v_today date := coalesce(p_today, public.practice_today());
  v_moved integer;
begin
  update public.authorizations
     set status = 'Due'
   where status = 'Authorized'
     and bill_by is not null
     and bill_by <= v_today
     -- A coaching parent is never billed; only its months are.
     and id not in (select parent_id from public.authorizations where parent_id is not null);
  get diagnostics v_moved = row_count;
  return v_moved;
end;
$$;

comment on function public.authorizations_fall_due is
  'Moves an authorization to Due on its bill-by date (§4). A coaching parent never falls due; its months do.';

revoke all on function public.authorizations_fall_due(date) from public, anon, authenticated;
grant execute on function public.authorizations_fall_due(date) to service_role;

-- ─────────────────────────────────────────────────────────────
-- §5 and §13.8. A coaching month makes itself, and closes itself
-- ─────────────────────────────────────────────────────────────
create or replace function public.open_coaching_months_for(p_month date)
returns integer language plpgsql security definer set search_path = public as $$
declare
  v_month   date := date_trunc('month', p_month)::date;
  v_made    integer := 0;
  v_parent  record;
  v_hours   numeric;
  v_child   uuid;
begin
  for v_parent in
    select a.*,
           coalesce(a.total_hours, 0) as authorized,
           coalesce(a.carried_used, 0)
             + coalesce((select sum(e.hours) from public.service_entries e
                          join public.authorizations c on c.id = e.auth_id
                         where (c.id = a.id or c.parent_id = a.id) and not e.non_billable), 0) as used
      from public.authorizations a
     where a.service_type = 'Job Coaching'
       and a.parent_id is null
       and a.status <> 'Closed'
  loop
    -- §5: no new months once the hours are gone or the parent is stale.
    v_hours := v_parent.authorized - v_parent.used;
    if v_parent.authorized > 0 and v_hours <= 0 then
      continue;
    end if;
    if v_parent.stale_date is not null and v_parent.stale_date < v_month then
      continue;
    end if;
    -- Nor before it started.
    if v_parent.start_date is not null
       and date_trunc('month', v_parent.start_date)::date > v_month then
      continue;
    end if;

    insert into public.authorizations (
      client_id, number, service_type, funding_source, rate_type, rate,
      total_hours, carried_used, start_date, end_date, stale_date,
      requires_forms, parent_id, period, received_on, bill_by, status
    )
    values (
      v_parent.client_id, '', v_parent.service_type, v_parent.funding_source,
      v_parent.rate_type, v_parent.rate,
      null, 0, v_parent.start_date, v_parent.end_date, v_parent.stale_date,
      v_parent.requires_forms, v_parent.id, v_month,
      (v_month + interval '1 month')::date,
      public.bill_by_for(v_parent.service_type, (v_month + interval '1 month')::date, v_month, null),
      'Authorized'
    )
    on conflict (parent_id, period) do nothing
    returning id into v_child;

    if v_child is not null then
      v_made := v_made + 1;
    end if;
  end loop;

  return v_made;
end;
$$;

comment on function public.open_coaching_months_for is
  'Creates each coaching parent its month (§5), unless the hours are gone, the parent is stale, or the month is before it started.';

revoke all on function public.open_coaching_months_for(date) from public, anon, authenticated;
grant execute on function public.open_coaching_months_for(date) to service_role;

/**
 * §13.8. A month with no hours closes itself.
 *
 * "the billing staff see a one-line note, not a task." So this closes it and
 * writes the event; nothing is raised, nobody is asked. A month somebody has
 * deliberately kept is left alone, which is what zero_hours_confirmed_by
 * records.
 */
create or replace function public.close_empty_coaching_months(p_today date default null)
returns integer language plpgsql security definer set search_path = public as $$
declare
  v_today  date := coalesce(p_today, public.practice_today());
  v_closed integer;
begin
  update public.authorizations a
     set status = 'Closed',
         closed_reason = 'Zero hours',
         closed_at = now()
   where a.parent_id is not null
     and a.status in ('Authorized', 'Due')
     and a.period is not null
     -- The month has finished.
     and (a.period + interval '1 month')::date <= v_today
     and a.zero_hours_confirmed_by is null
     and not exists (
       select 1 from public.service_entries e
        where e.auth_id = a.id and not e.non_billable and e.hours > 0);
  get diagnostics v_closed = row_count;
  return v_closed;
end;
$$;

comment on function public.close_empty_coaching_months is
  'Closes a finished coaching month that has no hours on it (§13.8): a one-line note, not a task. A month somebody kept on purpose is left alone.';

revoke all on function public.close_empty_coaching_months(date) from public, anon, authenticated;
grant execute on function public.close_empty_coaching_months(date) to service_role;

-- ─────────────────────────────────────────────────────────────
-- §6. The one list, and what is wrong with each row
--
-- §12.2 collapsed the Due list and the working list into one, sorted by
-- bill-by with overdue first. §13.11 collapses the flags into one line per
-- record. This is that list, so the screen does not work it out and the
-- dashboard count cannot disagree with it.
-- ─────────────────────────────────────────────────────────────
create or replace function public.billing_worklist(p_today date default null)
returns table (
  id uuid,
  client_id uuid,
  client_name text,
  number text,
  service_type text,
  period date,
  status text,
  bill_by date,
  stale_date date,
  submitted_on date,
  followup_due date,
  amount numeric,
  parent_id uuid,
  -- One line, not four flags (§13.11).
  attention text,
  -- What sorts it: overdue first, then by bill-by.
  urgency integer
) language sql stable set search_path = public as $$
  with me as (select coalesce(p_today, public.practice_today()) as today),
  rows as (
    select a.id, a.client_id, c.name as client_name,
           coalesce(nullif(a.number, ''), p.number, '') as number,
           a.service_type, a.period, a.status, a.bill_by, a.stale_date,
           a.submitted_on, a.followup_due, a.parent_id,
           case when a.rate_type = 'Flat Fee' then a.rate
                else coalesce(
                  (select sum(e.hours) from public.service_entries e
                    where e.auth_id = a.id and not e.non_billable), 0) * a.rate end as amount,
           -- Past the end date and past the grace: it cannot be submitted.
           public.authorization_blocked_from(a.stale_date) is not null
             and public.authorization_blocked_from(a.stale_date) < (select today from me)
             and a.status not in ('Submitted', 'Paid') as is_blocked,
           -- Past the end date but still inside the grace: a warning.
           a.stale_date is not null and a.stale_date < (select today from me)
             and (public.authorization_blocked_from(a.stale_date) is null
                  or public.authorization_blocked_from(a.stale_date) >= (select today from me))
             and a.status not in ('Submitted', 'Paid') as is_expired,
           -- No end date at all: §4 warns and never blocks.
           a.stale_date is null and a.status not in ('Submitted', 'Paid') as no_end_date,
           a.bill_by is not null and a.bill_by < (select today from me)
             and a.status in ('Authorized', 'Due') as is_overdue,
           a.followup_due is not null and a.followup_due <= (select today from me)
             and a.status = 'Submitted' as needs_chasing,
           a.stale_date is not null and a.status not in ('Submitted', 'Paid')
             and a.stale_date >= (select today from me)
             and a.stale_date <= (select today from me)
               + (select stale_soon_days from public.org_settings where id) as stale_soon
      from public.authorizations a
      join public.clients c on c.id = a.client_id
      left join public.authorizations p on p.id = a.parent_id
     where a.status not in ('Paid', 'Closed')
       -- A coaching parent is not a bill; its months are.
       and a.id not in (select parent_id from public.authorizations where parent_id is not null)
  )
  select r.id, r.client_id, r.client_name, r.number, r.service_type, r.period, r.status,
         r.bill_by, r.stale_date, r.submitted_on, r.followup_due, r.amount, r.parent_id,
         -- First true wins: the most pressing thing, said once (§13.11).
         case
           when r.is_blocked then 'Cannot be submitted - ended ' || r.stale_date
                                  || ', more than ' || (select stale_grace_days from public.org_settings where id)
                                  || ' days ago'
           when r.needs_chasing then 'Submitted ' || r.submitted_on || ', no payment after 14 days'
           when r.is_overdue then 'Overdue - meant to be billed by ' || r.bill_by
           when r.is_expired then 'Past its end date (' || r.stale_date || ') - can still be submitted until '
                                  || public.authorization_blocked_from(r.stale_date)
           when r.stale_soon then 'Ends ' || r.stale_date
           when r.no_end_date then 'No end date on the authorization'
           when r.status = 'Due' then 'Due to be billed'
           else ''
         end,
         case
           when r.is_blocked then 0
           when r.needs_chasing then 1
           when r.is_overdue then 2
           when r.is_expired then 3
           when r.stale_soon then 4
           when r.no_end_date then 5
           when r.status = 'Due' then 6
           else 7
         end
    from rows r
   order by 15, r.bill_by nulls last, r.client_name;
$$;

comment on function public.billing_worklist is
  'The one billing list (§12.2): everything not Paid and not Closed, each row with the single most pressing thing wrong with it (§13.11), the ones that cannot be submitted first. Past the end date is a warning; past the grace is a block; no end date only warns (§4, owner 7 Oct).';

revoke all on function public.billing_worklist(date) from anon, authenticated;
grant execute on function public.billing_worklist(date) to authenticated;
