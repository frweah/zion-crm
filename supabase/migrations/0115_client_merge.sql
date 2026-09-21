-- Zion Vocational Rehab CRM — two records for one client, made one
--
-- Punch list #11 (review, 20 Sept 2026): one client had two records - the
-- workbook's, in surname-first order and closed, and a newer active one - and
-- the activity was split between them. "Done" is one record holding the whole
-- history, with no second identity left.
--
-- A client record cannot simply be deleted once anybody has opened it: the
-- access log is append-only (0054) and names the record it was about, and it
-- stays that way - who looked at a client's file is not something a merge may
-- rewrite. So the record merged away stays as a row, marked merged_into, and
-- nobody signed in can see it: every list, search and picker loses it at
-- once, and an old link to it goes to the record it was merged into.
--
-- Everything else that pointed at it - notes, attachments, tasks, stage
-- history, authorizations, documents, whatever table is added later - is
-- moved, found from the foreign keys themselves rather than from a list that
-- would go stale. Blank fields on the kept record are filled from the other,
-- never overwritten, and the workbook's client number moves across so the
-- calendar tags and imports keyed on it keep finding the client.
--
-- All of it, or none: a move that cannot be made (a row that would collide
-- with one already there) stops the merge and changes nothing.

alter table public.clients
  add column if not exists merged_into uuid references public.clients(id);

comment on column public.clients.merged_into is
  'Set when this record was merged into another (0115). The row stays because the access log names it; nobody signed in sees it.';

-- Restrictive: whatever else lets somebody read a client, a merged record
-- stays out of sight.
drop policy if exists clients_not_merged on public.clients;
create policy clients_not_merged on public.clients as restrictive
  for select to authenticated
  using (merged_into is null);

/** Where a merged record went, for an old link to follow. Null if it was not merged. */
create or replace function public.client_merged_into(p_client uuid)
returns uuid language sql stable security definer set search_path = public as $$
  select c.merged_into from public.clients c
   where c.id = p_client and public.is_active_staff();
$$;

/**
 * Merge one client's record into another's. Admin only.
 */
create or replace function public.merge_clients(p_from uuid, p_into uuid)
returns table (moved text)
language plpgsql security definer set search_path = public as $$
declare
  v_from public.clients;
  v_into public.clients;
  r record;
  v_n integer;
  v_log text[] := '{}';
  v_sets text;
begin
  if not public.is_admin() then
    raise exception 'Only Admin merges client records.' using errcode = 'insufficient_privilege';
  end if;
  if p_from is null or p_into is null or p_from = p_into then
    raise exception 'Name two different records to merge.';
  end if;

  select * into v_from from public.clients where id = p_from for update;
  if not found then raise exception 'The record to merge away does not exist.'; end if;
  select * into v_into from public.clients where id = p_into for update;
  if not found then raise exception 'The record to keep does not exist.'; end if;
  if v_from.merged_into is not null then raise exception 'That record was already merged.'; end if;
  if v_into.merged_into is not null then raise exception 'The record to keep was itself merged away.'; end if;

  -- ── private details: one row per client ────────────────────
  if exists (select 1 from public.client_private where client_id = p_into) then
    update public.client_private i
       set dob = coalesce(i.dob, f.dob),
           address = coalesce(nullif(i.address, ''), f.address)
      from public.client_private f
     where i.client_id = p_into and f.client_id = p_from;
    delete from public.client_private where client_id = p_from;
  else
    update public.client_private set client_id = p_into where client_id = p_from;
  end if;

  -- ── everything else that points at it ─────────────────────
  for r in
    select c.conrelid::regclass as tbl, a.attname as col
      from pg_constraint c
      join pg_attribute a on a.attrelid = c.conrelid and a.attnum = any (c.conkey)
     where c.contype = 'f'
       and c.confrelid = 'public.clients'::regclass
       and array_length(c.conkey, 1) = 1
       and c.conrelid not in ('public.client_private'::regclass, 'public.access_log'::regclass, 'public.clients'::regclass)
  loop
    execute format('update %s set %I = $1 where %I = $2', r.tbl, r.col, r.col) using p_into, p_from;
    get diagnostics v_n = row_count;
    if v_n > 0 then
      v_log := v_log || format('%s: %s', r.tbl, v_n);
    end if;
  end loop;

  -- ── the record's own fields: blanks filled, nothing overwritten ──
  -- The unique identities are taken off the old record first, so they can
  -- go on the kept one.
  update public.clients set legacy_id = null, client_no = null, ghl_id = null where id = p_from;

  select string_agg(
           case when data_type in ('text', 'character varying')
                then format('%1$I = coalesce(nullif(i.%1$I, %2$L), f.%1$I)', column_name, '')
                else format('%1$I = coalesce(i.%1$I, f.%1$I)', column_name) end,
           ', ')
    into v_sets
    from information_schema.columns
   where table_schema = 'public' and table_name = 'clients'
     and column_name not in ('id', 'name', 'status', 'stage', 'created_at', 'updated_at', 'merged_into',
                             'legacy_id', 'client_no', 'ghl_id');
  execute format('update public.clients i set %s from (select ($1::public.clients).*) f where i.id = $2', v_sets)
    using v_from, p_into;

  update public.clients
     set legacy_id = coalesce(legacy_id, v_from.legacy_id),
         client_no = coalesce(client_no, v_from.client_no),
         ghl_id    = coalesce(ghl_id, v_from.ghl_id),
         -- The relationship began with the older record.
         created_at = least(created_at, v_from.created_at)
   where id = p_into;

  update public.clients set merged_into = p_into, status = 'Closed' where id = p_from;

  return query select unnest(v_log || array['merged'::text]);
end;
$$;

revoke execute on function public.client_merged_into(uuid) from public, anon;
grant execute on function public.client_merged_into(uuid) to authenticated;
revoke execute on function public.merge_clients(uuid, uuid) from public, anon;
grant execute on function public.merge_clients(uuid, uuid) to authenticated;
