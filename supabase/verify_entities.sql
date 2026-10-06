-- Zion Vocational Rehab CRM — more than one set of books (0152)
--
-- E5 is groundwork: today there is one entity and every figure is unchanged.
-- What this proves is that the second one works, so that adding the PCA is
-- an afternoon rather than a quarter.
--
-- What has to hold, each tried from the direction that would break it:
--
--   A posting cannot mix entities. Consolidated figures would still be
--   right and each entity's own would be wrong, which is invisible until
--   somebody files.
--
--   A new set of books arrives with the same chart, so the two can be read
--   side by side without mapping one onto the other.
--
--   A transfer between entities posts both sides, and nets to nothing when
--   the two are consolidated. One side only is the worst thing that can
--   happen to a set of books.
--
--   A report for one entity shows that entity. A report for none sums the
--   ones the reader may see.
--
--   Access is per entity: a row makes the list, and no row means the
--   default, so nobody is locked out by the table existing.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_zion     uuid;
  v_pca      uuid;
  v_admin    uuid;
  v_adm_uid  uuid := gen_random_uuid();
  v_cpa      uuid;
  v_cpa_uid  uuid := gen_random_uuid();
  v_zion_rev uuid;
  v_zion_ar  uuid;
  v_pca_rev  uuid;
  v_pca_bank uuid;
  v_zion_due uuid;
  v_pca_due  uuid;
  v_j        uuid;
  v_both     uuid[];
  v_n        integer;
  v_amount   numeric;
  failures   text[] := '{}';
begin
  select id into v_zion from public.ledger_entities where is_default;
  update public.ledger_settings set books_start = date '2020-01-01' where entity_id = v_zion;

  insert into public.staff (name, email, role, active)
  values ('ZZ Entity Admin', 'zz-entity@example.test', 'Admin', true) returning id into v_admin;
  insert into public.staff (name, email, role, active)
  values ('ZZ Entity CPA', 'zz-cpa@example.test', 'Reports', true) returning id into v_cpa;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_adm_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-entity@example.test', '{}', '{}', now(), now()),
         (v_cpa_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-cpa@example.test', '{}', '{}', now(), now());
  update public.staff set user_id = v_adm_uid where id = v_admin;
  update public.staff set user_id = v_cpa_uid where id = v_cpa;
  -- The CPA is given Insights, which is how a read-only outsider gets in.
  insert into public.staff_access_grants (staff_id, area, level, reason, granted_by)
  values (v_cpa, 'insights', 'view', 'ZZ the accountant', v_admin);

  -- ── a second set of books ─────────────────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);
  v_pca := public.create_entity('ZZ Zion PCA', date '2020-01-01');
  perform set_config('role', 'postgres', true);

  select count(*) into v_n from public.ledger_accounts where entity_id = v_pca;
  if v_n = 0 then
    failures := failures || 'FAILED: a new set of books arrived with no chart'::text;
  else
    select count(*) into v_amount from public.ledger_accounts where entity_id = v_zion;
    if v_n <> v_amount then
      failures := failures || format('FAILED: the new chart has %s accounts where the first has %s', v_n, v_amount)::text;
    else
      raise notice 'ok  a new set of books arrives with the same chart as the first';
    end if;
  end if;

  if not exists (select 1 from public.ledger_settings where entity_id = v_pca) then
    failures := failures || 'FAILED: the new books have no start date or basis'::text;
  else
    raise notice 'ok  and with a start date and a basis of its own';
  end if;

  select id into v_zion_rev from public.ledger_accounts where entity_id = v_zion and code = '4020';
  select id into v_zion_ar  from public.ledger_accounts where entity_id = v_zion and role = 'ar';
  select id into v_zion_due from public.ledger_accounts where entity_id = v_zion and role = 'inter_entity';
  select id into v_pca_rev  from public.ledger_accounts where entity_id = v_pca  and code = '4020';
  select id into v_pca_bank from public.ledger_accounts where entity_id = v_pca  and role = 'bank';
  select id into v_pca_due  from public.ledger_accounts where entity_id = v_pca  and role = 'inter_entity';

  -- ── an entry cannot reach across ──────────────────────────
  begin
    insert into public.journals (entity_id, entry_date, memo, source_kind)
    values (v_zion, date '2026-03-01', 'ZZ mixed', 'Manual') returning id into v_j;
    insert into public.journal_lines (journal_id, account_id, debit) values (v_j, v_zion_ar, 100);
    insert into public.journal_lines (journal_id, account_id, credit) values (v_j, v_pca_rev, 100);
    set constraints all immediate;
    failures := failures || 'FAILED: one entry debited one entity and credited another'::text;
  exception when others then
    raise notice 'ok  a posting cannot mix two entities'' accounts';
  end;
  set constraints all deferred;

  -- ── each set of books earns its own money ─────────────────
  perform public.post_journal(date '2026-03-02', 'ZZ Zion earns', 'Manual', null, '',
    jsonb_build_array(
      jsonb_build_object('account', v_zion_ar, 'debit', 300),
      jsonb_build_object('account', v_zion_rev, 'credit', 300)),
    null, '', null, null, '', true, v_zion);
  perform public.post_journal(date '2026-03-02', 'ZZ PCA earns', 'Manual', null, '',
    jsonb_build_array(
      jsonb_build_object('account', v_pca_bank, 'debit', 700),
      jsonb_build_object('account', v_pca_rev, 'credit', 700)),
    null, '', null, null, '', true, v_pca);

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);

  select coalesce(sum(amount), 0) into v_amount
    from public.ledger_profit_and_loss(date '2026-03-01', date '2026-03-31', 'Accrual', v_zion);
  if v_amount <> 300 then
    failures := failures || format('FAILED: one entity''s own revenue read as %s, not 300', v_amount)::text;
  else
    raise notice 'ok  a report for one entity is that entity''s';
  end if;

  select coalesce(sum(amount), 0) into v_amount
    from public.ledger_profit_and_loss(date '2026-03-01', date '2026-03-31', 'Accrual', null);
  if v_amount <> 1000 then
    failures := failures || format('FAILED: consolidated revenue read as %s, not 1000', v_amount)::text;
  else
    raise notice 'ok  and a report for none of them sums the ones the reader may see';
  end if;

  -- The same account code in two charts is one line consolidated.
  select count(*) into v_n
    from public.ledger_profit_and_loss(date '2026-03-01', date '2026-03-31', 'Accrual', null)
   where code = '4020';
  if v_n <> 1 then
    failures := failures || format('FAILED: the same account code appeared %s times consolidated', v_n)::text;
  else
    raise notice 'ok  the same code in two charts is one line, not two';
  end if;

  -- ── money moving between them ─────────────────────────────
  v_both := public.post_inter_entity_transfer(v_pca, v_zion, 250, date '2026-03-10', 'ZZ shared rent');
  perform set_config('role', 'postgres', true);

  if v_both[1] is null or v_both[2] is null then
    failures := failures || 'FAILED: a transfer posted only one side'::text;
  else
    raise notice 'ok  a transfer between entities posts both sides';
  end if;

  select coalesce(sum(l.debit) - sum(l.credit), 0) into v_amount
    from public.journal_lines l where l.account_id = v_pca_due;
  if v_amount <> 250 then
    failures := failures || format('FAILED: the paying entity is owed %s, not 250', v_amount)::text;
  end if;
  select coalesce(sum(l.credit) - sum(l.debit), 0) into v_amount
    from public.journal_lines l where l.account_id = v_zion_due;
  if v_amount <> 250 then
    failures := failures || format('FAILED: the receiving entity owes %s, not 250', v_amount)::text;
  end if;

  -- Consolidated, what one owes the other is nothing at all.
  select coalesce(sum(l.debit) - sum(l.credit), 0) into v_amount
    from public.journal_lines l where l.account_id in (v_zion_due, v_pca_due);
  if v_amount <> 0 then
    failures := failures || format('FAILED: consolidated, the entities owe each other %s', v_amount)::text;
  else
    raise notice 'ok  and nets to nothing when the two are read together';
  end if;

  begin
    perform public.post_inter_entity_transfer(v_zion, v_zion, 10, date '2026-03-10', 'ZZ to itself');
    failures := failures || 'FAILED: money was transferred from a set of books to itself'::text;
  exception when others then
    raise notice 'ok  a transfer needs two different sets of books';
  end;

  -- ── who may see which ─────────────────────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_cpa_uid, 'role', 'authenticated')::text, true);

  select count(*) into v_n from public.my_entities();
  if v_n <> 1 then
    failures := failures || format('FAILED: somebody with no entity named sees %s of them', v_n)::text;
  else
    raise notice 'ok  somebody with no entity named sees the default one, as they always did';
  end if;

  select coalesce(sum(amount), 0) into v_amount
    from public.ledger_profit_and_loss(date '2026-03-01', date '2026-03-31', 'Accrual', null);
  if v_amount <> 300 then
    failures := failures || format('FAILED: a reader of one entity saw %s, which is more than theirs', v_amount)::text;
  else
    raise notice 'ok  and a consolidated report shows them only what is theirs';
  end if;

  perform set_config('role', 'postgres', true);
  insert into public.staff_entities (staff_id, entity_id) values (v_cpa, v_pca);
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_cpa_uid, 'role', 'authenticated')::text, true);

  select coalesce(sum(amount), 0) into v_amount
    from public.ledger_profit_and_loss(date '2026-03-01', date '2026-03-31', 'Accrual', null);
  if v_amount <> 700 then
    failures := failures || format('FAILED: named to one entity, they saw %s rather than that entity''s 700', v_amount)::text;
  else
    raise notice 'ok  named to one entity, that one is the whole list';
  end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);
  select count(*) into v_n from public.my_entities();
  if v_n < 2 then
    failures := failures || 'FAILED: an Admin cannot see the books they just added'::text;
  else
    raise notice 'ok  an Admin sees every set of books, including one just added';
  end if;
  perform set_config('role', 'postgres', true);

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
