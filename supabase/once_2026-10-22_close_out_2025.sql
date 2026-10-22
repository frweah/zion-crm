-- RUN ONCE, 22 Oct 2026. Kept for the record, not to be run again:
-- it is written to be idempotent-ish (the merge checks, the update is
-- bounded by status) but it is a data change, not a migration, and the
-- system of record for what it did is public.directory_changes.
--
-- Part 1 clean-up, executed. Run once, 22 Oct 2026, on the owner's go.
--
-- Everything is attributed to the Admin who asked for it, because that is who
-- decided it. The reason rides on `zion.directory_reason`, which is what the
-- client change log reads, so every row carries its own line.
--
-- Order: the merge first, so the surviving Jaxon record is whole before
-- anything judges it; then the deactivation; then the four authorizations.

begin;

do $$
declare
  v_admin   uuid;
  v_keep    uuid;
  v_drop    uuid;
  r         record;
  v_n       int;
  v_closed  int := 0;
begin
  select user_id into v_admin from public.staff
   where role = 'Admin' and active and user_id is not null order by created_at limit 1;
  if v_admin is null then raise exception 'No Admin to attribute this to.'; end if;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);

  -- ── 3. the two Jaxon Ewell records become one ─────────────
  select id into v_keep from public.clients where client_no = 1064;
  select id into v_drop from public.clients
   where name = 'Jaxon G. Ewell' and client_no is null and merged_into is null;
  if v_keep is null or v_drop is null then
    raise notice 'merge: nothing to do (keep=%, drop=%)', v_keep, v_drop;
  else
    perform set_config('zion.directory_reason',
      'Merged the duplicate import record into client 1064 (2025 close-out)', true);
    for r in select m.moved as what from public.merge_clients(v_drop, v_keep) m loop
      raise notice 'merge moved: %', r.what;
    end loop;
    select count(*) into v_n from public.authorizations where client_id = v_keep;
    raise notice 'merge: client 1064 now holds % authorization(s)', v_n;
    select count(*) into v_n from public.client_documents where client_id = v_keep;
    raise notice 'merge: and % document(s)', v_n;
  end if;

  -- ── 1. everybody referred in 2025 goes Inactive ───────────
  --
  -- The twenty who are already Closed are left Closed. Closed is the more
  -- final of the two and they are already off every active list; moving them
  -- to Inactive would make them easier to reopen, which is not what closing
  -- out a caseload means.
  perform set_config('zion.directory_reason', '2025 caseload close-out', true);
  update public.clients
     set status = 'Inactive'
   where extract(year from created_at) = 2025
     and status = 'Active';
  get diagnostics v_n = row_count;
  raise notice 'deactivated: % client(s)', v_n;

  select count(*) into v_n from public.clients
   where extract(year from created_at) = 2025 and status = 'Closed';
  raise notice 'left Closed, untouched: % client(s)', v_n;

  -- ── 2. the four 2025 authorizations are closed ────────────
  perform set_config('zion.directory_reason', '', true);
  for r in
    select a.id as aid, a.number as num, c.name as who, a.status as st
      from public.authorizations a join public.clients c on c.id = a.client_id
     where extract(year from a.start_date) = 2025
       and a.status in ('Authorized', 'Due')
     order by a.number
  loop
    perform public.set_authorization_status(r.aid, 'Closed', '2025 — not billed', null);
    v_closed := v_closed + 1;
    raise notice 'closed: % (%) was %', r.num, r.who, r.st;
  end loop;
  raise notice 'closed % authorization(s)', v_closed;

  -- ── and the list the owner asked for ──────────────────────
  raise notice '';
  raise notice '════ deactivated clients still holding an open authorization ════';
  v_n := 0;
  for r in
    select c.name as who, c.stage as sg,
           string_agg(a.number || ' (' || a.status || ')', ', ' order by a.number) as auths
      from public.clients c
      join public.authorizations a on a.client_id = c.id
     where c.status = 'Inactive'
       and a.status not in ('Paid', 'Closed')
     group by c.name, c.stage
     order by c.name
  loop
    v_n := v_n + 1;
    raise notice '  % | stage % | %', rpad(r.who, 26), rpad(coalesce(r.sg, '-'), 16), r.auths;
  end loop;
  if v_n = 0 then
    raise notice '  (none - every deactivated client has only Paid or Closed authorizations)';
  else
    raise notice '  % client(s) above are worth a second look.', v_n;
  end if;
end $$;

commit;
