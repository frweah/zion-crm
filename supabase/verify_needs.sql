-- Zion Vocational Rehab CRM — paperwork status and "needs attention"
--
-- A dashboard counter is believed until it is wrong once. The two ways this
-- one could be wrong are a definition of "quiet" that ignores half of what
-- people do, and a paperwork state that calls somebody late when they are not.
--
-- The first was real: client_last_activity read six tables and predated logged
-- mail, appointments, job applications and stage changes, so a client emailed
-- yesterday counted as untouched for a month.
--
-- Runs inside a transaction that is rolled back. Nothing here is left behind.

begin;

do $$
declare
  v_admin    uuid;
  v_client   uuid;
  v_auth     uuid;
  v_monthly  uuid;
  v_form     uuid;
  v_state    text;
  v_last     timestamptz;
  v_count    int;
  failures   text[] := '{}';
begin
  select id into v_admin from public.staff where role = 'Admin' and active order by created_at limit 1;
  select id into v_client from public.clients where status = 'Active' order by created_at limit 1;

  -- ── activity means everything that counts as activity ──────
  -- A client with nothing but a logged email should not read as untouched.
  insert into public.mail_log (staff_id, client_id, graph_message_id, conversation_id,
                               subject, sent_at, direction, counterpart_email)
  values (v_admin, v_client, 'ZZ-needs-1', 'ZZ-t', 'ZZ recent mail', now(), 'Incoming', 'x@example.com');

  select last_activity_at into v_last
    from public.client_last_activity where client_id = v_client;

  if v_last is null or v_last < now() - interval '1 hour' then
    failures := failures || 'FAILED: a logged email today did not count as activity'::text;
  else
    raise notice 'ok  a logged email counts as activity';
  end if;

  insert into public.calendar_events (client_id, staff_id, kind, title, starts_at, ends_at, origin)
  values (v_client, v_admin, 'Coaching visit', 'ZZ visit',
          now() + interval '1 day', now() + interval '1 day 1 hour', 'CRM');

  select last_activity_at into v_last
    from public.client_last_activity where client_id = v_client;
  if v_last is null or v_last < now() then
    failures := failures || 'FAILED: a scheduled appointment did not count as activity'::text;
  else
    raise notice 'ok  an appointment counts too — the old view knew about neither';
  end if;

  -- ── paperwork: "not started" is not the same as "missing" ──
  -- WSA Tier 1 maps to exactly one billing form (DWS-USOR 94), so the states
  -- below are about this one form and not an accident of overlapping services.
  insert into public.authorizations (client_id, number, service_type, total_hours, rate,
                                     rate_type, status, start_date)
  values (v_client, 'ZZ-AUTH', 'WSA Tier 1', 10, 50, 'Hourly', 'Open', public.practice_today())
  returning id into v_auth;

  select state into v_state from public.client_paperwork
   where auth_id = v_auth and template_id = 'wsa';
  if v_state is distinct from 'Not started' then
    failures := failures || format('FAILED: a form with no hours reads as "%s"', coalesce(v_state, 'nothing'));
  else
    raise notice 'ok  a required form with no hours yet is Not started, not Missing';
  end if;

  -- Hours logged and no form is the state that actually blocks an invoice.
  insert into public.service_entries (auth_id, date, hours, staff_id, primary_code)
  values (v_auth, public.practice_today(), 3, v_admin, 'JC');

  select state into v_state from public.client_paperwork
   where auth_id = v_auth and template_id = 'wsa';
  if v_state is distinct from 'Missing' then
    failures := failures || format('FAILED: hours logged with no form reads as "%s"', coalesce(v_state, 'nothing'));
  else
    raise notice 'ok  hours logged with no form is Missing — the one that means somebody is late';
  end if;

  -- ── a draft, then a finished form ──────────────────────────
  insert into public.forms (template_id, client_id, auth_id, status, created_by)
  values ('wsa', v_client, v_auth, 'Draft', v_admin)
  returning id into v_form;

  select state into v_state from public.client_paperwork
   where auth_id = v_auth and template_id = 'wsa';
  if v_state is distinct from 'In progress' then
    failures := failures || format('FAILED: a draft reads as "%s"', coalesce(v_state, 'nothing'));
  else
    raise notice 'ok  a draft is In progress';
  end if;

  update public.forms set status = 'Completed', completed_at = now() where id = v_form;

  select state into v_state from public.client_paperwork
   where auth_id = v_auth and template_id = 'wsa';
  if v_state is distinct from 'Complete' then
    failures := failures || format('FAILED: a completed form reads as "%s"', coalesce(v_state, 'nothing'));
  else
    raise notice 'ok  a completed form is Complete, and stops blocking';
  end if;

  -- ── a monthly form asks for the month in hand ──────────────
  -- Job Development is monthly. Before any hours exist it must still say the
  -- current month is outstanding, or an authorization nobody has touched this
  -- month shows no paperwork at all, which reads as "nothing needed".
  insert into public.authorizations (client_id, number, service_type, total_hours, rate,
                                     rate_type, status, start_date)
  values (v_client, 'ZZ-AUTH-M', 'Job Development', 10, 50, 'Hourly', 'Open', public.practice_today())
  returning id into v_monthly;

  select state into v_state from public.client_paperwork
   where auth_id = v_monthly
     and template_id = 'usor96'
     and month = to_char(public.practice_today(), 'YYYY-MM');
  if v_state is distinct from 'Not started' then
    failures := failures || format('FAILED: the current month of a monthly form reads as "%s"',
                                   coalesce(v_state, 'nothing'));
  else
    raise notice 'ok  a monthly form asks for the month in hand before any hours are logged';
  end if;

  -- Hours in an earlier month raise that month too, and only once.
  insert into public.service_entries (auth_id, date, hours, staff_id, primary_code)
  values (v_monthly, public.practice_today() - interval '45 days', 2, v_admin, 'JD');

  select count(*) into v_count from public.client_paperwork
   where auth_id = v_monthly and template_id = 'usor96';
  if v_count <> 2 then
    failures := failures || format('FAILED: a monthly form over two months produced %s rows, not 2', v_count);
  else
    raise notice 'ok  a month with hours in it gets its own row, and no month is asked for twice';
  end if;

  -- ── a closed authorization asks for nothing ────────────────
  update public.authorizations set status = 'Paid' where id = v_auth;
  select count(*) into v_count from public.client_paperwork where auth_id = v_auth;
  if v_count <> 0 then
    failures := failures || format('FAILED: a closed authorization still wants %s form(s)', v_count);
  else
    raise notice 'ok  a closed authorization asks for nothing';
  end if;

  -- ── every client has a row, including untouched ones ───────
  -- The inactive counter reads this view; a client nothing has happened to
  -- must appear with a null date rather than vanish from the left join.
  select count(*) into v_count from public.clients;
  if (select count(*) from public.client_last_activity) <> v_count then
    failures := failures || 'FAILED: client_last_activity drops clients with no activity'::text;
  else
    raise notice 'ok  a client nothing has ever happened to still has a row';
  end if;

  if failures = '{}' then
    raise notice '';
    raise notice '--- PAPERWORK STATUS AND ACTIVITY VERIFIED ---';
  else
    raise notice '';
    raise notice '%  PROBLEM(S):', array_length(failures, 1);
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
