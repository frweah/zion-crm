-- Zion Vocational Rehab CRM — billing offices
--
-- What has to hold, each tried from the direction that would break it:
--
--   Every counselor office bills through exactly one billing office, as the
--   owner mapped them; an office cannot be added without one, and a counselor
--   cannot be given an office that is not on file.
--
--   A client bills through their counselor's office; with no counselor, their
--   referring office; with neither, nothing - never a guess. Where the two
--   disagree, the counselor wins.
--
--   A reconciliation for an office lists that office's Sent, unpaid invoices
--   with how long each has waited, and its open authorizations ending soon
--   with value not yet invoiced - and nothing paid, drafted, fully invoiced,
--   ending later, or belonging to another office.
--
--   Every member of staff can read the billing offices; only Admin changes
--   them. Nobody signed out reads or runs anything.
--
-- Runs inside a transaction that is rolled back. Nothing here is left behind.

begin;

do $$
declare
  v_admin     uuid;
  v_adm_uid   uuid;
  v_billing   uuid;
  v_bil_uid   uuid;
  v_vw        uuid;
  v_dt        uuid;
  v_davis     uuid;
  v_k_tooele  uuid;
  v_k_slc     uuid;
  v_a         uuid;
  v_b         uuid;
  v_c         uuid;
  v_d         uuid;
  v_auth_soon uuid;
  v_auth_late uuid;
  v_auth_done uuid;
  v_auth_c    uuid;
  v_n         bigint;
  v_text      text;
  r           record;
  failures    text[] := '{}';
begin
  select id, user_id into v_admin, v_adm_uid from public.staff
   where role = 'Admin' and active and user_id is not null order by created_at, id limit 1;
  select id, user_id into v_billing, v_bil_uid from public.staff
   where role <> 'Admin' and active and user_id is not null order by created_at, id limit 1;

  select id into v_vw from public.billing_offices where name = 'Valley West CRP';
  select id into v_dt from public.billing_offices where name = 'Downtown CRP';
  select id into v_davis from public.billing_offices where name = 'Davis CRP';

  -- ── the owner's mapping ────────────────────────────────────
  select string_agg(format('%s -> %s', o.name, coalesce(b.name, 'nothing')), '; ' order by o.name) into v_text
    from public.offices o left join public.billing_offices b on b.id = o.billing_office_id
   where (o.name, coalesce(b.name, '')) not in (
     ('Salt Lake City', 'Downtown CRP'), ('Taylorsville', 'Valley West CRP'), ('Tooele', 'Valley West CRP'),
     ('South Jordan', 'South Valley CRP'), ('Centerville', 'Davis CRP'), ('Spanish Fork', 'Spanish Fork'));
  if v_text is not null then
    failures := failures || format('FAILED: offices not mapped as the owner confirmed: %s', v_text)::text;
  elsif (select count(*) from public.offices) < 6 then
    failures := failures || 'FAILED: fewer than the six counselor offices are on file'::text;
  else
    raise notice 'ok  the six counselor offices bill through the five billing offices the owner confirmed';
  end if;

  begin
    insert into public.offices (name) values ('ZZ Nowhere Office');
    failures := failures || 'FAILED: an office was added without a billing office'::text;
  exception when not_null_violation then
    raise notice 'ok  an office cannot be added without saying where it bills';
  end;

  begin
    insert into public.counselors (name, office) values ('ZZ Counselor Nowhere', 'ZZ Nowhere Office');
    failures := failures || 'FAILED: a counselor was given an office that is not on file'::text;
  exception when foreign_key_violation then
    raise notice 'ok  a counselor''s office has to be one on file';
  end;

  if exists (select 1 from public.counselors k
              where k.office is not null and not exists (select 1 from public.offices o where o.name = k.office)) then
    failures := failures || 'FAILED: a counselor on file has an office that is not on file'::text;
  end if;

  -- ── what each client inherits ──────────────────────────────
  insert into public.counselors (name, office, email) values ('ZZ Counselor Tooele', 'Tooele', 'zz-tooele@example.test')
  returning id into v_k_tooele;
  insert into public.counselors (name, office) values ('ZZ Counselor SLC', 'Salt Lake City')
  returning id into v_k_slc;

  insert into public.clients (name, stage, status, assigned_staff_id, counselor_id)
  values ('ZZ Billing A', 'Job Coaching', 'Active', v_admin, v_k_tooele) returning id into v_a;
  insert into public.clients (name, stage, status, assigned_staff_id, referring_office)
  values ('ZZ Billing B', 'Job Coaching', 'Active', v_admin, 'Centerville') returning id into v_b;
  insert into public.clients (name, stage, status, assigned_staff_id, counselor_id, referring_office)
  values ('ZZ Billing C', 'Job Coaching', 'Active', v_admin, v_k_slc, 'Tooele') returning id into v_c;
  insert into public.clients (name, stage, status, assigned_staff_id)
  values ('ZZ Billing D', 'Job Coaching', 'Active', v_admin) returning id into v_d;

  if (select billing_office_id from public.client_billing_office where client_id = v_a) is distinct from v_vw
     or (select basis from public.client_billing_office where client_id = v_a) <> 'Counselor''s office' then
    failures := failures || 'FAILED: a Tooele counselor''s client does not bill through Valley West'::text;
  end if;
  if (select billing_office_id from public.client_billing_office where client_id = v_b) is distinct from v_davis
     or (select basis from public.client_billing_office where client_id = v_b) <> 'Referring office' then
    failures := failures || 'FAILED: a client with no counselor did not fall back to their referring office'::text;
  end if;
  if (select billing_office_id from public.client_billing_office where client_id = v_c) is distinct from v_dt then
    failures := failures || 'FAILED: where counselor and referring office disagree, the counselor did not win'::text;
  end if;
  if (select billing_office_id from public.client_billing_office where client_id = v_d) is not null then
    failures := failures || 'FAILED: a client with neither a counselor nor an office was guessed into a billing office'::text;
  end if;
  if not exists (select 1 from unnest(failures) f where f like '%inherit%' or f like '%fall back%' or f like '%did not win%' or f like '%guessed%' or f like '%Valley West%') then
    raise notice 'ok  a client bills through their counselor''s office, else their referring office, else nothing';
  end if;

  -- ── the reconciliation ─────────────────────────────────────
  -- A service no USOR form is required for, so the invoices can be Sent
  -- through the ordinary gate rather than around it.
  insert into public.authorizations (client_id, number, service_type, total_hours, rate, rate_type, status, start_date, end_date)
  values (v_a, 'ZQ-REC-SOON', 'ZZ Reconciliation Service', 20, 50, 'Hourly', 'Open',
          public.practice_today() - 60, public.practice_today() + 10)
  returning id into v_auth_soon;
  insert into public.authorizations (client_id, number, service_type, total_hours, rate, rate_type, status, start_date, end_date)
  values (v_a, 'ZQ-REC-LATE', 'ZZ Reconciliation Service', 20, 50, 'Hourly', 'Open',
          public.practice_today() - 60, public.practice_today() + 60)
  returning id into v_auth_late;
  insert into public.authorizations (client_id, number, service_type, rate, rate_type, status, start_date, end_date)
  values (v_a, 'ZQ-REC-DONE', 'ZZ Reconciliation Service', 300, 'Flat Fee', 'Open',
          public.practice_today() - 60, public.practice_today() + 5)
  returning id into v_auth_done;
  insert into public.authorizations (client_id, number, service_type, total_hours, rate, rate_type, status, start_date, end_date)
  values (v_c, 'ZQ-REC-OTHER', 'ZZ Reconciliation Service', 10, 50, 'Hourly', 'Open',
          public.practice_today() - 60, public.practice_today() + 10)
  returning id into v_auth_c;

  insert into public.invoices (auth_id, number, date, amount, status, sent_date, service_type)
  values (v_auth_soon, 'ZQ-INV-SENT', public.practice_today() - 40, 200, 'Sent', public.practice_today() - 40, 'ZZ Reconciliation Service');
  insert into public.invoices (auth_id, number, date, amount, status, sent_date, paid_date, service_type)
  values (v_auth_soon, 'ZQ-INV-PAID', public.practice_today() - 70, 100, 'Paid', public.practice_today() - 70, public.practice_today() - 20, 'ZZ Reconciliation Service');
  insert into public.invoices (auth_id, number, date, amount, status, service_type)
  values (v_auth_soon, 'ZQ-INV-DRAFT', public.practice_today() - 1, 50, 'Draft', 'ZZ Reconciliation Service');
  insert into public.invoices (auth_id, number, date, amount, status, sent_date, paid_date, service_type)
  values (v_auth_done, 'ZQ-INV-DONE', public.practice_today() - 30, 300, 'Paid', public.practice_today() - 30, public.practice_today() - 10, 'ZZ Reconciliation Service');
  insert into public.invoices (auth_id, number, date, amount, status, sent_date, service_type)
  values (v_auth_c, 'ZQ-INV-OTHER', public.practice_today() - 15, 100, 'Sent', public.practice_today() - 15, 'ZZ Reconciliation Service');

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);

  select count(*) into v_n from public.billing_office_reconciliation(v_vw, 30) x
   where x.kind = 'Unpaid invoice' and x.auth_number like 'ZQ-%';
  if v_n <> 1 then
    failures := failures || format('FAILED: Valley West''s reconciliation lists %s fixture unpaid invoices, not 1', v_n)::text;
  end if;
  select * into r from public.billing_office_reconciliation(v_vw, 30) x where x.invoice_number = 'ZQ-INV-SENT';
  if r.invoice_number is null or r.days_outstanding <> 40 or r.amount <> 200
     or r.counselor_email is distinct from 'zz-tooele@example.test' then
    failures := failures || 'FAILED: the Sent invoice is not listed with its amount, 40 days outstanding and the counselor to copy'::text;
  else
    raise notice 'ok  a Sent, unpaid invoice is listed with its amount, days outstanding and the counselor to copy';
  end if;
  if exists (select 1 from public.billing_office_reconciliation(v_vw, 30) x
              where x.invoice_number in ('ZQ-INV-PAID', 'ZQ-INV-DRAFT', 'ZQ-INV-DONE', 'ZQ-INV-OTHER')) then
    failures := failures || 'FAILED: a paid or draft invoice, or another office''s, is in the reconciliation'::text;
  else
    raise notice 'ok  nothing paid, nothing drafted and nothing of another office''s is listed';
  end if;

  select string_agg(x.auth_number, ', ' order by x.auth_number) into v_text
    from public.billing_office_reconciliation(v_vw, 30) x
   where x.kind <> 'Unpaid invoice' and x.auth_number like 'ZQ-%';
  if v_text is distinct from 'ZQ-REC-SOON' then
    failures := failures || format('FAILED: authorizations ending soon with value to invoice were %s, not ZQ-REC-SOON', coalesce(v_text, 'none'))::text;
  elsif (select x.unbilled from public.billing_office_reconciliation(v_vw, 30) x where x.auth_number = 'ZQ-REC-SOON' and x.kind <> 'Unpaid invoice')
        is distinct from (select not_yet_invoiced from public.billing_position where auth_id = v_auth_soon) then
    failures := failures || 'FAILED: the unbilled value in the reconciliation disagrees with Paid & outstanding'::text;
  else
    raise notice 'ok  an authorization ending within 30 days with value not invoiced is listed; one ending later, or fully invoiced, is not';
  end if;

  if not exists (select 1 from public.billing_office_reconciliation(v_dt, 30) x where x.invoice_number = 'ZQ-INV-OTHER') then
    failures := failures || 'FAILED: Downtown''s reconciliation misses its own Sent invoice'::text;
  end if;

  -- ── the contact log can name the office ────────────────────
  insert into public.contact_log (counselor_id, client_id, date, method, topic, outcome, staff_id, billing_office_id)
  values (v_k_tooele, v_a, public.practice_today(), 'Email', 'Billing reconciliation', 'ZZ', v_admin, v_vw);
  raise notice 'ok  a reconciliation can be logged against the client, the counselor and the billing office';

  -- ── who may change a billing office ────────────────────────
  if v_billing is not null then
    perform set_config('request.jwt.claims', json_build_object('sub', v_bil_uid, 'role', 'authenticated')::text, true);
    select count(*) into v_n from public.billing_offices;
    if v_n < 5 then
      failures := failures || 'FAILED: a member of staff who is not Admin cannot read the billing offices'::text;
    end if;
    update public.billing_offices set contact_name = 'ZZ changed' where id = v_vw;
    perform set_config('role', 'postgres', true);
    if (select contact_name from public.billing_offices where id = v_vw) = 'ZZ changed' then
      failures := failures || 'FAILED: a member of staff who is not Admin changed a billing office'::text;
    else
      raise notice 'ok  every member of staff reads the billing offices; only Admin changes them';
    end if;
    perform set_config('role', 'authenticated', true);
    begin
      insert into public.billing_offices (name, billing_email) values ('ZZ Office', 'zz@example.test');
      failures := failures || 'FAILED: a member of staff who is not Admin added a billing office'::text;
    exception when insufficient_privilege then null;
    end;
  end if;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('role', 'postgres', true);

  if has_table_privilege('anon', 'public.billing_offices', 'select')
     or has_table_privilege('anon', 'public.client_billing_office', 'select')
     or has_function_privilege('anon', 'public.billing_office_reconciliation(uuid, integer)', 'execute') then
    failures := failures || 'FAILED: somebody not signed in can read billing offices or run a reconciliation'::text;
  else
    raise notice 'ok  nobody signed out reads a billing office or runs a reconciliation';
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- BILLING OFFICES VERIFIED ---';
end $$;

rollback;
