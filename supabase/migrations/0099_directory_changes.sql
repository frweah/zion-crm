-- Zion Vocational Rehab CRM — an editable directory, with every change written down
--
-- The owner, 18 Sept 2026: staff can add and edit counselors; Admin and
-- Billing can edit billing offices and their contacts; every change is
-- logged; and a "moved office" action moves a counselor to another office -
-- which moves their billing office with it, since that follows the office.
--
--   Counselors: added and edited by whoever has Counselors to edit (the rules
--   from 0092 - Admin, Job Search, Billing, or a grant). Unchanged here.
--
--   Billing offices and offices: were Admin's alone. Now anybody with Billing
--   to edit - Admin, the Billing role, or a grant of it. Removing an office
--   stays Admin's.
--
--   The log is written by the database itself, on every insert, change and
--   removal of a counselor, a billing office or an office, however it was
--   made - a screen, a migration, a script. Each entry keeps who, when, which
--   fields went from what to what, and why when a reason was given. It is
--   never edited or deleted.
--
--   Moving office is its own action (move_counselor_office), with a reason,
--   logged as "Moved office" with the billing office before and after. The
--   screen offers no other way to change a counselor's office, so every
--   office change says why.

-- ── the log ─────────────────────────────────────────────────
create table if not exists public.directory_changes (
  id               uuid primary key default gen_random_uuid(),
  seq              bigserial,
  at               timestamptz not null default now(),
  entity           text not null check (entity in ('Counselor', 'Billing office', 'Office')),
  entity_key       text not null,
  entity_name      text not null,
  action           text not null check (action in ('Added', 'Edited', 'Moved office', 'Removed')),
  changes          jsonb not null default '{}'::jsonb,
  reason           text not null default '',
  changed_by       uuid references public.staff(id) on delete set null,
  changed_by_name  text not null default ''
);
create index if not exists directory_changes_entity on public.directory_changes (entity, entity_key, seq desc);
create index if not exists directory_changes_recent on public.directory_changes (seq desc);

create or replace function public.directory_changes_append_only()
returns trigger language plpgsql as $$
begin
  raise exception 'The directory''s change log is a record; it is added to, never changed or removed.'
    using errcode = 'insufficient_privilege';
end;
$$;
drop trigger if exists directory_changes_append_only on public.directory_changes;
create trigger directory_changes_append_only before update or delete on public.directory_changes
  for each row execute function public.directory_changes_append_only();

-- ── written by the database, on every change ────────────────
create or replace function public.directory_change_log()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_old     jsonb := case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) else '{}'::jsonb end;
  v_new     jsonb := case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) else '{}'::jsonb end;
  v_changes jsonb := '{}'::jsonb;
  v_key     text;
  v_entity  text;
  v_id      text;
  v_name    text;
  v_action  text;
  v_staff   public.staff%rowtype;
begin
  -- Which fields moved, from what to what. Bookkeeping columns are not news.
  for v_key in
    select k from jsonb_object_keys(v_old || v_new) as k
     where k not in ('created_at', 'updated_at')
  loop
    if (v_old -> v_key) is distinct from (v_new -> v_key) then
      v_changes := v_changes || jsonb_build_object(v_key, jsonb_build_object('from', v_old -> v_key, 'to', v_new -> v_key));
    end if;
  end loop;
  if tg_op = 'UPDATE' and v_changes = '{}'::jsonb then
    return null;
  end if;

  v_entity := case tg_table_name
    when 'counselors' then 'Counselor'
    when 'billing_offices' then 'Billing office'
    else 'Office' end;
  v_id := coalesce(v_new ->> 'id', v_old ->> 'id', v_new ->> 'name', v_old ->> 'name');
  v_name := coalesce(v_new ->> 'name', v_old ->> 'name', '');
  v_action := case tg_op
    when 'INSERT' then 'Added'
    when 'DELETE' then 'Removed'
    else coalesce(nullif(current_setting('zion.directory_action', true), ''), 'Edited') end;

  select * into v_staff from public.staff where id = public.current_staff_id();

  insert into public.directory_changes (entity, entity_key, entity_name, action, changes, reason, changed_by, changed_by_name)
  values (v_entity, v_id, v_name, v_action, v_changes,
          coalesce(nullif(current_setting('zion.directory_reason', true), ''), ''),
          v_staff.id, coalesce(v_staff.name, 'System'));
  return null;
end;
$$;

drop trigger if exists counselors_log on public.counselors;
create trigger counselors_log after insert or update or delete on public.counselors
  for each row execute function public.directory_change_log();
drop trigger if exists billing_offices_log on public.billing_offices;
create trigger billing_offices_log after insert or update or delete on public.billing_offices
  for each row execute function public.directory_change_log();
drop trigger if exists offices_log on public.offices;
create trigger offices_log after insert or update or delete on public.offices
  for each row execute function public.directory_change_log();

-- ── moving office ───────────────────────────────────────────
-- Security invoker: the counselor rules decide who may, as for any edit. The
-- billing office is not stored on the counselor - it follows the office - so
-- moving the office is what moves it; this says what it moved from and to.
create or replace function public.move_counselor_office(p_counselor uuid, p_office text, p_reason text)
returns table (from_office text, to_office text, from_billing text, to_billing text, clients integer)
language plpgsql security invoker set search_path = public as $$
declare
  v_from text;
  v_name text;
  v_n    integer;
begin
  if nullif(trim(coalesce(p_reason, '')), '') is null then
    raise exception 'Say why they moved - "moved to the Taylorsville office", "USOR reorganised".'
      using errcode = 'check_violation';
  end if;
  select office, name into v_from, v_name from public.counselors where id = p_counselor;
  if v_name is null then
    raise exception 'That counselor is not on file.' using errcode = 'check_violation';
  end if;
  if v_from is not distinct from p_office then
    raise exception '% is already at the % office.', v_name, p_office using errcode = 'check_violation';
  end if;
  if not exists (select 1 from public.offices where name = p_office) then
    raise exception 'The % office is not on file. Add it in Billing offices first.', p_office
      using errcode = 'check_violation';
  end if;

  perform set_config('zion.directory_action', 'Moved office', true);
  perform set_config('zion.directory_reason', trim(p_reason), true);
  update public.counselors set office = p_office where id = p_counselor;
  get diagnostics v_n = row_count;
  perform set_config('zion.directory_action', '', true);
  perform set_config('zion.directory_reason', '', true);
  if v_n = 0 then
    raise exception 'You cannot change counselors.' using errcode = 'insufficient_privilege';
  end if;

  return query
  select v_from, p_office,
         (select b.name from public.offices o join public.billing_offices b on b.id = o.billing_office_id where o.name = v_from),
         (select b.name from public.offices o join public.billing_offices b on b.id = o.billing_office_id where o.name = p_office),
         (select count(*)::integer from public.clients c where c.counselor_id = p_counselor);
end;
$$;

-- ── who may edit billing offices and offices ────────────────
drop policy if exists billing_offices_admin_write on public.billing_offices;
drop policy if exists billing_offices_write on public.billing_offices;
create policy billing_offices_write on public.billing_offices for all to authenticated
  using ((select public.staff_has_area('billing', 'edit')))
  with check ((select public.staff_has_area('billing', 'edit')));

drop policy if exists offices_admin_write on public.offices;
drop policy if exists offices_insert on public.offices;
drop policy if exists offices_update on public.offices;
drop policy if exists offices_delete on public.offices;
create policy offices_insert on public.offices for insert to authenticated
  with check ((select public.staff_has_area('billing', 'edit')));
create policy offices_update on public.offices for update to authenticated
  using ((select public.staff_has_area('billing', 'edit')))
  with check ((select public.staff_has_area('billing', 'edit')));
create policy offices_delete on public.offices for delete to authenticated
  using ((select public.is_admin()));

-- ── rules on the log ────────────────────────────────────────
alter table public.directory_changes enable row level security;
drop policy if exists directory_changes_read on public.directory_changes;
create policy directory_changes_read on public.directory_changes for select to authenticated
  using ((select public.is_active_staff()));

revoke all on public.directory_changes from anon;
revoke insert, update, delete, truncate on public.directory_changes from authenticated;
grant select on public.directory_changes to authenticated;
grant all on public.directory_changes to service_role;

revoke execute on function public.directory_change_log() from public, anon, authenticated;
revoke execute on function public.directory_changes_append_only() from public, anon, authenticated;
revoke execute on function public.move_counselor_office(uuid, text, text) from public, anon;
grant execute on function public.move_counselor_office(uuid, text, text) to authenticated, service_role;
