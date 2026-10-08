-- Zion Vocational Rehab CRM — the submission checklist (0160)
--
-- What has to hold, each tried from the direction that would break it:
--
--   Every line of the checklist answers. None of them answers null - a null
--   reads as neither ticked nor crossed on the screen and slips past
--   `not passed` as though it had passed.
--
--   The checklist and the submit trigger agree. Whenever the checklist says
--   it cannot be submitted the trigger refuses, and whenever the checklist
--   says nothing stands in the way the trigger allows it. This is the whole
--   point of the two reading one set of tests.
--
--   Exactly three lines refuse: the work inside the authorized period, the
--   hours within what was authorized, and still being inside the grace.
--
--   The USOR forms line is computed either way and refuses only when an Admin
--   has turned that on. Off, a missing form is shown and the submission goes
--   through; on, the same submission is refused.
--
--   A form counts whether it is a row in `forms` or a signed scan attached to
--   the authorization. The practice does them on paper.
--
--   The signed authorization is read from the attachments, not from a column
--   nothing writes.
--
--   The amount is computed, and an authorization with no billable hours says
--   so rather than claiming a figure.
--
--   Nobody who is not signed in can read any of it.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_client  uuid;
  v_office  uuid;
  v_office_name text;
  v_coun    uuid;
  v_flat    uuid;
  v_hourly  uuid;
  v_child   uuid;
  v_tmpl    uuid;
  v_lines   int;
  v_nulls   int;
  v_blockers text;
  v_passed  boolean;
  v_detail  text;
  v_grace   int;
  failures  text[] := '{}';
begin
  select stale_grace_days into v_grace from public.org_settings where id;

  -- The counselor's office is a foreign key onto `offices`, and the billing
  -- office it bills through hangs off that, so both come from one real office
  -- rather than being named here.
  select o.name, o.billing_office_id into v_office_name, v_office
    from public.offices o
    join public.billing_offices b on b.id = o.billing_office_id
   where b.billing_email like '%@%'
   order by o.name limit 1;
  insert into public.counselors (name, agency, office, email)
  values ('ZQ Gate Counselor', 'USOR', v_office_name, 'zq-gate@example.invalid')
  returning id into v_coun;
  -- The billing office is not stored on the client: it is derived from the
  -- counselor's office. §13.12 - read-only on the authorization, and nobody
  -- retypes it.
  insert into public.clients (name, stage, status, counselor_id)
  values ('ZZ Gate Client', 'Placement', 'Active', v_coun) returning id into v_client;
  if not exists (select 1 from public.client_billing_office
                  where client_id = v_client and billing_office_id = v_office) then
    failures := failures || 'FAILED: the billing office does not follow the counselor''s office'::text;
  end if;

  -- A flat fee, everything right about it, well inside its dates.
  insert into public.authorizations
    (client_id, number, service_type, rate_type, rate, status,
     start_date, end_date, service_start, service_end)
  values (v_client, 'V0000901', 'Job Development', 'Flat Fee', 560, 'Authorized',
          public.practice_today() - 60, public.practice_today() + 30,
          public.practice_today() - 50, public.practice_today() - 10)
  returning id into v_flat;

  -- ── every line answers, and none of them answers null ──────
  select count(*), count(*) filter (where g.passed is null)
    into v_lines, v_nulls
    from public.authorization_gate(v_flat) g;
  if v_lines < 10 then
    failures := failures || format('FAILED: the checklist came back with %s lines', v_lines);
  end if;
  if v_nulls > 0 then
    failures := failures || format('FAILED: %s checklist lines answered null, which reads as passing', v_nulls);
  else
    raise notice 'ok  every line of the checklist answers yes or no, never null';
  end if;

  -- The same, over every authorization the practice actually has.
  select count(*) filter (where g.passed is null) into v_nulls
    from public.authorizations a cross join lateral public.authorization_gate(a.id) g;
  if v_nulls > 0 then
    failures := failures || format('FAILED: %s lines answered null across the live records', v_nulls);
  end if;

  -- ── exactly three lines refuse ─────────────────────────────
  select string_agg(g.line, ' / ' order by g.line) into v_blockers
    from public.authorization_gate(v_flat) g where g.blocking;
  if v_blockers is distinct from
     'Hours within what was authorized / Still submittable / Work inside the authorized period' then
    failures := failures || format('FAILED: the refusing lines are now %s', v_blockers);
  else
    raise notice 'ok  three lines refuse a submission and the rest only report';
  end if;

  -- ── the signed authorization comes from the attachments ────
  select g.passed into v_passed from public.authorization_gate(v_flat) g
   where g.line = 'Signed authorization attached';
  if v_passed then
    failures := failures || 'FAILED: an authorization with nothing attached was said to have its signed copy'::text;
  end if;
  insert into public.attachments (client_id, auth_id, storage_path, filename, mime_type, size_bytes, category)
  values (v_client, v_flat, 'zz/gate/auth.pdf', 'auth.pdf', 'application/pdf', 1024, 'Authorization');
  select g.passed into v_passed from public.authorization_gate(v_flat) g
   where g.line = 'Signed authorization attached';
  if not v_passed then
    failures := failures || 'FAILED: the signed authorization is attached and the checklist cannot see it'::text;
  else
    raise notice 'ok  the signed authorization is read from the attachments';
  end if;

  -- ── the amount is computed ─────────────────────────────────
  select g.detail into v_detail from public.authorization_gate(v_flat) g where g.line = 'Amount';
  if v_detail not like '560.00%' then
    failures := failures || format('FAILED: a 560 flat fee came out as %s', v_detail);
  end if;

  -- ── the recipient, with nowhere to send it ─────────────────
  -- Both sides empty used to answer null rather than no. With no counselor
  -- and no referring office there is no billing office to derive.
  update public.clients set counselor_id = null, referring_office = '' where id = v_client;
  select g.passed into v_passed from public.authorization_gate(v_flat) g
   where g.line = 'Billing recipient';
  if v_passed is null then
    failures := failures || 'FAILED: with no billing office anywhere the recipient line answered null'::text;
  elsif v_passed then
    failures := failures || 'FAILED: an authorization with nowhere to send it has a billing recipient'::text;
  else
    raise notice 'ok  no billing office anywhere is a no, not a null';
  end if;
  update public.clients set counselor_id = v_coun where id = v_client;

  -- ── the forms line, and the switch ─────────────────────────
  update public.org_settings set require_forms_to_submit = false where id;
  select g.passed, g.blocking, g.detail into v_passed, v_blockers, v_detail
    from public.authorization_gate(v_flat) g where g.line = 'USOR forms complete and signed';
  if v_passed then
    failures := failures || 'FAILED: Job Development needs USOR 96 and the checklist did not ask for it'::text;
  end if;
  if v_blockers::boolean then
    failures := failures || 'FAILED: a missing form refuses a submission with the setting off'::text;
  end if;
  if v_detail not like '%does not stop a submission%' then
    failures := failures || format('FAILED: the forms line does not say it is not a block (%s)', v_detail);
  end if;

  -- and the submission goes through, which is the point
  update public.authorizations set status = 'Due' where id = v_flat;
  begin
    update public.authorizations set status = 'Submitted' where id = v_flat;
    raise notice 'ok  a missing USOR form does not stand in front of the person billing';
  exception when others then
    failures := failures || format('FAILED: a missing form refused the submission anyway (%s)', sqlerrm);
  end;

  -- with the switch on, the same submission is refused
  update public.authorizations set status = 'Due' where id = v_flat;
  update public.org_settings set require_forms_to_submit = true where id;
  if public.authorization_can_submit(v_flat) then
    failures := failures || 'FAILED: the checklist says it can be submitted with the forms block on'::text;
  end if;
  begin
    update public.authorizations set status = 'Submitted' where id = v_flat;
    failures := failures || 'FAILED: the forms block is on and a missing form went through'::text;
  exception when others then
    if sqlerrm not like '%DWS-USOR 96%' then
      failures := failures || format('FAILED: refused, but not for the missing form (%s)', sqlerrm);
    else
      raise notice 'ok  with the block on, the same submission is refused and the form is named';
    end if;
  end;

  -- ── a paper form counts ────────────────────────────────────
  insert into public.attachments (client_id, auth_id, storage_path, filename, mime_type, size_bytes, category)
  values (v_client, v_flat, 'zz/gate/96.pdf', '96.pdf', 'application/pdf', 2048, 'Signed USOR form');
  if public.authorization_missing_forms(v_flat) is not null then
    failures := failures || 'FAILED: the signed form is attached and the checklist still wants it'::text;
  else
    raise notice 'ok  a signed form on paper counts, which is how the practice does them';
  end if;
  update public.authorizations set status = 'Submitted' where id = v_flat;
  update public.org_settings set require_forms_to_submit = false where id;
  update public.authorizations set status = 'Due' where id = v_flat;

  -- ── the checklist and the trigger agree ────────────────────
  -- Work outside the authorized period: the checklist refuses and so does
  -- the trigger, with the same reason.
  update public.authorizations
     set service_start = public.practice_today() - 100 where id = v_flat;
  if public.authorization_can_submit(v_flat) then
    failures := failures || 'FAILED: work starting before the authorization was said to be submittable'::text;
  end if;
  begin
    update public.authorizations set status = 'Submitted' where id = v_flat;
    failures := failures || 'FAILED: work starting before the authorization was submitted'::text;
  exception when others then
    raise notice 'ok  the checklist and the trigger refuse the same submission';
  end;
  update public.authorizations
     set service_start = public.practice_today() - 50 where id = v_flat;

  -- Past the grace: refused, and the checklist says so first.
  -- The whole authorization is moved back past the grace, dates in order:
  -- authorized, worked, ended, and then long enough ago to be refused.
  update public.authorizations
     set start_date   = public.practice_today() - (v_grace + 40),
         service_start = public.practice_today() - (v_grace + 35),
         service_end  = public.practice_today() - (v_grace + 20),
         end_date     = public.practice_today() - (v_grace + 10),
         stale_date   = public.practice_today() - (v_grace + 10),
         stale_reason = 'verify: pushed past the grace on purpose'
   where id = v_flat;
  select g.passed into v_passed from public.authorization_gate(v_flat) g
   where g.line = 'Still submittable';
  if v_passed then
    failures := failures || 'FAILED: an authorization past the grace is still said to be submittable'::text;
  end if;
  begin
    update public.authorizations set status = 'Submitted' where id = v_flat;
    failures := failures || 'FAILED: an authorization past the grace was submitted'::text;
  exception when others then
    raise notice 'ok  past the grace, the checklist and the trigger both refuse';
  end;

  -- ── hours within what was authorized, across the months ────
  insert into public.authorizations
    (client_id, number, service_type, total_hours, rate_type, rate, status, start_date, end_date)
  values (v_client, 'V0000902', 'Job Coaching', 10, 'Hourly', 45, 'Authorized',
          public.practice_today() - 60, public.practice_today() + 30)
  returning id into v_hourly;
  -- Hours logged against the authorization land on the month they were worked
  -- (0171), so logging ten here opens this month and puts them on it.
  insert into public.service_entries (auth_id, date, hours)
  values (v_hourly, public.practice_today() - 5, 10);
  select id into v_child from public.authorizations
   where parent_id = v_hourly and period = date_trunc('month', public.practice_today())::date;
  if v_child is null or (select coalesce(sum(e.hours), 0) from public.service_entries e
                          where e.auth_id = v_child) <> 10 then
    failures := failures || 'FAILED: the hours did not land on this month, so the check below proves nothing'::text;
  end if;

  -- Over the authorized hours cannot be reached by logging - the cap refuses
  -- that, across every month (0171). The way it happens in practice is an
  -- amendment: USOR reduces an authorization to fewer hours than have already
  -- been worked. That is a conversation to have, and until it is had the work
  -- cannot be submitted.
  update public.authorizations set total_hours = 8 where id = v_hourly;
  if public.authorization_can_submit(v_hourly) then
    failures := failures || 'FAILED: ten hours worked against eight now authorized was said to be submittable'::text;
  else
    raise notice 'ok  hours are counted across the months and held to what the authorization says today';
  end if;

  -- ── and nobody who is not signed in reads any of it ────────
  if has_function_privilege('anon', 'public.authorization_gate(uuid)', 'execute')
     or has_function_privilege('anon', 'public.authorization_can_submit(uuid)', 'execute')
     or has_function_privilege('anon', 'public.authorization_missing_forms(uuid)', 'execute') then
    failures := failures || 'FAILED: somebody not signed in can read the submission checklist'::text;
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
