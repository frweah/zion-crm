-- Zion Vocational Rehab CRM — a change to a client is written down
-- (owner, 14 Oct 2026: "Clients and counselors: every field editable by the
-- roles that own them, same logging.")
--
-- Counselors have had this since 0099: a trigger that diffs the row and
-- records which fields moved, from what to what, who did it and why. Clients
-- had nothing. Their stage changes were kept (client_stage_history) and
-- everything else - the counselor they are assigned to, the billing office
-- they are billed through, their phone number - could change and leave no
-- trace at all.
--
-- So clients join the same log rather than getting one of their own. One
-- table, one trigger function, one screen pattern for reading it back; a
-- second log would have drifted from the first inside a month.
--
-- Two things made this more than adding a table name. The entity CASE ended
-- in `else 'Office'`, so a client would have been filed as an office - a
-- default branch quietly mislabelling the thing that was added next. And the
-- check constraint had to admit the new value before the trigger could write
-- it, which is why both are here and in that order.
--
-- The name is still the fixture test: a client invented for a test is not
-- news, however the write arrived (0179).

-- ── the log admits clients ──────────────────────────────────
alter table public.directory_changes drop constraint if exists directory_changes_entity_check;
alter table public.directory_changes add constraint directory_changes_entity_check
  check (entity in ('Counselor', 'Billing office', 'Office', 'Client'));

-- ── and knows one when it sees one ──────────────────────────
create or replace function public.directory_change_log()
returns trigger
language plpgsql security definer set search_path = public as $$
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
  -- This log is read by a person asking whether a record's details moved.
  -- Somebody invented for a test is not news, however the write arrived.
  if public.is_fixture_name(coalesce(v_new ->> 'name', v_old ->> 'name')) then
    return null;
  end if;

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

  /**
   * Every table that writes here is named.
   *
   * This used to end in `else 'Office'`. A default branch on a CASE like this
   * is a bug waiting for the next table: it does not fail, it mislabels, and
   * the log goes on looking fine while a client is filed as an office. Now an
   * unnamed table raises, which is a thing somebody notices on the deploy
   * that added it rather than a thing somebody finds in a year.
   */
  v_entity := case tg_table_name
    when 'counselors'      then 'Counselor'
    when 'billing_offices' then 'Billing office'
    when 'offices'         then 'Office'
    when 'clients'         then 'Client'
    else null end;
  if v_entity is null then
    raise exception 'The change log does not know what a row of % is', tg_table_name
      using hint = 'Name the table in directory_change_log and in the entity check.';
  end if;

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

comment on function public.directory_change_log is
  'Records a real change to a counselor, billing office, office or client: which fields moved, from what to what, by whom and why. A name following the fixture convention is not recorded — the log is read by a person, not by a machine. A table it does not know raises rather than guessing.';

drop trigger if exists clients_log on public.clients;
create trigger clients_log after insert or update or delete on public.clients
  for each row execute function public.directory_change_log();
