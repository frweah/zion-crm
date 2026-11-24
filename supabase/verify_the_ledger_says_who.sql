-- Zion Vocational Rehab CRM — the ledger says who did it (0386)
--
-- Four payments were written into this ledger by direct SQL on 23 November
-- with no `recorded_by` and a name no account here issues. Grants did not
-- stop it and could not: the service role and a direct connection go round
-- grants and row level security both. What has to hold now:
--
--   a write from inside one of the ledger's own functions is allowed, even
--   with no person behind it - the reader reconciling a warrant page runs as
--   the service role, and the function is what vouches for it;
--
--   a write from outside them is allowed only if it names a real, active
--   staff member, so a hand-written repair is attributable;
--
--   anything else is refused, with a sentence;
--
--   and the list of functions the trigger trusts is the list of functions
--   that actually write these tables. A twelfth one cannot arrive and be
--   refused in production, and one that is dropped cannot stay trusted.
--
-- The last of those is the one that would rot, so it is asked of the catalog
-- rather than of this comment.
--
-- Everything is rolled back.

begin;

do $$
declare
  failures  text[] := array[]::text[];
  v_mark    integer;
  v_admin   uuid; v_admin_uid uuid := gen_random_uuid();
  v_gone    uuid;
  v_counsel uuid;
  v_client  uuid;
  v_auth    uuid;
  v_page    uuid;
  v_doc     uuid;
  v_line    uuid;
  v_n       integer;
  v_said    text;
  v_blessed text[];
  v_writes  text[];
  v_missing text;
  v_extra   text;
begin
  insert into public.staff (name, email, role, active)
  values ('ZZ Says Admin', 'zz-says-admin@example.test', 'Admin', true) returning id into v_admin;
  insert into public.staff (name, email, role, active)
  values ('ZZ Says Former', 'zz-says-former@example.test', 'Billing', false) returning id into v_gone;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_admin_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-says-admin@example.test', '{}', '{}', now(), now());
  update public.staff set user_id = v_admin_uid where id = v_admin;

  insert into public.counselors (name, email, office)
  values ('ZQ Says Counselor', 'zq-says@example.test', 'Salt Lake City') returning id into v_counsel;
  insert into public.clients (name, stage, status, counselor_id)
  values ('ZZ Says Client', 'Job Coaching', 'Active', v_counsel) returning id into v_client;
  insert into public.authorizations (client_id, number, service_type, total_hours, rate_type, rate, status)
  values (v_client, 'V0000997', 'Job Development', 20, 'Hourly', 45, 'Authorized') returning id into v_auth;

  -- ── 1. a write that names nobody is refused ──────────────────
  v_mark := coalesce(array_length(failures, 1), 0);
  begin
    insert into public.payments (auth_id, amount, source, recorded_by_name)
    values (v_auth, 100, 'Workbook', 'ZZ nobody');
    failures := failures || 'FAILED: a payment was written with no recorded_by from outside the ledger functions'::text;
  exception when others then
    v_said := sqlerrm;
    if position('who did it' in v_said) = 0 then
      failures := failures || format('FAILED: the refusal does not say what is missing: %s', v_said)::text;
    end if;
  end;

  begin
    insert into public.invoices (client_id, auth_id, number, amount, status, source)
    values (v_client, v_auth, 9000997, 100, 'Submitted', 'Backfill');
    failures := failures || 'FAILED: an invoice was written with no submitted_by'::text;
  exception when others then null;
  end;

  begin
    insert into public.authorization_corrections (auth_id, auth_number, field, was_value, new_value, reason)
    values (v_auth, 'V0000997', 'Rate', '45', '50', 'ZZ no author');
    failures := failures || 'FAILED: a correction was written with no staff_id'::text;
  exception when others then null;
  end;
  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  a payment, an invoice and a correction that name nobody are all refused';
  end if;

  -- ── 2. nor somebody who is not here any more ─────────────────
  v_mark := coalesce(array_length(failures, 1), 0);
  begin
    insert into public.payments (auth_id, amount, source, recorded_by, recorded_by_name)
    values (v_auth, 100, 'Workbook', v_gone, 'ZZ Says Former');
    failures := failures || 'FAILED: a payment was recorded in the name of somebody no longer active'::text;
  exception when others then null;
  end;
  -- This one the foreign key on recorded_by would refuse whatever the guard
  -- thought, which a fault proved: it is here because a column that loses
  -- its foreign key should fail something.
  begin
    insert into public.payments (auth_id, amount, source, recorded_by, recorded_by_name)
    values (v_auth, 100, 'Workbook', gen_random_uuid(), 'ZZ Nobody At All');
    failures := failures || 'FAILED: a payment was recorded in the name of a staff id that does not exist'::text;
  exception when others then null;
  end;
  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  a name that is not an active staff member is not a name';
  end if;

  -- ── 3. a write that names somebody is allowed ────────────────
  --
  -- This is the half a blunt rule breaks: a repair by hand has to stay
  -- possible, or the next person to need one does it somewhere there is no
  -- trigger at all.
  v_mark := coalesce(array_length(failures, 1), 0);
  begin
    insert into public.payments (auth_id, amount, source, recorded_by, recorded_by_name)
    values (v_auth, 100, 'Workbook', v_admin, 'ZZ Says Admin');
  exception when others then
    failures := failures || format('FAILED: a payment naming an active staff member was refused: %s', sqlerrm)::text;
  end;
  begin
    insert into public.authorization_corrections (auth_id, auth_number, field, was_value, new_value, reason, staff_id, staff_name)
    values (v_auth, 'V0000997', 'Rate', '45', '50', 'ZZ with an author', v_admin, 'ZZ Says Admin');
  exception when others then
    failures := failures || format('FAILED: a correction naming an active staff member was refused: %s', sqlerrm)::text;
  end;
  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  a write that names an active staff member is allowed';
  end if;

  -- ── 4. and the ledger's own functions still work ─────────────
  --
  -- Through `raise_invoice`, which stamps `submitted_by` from the staff id it
  -- is given. If the trigger were reading the stack wrongly this is what
  -- would break, and it is the path every invoice in the practice comes down.
  v_mark := coalesce(array_length(failures, 1), 0);
  begin
    perform public.raise_invoice(v_auth, null, null, 100, v_admin);
  exception when others then
    failures := failures || format('FAILED: raise_invoice could not raise an invoice: %s', sqlerrm)::text;
  end;
  select count(*) into v_n from public.invoices where auth_id = v_auth;
  if v_n < 1 then
    failures := failures || 'FAILED: no invoice came out of raise_invoice'::text;
  end if;
  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  the ledger functions still write, which is the path everything real comes down';
  end if;

  -- ── 5. a warrant line arrives undecided, and is decided by somebody ──
  v_mark := coalesce(array_length(failures, 1), 0);
  insert into public.warrant_documents (sha256, filename, relative_path, page_count)
  values (repeat('d', 64), 'zz-says.pdf', 'zz-says.pdf', 1) returning id into v_doc;
  insert into public.warrant_pages (document_id, page_no, image_path, warrant_no, warrant_date, total, lines_total, status)
  values (v_doc, 1, 'zz/says-1.png', 'F19999997', public.practice_today() - 3, 100, 100, 'Needs review') returning id into v_page;

  -- The reader posts the line with nobody's name on it, which must stay
  -- possible: nobody has decided anything yet.
  begin
    insert into public.warrant_lines (page_id, line_no, voucher, invoice_ref, described_ref, amount, status)
    values (v_page, 1, '26ZZ00000000997', 'V0000997', 'V0000997', 100, 'Needs review')
    returning id into v_line;
  exception when others then
    failures := failures || format('FAILED: a warrant line could not arrive undecided: %s', sqlerrm)::text;
  end;

  if v_line is not null then
    -- Deciding it is somebody's act.
    begin
      update public.warrant_lines
         set decided_at = now(), status = 'Resolved by hand', decided_by_name = 'ZZ nobody'
       where id = v_line;
      failures := failures || 'FAILED: a warrant line was decided by nobody'::text;
    exception when others then null;
    end;

    begin
      update public.warrant_lines
         set decided_at = now(), status = 'Resolved by hand',
             decided_by = v_admin, decided_by_name = 'ZZ Says Admin'
       where id = v_line;
    exception when others then
      failures := failures || format('FAILED: a warrant line could not be decided by an active staff member: %s', sqlerrm)::text;
    end;
  end if;
  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  a line arrives undecided, and the decision says who made it';
  end if;

  -- ── 6. the trusted list is the list that writes ──────────────
  --
  -- Asked of the catalog. A function added next month that writes one of
  -- these tables and is not trusted would be refused in production the first
  -- time it ran, and the only place that could be noticed before then is
  -- here.
  v_mark := coalesce(array_length(failures, 1), 0);
  -- The names, taken out of the function itself. Comment lines inside the
  -- literal are stripped first: one was put there and this read it as a
  -- function name three hundred characters long.
  select array_agg(x order by x)
    into v_blessed
    from (
      select btrim(replace(unnest, '''', ''), E' 	
') as x
        from unnest(string_to_array(
               regexp_replace(
                 (regexp_match(pg_get_functiondef('public.the_ledger_says_who()'::regprocedure),
                               'k_blessed constant text\[\] := array\[([^\]]*)\]'))[1],
                 '--[^
]*', '', 'g'),
               ','))
    ) s
   where x <> '';
  if v_blessed is null or array_length(v_blessed, 1) is null then
    failures := failures || 'FAILED: the trigger function no longer names the functions it trusts'::text;
  end if;

  select array_agg(distinct p.proname order by p.proname) into v_writes
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname <> 'the_ledger_says_who'
     and pg_get_functiondef(p.oid) ~* '(insert\s+into|update)\s+(public\.)?(payments|invoices|authorization_corrections|warrant_lines)\M';

  select string_agg(w, ', ') into v_missing
    from unnest(v_writes) w where not (w = any(coalesce(v_blessed, array[]::text[])));
  if v_missing is not null then
    failures := failures || format(
      'FAILED: these functions write the ledger and the trigger does not trust them, so they would be refused: %s',
      v_missing)::text;
  end if;

  select string_agg(b, ', ') into v_extra
    from unnest(coalesce(v_blessed, array[]::text[])) b
   where not (b = any(coalesce(v_writes, array[]::text[])));
  if v_extra is not null then
    failures := failures || format(
      'FAILED: the trigger trusts functions that no longer write the ledger: %s', v_extra)::text;
  end if;
  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  the % function(s) the trigger trusts are the % that write the ledger',
      array_length(v_blessed, 1), array_length(v_writes, 1);
  end if;

  if array_length(failures, 1) > 0 then
    raise exception E'\n%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- THE LEDGER SAYS WHO VERIFIED ---';
end $$;

rollback;
