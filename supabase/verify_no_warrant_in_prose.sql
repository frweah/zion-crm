-- Zion Vocational Rehab CRM — a warrant number is not prose (0384)
--
-- Warrants are Admin's (owner, 14 November 2026). Every structured route was
-- closed that week - the warrant columns are not granted to `authenticated`,
-- a correction whose field is 'Warrant' is Admin's alone, the warrant tables
-- answer `warrant_hands()`. Prose was the route none of that could close, and
-- on 24 November a search of every text column found one sentence somebody
-- had typed into an authorization's note.
--
-- Two halves, because the rule has two:
--
--   the next keystroke: a warrant or voucher number typed into a note is
--   refused, with a sentence, for every role but Admin - who may read
--   warrants, so a note of theirs that names one tells nobody anything;
--
--   and the data: no text column a Billing seat can read holds one. Asked of
--   the catalog rather than of a list of columns, because the list is what
--   goes stale - a column added next month is in the scan the day it exists.
--
-- The scan proves it can fail before it is believed: an Admin writes a note
-- with a warrant number in it, the scan must find it, the note goes, and the
-- scan must then find nothing. A scan that cannot fail is a scan that says
-- the practice is clean whatever is in it.
--
-- It never prints what it found. A script that reports a leaked warrant
-- number by quoting it is the leak, in a log that is not Admin's either: it
-- names the table, the column and how many rows.
--
-- Everything is rolled back.

begin;

do $$
declare
  failures  text[] := array[]::text[];
  v_mark    integer;
  v_admin   uuid; v_admin_uid uuid := gen_random_uuid();
  v_bill    uuid; v_bill_uid  uuid := gen_random_uuid();
  v_coach   uuid; v_coach_uid uuid := gen_random_uuid();
  v_client  uuid;
  v_auth    uuid;
  v_note    uuid;
  v_n       integer;
  v_said    text;
  rec       record;
  cols      text[];
  c         text;
  where_sql text;
  pat       text;
  exact     text;
  found     text[];
  hits      bigint;
  /**
   * A number of each shape that is not on file: the rule is the shape, and a
   * fixture that borrowed a real warrant would be a client's payment in a
   * test script.
   */
  k_warrant text := 'F90000001';
  k_voucher text := '99ZZ00000000001';
  k_worded  text := 'paid on warrant 90000001';
  k_auth    text := 'V0000999';
begin
  insert into public.staff (name, email, role, active)
  values ('ZZ Prose Admin', 'zz-prose-admin@example.test', 'Admin', true) returning id into v_admin;
  insert into public.staff (name, email, role, active)
  values ('ZZ Prose Biller', 'zz-prose-biller@example.test', 'Billing', true) returning id into v_bill;
  insert into public.staff (name, email, role, active)
  values ('ZZ Prose Coach', 'zz-prose-coach@example.test', 'Job Coach', true) returning id into v_coach;

  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_admin_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-prose-admin@example.test', '{}', '{}', now(), now()),
         (v_bill_uid,  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-prose-biller@example.test', '{}', '{}', now(), now()),
         (v_coach_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-prose-coach@example.test', '{}', '{}', now(), now());
  update public.staff set user_id = v_admin_uid where id = v_admin;
  update public.staff set user_id = v_bill_uid  where id = v_bill;
  update public.staff set user_id = v_coach_uid where id = v_coach;

  insert into public.clients (name, stage, status, assigned_staff_id)
  values ('ZZ Prose Client', 'Job Coaching', 'Active', v_coach) returning id into v_client;
  insert into public.authorizations (client_id, number, service_type, total_hours, rate_type, rate, status)
  values (v_client, 'V0000998', 'Job Coaching', 20, 'Hourly', 45, 'Authorized') returning id into v_auth;

  -- ── 1. the shape is this practice's, not numbers in general ──
  v_mark := coalesce(array_length(failures, 1), 0);
  if not public.warrant_shaped(k_warrant) then
    failures := failures || 'FAILED: a warrant number is not recognised as one'::text;
  end if;
  if not public.warrant_shaped(k_voucher) then
    failures := failures || 'FAILED: a voucher number is not recognised as one'::text;
  end if;
  if not public.warrant_shaped(k_worded) then
    failures := failures || 'FAILED: the word warrant followed by eight digits is not recognised'::text;
  end if;
  if not public.warrant_shaped('Paid on warrant ' || k_warrant || '.') then
    failures := failures || 'FAILED: a warrant number inside a sentence is not recognised'::text;
  end if;
  /**
   * And the numbers staff write all day are not caught. A rule that refuses
   * an authorization number would be turned off within a week, and it would
   * deserve to be: that number is the one on every Billing screen.
   */
  if public.warrant_shaped(k_auth) then
    failures := failures || 'FAILED: an authorization number is read as a warrant, so Billing cannot write its own numbers'::text;
  end if;
  if public.warrant_shaped('Met for 90 minutes, 11/05/2026, invoice 1044403.') then
    failures := failures || 'FAILED: an ordinary note with dates and an invoice number is read as a warrant'::text;
  end if;
  if public.warrant_shaped('Warrant arrived, filed on the payment.') then
    failures := failures || 'FAILED: the word warrant with no number in it is refused'::text;
  end if;
  if public.warrant_shaped(null) or public.warrant_shaped('') then
    failures := failures || 'FAILED: nothing at all is read as a warrant number'::text;
  end if;
  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  a warrant and a voucher are recognised, and an authorization number is not';
  end if;

  -- ── 2. typed into a note, it is refused ──────────────────────
  v_mark := coalesce(array_length(failures, 1), 0);
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_coach_uid, 'role', 'authenticated')::text, true);

  begin
    insert into public.notes (client_id, staff_id, staff_name, text, type, method)
    values (v_client, v_coach, 'ZZ Prose Coach', 'Paid on warrant ' || k_warrant || '.', 'Phone call', 'Phone');
    failures := failures || 'FAILED: a Job Coach typed a warrant number into a note'::text;
  exception when others then
    v_said := sqlerrm;
    if position('payment' in lower(v_said)) = 0 then
      failures := failures || format('FAILED: the refusal does not say where the number belongs: %s', v_said)::text;
    end if;
  end;

  -- Billing too: they are the role that sees warrant numbers on paper.
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_bill_uid, 'role', 'authenticated')::text, true);
  begin
    insert into public.notes (client_id, staff_id, staff_name, text, type, method)
    values (v_client, v_bill, 'ZZ Prose Biller', k_voucher || ' came through today.', 'Phone call', 'Phone');
    failures := failures || 'FAILED: Billing typed a voucher number into a note'::text;
  exception when others then null;
  end;

  -- And an authorization's note, which is where it actually happened.
  begin
    update public.authorizations
       set note = 'Billed 11/06/2026. Paid on warrant ' || k_warrant || '.'
     where id = v_auth;
    if (select position(k_warrant in coalesce(note, '')) from public.authorizations where id = v_auth) > 0 then
      failures := failures || 'FAILED: Billing wrote a warrant number into an authorization note'::text;
    end if;
  exception when others then null;
  end;

  -- An ordinary note still saves, which is the half a blunt rule breaks.
  begin
    insert into public.notes (client_id, staff_id, staff_name, text, type, method)
    values (v_client, v_bill, 'ZZ Prose Biller',
            'Invoiced ' || k_auth || ' on 11/06/2026, $560 for job development.', 'Phone call', 'Phone');
  exception when others then
    failures := failures || format('FAILED: an ordinary Billing note was refused: %s', sqlerrm)::text;
  end;
  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  a warrant or voucher number in a note is refused, and an ordinary note is not';
  end if;

  -- ── 3. and Admin may write one ───────────────────────────────
  v_mark := coalesce(array_length(failures, 1), 0);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin_uid, 'role', 'authenticated')::text, true);
  begin
    insert into public.notes (client_id, staff_id, staff_name, text, type, method)
    values (v_client, v_admin, 'ZZ Prose Admin', 'Warrant ' || k_warrant || ' covers this month.', 'Phone call', 'Phone')
    returning id into v_note;
  exception when others then
    failures := failures || format('FAILED: an Admin could not write a warrant number: %s', sqlerrm)::text;
  end;

  /**
   * And a row that already holds one can still be edited, including by the
   * person taking the number out. A refusal on every later update of the row
   * would make the fix impossible from the screen the note is on.
   */
  if v_note is not null then
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_bill_uid, 'role', 'authenticated')::text, true);
    perform set_config('role', 'postgres', true);
    begin
      update public.notes set category = 'General progress' where id = v_note;
    exception when others then
      failures := failures || format('FAILED: a row holding a warrant number cannot be edited at all: %s', sqlerrm)::text;
    end;
  end if;
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  Admin may write one, and the row it is on can still be edited';
  end if;

  -- ── 4. no Billing-readable text column holds one ─────────────
  --
  -- The shape, and every warrant and voucher number actually on file. The
  -- second half catches the three warrants that are bare digits and would
  -- otherwise be indistinguishable from an amount; it is built here and never
  -- printed.
  select coalesce(string_agg(distinct x, '|'), '')
    into exact
    from (
      select btrim(warrant_no) as x from public.payments where coalesce(btrim(warrant_no), '') <> ''
      union select btrim(warrant) from public.invoices where coalesce(btrim(warrant), '') <> ''
      union select btrim(warrant) from public.authorizations where coalesce(btrim(warrant), '') <> ''
      union select btrim(voucher) from public.payments where coalesce(btrim(voucher), '') <> ''
    ) s
   where x ~ '^[A-Za-z0-9-]+$';

  pat := '(\yF[0-9]{8}\y)|(\y[0-9]{2}[A-Za-z]{2}[0-9]{11}\y)|((warrant|voucher)[^0-9A-Za-z]{0,12}[0-9]{6,})';
  if exact <> '' then
    pat := pat || '|(\y(' || exact || ')\y)';
  end if;

  -- Twice: once with the Admin's note still on file, which it must find, and
  -- once without it.
  for v_n in 1..2 loop
    if v_n = 2 and v_note is not null then
      delete from public.notes where id = v_note;
    end if;

    found := array[]::text[];
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_bill_uid, 'role', 'authenticated')::text, true);

    for rec in
      select c.table_name as t, array_agg(c.column_name order by c.column_name) as cs
        from information_schema.columns c
        join pg_class k on k.oid = (quote_ident(c.table_schema) || '.' || quote_ident(c.table_name))::regclass
       where c.table_schema = 'public'
         and c.data_type in ('text', 'character varying')
         and k.relkind = 'r'
       group by c.table_name
    loop
      -- Only the columns a signed-in person is granted. A column the practice
      -- closed is not Billing-readable, and that is the whole of the 14
      -- November work: `payments.warrant_no` is not in this scan because
      -- nobody signed in can read it.
      cols := array[]::text[];
      foreach c in array rec.cs loop
        if has_column_privilege('authenticated', format('public.%I', rec.t), c, 'select') then
          cols := cols || c;
        end if;
      end loop;
      if array_length(cols, 1) is null then continue; end if;

      select string_agg(format('%I ~* %L', x, pat), ' or ') into where_sql from unnest(cols) as x;
      begin
        execute format('select count(*) from public.%I where %s', rec.t, where_sql) into hits;
      exception when others then
        -- A table this seat cannot read at all answers nothing, which is the
        -- right answer: it is not Billing-readable.
        hits := 0;
      end;
      if hits > 0 then
        foreach c in array cols loop
          execute format('select count(*) from public.%I where %I ~* %L', rec.t, c, pat) into hits;
          if hits > 0 then
            found := found || format('%s.%s (%s row(s))', rec.t, c, hits);
          end if;
        end loop;
      end if;
    end loop;

    perform set_config('role', 'postgres', true);
    perform set_config('request.jwt.claims', '', true);

    if v_n = 1 then
      if array_length(found, 1) is null then
        failures := failures || 'FAILED: the scan did not find a warrant number an Admin had just written into a note, so it cannot find one at all'::text;
      else
        raise notice '  ok  the scan finds a warrant number in a note a Billing seat can read';
      end if;
    else
      if array_length(found, 1) is not null then
        failures := failures || format(
          'FAILED: a warrant or voucher number is in text a Billing seat can read: %s',
          array_to_string(found, '; ')
        )::text;
      else
        raise notice '  ok  no text column a Billing seat can read holds a warrant or voucher number';
      end if;
    end if;
  end loop;

  if array_length(failures, 1) > 0 then
    raise exception E'\n%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- NO WARRANT IN PROSE VERIFIED ---';
end $$;

rollback;
