-- Zion Vocational Rehab CRM — where an invoice number comes from (0323)
--
-- What has to hold:
--
--   Nothing hands out an invoice number that a rollback cannot take back.
--   No sequence, no column default: a sequence is deliberately not
--   transactional, which is how a hundred and thirty-eight of the practice's
--   numbers were spent on fixture invoices that never existed.
--
--   The next number is one past the highest number anybody can point at:
--   the ledger, or a warrant stub. A stub prints the invoice number it pays,
--   so a number Margaret used and nobody entered is still not handed out
--   twice (0327).
--
--   An invoice may have no number at all, because three in the ledger went
--   out before the CRM numbered them and nobody has read Margaret's copy.
--
--   Two invoices written by one statement get two numbers.
--
--   A number given explicitly is kept, which is how 161 warrant-index rows
--   were backfilled.
--
-- This script is itself the test of the first rule: everything below is
-- rolled back, and the next run finds the ledger exactly where this one
-- found it.
--
-- The structural questions are asked first, before anything is written. Put
-- the trigger back the way it was and the insert below fails on a not-null
-- violation, which is a Postgres sentence about a column rather than this
-- script saying what is wrong.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_admin uuid; v_admin_uid uuid := gen_random_uuid();
  v_client uuid; v_auth uuid;
  v_top bigint; v_ledger bigint; v_stubs bigint;
  v_a bigint; v_b bigint; v_c bigint; v_d bigint;
  v_doc uuid; v_page uuid;
  v_n integer;
  failures text[] := '{}';
begin
  -- ── nothing hands them out ─────────────────────────────────
  if exists (select 1 from pg_class where relnamespace = 'public'::regnamespace
              and relkind = 'S' and relname = 'zion_invoice_number') then
    failures := failures || 'FAILED: the invoice number sequence is back, and a rollback does not undo it'::text;
  elsif (select count(*) from pg_attrdef d join pg_attribute a
            on a.attrelid = d.adrelid and a.attnum = d.adnum
          where d.adrelid = 'public.invoices'::regclass and a.attname = 'number') <> 0 then
    failures := failures || 'FAILED: invoices.number has a default again'::text;
  elsif not exists (select 1 from pg_trigger
                     where tgrelid = 'public.invoices'::regclass
                       and tgname = 'invoices_number' and not tgisinternal and tgenabled <> 'D') then
    failures := failures || 'FAILED: nothing numbers an invoice from the ledger'::text;
  else
    raise notice 'ok  no sequence decides an invoice number, and the trigger that does is on';
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;

  -- The two places a number can already have been used, asked separately so
  -- a rule that stopped reading one of them fails here.
  select coalesce(max(number), 0) into v_ledger from public.invoices;
  select coalesce(max(client_code::bigint), 0) into v_stubs
    from public.warrant_lines where client_code ~ '^[0-9]{6}$';
  v_top := greatest(v_ledger, v_stubs);

  insert into public.staff (name, email, role, active)
  values ('ZZ Numbering Admin', 'zz-numbering-admin@example.test', 'Admin', true) returning id into v_admin;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_admin_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'zz-numbering-admin@example.test', '{}', '{}', now(), now());
  update public.staff set user_id = v_admin_uid where id = v_admin;

  insert into public.clients (name, stage, status, assigned_staff_id)
  values ('ZZ Numbered Person', 'Job Search', 'Active', v_admin) returning id into v_client;

  insert into public.authorizations
    (client_id, number, service_type, rate_type, rate, total_hours, status, start_date, end_date)
  values (v_client, 'V0000923', 'WSA Tier 2', 'Hourly', 45, 20, 'Due',
          public.practice_today() - 90, public.practice_today() + 90)
  returning id into v_auth;

  -- ── one past the end of the ledger ─────────────────────────
  insert into public.invoices (client_id, auth_id, submitted_on, submitted_by, amount, source)
  values (v_client, v_auth, public.practice_today(), v_admin, 100, 'Backfill')
  returning number into v_a;

  if v_a <> v_top + 1 then
    failures := failures || format(
      'FAILED: the ledger ends at %s, the warrant stubs at %s, and the next invoice was numbered %s',
      v_ledger, v_stubs, v_a)::text;
  else
    raise notice 'ok  an invoice takes the number after the highest one anybody can point at';
  end if;

  -- ── two in one statement get two numbers ───────────────────
  -- The BEFORE trigger runs twice without the command counter moving between
  -- them, so a reading of max(number) alone hands both rows the same number
  -- and the unique index refuses the second. Caught here rather than left to
  -- abort the script, so the failure is a sentence about invoice numbers.
  v_b := 0;
  begin
    insert into public.invoices (client_id, auth_id, submitted_on, submitted_by, amount, source)
    values (v_client, v_auth, public.practice_today(), v_admin, 110, 'Backfill'),
           (v_client, v_auth, public.practice_today(), v_admin, 120, 'Backfill');
    select count(distinct number) into v_n from public.invoices
     where client_id = v_client and amount in (110, 120);
    select max(number) into v_b from public.invoices where client_id = v_client;
  exception when unique_violation then
    v_n := -1;
  end;

  if v_n = -1 then
    failures := failures || 'FAILED: two invoices written at once were handed the same number'::text;
  elsif v_n <> 2 then
    failures := failures || format('FAILED: two invoices written at once took %s number(s)', v_n)::text;
  elsif v_b <> v_top + 3 then
    failures := failures || format('FAILED: three invoices from %s reached %s, not %s',
                                   v_top, v_b, v_top + 3)::text;
  else
    raise notice 'ok  two invoices in one statement take two consecutive numbers';
  end if;

  -- ── a number given is a number kept ────────────────────────
  insert into public.invoices (client_id, auth_id, number, submitted_on, submitted_by, amount, source)
  values (v_client, v_auth, 700001, public.practice_today(), v_admin, 130, 'Backfill')
  returning number into v_c;

  if v_c <> 700001 then
    failures := failures || format('FAILED: an invoice given 700001 was numbered %s', v_c)::text;
  else
    raise notice 'ok  an invoice told its number keeps it';
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;

  -- ── a number on a stub is a number used ────────────────────
  -- Margaret's invoicing issued the numbers that went to USOR, and the only
  -- record of most of them in this practice is the warrant that paid them. A
  -- number printed on a stub must not be handed out to a new invoice.
  insert into public.warrant_documents (sha256, filename, relative_path, page_count)
  values (repeat('b', 64), 'zz-numbering.pdf', 'zz-numbering.pdf', 1) returning id into v_doc;
  insert into public.warrant_pages
    (document_id, page_no, image_path, ocr_text, rotation, warrant_no, warrant_date, total, status)
  values (v_doc, 1, '', 'ZZ stub', 0, 'F99000888', public.practice_today(), 500.00, 'Needs review')
  returning id into v_page;
  insert into public.warrant_lines
    (page_id, line_no, raw, dept, voucher, invoice_ref, described_ref, client_code, client_name, amount, status)
  values (v_page, 1, 'ZZ 999500- stub line', '6006', '99AW00000000009', 'V0000923', 'V0000923',
          '999500', 'ZZ', 500.00, 'Needs review');

  insert into public.invoices (client_id, auth_id, submitted_on, submitted_by, amount, source)
  values (v_client, v_auth, public.practice_today(), v_admin, 140, 'Backfill')
  returning number into v_d;

  if v_d <> 999501 then
    failures := failures || format(
      'FAILED: invoice 999500 is printed on a warrant stub and the next number handed out was %s', v_d)::text;
  else
    raise notice 'ok  a number printed on a warrant stub is not handed out again';
  end if;

  -- ── and an invoice may have no number ──────────────────────
  -- Three in the ledger have none: they went out before the CRM numbered
  -- them, and saying nothing is more honest than saying a number USOR cannot
  -- find. The column has to allow it.
  update public.invoices set number = null where number = 700001;
  select count(*) into v_n from public.invoices
   where client_id = v_client and number is null;
  if v_n < 1 then
    failures := failures || 'FAILED: an invoice cannot be left without a number'::text;
  else
    raise notice 'ok  an invoice whose number nobody has read can say so';
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, chr(10));
  end if;
end $$;

rollback;
