-- Zion Vocational Rehab CRM — the directory log is for real people
--
-- Six rows reading "ZZ Report Test Counselor" were sitting in Recent changes
-- on Counselors → Directory, three Added/Removed pairs ninety seconds apart on
-- 21 Sept 2026. The owner saw them. They are gone below.
--
-- Where they came from matters, because it decides what prevents the next one.
-- That name appears nowhere in this repository and never has, in any commit:
-- they were not left behind by a verification script. They were committed by
-- somebody - me, in an earlier session - inserting and deleting a test
-- counselor by hand while the counselor report was being built.
--
-- Which means the obvious guard does not work. A verification script's rows
-- roll back, and a log row written by a trigger inside that transaction rolls
-- back with it: there is nothing there to stop. What put these in front of the
-- owner was a write outside any transaction at all, and the only thing that
-- catches that is the name.
--
-- So the log asks what it is being asked to record. The directory change log
-- is read by a person deciding whether a counselor's details moved - it is not
-- an audit of the database, which is what access_log and client_deletions are
-- for. A row named by the fixture convention is not news to anybody, and
-- refusing to write it holds however the write arrived: a script that forgot
-- its rollback, a statement run by hand, a probe left open.
--
-- The convention itself is the thing being leaned on, so it is written down
-- once, here, and both the log and verify_zz_no_fixtures.sql read it (§11).

/**
 * True when a name follows the fixture convention — ZZ or ZQ, as every
 * verification script and probe names the people it invents.
 *
 * Deliberately narrow: ZZ or ZQ has to be the whole word, so it is followed by
 * a space, a hyphen or the end of the name. "ZZ Delete Client" and "ZQ-001"
 * match; a real person whose name merely begins with those letters does not.
 */
create or replace function public.is_fixture_name(p_name text)
returns boolean
language sql immutable parallel safe as $$
  select btrim(coalesce(p_name, '')) ~ '^Z[ZQ]([ -]|$)'
$$;

comment on function public.is_fixture_name is
  'True when a name follows the ZZ/ZQ fixture convention. One definition, read by the directory change log and by verify_zz_no_fixtures.sql.';

grant execute on function public.is_fixture_name(text) to authenticated;

-- ── the log may let go of what it should never have held ─────
-- The change log is append-only, and that is right: it is the directory's
-- record and nobody edits it. But it refused to let the six invented rows go,
-- which left the owner looking at test data in a screen that cannot be
-- corrected - an append-only rule protecting the opposite of what it is for.
--
-- So the guard learns the one distinction that matters, the same way the
-- access log learned one in 0178: a row the log would now refuse to write may
-- be removed. Nothing real can match it, because is_fixture_name is what the
-- insert is checked against - the rule that decides what goes in is the rule
-- that decides what may come back out, which is why there is one definition of
-- it and not two.
create or replace function public.directory_changes_append_only()
returns trigger language plpgsql
security definer set search_path = public as $$
begin
  if tg_op = 'DELETE' and public.is_fixture_name(old.entity_name) then
    return old;
  end if;
  raise exception 'The directory''s change log is a record; it is added to, never changed or removed.'
    using errcode = 'insufficient_privilege';
end;
$$;

comment on function public.directory_changes_append_only is
  'The change log is added to, never changed. The one exception is removing a row the log would now refuse to write — an invented name, which is not a record of anything.';

-- ── the six rows the owner saw ───────────────────────────────
-- Named by the convention rather than by their keys, so this says what it is
-- removing. Nothing real can match it, and the count is reported.
do $$
declare v_n bigint;
begin
  delete from public.directory_changes where public.is_fixture_name(entity_name);
  get diagnostics v_n = row_count;
  raise notice 'removed % fixture row(s) from the directory change log', v_n;
end $$;

-- ── and the log stops recording them ─────────────────────────
-- Everything below the first branch is 0099 unchanged.
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
  -- This log is read by a person asking whether a counselor's details moved.
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

  v_entity := case tg_table_name
    when 'counselors' then 'Counselor'
    when 'billing_offices' then 'Billing office'
    else 'Office' end;
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
  'Records a real change to a counselor, billing office or office. A name following the fixture convention is not recorded — the log is read by a person, not by a machine.';
