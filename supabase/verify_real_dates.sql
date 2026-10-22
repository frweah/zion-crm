-- Zion Vocational Rehab CRM — a date has to be one somebody meant (0210)
--
-- The bug: nothing checked the year. `/^\d{4}-\d{2}-\d{2}$/` accepts
-- 0226-03-14, and the schema had exactly one date range in it. A slipped
-- year on an authorization goes one of two ways, and both are quiet:
-- backwards and it is reported expired for ever, raising an alert that doing
-- the work cannot clear; forwards and bill_by never arrives, so it never
-- falls due and is never billed.
--
-- What has to hold:
--
--   A year typed short is refused, on an authorization, on a document and on
--   an hour.
--
--   A year typed long is refused too - that is the expensive direction,
--   because nothing else would ever complain about it.
--
--   The refusal says which date and what the window is, so the person can
--   see what they did rather than being told "invalid input".
--
--   Ordinary dates still go in, including an end date a couple of years out,
--   because a real authorization can run longer than a year and this must
--   not become a rule that staff have to work around.
--
--   A row already on file whose date is outside the window can still be
--   saved when somebody edits something else about it. Nothing is outside it
--   today, and if a legacy row ever is, the fix for that is a correction and
--   not an unsaveable record.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_client uuid;
  v_staff  uuid;
  v_auth   uuid;
  v_doc    uuid;
  v_text   text;
  v_lo     date := date '1990-01-01';
  v_hi     date := (public.practice_today() + interval '5 years')::date;
  failures text[] := '{}';
begin
  insert into public.staff (name, email, role, active)
  values ('ZZ Date Admin', 'zz-date@example.test', 'Admin', true) returning id into v_staff;
  insert into public.clients (name, stage, status) values ('ZZ Date Client', 'Job Placement', 'Active')
  returning id into v_client;

  -- ── a year typed short ────────────────────────────────────
  begin
    insert into public.authorizations (client_id, number, service_type, rate_type, rate,
                                       total_hours, start_date, end_date, received_on)
    values (v_client, 'ZZ-D-1', 'WSA Tier 1', 'Hourly', 50, 10,
            date '0226-03-14', public.practice_today() + 30, public.practice_today());
    failures := failures || 'FAILED: an authorization starting in the year 226 was accepted'::text;
  exception when check_violation then
    v_text := SQLERRM;
    if position('0226' in v_text) = 0 then
      failures := failures || format('FAILED: the refusal does not say which date was wrong: %s', v_text)::text;
    elsif position('check the year' in v_text) = 0 then
      failures := failures || format('FAILED: the refusal does not say what to look at: %s', v_text)::text;
    else
      raise notice 'ok  a year typed short is refused, and the refusal says which date and why';
    end if;
  end;

  -- ── a year typed long. The quiet one ──────────────────────
  begin
    insert into public.authorizations (client_id, number, service_type, rate_type, rate,
                                       total_hours, start_date, end_date, received_on)
    values (v_client, 'ZZ-D-2', 'WSA Tier 1', 'Hourly', 50, 10,
            public.practice_today(), date '2062-01-01', public.practice_today());
    failures := failures || 'FAILED: an authorization ending in 2062 was accepted; it would never fall due'::text;
  exception when check_violation then
    raise notice 'ok  a year typed long is refused too, which is the one nothing else would catch';
  end;

  -- ── an ordinary authorization still goes in ───────────────
  insert into public.authorizations (client_id, number, service_type, rate_type, rate,
                                     total_hours, start_date, end_date, received_on)
  values (v_client, 'ZZ-D-3', 'WSA Tier 1', 'Hourly', 50, 10,
          public.practice_today() - 30, public.practice_today() + 730, public.practice_today() - 30)
  returning id into v_auth;
  raise notice 'ok  and an ordinary one, running two years out, still goes in';

  -- ── a document ────────────────────────────────────────────
  begin
    insert into public.attachments (client_id, storage_path, filename, mime_type, size_bytes,
                                    category, document_date, uploaded_by, uploaded_by_name)
    values (v_client, 'clients/zz/zz-date.pdf', 'ZZ date.pdf', 'application/pdf', 1000,
            'Other', date '0225-06-01', v_staff, 'ZZ Date Admin');
    failures := failures || 'FAILED: a document dated in the year 225 was accepted'::text;
  exception when check_violation then
    raise notice 'ok  a document dated centuries ago is refused';
  end;

  insert into public.attachments (client_id, storage_path, filename, mime_type, size_bytes,
                                  category, document_date, uploaded_by, uploaded_by_name)
  values (v_client, 'clients/zz/zz-date-ok.pdf', 'ZZ date ok.pdf', 'application/pdf', 1000,
          'Other', public.practice_today() - 10, v_staff, 'ZZ Date Admin')
  returning id into v_doc;
  raise notice 'ok  and one dated last week is fine';

  -- ── an hour ───────────────────────────────────────────────
  begin
    insert into public.service_entries (auth_id, date, hours, staff_id, notes)
    values (v_auth, date '0226-01-02', 1, v_staff, 'ZZ hours in the year 226');
    failures := failures || 'FAILED: hours were logged for the year 226'::text;
  exception when check_violation then
    raise notice 'ok  hours cannot be logged for the year 226 either';
  end;

  -- ── and an edit to something else still saves ─────────────
  -- Put a date outside the window on a row directly, the way a legacy import
  -- could have, and then change an unrelated column. The row has to save: a
  -- rule that makes an existing record unsaveable turns one bad date into a
  -- record nobody can correct.
  -- Planted with the trigger off, which is the only honest way to make a row
  -- that pre-dates the rule: with it on, the rule refuses the plant, which is
  -- itself the first half of what is being asserted.
  -- Moving a stale date needs a reason written on the row (0160).
  alter table public.authorizations disable trigger authorizations_dates_are_real;
  update public.authorizations
     set stale_date = date '2062-01-01', stale_reason = 'ZZ planting a legacy date'
   where id = v_auth;
  alter table public.authorizations enable trigger authorizations_dates_are_real;

  update public.authorizations set followup_action = 'ZZ chased' where id = v_auth;
  if (select stale_date from public.authorizations where id = v_auth) <> date '2062-01-01' then
    failures := failures || 'FAILED: editing the row changed the out-of-window date behind the staff member''s back'::text;
  else
    raise notice 'ok  a row whose date is already outside the window can still be edited, and keeps it';
  end if;

  -- But writing that date again, deliberately, is still refused.
  begin
    update public.authorizations
       set stale_date = date '2063-01-01', stale_reason = 'ZZ trying a bad year'
     where id = v_auth;
    failures := failures || 'FAILED: a new out-of-window date was accepted on an existing row'::text;
  exception when check_violation then
    raise notice 'ok  while writing a new out-of-window date to it is still refused';
  end;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- REAL DATES VERIFIED ---';
end $$;

rollback;
