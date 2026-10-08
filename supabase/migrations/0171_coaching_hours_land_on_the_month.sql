-- Zion Vocational Rehab CRM — coaching hours land on the month
-- (Billing Simplification Brief §§5, 10, 12.5)
--
-- §5: a Job Coaching authorization is a parent holding the hours, with a child
-- per month that carries that month's bill. §12.5: "hours are logged from the
-- client record (and quick-add) by whoever did them, and roll up to the month
-- record."
--
-- They did not roll up. Nothing moved an entry to the month, and both places
-- that log hours offer the parent - so every hour went onto the parent, and
-- `authorization_amount` for a month sums only that month's own entries.
-- Which means every coaching month would have been billed at 0.00: the
-- worklist showing nothing to bill, the checklist's Amount line failing, and
-- the ledger posting nothing, for the practice's only monthly service.
--
-- Nobody had hit it yet because the two coaching months that exist were opened
-- by the fold and no hours have been logged since. Margaret's first coaching
-- month would have been the first to find out.
--
-- Two things are needed, and they have to come together:
--
--   An entry against a monthly authorization belongs to the month its date
--   falls in. The trigger below moves it there, opening the month if the
--   calendar has not got to it - a person logging Tuesday's hours should not
--   have to know whether a record for October exists.
--
--   And the hours cap has to follow. check_entry_hours() capped against the
--   authorization the entry names; a month carries no hours of its own (§5),
--   so an entry on a child found total_hours null and was waved through with
--   no cap at all. It counts across the parent and every month under it now,
--   against the parent's total - which is what the authorization actually
--   says, and is how the submission checklist already counts.

/**
 * The month an entry belongs to, opened if it is not there yet.
 *
 * Only for a monthly service, and only for a parent: an entry logged directly
 * against a month is already where it belongs, and a one-off service has no
 * months at all.
 */
create or replace function public.route_entry_to_month()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  a        public.authorizations;
  rule     public.billing_service_rules;
  v_period date;
  v_child  uuid;
begin
  select * into a from public.authorizations where id = new.auth_id;
  if not found or a.parent_id is not null then
    return new;                       -- already on a month, or nothing to do
  end if;
  select * into rule from public.billing_service_rules where service = a.service_type;
  if coalesce(rule.recurrence, 'One-time') <> 'Monthly' then
    return new;                       -- a one-off service has no months
  end if;

  v_period := date_trunc('month', new.date)::date;

  select id into v_child from public.authorizations
   where parent_id = a.id and period = v_period;

  if v_child is null then
    insert into public.authorizations
      (client_id, number, service_type, funding_source, rate_type, rate,
       start_date, end_date, status, parent_id, period, requires_forms, note)
    values
      (a.client_id, '', a.service_type, a.funding_source, a.rate_type, a.rate,
       a.start_date, a.end_date, 'Authorized', a.id, v_period, a.requires_forms,
       'Opened when hours were logged for ' || to_char(v_period, 'FMMonth YYYY') || '.')
    returning id into v_child;
  end if;

  new.auth_id := v_child;
  return new;
end;
$$;

comment on function public.route_entry_to_month is
  'Hours logged against a monthly authorization land on the month they were worked (§§5, 12.5). The month is opened if the calendar has not reached it, so nobody logging Tuesday''s hours has to know whether October exists yet.';

revoke execute on function public.route_entry_to_month() from public, anon, authenticated;

-- Before the guards: the entry has to know which record it is on before
-- anything checks it against that record's hours and dates. Postgres fires
-- BEFORE row triggers in name order, which is why this one is named to sort
-- ahead of service_entries_hours_guard and service_entries_in_dates.
drop trigger if exists service_entries_a_month on public.service_entries;
create trigger service_entries_a_month
  before insert or update of auth_id, date on public.service_entries
  for each row execute function public.route_entry_to_month();

/**
 * The hours cap, counted across the whole authorization.
 *
 * A month carries no hours of its own, so capping against the record an entry
 * names let every coaching hour through uncapped once the entries moved to the
 * months. The authorized total is the parent's, and what is used is everything
 * billable on the parent and on every month under it - the same sum the
 * submission checklist makes.
 */
create or replace function public.check_entry_hours()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  a          public.authorizations%rowtype;
  v_root     uuid;
  v_total    numeric;
  v_carried  numeric;
  used_hours numeric;
begin
  if new.date > public.practice_today() then
    raise exception 'Service hours cannot be logged for % — that date has not happened yet.',
      new.date using errcode = 'check_violation';
  end if;

  if new.non_billable then
    return new;
  end if;

  select * into a from public.authorizations where id = new.auth_id;
  if not found then
    return new;
  end if;

  -- The authorization itself, which for a coaching month is its parent.
  v_root := coalesce(a.parent_id, a.id);
  select total_hours, carried_used into v_total, v_carried
    from public.authorizations where id = v_root;

  if v_total is null then
    return new;                                   -- flat fee, no hour cap
  end if;

  select coalesce(v_carried, 0) + coalesce(sum(e.hours), 0)
    into used_hours
    from public.service_entries e
   where e.non_billable = false
     and e.id is distinct from new.id
     and (e.auth_id = v_root
          or e.auth_id in (select id from public.authorizations where parent_id = v_root));

  if used_hours + new.hours > v_total then
    raise exception
      'Entry of % hrs exceeds the hours left on % (% authorized, % used). Request additional hours from the counselor first.',
      new.hours,
      coalesce(nullif((select number from public.authorizations where id = v_root), ''), a.service_type),
      v_total, used_hours
      using errcode = 'check_violation';
  end if;

  return new;
end;
$$;
