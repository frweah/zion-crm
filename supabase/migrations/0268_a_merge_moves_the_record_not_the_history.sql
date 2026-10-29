-- A merge moves the record, not the history
--
-- `merge_clients` moves every row pointing at the record being merged away,
-- found by walking the foreign keys rather than from a list somebody keeps up
-- to date. That is why it has gone on working as tables were added, and it is
-- also why it has never once worked on a client with a filed document: four of
-- those tables are append-only logs whose triggers refuse every update, so the
-- merge raised "The document log is a record" and rolled itself back.
--
-- Found on 29 October, merging away a client record created from a misread
-- referral - the one client whose document had to move.
--
-- The fix is not to let the logs be updated. An append-only log records what
-- happened, and what happened is that the document was added to the record
-- that was later merged away. Rewriting the row to name the kept client would
-- make the log say something that is not true. The client row survives the
-- merge with `merged_into` set precisely so that history stays findable
-- through it.
--
-- So the merge leaves those rows where they are and says which ones it left,
-- in the list it already returns. A merge that silently left things behind
-- would be worse than one that failed.

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
  v_kept boolean;
  u record;
  v_match text;
  v_dropped integer;
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
    -- A log that refuses to be changed is left alone. Asked of the catalogue
    -- rather than from a list of table names, so a fifth append-only log added
    -- later is handled by having its trigger, not by somebody remembering to
    -- come back here. (CLAUDE.md: ask the rule rather than the roster.)
    select exists (
      select 1 from pg_trigger t
       join pg_proc p on p.oid = t.tgfoid
      where t.tgrelid = r.tbl and not t.tgisinternal
        and (t.tgtype & 16) <> 0
        and pg_get_functiondef(p.oid) ilike '%never changed or removed%'
    ) into v_kept;

    if v_kept then
      execute format('select count(*) from %s where %I = $1', r.tbl, r.col) into v_n using p_from;
      if v_n > 0 then
        v_log := v_log || format('%s: %s left on the merged record, which is where it happened', r.tbl, v_n);
      end if;
      continue;
    end if;

    -- A unique key that includes the client column collides the moment both
    -- records have a row with the same one: one weekly report per client per
    -- week, one monthly report per client per month, one of several others.
    -- Moving blindly raises unique_violation and takes the whole merge with
    -- it, which is the second thing that stopped a real merge on 29 October.
    --
    -- Where they collide, the kept record's row wins and the merged-away one
    -- goes. That is the only defensible way round: the two rows say the same
    -- thing about the same week, and the kept record's is the one on the
    -- record that survives. The count is reported rather than swallowed.
    for u in
      select array_agg(a.attname order by k.ord) as cols
        from pg_index i
        join unnest(i.indkey) with ordinality k(attnum, ord) on true
        join pg_attribute a on a.attrelid = i.indrelid and a.attnum = k.attnum
       where i.indrelid = r.tbl and i.indisunique and i.indpred is null
       group by i.indexrelid
      having r.col = any (array_agg(a.attname))
    loop
      select coalesce(string_agg(format('i.%1$I is not distinct from f.%1$I', c), ' and '), 'true')
        into v_match
        from unnest(u.cols) c
       where c <> r.col;

      execute format(
        'delete from %1$s f where f.%2$I = $1 and exists ('
          || 'select 1 from %1$s i where i.%2$I = $2 and %3$s)',
        r.tbl, r.col, v_match) using p_from, p_into;
      get diagnostics v_dropped = row_count;
      if v_dropped > 0 then
        v_log := v_log || format('%s: %s dropped, the kept record already had them', r.tbl, v_dropped);
      end if;
    end loop;

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

comment on function public.merge_clients(uuid, uuid) is
  'Merge one client record into another. Append-only logs are left on the merged record, which is where the thing they record happened; merged_into is the link to it.';

-- Same signature, so the grants carry over. Said out loud because a defaulted
-- parameter here would make a second function open to everybody.
revoke execute on function public.merge_clients(uuid, uuid) from anon;
