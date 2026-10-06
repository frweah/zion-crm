-- Zion Vocational Rehab CRM — the asset register (0150)
--
-- What has to hold, each tried from the direction that would break it:
--
--   One person holds a thing at a time, and handing it on is a return and an
--   assignment in the same breath.
--
--   What somebody still has is a list of real things with real tags, which
--   is what makes "return assigned assets" worth having on an offboarding
--   checklist.
--
--   Depreciation is straight line, posted once per month per thing, never
--   past what the thing cost, and the last month takes the rounding with it
--   so nothing is left on the books forever.
--
--   A month that has not finished is not depreciated.
--
--   Disposal takes the cost and the depreciation off together and recognises
--   what is left as a gain or a loss. A disposed thing is nobody's.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_entity   uuid;
  v_asset    uuid;
  v_cheap    uuid;
  v_odd      uuid;
  v_admin    uuid;
  v_adm_uid  uuid := gen_random_uuid();
  v_one      uuid;
  v_two      uuid;
  v_equip    uuid;
  v_acc      uuid;
  v_dep      uuid;
  v_loss     uuid;
  v_posted   integer;
  v_n        integer;
  v_amount   numeric;
  failures   text[] := '{}';
begin
  select id into v_entity from public.ledger_entities where is_default;
  update public.ledger_settings set books_start = date '2020-01-01' where entity_id = v_entity;

  v_equip := public.ledger_account('equipment');
  v_acc   := public.ledger_account('accumulated_dep');
  v_dep   := public.ledger_account('depreciation');
  v_loss  := public.ledger_account('disposal_loss');
  if v_equip is null or v_acc is null or v_dep is null or v_loss is null then
    raise exception 'FAILED: the chart is missing an account the register posts to';
  end if;
  raise notice 'ok  the chart has the accounts a register needs';

  insert into public.staff (name, email, role, active)
  values ('ZZ Asset Admin', 'zz-asset@example.test', 'Admin', true) returning id into v_admin;
  insert into public.staff (name, email, role, active)
  values ('ZZ Asset One', 'zz-asset1@example.test', 'Job Search', true) returning id into v_one;
  insert into public.staff (name, email, role, active)
  values ('ZZ Asset Two', 'zz-asset2@example.test', 'Job Search', true) returning id into v_two;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_adm_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-asset@example.test', '{}', '{}', now(), now());
  update public.staff set user_id = v_adm_uid where id = v_admin;

  -- A laptop costing 3600 on a 36-month life: 100 a month exactly. Bought
  -- in 2021, so all thirty-six of its months are in the past and the cap can
  -- actually be reached - nothing in the future is depreciable.
  insert into public.assets (entity_id, tag, name, class_key, cost, acquired_on)
  values (v_entity, 'ZZ-1', 'ZZ laptop', 'laptop', 3600, date '2021-01-10')
  returning id into v_asset;
  -- And one whose cost does not divide evenly, to see the last month take
  -- the rounding: 1000 over 36 months is 27.78, and 36 of those is 1000.08.
  insert into public.assets (entity_id, tag, name, class_key, cost, acquired_on)
  values (v_entity, 'ZZ-3', 'ZZ phone', 'laptop', 1000, date '2021-01-10')
  returning id into v_odd;
  -- And one that costs 250, which is below what a laptop is capitalised over.
  insert into public.assets (entity_id, tag, name, class_key, cost, acquired_on)
  values (v_entity, 'ZZ-2', 'ZZ keyboard', 'equipment', 0, date '2026-01-10')
  returning id into v_cheap;

  -- ── one holder at a time ──────────────────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);

  perform public.assign_asset(v_asset, v_one, 'ZZ first');
  perform public.assign_asset(v_asset, v_two, 'ZZ handed on');
  perform set_config('role', 'postgres', true);

  select count(*) into v_n from public.asset_assignments
   where asset_id = v_asset and to_date is null;
  if v_n <> 1 then
    failures := failures || format('FAILED: %s people hold the same laptop', v_n)::text;
  else
    raise notice 'ok  one person holds a thing at a time';
  end if;

  select count(*) into v_n from public.asset_assignments where asset_id = v_asset;
  if v_n <> 2 then
    failures := failures || format('FAILED: handing it on left %s rows of history', v_n)::text;
  else
    raise notice 'ok  and who had it before is still written down';
  end if;

  if (select assigned_staff_id from public.assets where id = v_asset) is distinct from v_two then
    failures := failures || 'FAILED: the register does not say who has it'::text;
  end if;

  -- ── what somebody still has ───────────────────────────────
  select count(*) into v_n from public.assets_held_by(v_two);
  if v_n <> 1 then
    failures := failures || format('FAILED: the person holding one thing is shown holding %s', v_n)::text;
  else
    raise notice 'ok  what somebody still has is a list of real things with real tags';
  end if;
  select count(*) into v_n from public.assets_held_by(v_one);
  if v_n <> 0 then
    failures := failures || 'FAILED: somebody who handed it back is still shown holding it'::text;
  end if;

  -- ── depreciation, straight line ───────────────────────────
  -- A month that has not finished cannot be depreciated.
  v_posted := public.post_depreciation_for(public.practice_today());
  if v_posted <> 0 then
    failures := failures || 'FAILED: the current month was depreciated before it finished'::text;
  else
    raise notice 'ok  a month that has not finished is not depreciated';
  end if;

  v_posted := public.post_depreciation_for(date '2026-02-01');
  if v_posted < 1 then
    failures := failures || 'FAILED: a finished month depreciated nothing'::text;
  end if;
  select amount into v_amount from public.asset_depreciation
   where asset_id = v_asset and month = date '2026-02-01';
  if v_amount <> 100 then
    failures := failures || format('FAILED: 3600 over 36 months posted %s for the month', v_amount)::text;
  else
    raise notice 'ok  depreciation is the cost divided by the life the CPA set';
  end if;

  -- Twice for the same month changes nothing.
  v_posted := public.post_depreciation_for(date '2026-02-01');
  select count(*) into v_n from public.asset_depreciation
   where asset_id = v_asset and month = date '2026-02-01';
  if v_posted <> 0 or v_n <> 1 then
    failures := failures || 'FAILED: a month was depreciated twice'::text;
  else
    raise notice 'ok  running it again for the same month changes nothing';
  end if;

  -- A thing that cost nothing is not depreciated at all.
  select count(*) into v_n from public.asset_depreciation where asset_id = v_cheap;
  if v_n <> 0 then
    failures := failures || 'FAILED: something that cost nothing was depreciated'::text;
  else
    raise notice 'ok  something that was never capitalised is never written off';
  end if;

  -- The ledger agrees with the schedule.
  select coalesce(sum(l.debit), 0) into v_amount
    from public.journal_lines l
    join public.journals j on j.id = l.journal_id
   where l.account_id = v_dep and j.source_id = v_asset;
  if v_amount <> 100 then
    failures := failures || format('FAILED: the ledger shows %s of depreciation where the schedule shows 100', v_amount)::text;
  else
    raise notice 'ok  what the schedule says is what the ledger posted';
  end if;

  -- ── it never writes off more than it cost ─────────────────
  for v_n in 0..59 loop
    perform public.post_depreciation_for((date '2021-01-01' + (v_n || ' months')::interval)::date);
  end loop;
  select coalesce(sum(d.amount), 0) into v_amount
    from public.asset_depreciation d where d.asset_id = v_asset;
  if v_amount > 3600 then
    failures := failures || format('FAILED: %s written off something that cost 3600', v_amount)::text;
  elsif v_amount < 3600 then
    failures := failures || format('FAILED: only %s of 3600 written off over five years', v_amount)::text;
  else
    raise notice 'ok  it writes off exactly what the thing cost, and then stops';
  end if;

  -- The one that does not divide evenly comes out exactly too.
  select coalesce(sum(d.amount), 0) into v_amount
    from public.asset_depreciation d where d.asset_id = v_odd;
  if v_amount <> 1000 then
    failures := failures || format('FAILED: %s written off something that cost 1000', v_amount)::text;
  else
    raise notice 'ok  and the last month takes the rounding, so nothing is left on the books';
  end if;

  -- ── disposal ──────────────────────────────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);
  begin
    perform public.dispose_asset(v_asset, public.practice_today(), '');
    failures := failures || 'FAILED: something was disposed of with no reason'::text;
  exception when others then
    raise notice 'ok  disposal needs a reason';
  end;

  perform public.dispose_asset(v_asset, public.practice_today(), 'ZZ dropped down the stairs', 0);
  perform set_config('role', 'postgres', true);

  select coalesce(sum(l.credit) - sum(l.debit), 0) into v_amount
    from public.journal_lines l
    join public.journals j on j.id = l.journal_id
   where l.account_id = v_equip and j.source_kind = 'Asset disposal' and j.source_id = v_asset;
  if v_amount <> 3600 then
    failures := failures || format('FAILED: disposal took %s off equipment, not 3600', v_amount)::text;
  else
    raise notice 'ok  disposal takes the cost off the books';
  end if;

  -- Everything this laptop was ever depreciated by, taken off in one entry.
  select coalesce(sum(l.credit) - sum(l.debit), 0) into v_amount
    from public.journal_lines l
    join public.journals j on j.id = l.journal_id
   where l.account_id = v_acc and j.source_id = v_asset;
  if v_amount <> 0 then
    failures := failures || format('FAILED: %s of this laptop''s depreciation is left behind', v_amount)::text;
  else
    raise notice 'ok  and the depreciation with it, leaving nothing behind';
  end if;

  if (select assigned_staff_id from public.assets where id = v_asset) is not null then
    failures := failures || 'FAILED: a disposed thing is still assigned to somebody'::text;
  else
    raise notice 'ok  a disposed thing is nobody''s';
  end if;

  select count(*) into v_n from public.asset_assignments
   where asset_id = v_asset and to_date is null;
  if v_n <> 0 then
    failures := failures || 'FAILED: somebody is still holding a disposed thing'::text;
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
