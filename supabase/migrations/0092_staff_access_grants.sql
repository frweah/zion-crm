-- Zion Vocational Rehab CRM — access given to one person, on top of their role
--
-- Roles stay the default (owner, 2026-09-18). Admin can give an individual an
-- area their role does not include - Margaret Billing, view only or view and
-- edit; somebody Insights - and nothing else changes:
--
--   Additive only. A grant can add an area or raise view to edit; it can never
--   take away what a role gives, because every rule below is "what the role
--   allowed, OR a live grant".
--
--   Enforced here, not in the menu. Each rule that decided by role now also
--   asks public.staff_has_area(area, level), and so do the six functions that
--   check a Billing role themselves.
--
--   A record. Who gave it, when, why; who ended it, when, why. A grant is
--   never edited or deleted - the only change ever made to one is ending it,
--   once. Changing view to edit ends the old grant and starts a new one.
--
--   Ended automatically the moment the person is made inactive, however that
--   happens (offboarding, or the Active switch).
--
-- Grantable areas: tasks, counselors, billing (view or edit) and insights
-- (view; Capacity stays Admin's, since it shows everybody's hours). Not
-- grantable: People and Admin -> System - a grant must not be a way into staff
-- pay or into granting.
--
-- Numbered 0092: the live database holds 0087-0090 from the paused portal.

-- ── the grants ──────────────────────────────────────────────
create table if not exists public.staff_access_grants (
  id               uuid primary key default gen_random_uuid(),
  staff_id         uuid not null references public.staff(id) on delete restrict,
  area             text not null check (area in ('tasks', 'counselors', 'billing', 'insights')),
  level            text not null check (level in ('view', 'edit')),
  reason           text not null check (length(trim(reason)) >= 3),
  granted_by       uuid references public.staff(id) on delete set null,
  granted_by_name  text not null default '',
  granted_at       timestamptz not null default now(),
  revoked_at       timestamptz,
  revoked_by       uuid references public.staff(id) on delete set null,
  revoked_by_name  text not null default '',
  revoke_reason    text not null default '',
  constraint staff_access_grants_insights_view check (area <> 'insights' or level = 'view'),
  constraint staff_access_grants_revoked_whole check ((revoked_at is null) = (revoke_reason = ''))
);

create unique index if not exists staff_access_grants_one_live
  on public.staff_access_grants (staff_id, area) where revoked_at is null;
create index if not exists staff_access_grants_staff on public.staff_access_grants (staff_id, granted_at desc);

-- A grant is a record. The only change ever made to one is ending it, once.
create or replace function public.staff_access_grants_guard()
returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'A grant of access is a record; end it instead of deleting it.' using errcode = 'insufficient_privilege';
  end if;
  if old.revoked_at is not null then
    raise exception 'That access has already ended.' using errcode = 'check_violation';
  end if;
  if new.revoked_at is null
     or (new.staff_id, new.area, new.level, new.reason, new.granted_by, new.granted_by_name, new.granted_at)
        is distinct from (old.staff_id, old.area, old.level, old.reason, old.granted_by, old.granted_by_name, old.granted_at) then
    raise exception 'A grant of access cannot be changed, only ended. To change it, end it and give a new one.'
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
drop trigger if exists staff_access_grants_guard on public.staff_access_grants;
create trigger staff_access_grants_guard before update or delete on public.staff_access_grants
  for each row execute function public.staff_access_grants_guard();

-- ── what a role gives, and what a person has ────────────────
-- What each role has with no grant at all. lib/roles.ts ROLE_AREAS says the
-- same for the screens; verify_access_grants.sql holds the two together.
create or replace function public.role_has_area(p_role text, p_area text, p_level text default 'view')
returns boolean language sql immutable set search_path = public as $$
  select coalesce(case p_area
    when 'tasks'      then p_role in ('Admin', 'Job Search', 'Reports')
    when 'counselors' then p_role in ('Admin', 'Job Search', 'Billing')
    when 'billing'    then p_role in ('Admin', 'Billing')
    when 'insights'   then p_role = 'Admin'
    else false
  end, false);
$$;

-- The one question every rule asks: may the person signed in do this here?
-- Their role, or a live grant of their own - and only while they are active
-- staff, since current_staff_role and current_staff_id both require it.
create or replace function public.staff_has_area(p_area text, p_level text default 'view')
returns boolean language sql stable security definer set search_path = public as $$
  select public.role_has_area(public.current_staff_role(), p_area, p_level)
      or exists (
        select 1 from public.staff_access_grants g
         where g.staff_id = public.current_staff_id()
           and g.revoked_at is null
           and g.area = p_area
           and (p_level = 'view' or g.level = 'edit'));
$$;

-- ── giving and ending ───────────────────────────────────────
create or replace function public.grant_staff_access(p_staff uuid, p_area text, p_level text, p_reason text)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_me     public.staff%rowtype;
  v_target public.staff%rowtype;
  v_live   public.staff_access_grants%rowtype;
  v_id     uuid;
begin
  if not public.is_admin() then
    raise exception 'Only Admin gives somebody access beyond their role.' using errcode = 'insufficient_privilege';
  end if;
  select * into v_me from public.staff where id = public.current_staff_id();
  select * into v_target from public.staff where id = p_staff;
  if v_target.id is null or not v_target.active then
    raise exception 'Access can only be given to an active member of staff.' using errcode = 'check_violation';
  end if;
  if p_area not in ('tasks', 'counselors', 'billing', 'insights') then
    raise exception 'That is not an area access can be given to.' using errcode = 'check_violation';
  end if;
  if p_level not in ('view', 'edit') or (p_area = 'insights' and p_level <> 'view') then
    raise exception 'Insights can be given to view; the other areas to view, or to view and edit.' using errcode = 'check_violation';
  end if;
  if nullif(trim(coalesce(p_reason, '')), '') is null or length(trim(p_reason)) < 3 then
    raise exception 'Say why this access is being given.' using errcode = 'check_violation';
  end if;
  -- A grant only adds. One that would add nothing is refused rather than kept
  -- as noise on the record.
  if public.role_has_area(v_target.role, p_area, p_level) then
    raise exception '%''s role already gives them this. A grant can only add to a role.', v_target.name
      using errcode = 'check_violation';
  end if;

  select * into v_live from public.staff_access_grants
   where staff_id = p_staff and area = p_area and revoked_at is null;
  if v_live.id is not null then
    if v_live.level = p_level then
      raise exception '% already has this access.', v_target.name using errcode = 'check_violation';
    end if;
    update public.staff_access_grants
       set revoked_at = now(), revoked_by = v_me.id, revoked_by_name = v_me.name,
           revoke_reason = format('Replaced by %s access: %s', case when p_level = 'edit' then 'view and edit' else 'view only' end, trim(p_reason))
     where id = v_live.id;
  end if;

  insert into public.staff_access_grants (staff_id, area, level, reason, granted_by, granted_by_name)
  values (p_staff, p_area, p_level, trim(p_reason), v_me.id, v_me.name)
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.revoke_staff_access(p_grant uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_me public.staff%rowtype;
begin
  if not public.is_admin() then
    raise exception 'Only Admin ends access given beyond a role.' using errcode = 'insufficient_privilege';
  end if;
  if nullif(trim(coalesce(p_reason, '')), '') is null then
    raise exception 'Say why this access is ending.' using errcode = 'check_violation';
  end if;
  select * into v_me from public.staff where id = public.current_staff_id();
  update public.staff_access_grants
     set revoked_at = now(), revoked_by = v_me.id, revoked_by_name = v_me.name, revoke_reason = trim(p_reason)
   where id = p_grant and revoked_at is null;
  if not found then
    raise exception 'That access is not current.' using errcode = 'check_violation';
  end if;
end;
$$;

-- ── ended with the person ───────────────────────────────────
-- However somebody is made inactive - offboard_staff, or the Active switch -
-- everything given to them beyond their role ends at the same moment.
create or replace function public.staff_grants_end_with_staff()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_by public.staff%rowtype;
begin
  if old.active and not new.active then
    select * into v_by from public.staff where id = public.current_staff_id();
    update public.staff_access_grants
       set revoked_at = now(),
           revoked_by = v_by.id,
           revoked_by_name = coalesce(v_by.name, 'System'),
           revoke_reason = format('Ended automatically when %s was made inactive.', new.name)
     where staff_id = new.id and revoked_at is null;
  end if;
  return new;
end;
$$;
drop trigger if exists staff_grants_end_with_staff on public.staff;
create trigger staff_grants_end_with_staff after update of active on public.staff
  for each row execute function public.staff_grants_end_with_staff();

-- ── the rules that decided by role now also ask ─────────────
-- Each is exactly what it was, OR the matching grant. Nothing is narrowed.
drop policy if exists authorizations_write on public.authorizations;
create policy authorizations_write on public.authorizations for all to authenticated
  using (public.current_staff_role() = any (array['Admin', 'Billing']) or public.staff_has_area('billing', 'edit'))
  with check (public.current_staff_role() = any (array['Admin', 'Billing']) or public.staff_has_area('billing', 'edit'));

drop policy if exists invoices_write on public.invoices;
create policy invoices_write on public.invoices for all to authenticated
  using (public.current_staff_role() = any (array['Admin', 'Billing']) or public.staff_has_area('billing', 'edit'))
  with check (public.current_staff_role() = any (array['Admin', 'Billing']) or public.staff_has_area('billing', 'edit'));

drop policy if exists completions_write on public.completions;
create policy completions_write on public.completions for all to authenticated
  using (public.current_staff_role() = any (array['Admin', 'Billing']) or public.staff_has_area('billing', 'edit'))
  with check (public.current_staff_role() = any (array['Admin', 'Billing']) or public.staff_has_area('billing', 'edit'));

drop policy if exists service_entries_write on public.service_entries;
create policy service_entries_write on public.service_entries for all to authenticated
  using (public.current_staff_role() = any (array['Admin', 'Billing', 'Job Search']) or public.staff_has_area('billing', 'edit'))
  with check (public.current_staff_role() = any (array['Admin', 'Billing', 'Job Search']) or public.staff_has_area('billing', 'edit'));

drop policy if exists hours_requests_update on public.hours_requests;
create policy hours_requests_update on public.hours_requests for update to authenticated
  using (public.current_staff_role() = any (array['Admin', 'Billing']) or staff_id = public.current_staff_id() or public.staff_has_area('billing', 'edit'))
  with check (public.current_staff_role() = any (array['Admin', 'Billing']) or staff_id = public.current_staff_id() or public.staff_has_area('billing', 'edit'));

drop policy if exists warrant_documents_read on public.warrant_documents;
create policy warrant_documents_read on public.warrant_documents for select to authenticated
  using (public.current_staff_role() = any (array['Admin', 'Billing']) or public.staff_has_area('billing', 'view'));

drop policy if exists warrant_pages_read on public.warrant_pages;
create policy warrant_pages_read on public.warrant_pages for select to authenticated
  using (public.current_staff_role() = any (array['Admin', 'Billing']) or public.staff_has_area('billing', 'view'));

drop policy if exists warrant_lines_read on public.warrant_lines;
create policy warrant_lines_read on public.warrant_lines for select to authenticated
  using (public.current_staff_role() = any (array['Admin', 'Billing']) or public.staff_has_area('billing', 'view'));

drop policy if exists counselors_write on public.counselors;
create policy counselors_write on public.counselors for insert to authenticated
  with check (public.current_staff_role() = any (array['Admin', 'Job Search', 'Billing']) or public.staff_has_area('counselors', 'edit'));

drop policy if exists counselors_update on public.counselors;
create policy counselors_update on public.counselors for update to authenticated
  using (public.current_staff_role() = any (array['Admin', 'Job Search', 'Billing']) or public.staff_has_area('counselors', 'edit'))
  with check (public.current_staff_role() = any (array['Admin', 'Job Search', 'Billing']) or public.staff_has_area('counselors', 'edit'));

-- ── and so do the six functions that check Billing themselves ──
-- Each keeps its own check word for word and gains "and no billing edit
-- grant": it refuses only when the role would refuse AND there is no grant.
-- Rewritten from the live definition rather than copied here by hand, and
-- each rewrite must actually happen or the migration stops.
do $$
declare
  f        record;
  v_def    text;
  v_new    text;
  v_checks text[] := array[
    'v_role is null or v_role not in (''service_role'', ''Admin'', ''Billing'')',
    'v_role is null or v_role not in (''Admin'', ''Billing'')',
    'public.current_staff_role() is null or public.current_staff_role() not in (''Admin'', ''Billing'')'
  ];
  v_check  text;
begin
  for f in
    select p.oid, p.proname
      from pg_proc p
     where p.pronamespace = 'public'::regnamespace
       and p.proname in ('confirm_authorization_document', 'dismiss_warrant_line', 'link_document_to_authorization',
                         'reconcile_warrant_line', 'reconcile_warrant_page', 'replace_placeholder_authorization')
  loop
    v_def := pg_get_functiondef(f.oid);
    if position('staff_has_area' in v_def) > 0 then
      continue;  -- already done
    end if;
    v_new := v_def;
    foreach v_check in array v_checks loop
      v_new := replace(v_new, 'if ' || v_check || ' then',
                       'if (' || v_check || ') and not public.staff_has_area(''billing'', ''edit'') then');
    end loop;
    if v_new = v_def then
      raise exception 'Found no Billing check to extend in %', f.proname;
    end if;
    execute v_new;
  end loop;

  if (select count(*) from pg_proc p
       where p.pronamespace = 'public'::regnamespace
         and p.proname in ('confirm_authorization_document', 'dismiss_warrant_line', 'link_document_to_authorization',
                           'reconcile_warrant_line', 'reconcile_warrant_page', 'replace_placeholder_authorization')
         and position('staff_has_area' in pg_get_functiondef(p.oid)) > 0) <> 6 then
    raise exception 'Not all six billing functions ask about grants';
  end if;
end $$;

-- ── rules on the grants themselves ──────────────────────────
alter table public.staff_access_grants enable row level security;

drop policy if exists staff_access_grants_read on public.staff_access_grants;
create policy staff_access_grants_read on public.staff_access_grants for select to authenticated
  using (public.is_admin() or staff_id = public.current_staff_id());

-- Written only through grant_staff_access / revoke_staff_access and the trigger.
revoke all on public.staff_access_grants from anon;
revoke insert, update, delete, truncate on public.staff_access_grants from authenticated;
grant select on public.staff_access_grants to authenticated;
grant all on public.staff_access_grants to service_role;

revoke execute on function public.staff_access_grants_guard() from public, anon, authenticated;
revoke execute on function public.staff_grants_end_with_staff() from public, anon, authenticated;
revoke execute on function public.role_has_area(text, text, text) from public, anon;
revoke execute on function public.staff_has_area(text, text) from public, anon;
revoke execute on function public.grant_staff_access(uuid, text, text, text) from public, anon;
revoke execute on function public.revoke_staff_access(uuid, text) from public, anon;
grant execute on function public.role_has_area(text, text, text), public.staff_has_area(text, text),
  public.grant_staff_access(uuid, text, text, text), public.revoke_staff_access(uuid, text)
  to authenticated, service_role;
