-- Zion Vocational Rehab CRM — a merge finds out which logs refuse to move
--
-- Ruling 5 of 6 November could not be carried out: merge_clients refused with
--
--   A consent record cannot be changed. Record the new state instead.
--
-- which is sms_consent_events doing its job. A consent is proof the practice
-- was allowed to text somebody, and it outlives the record it points at; the
-- only update its guard permits is the pointer going null when the client is
-- deleted. Moving it to another client is not that.
--
-- ── why the merge did not already know ───────────────────────
--
-- It did know about four append-only logs, and it found them the way its own
-- comment says to - "asked of the catalogue rather than from a list of table
-- names, so a fifth append-only log added later is handled by having its
-- trigger, not by somebody remembering to come back here."
--
-- Except it asked the catalogue for the *wording*: a trigger whose function
-- text contains "never changed or removed". The four logs it was written
-- against all say that. The consent guard says something else, so the fifth
-- append-only log slipped through the check written to catch exactly it.
--
-- That is this repository's own recurring fault - a check that asks a
-- question merely near the rule. The rule is not "the trigger says these
-- words", it is "this table refuses the move". So now it is asked that way:
-- the move is attempted, and a refusal is taken as the answer. A plpgsql
-- block with an exception clause is a savepoint, so a refusal rolls back that
-- one table and nothing else.
--
-- Narrow on purpose: only check_violation and insufficient_privilege, the two
-- codes this schema refuses with. Anything else still takes the merge down,
-- because a half-finished merge that swallowed an unexpected error would be
-- worse than one that stopped.

begin;

create or replace function public.merge_clients(p_from uuid, p_into uuid)
 returns table(moved text)
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_from public.clients;
  v_into public.clients;
  r record;
  v_n integer;
  v_log text[] := '{}';
  v_sets text;
  u record;
  v_match text;
  v_dropped integer;
  v_refused text;
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
    v_refused := null;

    /**
     * The move, and a refusal taken as an answer.
     *
     * A log that will not be changed is left where the thing happened. Which
     * logs those are is not read off their wording any more - it is found out
     * by asking them. The block has an exception clause, so it is a savepoint:
     * a refusal undoes this table's move and leaves the rest of the merge
     * standing.
     */
    begin
      -- A unique key that includes the client column collides the moment both
      -- records have a row with the same one: one weekly report per client
      -- per week, one monthly report per client per month, one of several
      -- others. Moving blindly raises unique_violation and takes the whole
      -- merge with it, which is the second thing that stopped a real merge on
      -- 29 October.
      --
      -- Where they collide, the kept record's row wins and the merged-away
      -- one goes. That is the only defensible way round: the two rows say the
      -- same thing about the same week, and the kept record's is the one on
      -- the record that survives. The count is reported rather than swallowed.
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
    exception
      when check_violation or insufficient_privilege then
        v_refused := 'refused';
    end;

    if v_refused is not null then
      execute format('select count(*) from %s where %I = $1', r.tbl, r.col) into v_n using p_from;
      if v_n > 0 then
        v_log := v_log || format('%s: %s left on the merged record, which is where it happened', r.tbl, v_n);
      end if;
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
$function$;

revoke execute on function public.merge_clients(uuid, uuid) from anon, authenticated;
grant execute on function public.merge_clients(uuid, uuid) to authenticated;

commit;
