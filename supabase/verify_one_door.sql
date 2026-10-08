-- Zion Vocational Rehab CRM — one door to a bill (0168)
--
-- §10: "a verify script asserts there is exactly one write path that creates a
-- billable record (add_authorization)".
--
-- What has to hold, each tried from the direction that would break it:
--
--   There is one table a bill can live in. The invoice and the billing item are
--   gone - table, views, events and all - and nothing can recreate them by
--   accident because nothing refers to them.
--
--   add_authorization() is the only way a row gets into it. A signed-in person
--   has no insert on authorizations, so a screen that tried to go round the
--   door would be refused by the database rather than by a code review.
--
--   The door still enforces who. Billing and Admin go through it; nobody else.
--
--   The functions that also create an authorization row are only the ones that
--   enter an authorization, or open a month of one already entered: the
--   calendar, a confirmed PDF, a packet sent for a month not opened yet, and
--   hours logged in one. Anything else appearing in that list is a second door.
--
--   A payment is still written only by reconciliation, and nothing is Paid
--   without one behind it.
--
--   Service hours create nothing. The log records time; it does not bill.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_client  uuid;
  v_auth    uuid;
  v_doors   text;
  v_n       int;
  failures  text[] := '{}';
begin
  -- ── one table, and the old ones gone ──────────────────────
  foreach v_doors in array array['invoices', 'billing_items', 'billing_item_events',
                                 'billing_item_rows', 'billing_items_undated'] loop
    if exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
                where n.nspname = 'public' and c.relname = v_doors) then
      failures := failures || format('FAILED: %s still exists', v_doors);
    end if;
  end loop;
  if failures = '{}' then
    raise notice 'ok  the invoice and the billing item are gone, with their views and their events';
  end if;

  -- ── nothing names them any more ───────────────────────────
  -- A function still naming a removed table is a path that fails the first time
  -- somebody walks it, which is how warrant reconciliation was found broken.
  select string_agg(p.proname, ', ' order by p.proname) into v_doors
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and pg_get_functiondef(p.oid) ~ '\mpublic\.(invoices|billing_items|billing_item_events|billing_item_rows|billing_item_gate|billing_gate_met|invoice_date_for)\M';
  if v_doors is not null then
    failures := failures || format('FAILED: these still read a record that no longer exists: %s', v_doors);
  else
    raise notice 'ok  no function still reads the invoice or the billing item';
  end if;

  -- ── the door is the only way in ───────────────────────────
  if has_table_privilege('authenticated', 'public.authorizations', 'insert') then
    failures := failures || 'FAILED: a signed-in person can insert an authorization without going through add_authorization'::text;
  else
    raise notice 'ok  a bill cannot be created except through add_authorization';
  end if;
  if not has_function_privilege('authenticated',
      'public.add_authorization(uuid, text, text, text, numeric, numeric, date, date, text, text, text)', 'execute') then
    failures := failures || 'FAILED: staff cannot reach the one door'::text;
  end if;
  if has_function_privilege('anon',
      'public.add_authorization(uuid, text, text, text, numeric, numeric, date, date, text, text, text)', 'execute') then
    failures := failures || 'FAILED: somebody not signed in can create a bill'::text;
  end if;

  -- ── and nothing else creates one ──────────────────────────
  --
  -- Every function that inserts into authorizations, named. Each one on this
  -- list is entering an authorization: the door itself, a coaching month
  -- opening on the calendar or on a send, a PDF confirmed from the documents
  -- folder, and a placeholder replaced in place by its real USOR number.
  select string_agg(p.proname, ', ' order by p.proname) into v_doors
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and pg_get_functiondef(p.oid) ~ 'insert\s+into\s+public\.authorizations'
     and p.proname <> 'add_authorization';
  -- replace_placeholder_authorization is not on this list: it replaces the
  -- number on an authorization that is already there, in place, rather than
  -- creating a second one. That is the point of it.
  if v_doors is distinct from
     'confirm_authorization_document, open_coaching_months_for, route_entry_to_month, submit_authorization_on_send' then
    failures := failures || format('FAILED: the write paths into authorizations are now %s', coalesce(v_doors, 'none'));
  else
    raise notice 'ok  the only other writers are a coaching month, a confirmed PDF and a packet sent early';
  end if;

  -- ── the door works, and enforces who ──────────────────────
  insert into public.clients (name, stage, status) values ('ZZ One Door', 'Placement', 'Active')
  returning id into v_client;

  perform set_config('role', 'postgres', true);
  v_auth := public.add_authorization(
    v_client, 'V0000970', 'Job Development', 'Flat Fee', 560, null,
    public.practice_today() - 10, public.practice_today() + 50);
  if v_auth is null then
    failures := failures || 'FAILED: the door did not create an authorization'::text;
  elsif (select status from public.authorizations where id = v_auth) <> 'Authorized' then
    failures := failures || 'FAILED: a new authorization did not start as Authorized'::text;
  elsif (select bill_by from public.authorizations where id = v_auth) is null then
    failures := failures || 'FAILED: the insert trigger did not fill in the bill-by date'::text;
  else
    raise notice 'ok  the door creates one authorization, Authorized, with its own dates filled in';
  end if;

  -- ── service hours open a month, and nothing else ──────────
  --
  -- Logging hours in a coaching month opens that month if it is not there
  -- (§§5, 12.5), which is a month of an authorization somebody already
  -- entered - not a new bill. What must not happen is a second
  -- authorization: the test is that nothing new appears at the top level.
  select count(*) into v_n from public.authorizations
   where client_id = v_client and parent_id is null;
  insert into public.authorizations
    (client_id, number, service_type, rate_type, rate, total_hours, start_date, end_date)
  values (v_client, 'V0000971', 'Job Coaching', 'Hourly', 45, 20,
          public.practice_today() - 10, public.practice_today() + 50);
  insert into public.service_entries (auth_id, date, hours)
  select id, public.practice_today() - 1, 3 from public.authorizations
   where client_id = v_client and number = 'V0000971';
  if (select count(*) from public.authorizations
       where client_id = v_client and parent_id is null) <> v_n + 1 then
    failures := failures || 'FAILED: logging hours created an authorization of its own'::text;
  elsif not exists (
    select 1 from public.authorizations ch
      join public.authorizations p on p.id = ch.parent_id
     where p.number = 'V0000971' and ch.period = date_trunc('month', public.practice_today() - 1)::date) then
    failures := failures || 'FAILED: the hours did not open the month they were worked in'::text;
  else
    raise notice 'ok  logging hours opens the month it was worked in, and bills nothing new';
  end if;

  -- ── a payment comes only from a warrant ───────────────────
  if has_table_privilege('authenticated', 'public.payments', 'insert') then
    failures := failures || 'FAILED: a signed-in person can write a payment directly'::text;
  end if;
  if exists (select 1 from public.authorizations a
              where a.status = 'Paid'
                and not exists (select 1 from public.payments p where p.auth_id = a.id)) then
    failures := failures || 'FAILED: something is marked Paid with no payment behind it'::text;
  else
    raise notice 'ok  a payment comes only from a warrant, and nothing is Paid without one';
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
