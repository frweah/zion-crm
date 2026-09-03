-- Zion Vocational Rehab CRM — 0002 identity helpers and business rules
-- The rules below are the ones the owner signed off on in the prototype. They
-- live in the database so they hold no matter which screen, script or API call
-- writes the row.

-- ─────────────────────────────────────────────────────────────
-- Who is acting
-- SECURITY DEFINER so these can read public.staff without tripping the RLS
-- policies that are themselves defined in terms of these functions.
-- An inactive staff row resolves to NULL everywhere — offboarding is immediate.
-- ─────────────────────────────────────────────────────────────
create or replace function public.current_staff_id()
returns uuid
language sql stable security definer set search_path = public
as $$
  select s.id from public.staff s
   where s.user_id = auth.uid() and s.active
   limit 1;
$$;

create or replace function public.current_staff_role()
returns text
language sql stable security definer set search_path = public
as $$
  select s.role from public.staff s
   where s.user_id = auth.uid() and s.active
   limit 1;
$$;

create or replace function public.is_active_staff()
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.staff s
     where s.user_id = auth.uid() and s.active
  );
$$;

create or replace function public.is_admin()
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.staff s
     where s.user_id = auth.uid() and s.active and s.role = 'Admin'
  );
$$;

-- Restricted tier (kickoff): DOB, address, accommodations, USOR 94/98 content
-- are visible to Admin, Intake & Reports, or the client's assigned staff member.
create or replace function public.can_see_restricted(p_client_id uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1
      from public.staff s
      left join public.clients c on c.id = p_client_id
     where s.user_id = auth.uid()
       and s.active
       and (
         s.role in ('Admin','Reports')
         or c.assigned_staff_id = s.id
       )
  );
$$;

revoke execute on function public.current_staff_id()      from public;
revoke execute on function public.current_staff_role()    from public;
revoke execute on function public.is_active_staff()       from public;
revoke execute on function public.is_admin()              from public;
revoke execute on function public.can_see_restricted(uuid) from public;
grant execute on function public.current_staff_id()      to authenticated;
grant execute on function public.current_staff_role()    to authenticated;
grant execute on function public.is_active_staff()       to authenticated;
grant execute on function public.is_admin()              to authenticated;
grant execute on function public.can_see_restricted(uuid) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- Pipeline history: every stage change is recorded, whoever makes it.
-- ─────────────────────────────────────────────────────────────
create or replace function public.log_stage_change()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' or new.stage is distinct from old.stage then
    insert into public.client_stage_history (client_id, stage, staff_id)
    values (new.id, new.stage, public.current_staff_id());
  end if;
  return new;
end;
$$;
create trigger clients_stage_history
  after insert or update of stage on public.clients
  for each row execute function public.log_stage_change();

-- ─────────────────────────────────────────────────────────────
-- Billing rule 1: hours are logged on the day the service happened, never
-- ahead, and a service entry may not push an authorization past its
-- authorized hours.
-- ─────────────────────────────────────────────────────────────
create or replace function public.check_entry_hours()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  a          public.authorizations%rowtype;
  used_hours numeric;
begin
  if new.date > current_date then
    raise exception 'Service hours cannot be logged for % — that date has not happened yet.',
      new.date using errcode = 'check_violation';
  end if;

  if new.non_billable then
    return new;
  end if;

  select * into a from public.authorizations where id = new.auth_id;
  if a.total_hours is null then
    return new;                                   -- flat-fee authorization, no hour cap
  end if;

  select a.carried_used + coalesce(sum(e.hours), 0)
    into used_hours
    from public.service_entries e
   where e.auth_id = new.auth_id
     and e.non_billable = false
     and e.id is distinct from new.id;

  if used_hours + new.hours > a.total_hours then
    raise exception
      'Entry of % hrs exceeds the hours left on % (% authorized, % used). Request additional hours from the counselor first.',
      new.hours, coalesce(nullif(a.number, ''), a.service_type), a.total_hours, used_hours
      using errcode = 'check_violation';
  end if;

  return new;
end;
$$;
create trigger service_entries_hours_guard
  before insert or update on public.service_entries
  for each row execute function public.check_entry_hours();

-- ─────────────────────────────────────────────────────────────
-- Billing rule 2: an invoice may not exceed what its authorization authorizes.
-- ─────────────────────────────────────────────────────────────
create or replace function public.check_invoice_amount()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  a          public.authorizations%rowtype;
  authorized numeric;
begin
  select * into a from public.authorizations where id = new.auth_id;
  authorized := case
    when a.rate_type = 'Flat Fee' then a.rate
    else coalesce(a.total_hours, 0) * a.rate
  end;

  if authorized > 0 and new.amount > authorized then
    raise exception 'Invoice of % exceeds the % authorized by %.',
      new.amount, authorized, coalesce(nullif(a.number, ''), a.service_type)
      using errcode = 'check_violation';
  end if;

  return new;
end;
$$;
create trigger invoices_amount_guard
  before insert or update of amount, auth_id on public.invoices
  for each row execute function public.check_invoice_amount();

-- ─────────────────────────────────────────────────────────────
-- Billing rule 3: an invoice cannot be marked Sent until every USOR form
-- required for that authorization's service type is out of Draft.
-- ─────────────────────────────────────────────────────────────
create or replace function public.check_invoice_forms()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  a       public.authorizations%rowtype;
  missing text;
begin
  if new.status <> 'Sent' then
    return new;
  end if;
  if tg_op = 'UPDATE' and old.status = 'Sent' then
    return new;
  end if;

  select * into a from public.authorizations where id = new.auth_id;

  select string_agg(t.usor, ' + ' order by t.sort_order)
    into missing
    from public.form_templates t
   where t.required_for_billing
     and a.service_type = any (t.services)
     and not exists (
       select 1 from public.forms f
        where f.auth_id = new.auth_id
          and f.template_id = t.id
          and f.status <> 'Draft'
     );

  if missing is not null then
    raise exception 'Invoice cannot be sent: % still outstanding for %.',
      missing, coalesce(nullif(a.number, ''), a.service_type)
      using errcode = 'check_violation';
  end if;

  new.sent_date := coalesce(new.sent_date, current_date);
  return new;
end;
$$;
create trigger invoices_forms_guard
  before insert or update on public.invoices
  for each row execute function public.check_invoice_forms();

-- ─────────────────────────────────────────────────────────────
-- Forms: sensitivity mirrors the template; a completed form is locked and
-- records who signed it and when.
-- ─────────────────────────────────────────────────────────────
create or replace function public.forms_sync_sensitive()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  select coalesce(t.sensitive, false) into new.sensitive
    from public.form_templates t where t.id = new.template_id;
  new.sensitive := coalesce(new.sensitive, false);
  return new;
end;
$$;
create trigger forms_sensitive_sync
  before insert or update of template_id on public.forms
  for each row execute function public.forms_sync_sensitive();

create or replace function public.forms_lock_when_complete()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  actor uuid := public.current_staff_id();
begin
  if old.status <> 'Draft' then
    if new.data is distinct from old.data
       or new.template_id is distinct from old.template_id
       or new.auth_id is distinct from old.auth_id then
      raise exception 'Form % is % and cannot be edited. Start a new form instead.',
        old.id, old.status using errcode = 'check_violation';
    end if;
    if new.status = 'Draft' then
      raise exception 'A completed form cannot be reopened.' using errcode = 'check_violation';
    end if;
  end if;

  if new.status = 'Completed' and old.status = 'Draft' then
    new.completed_at := coalesce(new.completed_at, now());
    new.completed_by := coalesce(new.completed_by, actor);
    new.completed_by_name := coalesce(
      nullif(new.completed_by_name, ''),
      (select name from public.staff where id = coalesce(new.completed_by, actor)),
      ''
    );
  end if;

  if new.status = 'Sent' and old.status <> 'Sent' then
    new.sent_at := coalesce(new.sent_at, now());
  end if;

  return new;
end;
$$;
create trigger forms_lock
  before update on public.forms
  for each row execute function public.forms_lock_when_complete();
