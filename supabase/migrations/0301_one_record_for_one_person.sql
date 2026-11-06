-- Zion Vocational Rehab CRM — Phase 2 of the warrant reconciliation, part three
--
-- Ruling 5: the two records for one person become one.
--
-- The warrant index lists 57 clients and every one of them is already in the
-- CRM - which is why Phase 2 creates no clients at all. One of the 57 fitted
-- two records, both with the same name:
--
--   #1041, Closed, created 29 October 2025, three authorizations and three
--   payments on it, no counselor;
--   and a second with no client number, Active, created 7 September 2026,
--   nothing billed, with the counselor.
--
-- Neither was merged into the other, so the money was on one record and the
-- working relationship on the other. The closed one goes into the active one,
-- as ruled: merge_clients fills the blanks on the kept record without
-- overwriting anything, carries the client number across, and takes the
-- earlier created_at, because the relationship began with the older record.
--
-- It is the function rather than a hand-written move for the reason the
-- function exists: it asks the catalogue which tables point at a client, so a
-- table added since is handled, and it leaves the append-only logs where the
-- thing happened rather than rewriting history to tidy it.

begin;

do $$
declare
  v_admin uuid;
  v_uid   uuid;
  v_from  uuid;
  v_into  uuid;
  v_name  text;
  v_n     integer;
  r       record;
  v_auths integer;
  v_pays  numeric;
begin
  select id, user_id into v_admin, v_uid
    from public.staff where role = 'Admin' and active and not is_system
   order by created_at limit 1;
  if v_uid is null then
    raise exception 'no active Admin with a sign-in, so there is nobody who could merge a record';
  end if;

  -- Found by the shape the report described rather than by id: two live
  -- records with one name, one holding the money and one holding the
  -- counselor. If that is not what is there, this file stops.
  select c.name into v_name
    from public.clients c
   where c.merged_into is null
   group by c.name having count(*) > 1;
  if v_name is null then
    raise exception 'no name has two unmerged records any more, so there is nothing to merge';
  end if;

  select count(*) into v_n from public.clients where name = v_name and merged_into is null;
  if v_n <> 2 then
    raise exception '% has % unmerged records, and the ruling was about two', v_name, v_n;
  end if;

  select id into v_from from public.clients
   where name = v_name and merged_into is null and status = 'Closed';
  select id into v_into from public.clients
   where name = v_name and merged_into is null and status <> 'Closed';
  if v_from is null or v_into is null then
    raise exception 'the two records for % are not one closed and one live', v_name;
  end if;

  select count(*) into v_auths from public.authorizations where client_id = v_from;
  select coalesce(sum(p.amount), 0) into v_pays
    from public.payments p join public.authorizations a on a.id = p.auth_id
   where a.client_id = v_from;
  raise notice 'note  the closed record carries % authorization(s) and % in payments',
    v_auths, to_char(v_pays, 'FM999999.00');

  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);

  for r in select moved from public.merge_clients(v_from, v_into) loop
    raise notice '   %', r.moved;
  end loop;

  perform set_config('request.jwt.claims', '', true);

  -- ── and it is checked ──────────────────────────────────────
  if (select merged_into from public.clients where id = v_from) is distinct from v_into then
    raise exception 'the closed record was not marked as merged away';
  end if;
  if (select count(*) from public.authorizations where client_id = v_from) <> 0 then
    raise exception 'authorizations are still attached to the record that was merged away';
  end if;
  if (select count(*) from public.authorizations where client_id = v_into) <> v_auths then
    raise exception 'the kept record holds % authorization(s) and % came across',
      (select count(*) from public.authorizations where client_id = v_into), v_auths;
  end if;
  if (select coalesce(sum(p.amount), 0) from public.payments p
        join public.authorizations a on a.id = p.auth_id where a.client_id = v_into) <> v_pays then
    raise exception 'the money did not all arrive on the kept record';
  end if;
  if (select client_no from public.clients where id = v_into) is null then
    raise exception 'the kept record has no client number, and the merged one had 1041';
  end if;
  raise notice 'ok  one record now, with the client number, the counselor, the % authorization(s) and the %',
    v_auths, to_char(v_pays, 'FM999999.00');
end $$;

-- The ledger is untouched by a merge: the same payments, on the same
-- authorizations, under one client instead of two.
do $$
declare v_count integer; v_total numeric;
begin
  select count(*), coalesce(sum(amount), 0) into v_count, v_total from public.payments;
  if v_count <> 157 or v_total <> 160562.50 then
    raise exception 'the ledger moved during a merge: % payments, %', v_count, to_char(v_total, 'FM999999.00');
  end if;
  raise notice 'ok  157 payments, 160562.50 - a merge moves no money';
end $$;

commit;
