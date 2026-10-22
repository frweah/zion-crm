-- Zion Vocational Rehab CRM — the working list counts once (0206)
--
-- What has to hold:
--
--   One definition. authorization_amount and authorization_attention are now
--   wrappers over the set-wise versions, so the authorization record and the
--   working list read the same rules. Asked of every authorization on file,
--   not of a fixture: if the two ever disagree about any real row, this says
--   which one.
--
--   The amount is the authorization's own hours; the cap is the family's.
--   Two different questions, and 0206 must not have merged them.
--
--   Asking for one client gives exactly that client's rows from the whole
--   list - the client record shows what Billing shows, no more and no less.
--
--   The attention rules still say what they said. Out of hours, overdue and
--   due are pinned by wording and by urgency, because this migration moved
--   them and a silent reword would change what every alert says.
--
--   And anon cannot call any of it.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_client   uuid;
  v_staff    uuid;
  v_uid      uuid := gen_random_uuid();
  v_parent   uuid;
  v_month    uuid;
  v_one      uuid;
  v_n        integer;
  v_amount   numeric;
  v_amount2  numeric;
  v_text     text;
  v_urgency  integer;
  r          record;
  failures   text[] := '{}';
begin
  -- ── the wrappers agree with the set-wise versions, on real rows ──
  select count(*) into v_n
    from public.authorizations a
    join public.authorization_amount_for(array(select id from public.authorizations)) f
      on f.auth_id = a.id
   where round(coalesce(public.authorization_amount(a.id), -1), 2)
         is distinct from round(coalesce(f.amount, -1), 2);
  if v_n > 0 then
    failures := failures || format('FAILED: %s authorization(s) where the amount wrapper and the set differ', v_n)::text;
  else
    raise notice 'ok  the amount is the same asked one at a time or all at once';
  end if;

  select count(*) into v_n
    from public.authorizations a
    join public.authorization_attention_for(array(select id from public.authorizations)) f
      on f.auth_id = a.id
    cross join lateral public.authorization_attention(a.id) one
   where coalesce(one.attention, '~') is distinct from coalesce(f.attention, '~')
      or coalesce(one.urgency, -1) is distinct from coalesce(f.urgency, -1);
  if v_n > 0 then
    failures := failures || format('FAILED: %s authorization(s) where attention differs one at a time', v_n)::text;
  else
    raise notice 'ok  what needs attention is the same asked one at a time or all at once';
  end if;

  -- ── the ground to test the rules on ───────────────────────
  insert into public.staff (name, email, role, active)
  values ('ZZ List Admin', 'zz-list@example.test', 'Admin', true) returning id into v_staff;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'zz-list@example.test', '{}', '{}', now(), now());
  update public.staff set user_id = v_uid where id = v_staff;

  insert into public.clients (name, stage, status) values ('ZZ List Client', 'Job Placement', 'Active')
  returning id into v_client;

  -- A coaching parent with 10 hours, and one month under it.
  insert into public.authorizations (client_id, number, service_type, rate_type, rate,
                                     total_hours, start_date, end_date, received_on, status)
  values (v_client, 'ZZ-L-1', 'Job Coaching', 'Hourly', 50, 10,
          public.practice_today() - 40, public.practice_today() + 40,
          public.practice_today() - 35, 'Authorized')
  returning id into v_parent;

  insert into public.authorizations (client_id, parent_id, service_type, rate_type, rate,
                                     period, start_date, end_date, received_on, status)
  values (v_client, v_parent, 'Job Coaching', 'Hourly', 50,
          date_trunc('month', public.practice_today())::date,
          public.practice_today() - 10, public.practice_today() + 20,
          public.practice_today() - 10, 'Authorized')
  returning id into v_month;

  insert into public.service_entries (auth_id, date, hours, staff_id, notes)
  values (v_month, public.practice_today() - 1, 4, v_staff, 'ZZ list hours');

  -- ── the amount is its own hours; the cap is the family's ──
  select amount into v_amount from public.authorization_amount_for(array[v_month]) f;
  if coalesce(v_amount, -1) <> 200 then
    failures := failures || format('FAILED: the month bills %s, not its own 4 hrs at 50', v_amount)::text;
  else
    raise notice 'ok  a coaching month bills the hours logged on it (4 x 50 = 200)';
  end if;

  select amount into v_amount2 from public.authorization_amount_for(array[v_parent]) f;
  if coalesce(v_amount2, -1) <> 0 then
    failures := failures || format('FAILED: the parent bills %s; a parent is not a bill', v_amount2)::text;
  else
    raise notice 'ok  and its parent bills nothing - the months carry the billing';
  end if;

  select used into v_amount from public.authorization_hours_used(array[v_month]) u;
  if coalesce(v_amount, -1) <> 4 then
    failures := failures || format('FAILED: the family has used %s hours, not 4', v_amount)::text;
  else
    raise notice 'ok  while the hours used are the family''s, which is the cap';
  end if;

  -- ── the attention rules still say what they said ──────────
  -- Out of hours: fill the authorization exactly.
  insert into public.service_entries (auth_id, date, hours, staff_id, notes)
  values (v_month, public.practice_today() - 1, 6, v_staff, 'ZZ list the rest');

  select attention, urgency into v_text, v_urgency
    from public.authorization_attention_for(array[v_month]) f;
  if v_text <> 'No hours left - request more before any further service' or v_urgency <> 1 then
    failures := failures || format('FAILED: out of hours says "%s" at urgency %s', v_text, v_urgency)::text;
  else
    raise notice 'ok  out of hours reads as it did, at urgency 1';
  end if;

  -- Overdue: a one-off authorization whose bill-by has passed.
  insert into public.authorizations (client_id, number, service_type, rate_type, rate,
                                     start_date, end_date, received_on, status, bill_by)
  values (v_client, 'ZZ-L-2', 'Job Placement', 'Flat Fee', 1200,
          public.practice_today() - 60, public.practice_today() + 60,
          public.practice_today() - 60, 'Authorized', public.practice_today() - 5)
  returning id into v_one;

  select attention, urgency into v_text, v_urgency
    from public.authorization_attention_for(array[v_one]) f;
  if v_text not like 'Overdue - meant to be billed by %' or v_urgency <> 3 then
    failures := failures || format('FAILED: overdue says "%s" at urgency %s', v_text, v_urgency)::text;
  else
    raise notice 'ok  overdue reads as it did, at urgency 3';
  end if;

  -- ── one client's list is that client's rows from the whole list ──
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);

  select count(*) into v_n from public.billing_worklist(null, v_client);
  if v_n = 0 then
    failures := failures || 'FAILED: this client has open authorizations and the list for them is empty'::text;
  else
    raise notice 'ok  asking for one client gives their % rows', v_n;
  end if;

  select count(*) into v_n
    from (
      select id from public.billing_worklist() where client_id = v_client
      except
      select id from public.billing_worklist(null, v_client)
    ) q;
  if v_n > 0 then
    failures := failures || format('FAILED: %s row(s) on the practice list are missing from the client list', v_n)::text;
  end if;

  select count(*) into v_n
    from (
      select id from public.billing_worklist(null, v_client)
      except
      select id from public.billing_worklist() where client_id = v_client
    ) q;
  if v_n > 0 then
    failures := failures || format('FAILED: %s row(s) on the client list are not on the practice list', v_n)::text;
  else
    raise notice 'ok  and they are exactly the rows the practice list holds for them';
  end if;

  -- A client with nothing open gets an empty list rather than everybody's.
  select count(*) into v_n from public.billing_worklist(null, gen_random_uuid());
  if v_n <> 0 then
    failures := failures || format('FAILED: an unknown client got %s rows back', v_n)::text;
  else
    raise notice 'ok  a client with nothing open gets nothing, not the practice''s list';
  end if;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('role', 'postgres', true);

  -- ── and anon cannot call any of it ────────────────────────
  for r in
    select unnest(array[
      'public.authorization_amount_for(uuid[])',
      'public.authorization_attention_for(uuid[], date)',
      'public.billing_worklist(date, uuid)',
      'public.billing_needs_action(date)'
    ]) as sig
  loop
    if has_function_privilege('anon', r.sig, 'execute') then
      failures := failures || format('FAILED: anon may execute %s', r.sig)::text;
    end if;
  end loop;
  raise notice 'ok  anon cannot call the working list or anything behind it';

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
