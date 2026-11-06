-- Zion Vocational Rehab CRM — Phase 2 of the warrant reconciliation, part four
--
-- Ruling 7: the two invoices that are owed money and were invisible as debts,
-- and somebody told to chase them. Ruling 8 supplied the amounts, because the
-- amounts are not the ones the authorizations' own rates imply.
--
-- Everybody here is named by authorization number rather than by name. The
-- practice's rule is that no client data goes into the codebase or into git
-- history, and a V-number with a client's name beside it is a client's name in
-- the repository.
--
-- ── the two ───────────────────────────────────────────────────
--
-- V1037901, Job Coaching, was not in the CRM at all. It was invoiced to the
-- Downtown office on 6 October 2026 and again on 16 October, and the USOR 95
-- Job Coaching Tracker attached to the first says the rest: authorization
-- V1037901, eight coaching hours of twenty authorized, worked on 22 and 29
-- September, and the signed authorization line says $360.00. So it is entered
-- as eight hours at the practice's $45 against a twenty-hour authorization,
-- submitted on the day it was first invoiced.
--
-- V1045641, Job Development, was in the CRM as Authorized - never marked
-- submitted - though the invoice went to Valley West on 27 October with the
-- signed authorization at $560.00. Its bill-by date was today.
--
-- Neither appeared on any list of money owed, because that list is what is
-- Submitted and unpaid. Both do now.
--
-- ── the amounts come from the invoices ────────────────────────
--
-- Ruling 8: where the PDF differs from the authorization rate, the PDF is
-- what was invoiced. Two did differ, and both matter:
--
--   V1028166 was reported as "up to $900" from twenty hours at $45. The
--   signed authorization invoiced on 27 October says $450.00.
--   V1037901 was reported as unknown. It is $360.00.
--
-- Which changes the figure in the task the owner dictated. Their text said
-- $3,710 across three authorizations, worked out from the Phase 1 report
-- before the PDFs were read. Downtown is owed $3,620 across four: V1037898
-- at $2,250, V1037893 at $560, V1037901 at $360 and V1028166 at $450. The
-- task says the true figure, because a task that sends somebody to the
-- telephone with the wrong number is worse than no task.

begin;

do $$
declare
  v_admin    uuid;
  v_uid      uuid;
  v_margaret uuid;
  v_client   uuid;
  v_auth     uuid;
  v_n        integer;
begin
  select id, user_id into v_admin, v_uid
    from public.staff where role = 'Admin' and active and not is_system
   order by created_at limit 1;
  select intake_staff_id into v_margaret from public.org_settings limit 1;
  if v_uid is null then
    raise exception 'no active Admin with a sign-in';
  end if;
  if v_margaret is null then
    raise exception 'nobody is set as intake staff, so there is nobody to give the chase to';
  end if;

  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);

  -- ── V1037901, which did not exist ──────────────────────────
  -- Whose it is comes from the two authorizations of theirs the CRM already
  -- holds, which were invoiced in the same thread.
  select client_id into v_client from public.authorizations where number = 'V1037893';
  if v_client is null then
    raise exception 'V1037893 is not on file, so the client the Downtown job-coaching invoice is about cannot be found';
  end if;

  select id into v_auth from public.authorizations where number = 'V1037901';
  if v_auth is not null then
    raise notice 'note  V1037901 is already on file; it is left as it is';
  else
    v_auth := public.add_authorization(
      v_client, 'V1037901', 'Job Coaching', 'Hourly', 45, 20,
      null, null, null, 'Utah VR',
      'Entered from the invoice sent to the Downtown office on 6 October 2026 and again on '
      || '16 October. The USOR 95 Job Coaching Tracker attached to it gives the authorization '
      || 'number, twenty authorized hours, eight used on 22 and 29 September 2026, and the '
      || 'signed authorization line gives $360.00. The authorization document itself is not on '
      || 'file, so the authorized period is blank rather than guessed.',
      null, null, null, null);
    raise notice 'ok  V1037901 entered, 8 hours of 20 at 45, invoiced 360.00';
  end if;

  -- Authorized to Due to Submitted, which is the way the state machine goes;
  -- and submitted_on is written in the same statement as the status, so the
  -- trigger does not stamp today over the day it actually went out.
  if (select status from public.authorizations where id = v_auth) = 'Authorized' then
    update public.authorizations set status = 'Due' where id = v_auth;
  end if;
  if (select status from public.authorizations where id = v_auth) = 'Due' then
    update public.authorizations
       set status = 'Submitted', submitted_on = date '2026-10-06',
           submitted_by = v_admin, recipient = 'Downtown CRP',
           service_start = date '2026-09-22', service_end = date '2026-09-29'
     where id = v_auth;
    raise notice 'ok  V1037901 submitted as of 6 October 2026, to Downtown';
  end if;

  -- ── V1045641, which was never marked submitted ─────────────
  select id into v_auth from public.authorizations where number = 'V1045641';
  if v_auth is null then
    raise exception 'V1045641 is not on file';
  end if;
  if (select status from public.authorizations where id = v_auth) = 'Authorized' then
    update public.authorizations set status = 'Due' where id = v_auth;
    update public.authorizations
       set status = 'Submitted', submitted_on = date '2026-10-27',
           submitted_by = v_admin, recipient = 'Valley West CRP'
     where id = v_auth;
    raise notice 'ok  V1045641 submitted as of 27 October 2026, to Valley West';
  else
    raise notice 'note  V1045641 is %, not authorized; it is left as it is',
      lower((select status from public.authorizations where id = v_auth));
  end if;

  perform set_config('request.jwt.claims', '', true);

  -- ── and somebody to chase them ─────────────────────────────
  --
  -- Two tasks, not one: two offices, two telephone calls, and a task that
  -- names two places to ring is a task that gets half done.
  if not exists (select 1 from public.tasks
                  where status = 'Open' and title like 'Downtown %outstanding%') then
    insert into public.tasks (client_id, assigned_staff_id, title, due, system_generated, source_kind)
    values (null, v_margaret,
            'Downtown owes $3,620 across V1037898, V1037893, V1037901 and V1028166',
            public.practice_today(), true, 'authorization_missing');
    insert into public.task_comments (task_id, staff_id, staff_name, said)
    select t.id, v_admin, s.name,
           'V1037898 Job Placement $2,250.00 invoiced 8 October and again 16 October, chased 19 October. '
           || 'V1037893 Job Development $560.00 invoiced 16 October, chased twice on 4 November. '
           || 'V1037901 Job Coaching $360.00 invoiced 6 October and again 16 October. '
           || 'V1028166 Job Coaching $450.00 invoiced 27 October. '
           || 'The amounts are from the signed authorizations attached to those emails, not from the rates. '
           || 'Downtown has been chased three times and has paid none of it. Call them.'
      from public.tasks t, public.staff s
     where t.title like 'Downtown %outstanding%' and t.status = 'Open' and s.id = v_admin;
    raise notice 'ok  the Downtown chase is on the intake list';
  end if;

  if not exists (select 1 from public.tasks
                  where status = 'Open' and title like 'Valley West %outstanding%') then
    insert into public.tasks (client_id, assigned_staff_id, title, due, system_generated, source_kind)
    select a.client_id, v_margaret,
           'Valley West owes $560 on V1045641',
           public.practice_today(), true, 'authorization_missing'
      from public.authorizations a where a.number = 'V1045641';
    insert into public.task_comments (task_id, staff_id, staff_name, said)
    select t.id, v_admin, s.name,
           'V1045641 Job Development $560.00, invoiced to Valley West on 27 October 2026. It was sitting '
           || 'in the CRM as Authorized rather than Submitted, so it has been owed for ten days without '
           || 'appearing anywhere. Its bill-by date was 6 November.'
      from public.tasks t, public.staff s
     where t.title like 'Valley West %outstanding%' and t.status = 'Open' and s.id = v_admin;
    raise notice 'ok  the Valley West chase is on the intake list';
  end if;

  -- ── what is owed, counted ──────────────────────────────────
  select count(*) into v_n from public.authorizations where status = 'Submitted';
  raise notice 'ok  % authorization(s) are submitted and unpaid', v_n;
end $$;

do $$
declare v_total numeric; v_count integer;
begin
  select count(*), coalesce(sum(amount), 0) into v_count, v_total from public.payments;
  if v_count <> 157 or v_total <> 160562.50 then
    raise exception 'the ledger moved: % payments, %', v_count, to_char(v_total, 'FM999999.00');
  end if;
  raise notice 'ok  157 payments, 160562.50 - nothing here touches money received';
end $$;

commit;
