-- Zion Vocational Rehab CRM — Job Coach and Case Manager
--
-- Two roles the practice has been working around (Intake Automation Brief,
-- 10 Oct 2026). Both see every client, because both work with whoever is in
-- front of them; neither sees Billing's money or Admin.
--
--   Job Coach is Job Search with one addition: logging billable hours against
--   a coaching authorization. That is the job - somebody sitting with a client
--   at a worksite, whose hours are what the practice bills - and until now it
--   meant giving them the Job Search role and hoping.
--
--   Case Manager is Intake & Client Reports, which the database already calls
--   'Reports'. The label was always wrong for what the person does: the role
--   is not reporting, it is carrying the case.
--
-- Areas rather than screens, as 0092 set up: a role says what somebody has
-- with no grant at all, and role_has_area is the one answer the database and
-- lib/roles.ts are both held to (verify_access_grants.sql, check-nav.mjs).

alter table public.staff drop constraint if exists staff_role_check;
alter table public.staff add constraint staff_role_check check (
  role = any (array['Admin', 'Job Search', 'Reports', 'Billing', 'Job Coach', 'Case Manager'])
);

create or replace function public.role_has_area(p_role text, p_area text, p_level text default 'view')
returns boolean
language sql immutable set search_path = public as $$
  select coalesce(case p_area
    -- Job Coach has what Job Search has; Case Manager has what Reports has.
    when 'tasks'      then p_role in ('Admin', 'Job Search', 'Reports', 'Job Coach', 'Case Manager')
    when 'counselors' then p_role in ('Admin', 'Job Search', 'Billing', 'Job Coach')
    when 'billing'    then p_role in ('Admin', 'Billing')
    when 'insights'   then p_role = 'Admin'
    else false
  end, false);
$$;

comment on function public.role_has_area is
  'What a role has with no grant at all. Job Coach is Job Search; Case Manager is Reports. Neither reaches billing or insights.';

-- ── a Job Coach logs hours, against coaching and nothing else ──
--
-- The role exists for this, so it is the database that says it and not only
-- the screen: the client record offers a Job Coach only their coaching
-- authorizations to log against, and this refuses the rest if the request
-- comes any other way.
--
-- Asked through a function rather than with an `exists` in the policy, and
-- neither of the two things about that function is a style choice. Both were
-- found by the verification refusing the coaching hours this role exists to
-- log, which is the one case that had to work.
--
--   SECURITY DEFINER, because a subquery inside a policy runs as the person
--   the policy is being applied to: it would read `authorizations` through
--   `authorizations`' own row rules, and a Job Coach who cannot select the row
--   gets `false`.
--
--   VOLATILE, not STABLE, which is the subtle one. Logging coaching hours
--   fires route_entry_to_month (0172), a BEFORE trigger that opens that
--   month's child authorization and points the entry at it - so by the time
--   the row rules are checked, the authorization they are asked about was
--   created earlier in this same statement. A STABLE function reads the
--   snapshot from the start of the statement, where that row does not exist
--   yet, and answers "not coaching" about a coaching authorization.
create or replace function public.authorization_is_coaching(p_auth uuid)
returns boolean
language sql volatile security definer set search_path = public as $$
  select exists (
    select 1 from public.authorizations a
     where a.id = p_auth and a.service_type like 'Job Coaching%'
  )
$$;

comment on function public.authorization_is_coaching is
  'Is this authorization a coaching one? Definer, because the policy that asks is applied to somebody who may not be able to read the row.';

revoke all on function public.authorization_is_coaching(uuid) from anon, authenticated;
grant execute on function public.authorization_is_coaching(uuid) to authenticated;

-- Everybody who could write a service entry before still can, unchanged.
drop policy if exists service_entries_write on public.service_entries;
create policy service_entries_write on public.service_entries
  for all
  using (
    (select public.current_staff_role()) = any (array['Admin', 'Billing', 'Job Search'])
    or (select public.staff_has_area('billing', 'edit'))
    or ((select public.current_staff_role()) = 'Job Coach'
        and public.authorization_is_coaching(service_entries.auth_id))
  )
  with check (
    (select public.current_staff_role()) = any (array['Admin', 'Billing', 'Job Search'])
    or (select public.staff_has_area('billing', 'edit'))
    or ((select public.current_staff_role()) = 'Job Coach'
        and public.authorization_is_coaching(service_entries.auth_id))
  );

-- ── Rispah ───────────────────────────────────────────────────
-- Her record and her invite already exist; the owner made both. Only the role
-- is set here, and only if it has not been set already.
do $$
declare v_n bigint;
begin
  update public.staff set role = 'Case Manager'
   where name = 'Rispah Otieno' and role <> 'Case Manager';
  get diagnostics v_n = row_count;
  raise notice 'Rispah: % record(s) set to Case Manager', v_n;
end $$;

-- ── the placeholder goes ─────────────────────────────────────
-- "Billing (to be assigned)" was a seat with nobody in it, kept so work could
-- be addressed somewhere before Melanie arrived. Melanie is here.
--
-- Nothing of anybody else's points at it: the only references are its own two
-- HR records, its onboarding checklist and its employment row, which go with
-- it. So there is nothing to reassign - checked rather than assumed, and the
-- count is raised either way so a future reference is not deleted quietly.
do $$
declare
  v_id uuid;
  v_n  bigint := 0;
  v_m  bigint;
  r    record;
begin
  select id into v_id from public.staff where name = 'Billing (to be assigned)';
  if v_id is null then
    raise notice 'the placeholder is already gone';
    return;
  end if;

  for r in
    select rel.relname as tbl, att.attname as col
      from pg_constraint con
      join pg_class rel on rel.oid = con.conrelid
      join unnest(con.conkey) k on true
      join pg_attribute att on att.attrelid = rel.oid and att.attnum = k
     where con.confrelid = 'public.staff'::regclass
       and con.contype = 'f'
       and rel.relname not in ('staff_checklist_items', 'staff_employment')
  loop
    execute format('select count(*) from public.%I where %I = $1', r.tbl, r.col)
      using v_id into v_m;
    if v_m > 0 then
      v_n := v_n + v_m;
      raise notice 'still referenced: %.% holds % row(s)', r.tbl, r.col, v_m;
    end if;
  end loop;

  if v_n > 0 then
    raise exception 'The placeholder is referenced by % row(s) outside its own HR records. Reassign them to Melanie first.', v_n
      using errcode = 'check_violation';
  end if;

  delete from public.staff where id = v_id;
  raise notice 'the placeholder is removed, with its own two HR records';
end $$;
