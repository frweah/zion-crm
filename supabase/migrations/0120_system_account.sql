-- Zion Vocational Rehab CRM — a system account, for the check that runs after
-- every deploy
--
-- Clients → Jobs shipped with a server error on 21 Sept 2026 that nothing
-- caught until somebody opened it. The answer is an account that signs in
-- after each deploy and opens every screen it can reach, and a deploy that
-- fails when one of them does (scripts/smoke.mjs, .github/workflows/smoke.yml).
-- That account is not a person, and everything here is about keeping it from
-- being mistaken for one or used as one:
--
--   It is marked is_system, shown as a system account on People, and left
--   out of every list somebody picks a colleague from.
--
--   It is Job Search, the least a signed-in account can be, and it can be
--   nothing else: not Admin, not given any area beyond its role.
--
--   It reads and never writes. Every table's rules gain a restrictive one
--   refusing an insert, update or delete made as a system account - so if its
--   password ever leaked, what leaked is the ability to look, not to change
--   anything. (Functions that write for themselves - noting a record was
--   opened - still do, as for anybody.)
--
--   Its reads are logged like anybody's: nothing here, or anywhere, exempts it.

alter table public.staff
  add column if not exists is_system boolean not null default false;

comment on column public.staff.is_system is
  'An account that is not a person (0120): the deploy check. Read-only, Job Search, never given more.';

alter table public.staff drop constraint if exists staff_system_is_job_search;
alter table public.staff add constraint staff_system_is_job_search
  check (not is_system or role = 'Job Search');

/** Whether the signed-in account is a system account. */
create or replace function public.current_staff_is_system()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select s.is_system from public.staff s where s.user_id = auth.uid()), false);
$$;
revoke execute on function public.current_staff_is_system() from public, anon;
grant execute on function public.current_staff_is_system() to authenticated;

-- ── never given more than its role ─────────────────────────
create or replace function public.refuse_grant_to_system()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.staff s where s.id = new.staff_id and s.is_system) then
    raise exception 'A system account is given nothing beyond its role.' using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
drop trigger if exists staff_access_grants_not_system on public.staff_access_grants;
create trigger staff_access_grants_not_system before insert or update on public.staff_access_grants
  for each row execute function public.refuse_grant_to_system();
revoke execute on function public.refuse_grant_to_system() from public, anon, authenticated;

-- ── reads, never writes ────────────────────────────────────
-- Every table with row-level security. A later migration that adds a table
-- calls apply_system_read_only on it; verify_system_account.sql fails if one
-- is ever missed.
create or replace function public.apply_system_read_only(p_table regclass)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_name text := (select relname from pg_class where oid = p_table);
begin
  execute format('drop policy if exists system_read_only_insert on %s', p_table);
  execute format('drop policy if exists system_read_only_update on %s', p_table);
  execute format('drop policy if exists system_read_only_delete on %s', p_table);
  execute format('create policy system_read_only_insert on %s as restrictive for insert to authenticated with check (not (select public.current_staff_is_system()))', p_table);
  execute format('create policy system_read_only_update on %s as restrictive for update to authenticated using (not (select public.current_staff_is_system())) with check (not (select public.current_staff_is_system()))', p_table);
  execute format('create policy system_read_only_delete on %s as restrictive for delete to authenticated using (not (select public.current_staff_is_system()))', p_table);
end;
$$;
revoke execute on function public.apply_system_read_only(regclass) from public, anon, authenticated;

do $$
declare r record;
begin
  for r in
    select c.oid::regclass as t
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind = 'r' and c.relrowsecurity
  loop
    perform public.apply_system_read_only(r.t);
  end loop;
end $$;

-- Files as well: nothing uploaded, replaced or removed as a system account.
drop policy if exists system_read_only_insert on storage.objects;
drop policy if exists system_read_only_update on storage.objects;
drop policy if exists system_read_only_delete on storage.objects;
create policy system_read_only_insert on storage.objects as restrictive for insert to authenticated
  with check (not (select public.current_staff_is_system()));
create policy system_read_only_update on storage.objects as restrictive for update to authenticated
  using (not (select public.current_staff_is_system()));
create policy system_read_only_delete on storage.objects as restrictive for delete to authenticated
  using (not (select public.current_staff_is_system()));
