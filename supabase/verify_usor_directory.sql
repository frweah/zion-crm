-- Zion Vocational Rehab CRM — the directory after the USOR roster (0195–0196)
--
-- What has to hold, each tried from the direction that would break it:
--
--   No counselor is in the directory twice under two spellings of the same
--   name. This is the thing the import existed to avoid and the thing most
--   likely to come undone later: the next roster, or somebody typing "Josh
--   Madsen" into the quick-add, and now there are two people with one
--   caseload between them.
--
--   directory_name_key() collapses what it was taught and nothing else. The
--   pairs it knows are checked, and so is the fact that it leaves alone the
--   short forms an earlier draft guessed at - because a wrong match merges two
--   counselors and there is no undoing that.
--
--   An office may have no billing office, and an authorization for a client at
--   one refuses to submit rather than mailing a packet nowhere. That is the
--   whole reason the column was allowed to be null instead of guessed at.
--
--   A billing office's address may be blank, but not malformed.
--
--   A billing office's contacts are readable by staff, writable by Billing,
--   invisible to anyone not signed in, logged when they change, and go with
--   the billing office if it is ever deleted.
--
--   Every office carries an address and a main line, which is what the roster
--   was imported for.
--
-- Uses made-up people (ZZ/ZQ). Everything is rolled back.

begin;

do $$
declare
  v_admin    uuid;
  v_adm_uid  uuid;
  v_bil      uuid;
  v_bil_uid  uuid := gen_random_uuid();
  v_rep      uuid;
  v_rep_uid  uuid := gen_random_uuid();
  v_bo       uuid;
  v_contact  uuid;
  v_office   text;
  v_client   uuid;
  v_auth     uuid;
  v_n        integer;
  v_text     text;
  r          record;
  failures   text[] := '{}';
begin
  select id, user_id into v_admin, v_adm_uid from public.staff
   where role = 'Admin' and active and user_id is not null order by created_at, id limit 1;

  insert into public.staff (name, email, role, active)
  values ('ZZ Dir Billing', 'zz-usor-billing@example.test', 'Billing', true) returning id into v_bil;
  insert into public.staff (name, email, role, active)
  values ('ZZ Dir Reports', 'zz-usor-reports@example.test', 'Reports', true) returning id into v_rep;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_bil_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'zz-usor-billing@example.test', '{}', '{}', now(), now()),
         (v_rep_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'zz-usor-reports@example.test', '{}', '{}', now(), now());
  update public.staff set user_id = v_bil_uid where id = v_bil;
  update public.staff set user_id = v_rep_uid where id = v_rep;

  -- ── nobody is in here twice ────────────────────────────────
  v_text := null;
  select string_agg(format('%s (%s)', key, names), '; ') into v_text
    from (select public.directory_name_key(name) as key,
                 string_agg(name, ' / ' order by name) as names
            from public.counselors
           group by public.directory_name_key(name)
          having count(*) > 1) d;
  if v_text is not null then
    failures := failures || format('FAILED: the same counselor is on file twice: %s', v_text)::text;
  else
    raise notice 'ok  no counselor is in the directory twice under two spellings';
  end if;

  -- ── and the key collapses what it was taught ───────────────
  if public.directory_name_key('Josh Madsen') <> public.directory_name_key('Joshua Madsen')
     or public.directory_name_key('Jenny Shurtleff') <> public.directory_name_key('Jennifer Shurtleff')
     or public.directory_name_key('Matt Christensen') <> public.directory_name_key('Matthew Christensen') then
    failures := failures || 'FAILED: a short form the roster evidences no longer matches its long one'::text;
  else
    raise notice 'ok  Josh matches Joshua, Jenny matches Jennifer, Matt matches Matthew';
  end if;

  if public.directory_name_key('Denise Francis-Montaño') <> 'denise francis montano' then
    failures := failures || format('FAILED: accents and hyphens are not stripped (%s)',
      public.directory_name_key('Denise Francis-Montaño'))::text;
  else
    raise notice 'ok  accents and hyphens come out, so one spelling of a name is enough';
  end if;

  if public.directory_name_key('Ben (William) Powers') <> 'ben powers' then
    failures := failures || format('FAILED: a bracketed formal name is not dropped (%s)',
      public.directory_name_key('Ben (William) Powers'))::text;
  else
    raise notice 'ok  and a bracketed formal name is dropped without leaving a gap';
  end if;

  /**
   * The guesses that were taken back out.
   *
   * An earlier draft mapped ben to benjamin, kami to kamille and debi to
   * deborah on no evidence at all - and the roster's only Ben is "Ben
   * (William) Powers" at wpowers@utah.gov, so that one was confidently wrong
   * about a real person. If somebody adds them back, this says so.
   */
  if public.directory_name_key('Ben Powers') = public.directory_name_key('Benjamin Powers')
     or public.directory_name_key('Kami McNeil') = public.directory_name_key('Kamille McNeil')
     or public.directory_name_key('Debi Giles') = public.directory_name_key('Deborah Giles') then
    failures := failures || 'FAILED: the name key is guessing at short forms again'::text;
  else
    raise notice 'ok  and it still guesses at nothing it was not taught';
  end if;

  -- ── every office says where it is and what to ring ─────────
  select count(*) into v_n from public.offices where btrim(address) = '' or btrim(phone) = '';
  if v_n > 0 then
    select string_agg(name, ', ') into v_text from public.offices
     where btrim(address) = '' or btrim(phone) = '';
    failures := failures || format('FAILED: %s office(s) with no address or no main line: %s', v_n, v_text)::text;
  else
    raise notice 'ok  every office carries an address and a main line';
  end if;

  select count(*) into v_n from public.offices where btrim(usor_district) = '';
  if v_n > 0 then
    failures := failures || format('FAILED: %s office(s) with no USOR district', v_n)::text;
  else
    raise notice 'ok  and the district USOR calls it, which is not the same as its city';
  end if;

  -- ── an office with no billing office is allowed ────────────
  perform set_config('role', 'postgres', true);
  insert into public.offices (name, address, phone, usor_district, note, billing_office_id)
  values ('ZZ Nowhere', '1 ZZ Street, Nowhere, UT 80000', '(435) 000-0000', 'ZZ District (99)', '', null)
  returning name into v_office;
  if v_office is null then
    failures := failures || 'FAILED: an office could not be added without a billing office'::text;
  else
    raise notice 'ok  an office can be on file before anybody knows how it bills';
  end if;

  /**
   * And a packet for a client at one is refused rather than sent nowhere.
   *
   * This is the assertion that makes leaving the column null safe. If
   * submission ever starts falling back to some other office, a district's
   * paperwork goes to the wrong CRP and the refusal that used to stop it is
   * gone.
   */
  insert into public.clients (name, stage, status, referring_office)
  values ('ZZ Nowhere Client', 'Placement', 'Active', 'ZZ Nowhere') returning id into v_client;
  insert into public.authorizations
    (client_id, number, service_type, rate_type, rate, start_date, end_date, received_on, status)
  values (v_client, 'ZQ-NW-1', 'Job Coaching', 'Flat Fee', 100,
          date '2026-01-01', date '2026-12-31', date '2026-02-01', 'Due') returning id into v_auth;

  select billing_office_email into v_text from public.authorization_record where id = v_auth;
  if coalesce(v_text, '') <> '' then
    failures := failures || format('FAILED: a client at an office with no billing office was given the address %s', v_text)::text;
  else
    raise notice 'ok  and a client there has no billing address, so nothing is sent to the wrong one';
  end if;

  /**
   * And the same when the billing office exists but has no address.
   *
   * This is the live state as of 0197: every office bills through a district
   * CRP, and seventeen of those CRPs have no published address yet. So the
   * refusal has to come from the blank address rather than from the missing
   * billing office - a different path to the same place, and the one the
   * practice is actually in.
   */
  perform set_config('role', 'postgres', true);
  insert into public.billing_offices (name, billing_email, has_group_address, notes)
  values ('ZZ Addressless CRP', '', false, 'ZZ no address published') returning id into v_bo;
  update public.offices set billing_office_id = v_bo where name = 'ZZ Nowhere';

  select billing_office_email into v_text from public.authorization_record where id = v_auth;
  if coalesce(v_text, '') <> '' then
    failures := failures || format('FAILED: a client at a CRP with no address was given %s', v_text)::text;
  else
    raise notice 'ok  and one whose CRP has no address published is refused the same way';
  end if;

  -- ── a billing address may be blank, but not wrong ──────────
  insert into public.billing_offices (name, billing_email, has_group_address, notes)
  values ('ZZ Central', '', false, 'ZZ no group address published') returning id into v_bo;
  if v_bo is null then
    failures := failures || 'FAILED: a billing office with no published address was refused'::text;
  else
    raise notice 'ok  a billing office can exist with no group address published';
  end if;

  begin
    update public.billing_offices set billing_email = 'not-an-address' where id = v_bo;
    failures := failures || 'FAILED: a malformed billing address was accepted'::text;
  exception when check_violation then
    raise notice 'ok  but a malformed one is still refused, which is the half that matters';
  end;

  -- ── its contacts ───────────────────────────────────────────
  /**
   * Deliberately not a ZZ name.
   *
   * The log ignores anybody following the fixture convention (0179), so a
   * contact called "ZZ Pay Person" is correctly not recorded - and an earlier
   * draft of this script asserted it would be, which is how it found out that
   * the first half of this file was not checking its own failures. Both halves
   * are tried, because a guard that quietly stopped logging everything would
   * pass a test that only looked at one.
   */
  insert into public.billing_office_contacts (billing_office_id, name, title, email, phone)
  values (v_bo, 'Marlow Pay Testperson', 'Accounts Payable', 'zz-pay@example.test', '555-0000')
  returning id into v_contact;

  if not exists (select 1 from public.directory_changes
                  where entity = 'Billing contact' and entity_key = v_contact::text and action = 'Added') then
    failures := failures || 'FAILED: adding a billing contact was not written to the directory log'::text;
  else
    raise notice 'ok  adding a billing contact is written to the directory log';
  end if;

  insert into public.billing_office_contacts (billing_office_id, name, title)
  values (v_bo, 'ZQ Invented Contact', 'Accounts Payable') returning id into v_contact;
  if exists (select 1 from public.directory_changes where entity_key = v_contact::text) then
    failures := failures || 'FAILED: a billing contact invented for a test was written into the log'::text;
  else
    raise notice 'ok  and one invented for a test is not';
  end if;

  -- Several contacts on one billing office is the whole point of the table.
  insert into public.billing_office_contacts (billing_office_id, name, title)
  values (v_bo, 'ZZ Purchasing Person', 'Case Service Purchasing Agent');
  select count(*) into v_n from public.billing_office_contacts where billing_office_id = v_bo;
  if v_n <> 3 then
    failures := failures || format('FAILED: one billing office holds %s contacts, not 3', v_n)::text;
  else
    raise notice 'ok  and one billing office holds as many of them as it has';
  end if;

  -- They go with it, rather than being left pointing at nothing.
  delete from public.billing_offices where id = v_bo;
  select count(*) into v_n from public.billing_office_contacts where billing_office_id = v_bo;
  if v_n <> 0 then
    failures := failures || format('FAILED: %s contact(s) outlived their billing office', v_n)::text;
  else
    raise notice 'ok  and they go with it when it goes';
  end if;

  -- ── who may read and write them ────────────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_rep_uid, 'role', 'authenticated')::text, true);

  select count(*) into v_n from public.billing_office_contacts;
  if v_n = 0 then
    failures := failures || 'FAILED: a member of staff cannot read the billing contacts at all'::text;
  else
    raise notice 'ok  any member of staff can look up who to ring about a warrant';
  end if;

  /**
   * Somebody on Reports may not add one.
   *
   * In its own block with its own handler, so the refusal does not abandon
   * the rest of this one. An earlier draft put the handler on the whole block
   * and the failures collected above were never raised at all - every check
   * in here printed "ok" and a real failure went to the floor. That is the
   * same fault this project keeps finding: a check sitting near the rule
   * rather than on it.
   */
  select id into v_bo from public.billing_offices
   where name = 'USOR Administration (central billing)';
  begin
    insert into public.billing_office_contacts (billing_office_id, name)
    values (v_bo, 'Rowan Reports Testperson');
    failures := failures || 'FAILED: somebody on Reports added a billing contact'::text;
  exception when insufficient_privilege then
    raise notice 'ok  and somebody who does not own billing cannot add one';
  end;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('role', 'postgres', true);

  if has_table_privilege('anon', 'public.billing_office_contacts', 'select')
     or has_function_privilege('anon', 'public.directory_name_key(text)', 'execute') then
    failures := failures || 'FAILED: somebody not signed in can read the billing contacts'::text;
  else
    raise notice 'ok  and somebody not signed in can read none of it';
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'
');
  end if;
  raise notice '--- THE USOR DIRECTORY VERIFIED ---';
end $$;

rollback;
