-- 0232 — Restricted client records, given person by person (owner, 21 Oct 2026).
--
-- Until now restricted documents (ID, medical, financial, legal, signed
-- intake) and the client portal's messages and requests were open to Admin,
-- Reports, and the client's assigned staff member - by role, and nothing
-- else. The owner wants to give that to any employee as he decides.
--
-- So it becomes an area in the existing grant system (0092): "Restricted
-- client records", view only. Admin and Reports still have it by role, as
-- before; anybody else is given it on Admin -> People, with a reason, and it
-- can be ended the same way. Every grant keeps who gave it, when and why.
-- The assigned staff member keeps seeing their own clients' records as
-- before.
--
-- Also: portal text alerts go back to 8 a.m. - 9 p.m., the practice's
-- texting window everywhere (owner, 21 Oct 2026), replacing 0231.
--
-- Applied in parts (0232a-b) on 21 Oct 2026; this file is their sum.

-- ── the area ────────────────────────────────────────────────
alter table public.staff_access_grants drop constraint if exists staff_access_grants_area_check;
alter table public.staff_access_grants add constraint staff_access_grants_area_check
  check (area = any (array['tasks', 'counselors', 'billing', 'insights', 'restricted']));
alter table public.staff_access_grants drop constraint if exists staff_access_grants_restricted_view;
alter table public.staff_access_grants add constraint staff_access_grants_restricted_view
  check (area <> 'restricted' or level = 'view');

create or replace function public.role_has_area(p_role text, p_area text, p_level text default 'view')
returns boolean language sql immutable set search_path = public as $$
  select coalesce(case p_area
    -- Job Coach has what Job Search has; Case Manager has what Reports has.
    when 'tasks'      then p_role in ('Admin', 'Job Search', 'Reports', 'Job Coach', 'Case Manager')
    when 'counselors' then p_role in ('Admin', 'Job Search', 'Billing', 'Job Coach')
    when 'billing'    then p_role in ('Admin', 'Billing')
    when 'insights'   then p_role = 'Admin'
    when 'restricted' then p_role in ('Admin', 'Reports') and p_level = 'view'
    else false
  end, false);
$$;

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
  if p_area not in ('tasks', 'counselors', 'billing', 'insights', 'restricted') then
    raise exception 'That is not an area access can be given to.' using errcode = 'check_violation';
  end if;
  if p_level not in ('view', 'edit') or (p_area in ('insights', 'restricted') and p_level <> 'view') then
    raise exception 'Insights and restricted records can be given to view; the other areas to view, or to view and edit.' using errcode = 'check_violation';
  end if;
  if nullif(trim(coalesce(p_reason, '')), '') is null or length(trim(p_reason)) < 3 then
    raise exception 'Say why this access is being given.' using errcode = 'check_violation';
  end if;
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

-- ── who may see restricted records, and the portal ──────────
-- The same three as before, plus anybody with a live grant.
create or replace function public.can_see_restricted(p_client_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1
      from public.staff s
      left join public.clients c on c.id = p_client_id
     where s.user_id = auth.uid()
       and s.active
       and (
         s.role in ('Admin', 'Reports')
         or c.assigned_staff_id = s.id
         or exists (select 1 from public.staff_access_grants g
                     where g.staff_id = s.id and g.area = 'restricted' and g.revoked_at is null)
       )
  );
$$;

create or replace function public.can_manage_portal(p_client uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1
      from public.staff s
      left join public.clients c on c.id = p_client
     where s.user_id = auth.uid() and s.active
       and (s.role in ('Admin', 'Reports')
            or c.assigned_staff_id = s.id
            or exists (select 1 from public.staff_access_grants g
                        where g.staff_id = s.id and g.area = 'restricted' and g.revoked_at is null)));
$$;

-- ── portal text alerts: 8 a.m. - 9 p.m. again ──────────────
create or replace function public.portal_claim_notice(p_conversation uuid)
returns table (notice_id uuid, channel text, destination text, name text)
language plpgsql security definer set search_path = public as $$
declare
  v_acc     public.portal_accounts%rowtype;
  v_local   time := (now() at time zone 'America/Denver')::time;
  v_text    boolean;
  v_channel text;
  v_dest    text;
  v_id      uuid;
  v_why     text := '';
begin
  select a.* into v_acc
    from public.conversations c join public.portal_accounts a on a.id = c.portal_account_id
   where c.id = p_conversation and c.kind = 'portal';
  if v_acc.id is null then
    raise exception 'That is not a portal conversation.' using errcode = 'check_violation';
  end if;
  if not public.can_manage_portal(v_acc.client_id) then
    raise exception 'Only Admin, Reports or the assigned staff member writes to this client''s portal.' using errcode = 'insufficient_privilege';
  end if;

  -- One an hour. A notice that was skipped sent nothing, so it does not count.
  if exists (select 1 from public.portal_notices n
              where n.conversation_id = p_conversation and n.status <> 'Skipped'
                and n.at > now() - interval '1 hour') then
    return;
  end if;

  if v_acc.disabled_at is not null or v_acc.first_signed_in_at is null then
    v_channel := 'None';
    v_why := case when v_acc.disabled_at is not null then 'Account disabled' else 'Not signed in yet' end;
  else
    v_text := public.portal_can_text(v_acc.id) and v_local >= time '08:00' and v_local < time '21:00';
    if coalesce(v_acc.notice_channel, case when nullif(v_acc.email, '') is not null then 'Email' else 'Text' end) = 'Text' and v_text then
      v_channel := 'Text'; v_dest := v_acc.phone;
    elsif nullif(v_acc.email, '') is not null then
      v_channel := 'Email'; v_dest := v_acc.email;
      if v_acc.notice_channel = 'Text' then v_why := 'Text not possible now, sent by email'; end if;
    elsif v_acc.phone is not null and public.portal_can_text(v_acc.id) then
      v_channel := 'None'; v_why := 'Outside texting hours';
    else
      v_channel := 'None'; v_why := 'No way to reach them';
    end if;
  end if;

  insert into public.portal_notices (conversation_id, account_id, channel, status, detail)
  values (p_conversation, v_acc.id, v_channel, case when v_channel = 'None' then 'Skipped' else 'Claimed' end, v_why)
  returning id into v_id;

  if v_channel = 'None' then return; end if;
  return query select v_id, v_channel, v_dest, v_acc.name;
end;
$$;

