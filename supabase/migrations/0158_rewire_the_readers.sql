-- Zion Vocational Rehab CRM — what else read the billing item
-- (Billing Simplification Brief §§1, 6, 10, 11)
--
-- 0155 to 0157 moved the record and the ledger. These are the rest of the
-- things that read either the billing item or the authorization's old Open
-- status, rewired so nothing goes quiet.
--
-- Two of them would have failed silently, which is the only reason this file
-- is interesting:
--
--   The nightly "authorization nearly out of hours" alert summed the hours
--   logged against the authorization itself. Coaching hours now land on the
--   month, which is a child record, so the parent would have read zero used
--   for ever and the alert would never have fired again. It sums across the
--   parent and its children now.
--
--   The "sent and unpaid" alert read the invoice table, which §10 removes.
--   It reads the authorization's own submitted date instead, and keeps its
--   old kind name so an alert somebody is looking at today does not vanish
--   and come back as a different one.
--
-- The functions §10 deletes outright - billing_item_gate,
-- submit_item_for_form, draft_invoice_for_authorization and the billing-item
-- views - are not rewired here. §13.17 says delete rather than hide, and
-- they go with the table they are about.

-- ── the chase, on the authorization (§6) ───────────────────
create or replace function public.billing_followups_on(p_today date)
returns integer language plpgsql security definer set search_path = public as $$
declare r record; v_made integer := 0;
begin
  for r in
    select a.id, a.client_id, a.service_type, a.period, c.name as client_name,
           a.submitted_on as sent_on,
           -- Whoever bills for this client, which is who chases it.
           coalesce(c.billing_staff_id, c.assigned_staff_id) as chase_by
      from public.authorizations a
      join public.clients c on c.id = a.client_id
     where a.status = 'Submitted'
       and a.submitted_on is not null
       and coalesce(a.followup_due, a.submitted_on + 14) <= p_today
  loop
    if not exists (
      select 1 from public.tasks t
       where t.source_kind = 'authorization' and t.source_ref = r.id and t.status = 'Open'
    ) then
      insert into public.tasks (client_id, assigned_staff_id, title, due, status,
                                system_generated, source_kind, source_ref)
      values (r.client_id,
              r.chase_by,
              'No answer yet on ' || r.service_type
                || coalesce(' for ' || to_char(r.period, 'FMMonth'), '')
                || ' - sent ' || to_char(r.sent_on, 'FMDD Mon') || '. Chase it.',
              p_today,
              'Open', true, 'authorization', r.id);
      v_made := v_made + 1;
    end if;
    update public.authorizations set followup_due = p_today + 14 where id = r.id;
  end loop;
  return v_made;
end;
$$;

comment on function public.billing_followups_on is
  'The 14-day chase (§6): a task for whoever bills the client, on an authorization submitted with no payment. "Pending" was a status; it is this task now.';

revoke all on function public.billing_followups_on(date) from public, anon, authenticated;
grant execute on function public.billing_followups_on(date) to service_role, authenticated;

-- ── the nightly alerts ─────────────────────────────────────
CREATE OR REPLACE FUNCTION public.generate_notifications_on(p_today date)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  n_open      integer;
  v_today     date := coalesce(p_today, public.practice_today());
  last_month  text := to_char((date_trunc('month', v_today) - interval '1 day'), 'YYYY-MM');
  tax_year    integer := extract(year from v_today)::int - 1;
  in_season   boolean := (extract(month from v_today) = 1 and extract(day from v_today) >= 2)
                         or extract(month from v_today) = 2;
  past_target boolean := (extract(month from v_today) = 1 and extract(day from v_today) >= 15)
                         or extract(month from v_today) = 2;
  v_threshold numeric;
  n_due       integer;
begin
  drop table if exists _current;
  drop table if exists _used;

  create temporary table _current (
    dedupe_key text primary key,
    kind text, level text, text text, roles text[], href text,
    client_id uuid, staff_id uuid
  ) on commit drop;

  create temporary table _used on commit drop as
  select a.id, a.client_id, a.number, a.service_type, a.total_hours, a.end_date,
         a.carried_used + coalesce(
           (select sum(e.hours) from public.service_entries e
             join public.authorizations c on c.id = e.auth_id
            where (c.id = a.id or c.parent_id = a.id) and not e.non_billable), 0) as used
    from public.authorizations a
   where a.status in ('Authorized', 'Due', 'Submitted')
     and a.parent_id is null;

  -- 1. Authorizations out of hours, or nearly.
  insert into _current
  select 'auth_hours:' || u.id,
         case when u.total_hours - u.used <= 0 then 'auth_exhausted' else 'auth_low' end,
         case when u.total_hours - u.used <= 0 then 'bad' else 'warn' end,
         case
           when u.total_hours - u.used <= 0 then
             coalesce(nullif(u.number, ''), u.service_type) || ' (' || u.service_type ||
             ') has no hours left — request additional hours before more service.'
           else
             coalesce(nullif(u.number, ''), u.service_type) || ' (' || u.service_type ||
             ') is under 10% remaining (' || public.fmt_hours(u.total_hours - u.used) || ' hrs).'
         end,
         case when u.total_hours - u.used <= 0
              then array['Admin','Billing','Job Search'] else array['Admin','Billing'] end,
         '/clients/' || u.client_id || '?tab=authorizations',
         u.client_id, null
    from _used u
   where u.total_hours is not null and u.total_hours - u.used <= u.total_hours * 0.1;

  -- 2. Authorizations ending within a fortnight.
  insert into _current
  select 'auth_ending:' || u.id, 'auth_ending', 'warn',
         coalesce(nullif(u.number, ''), u.service_type) || ' ends ' || u.end_date ||
         ' — unbilled work after that date will not be paid.',
         array['Admin','Billing'],
         '/clients/' || u.client_id || '?tab=authorizations', u.client_id, null
    from _used u
   where u.end_date is not null and u.end_date >= v_today and u.end_date <= v_today + 14;

  -- 3. Submitted and unpaid, escalating at 30 / 60 / 90.
  --
  -- Read off the authorization rather than an invoice: §10 removes the
  -- invoice record, and §11 says the fact lives in one place. The kind keeps
  -- its old name so the alert somebody is looking at today does not vanish
  -- and reappear under a new one.
  insert into _current
  select 'invoice_unpaid:' || a.id || ':' ||
         case when v_today - a.submitted_on >= 90 then '90'
              when v_today - a.submitted_on >= 60 then '60' else '30' end,
         'invoice_unpaid',
         case when v_today - a.submitted_on >= 90 then 'bad' else 'warn' end,
         coalesce(nullif(a.number, ''), a.service_type) || ' submitted '
           || (v_today - a.submitted_on) || ' days ago with no payment.',
         array['Admin','Billing'], '/billing', a.client_id, null
    from public.authorizations a
   where a.status = 'Submitted'
     and a.submitted_on is not null
     and v_today - a.submitted_on >= 30;

  -- 4. Overdue tasks.
  insert into _current
  select 'task_overdue:' || t.id, 'task_overdue', 'warn',
         'Overdue task: ' || t.title,
         array_remove(array['Admin', s.role], null), '/tasks', t.client_id, t.assigned_staff_id
    from public.tasks t
    left join public.staff s on s.id = t.assigned_staff_id
   where t.status = 'Open' and t.due is not null and t.due < v_today;

  -- 5. Monthly USOR reports, due by the 15th.
  if extract(day from v_today) <= 15 then
    insert into _current
    select 'monthly_forms:' || u.id || ':' || last_month, 'monthly_forms', 'warn',
           missing.usors || ' for ' || last_month || ' due by the 15th — ' ||
           c.name || ' (' || coalesce(nullif(u.number, ''), u.service_type) || ')',
           array['Admin','Billing','Job Search'],
           '/clients/' || u.client_id || '?tab=forms', u.client_id, null
      from _used u
      join public.clients c on c.id = u.client_id
      cross join lateral (
        select string_agg(t.usor, ' + ' order by t.sort_order) as usors
          from public.form_templates t
         where t.monthly and t.required_for_billing
           and u.service_type = any (t.services)
           and not exists (
             select 1 from public.forms f
              where f.auth_id = u.id and f.template_id = t.id
                and f.month = last_month and f.status <> 'Draft')
      ) missing
     where u.service_type in ('Job Coaching', 'Job Development', 'Job Development + HQ Indicator')
       and missing.usors is not null
       and (
         exists (select 1 from public.service_entries e
                  where e.auth_id = u.id and to_char(e.date, 'YYYY-MM') = last_month)
         or exists (select 1 from public.notes n
                     where n.client_id = u.client_id
                       and to_char(n.at, 'YYYY-MM') = last_month
                       and n.type in ('Job search','Application submitted','Interview','Employer contact'))
       );
  end if;

  -- 6. Counselor follow-ups now due.
  insert into _current
  select 'followup:' || cl.id, 'followup_due', 'warn',
         'Counselor follow-up due: ' || cl.topic,
         array_remove(array['Admin', s.role], null), '/counselors', cl.client_id, cl.staff_id
    from public.contact_log cl
    left join public.staff s on s.id = cl.staff_id
   where cl.follow_up is not null and not cl.follow_up_done and cl.follow_up <= v_today;

  -- ── 7. A foreign contractor with no W-8BEN on file ──────────
  insert into _current
  select 'w8ben_missing:' || s.id, 'w8ben_missing', 'warn',
         s.name || ' is a foreign person with no W-8BEN on file. One is needed before payment.',
         array['Admin'], '/staff', null, s.id
    from public.staff s
    join public.contractor_profiles p on p.staff_id = s.id
   where s.active and p.tax_status = 'Foreign person' and p.w8ben_received_on is null;

  -- ── 8. A W-8BEN expiring, or already expired ────────────────
  --      Valid through the last day of the third succeeding calendar year;
  --      60 days' notice is enough to get a fresh one signed and returned.
  insert into _current
  select 'w8ben_expiry:' || s.id || ':' || to_char(p.w8ben_expires_on, 'YYYY'),
         case when p.w8ben_expires_on < v_today then 'w8ben_expired' else 'w8ben_expiring' end,
         case when p.w8ben_expires_on < v_today then 'bad' else 'warn' end,
         case when p.w8ben_expires_on < v_today
              then s.name || '''s W-8BEN expired on ' || p.w8ben_expires_on || '. A new one is needed.'
              else s.name || '''s W-8BEN expires ' || p.w8ben_expires_on || ' — ask for a new one.'
         end,
         array['Admin'], '/staff', null, s.id
    from public.staff s
    join public.contractor_profiles p on p.staff_id = s.id
   where s.active
     and p.tax_status = 'Foreign person'
     and p.w8ben_expires_on is not null
     and p.w8ben_expires_on <= v_today + 60;

  -- ── 9. January: the threshold the CPA confirms ──────────────
  if in_season then
    select federal_threshold into v_threshold from public.tax_years where year = tax_year;

    if v_threshold is null then
      insert into _current values (
        'tax_threshold:' || tax_year, 'tax_threshold_unconfirmed', 'warn',
        'Confirm the ' || tax_year || ' federal 1099-NEC threshold with your CPA, and whether Utah requires a state copy. Nothing can be generated until it is entered.',
        array['Admin'], '/staff?tab=tax', null, null);
    else
      -- ── 10. January: the run itself ─────────────────────────
      select count(*) into n_due from public.form_1099_candidates(tax_year);

      if n_due > 0 and not exists (
        select 1 from public.form_1099_runs where year = tax_year
      ) then
        insert into _current values (
          'form_1099_run:' || tax_year, 'form_1099_due',
          case when past_target then 'bad' else 'warn' end,
          n_due || ' contractor' || case when n_due = 1 then '' else 's' end ||
          ' need a ' || tax_year || ' 1099-NEC. ' ||
          case when past_target
               then 'Past the 15 January target — recipient copies and filing are due by 31 January.'
               else 'Aim to generate by 15 January; delivery and filing are due by 31 January.'
          end,
          array['Admin'], '/staff?tab=tax', null, null);
      end if;
    end if;
  end if;

  -- 11. Certifications and clearances.
  --
  -- Missing and expired are the same colour on purpose: somebody without a
  -- current background check is in the same position whether the card ran out
  -- or was never recorded, and the difference is a matter for the
  -- conversation rather than for the flag.
  --
  -- The state is in the dedupe key, so a card moving from Expiring to Expired
  -- raises a new flag and resolves the old one, rather than quietly rewriting
  -- the first and losing the date it started.
  insert into _current
  select 'credential:' || a.staff_id || ':' || a.type_key || ':' || a.state,
         'credential_' || lower(a.state),
         case when a.state in ('Expired', 'Missing') then 'bad' else 'warn' end,
         case a.state
           when 'Missing' then
             a.staff_name || ' has no ' || a.label || ' on file.'
           when 'Expired' then
             a.staff_name || '''s ' || a.label || ' expired ' || a.expires_on || '.'
           else
             a.staff_name || '''s ' || a.label || ' expires ' || a.expires_on ||
             ' - ' || a.days_left || ' days.'
         end,
         array['Admin'],
         '/admin/staff',
         null,
         -- Named so the person themselves sees it, and nobody else in their
         -- role does. A colleague has no business knowing whose CPR card has
         -- run out.
         a.staff_id
    from public.credential_attention a
   where a.state in ('Expired', 'Missing', 'Expiring');

  -- 11b. A card somebody put forward themselves, waiting for Admin to look.
  --      Admin only: it is a request to check, not news for the person.
  insert into _current
  select 'credential:' || a.staff_id || ':' || a.type_key || ':' || a.state,
         'credential_awaiting_check',
         'warn',
         a.staff_name || ' put forward their ' || a.label || ' - check it against the scan and verify.',
         array['Admin'],
         '/admin/people/' || a.staff_id,
         null,
         null
    from public.credential_attention a
   where a.state = 'Awaiting check';

  -- 12. Continuing education, but only once it matters.
  --
  -- Somebody being short of hours in February is not news; being short in
  -- October is. Raising it in January would train everybody to ignore it for
  -- nine months and then miss it in the tenth.
  if extract(month from v_today) >= 10 then
    insert into _current
    select 'ce_short:' || a.staff_id || ':' || extract(year from v_today),
           'credential_ce',
           case when extract(month from v_today) = 12 then 'bad' else 'warn' end,
           a.staff_name || ' has ' || a.hours_this_year || ' of ' ||
           a.hours_target || ' training hours for the year.',
           array['Admin'],
           '/paperwork',
           null,
           a.staff_id
      from public.credential_attention a
     where a.state = 'Outstanding';
  end if;

  -- 13. Onboarding steps still open (0100). Named to the person, so it is on
  --     their own dashboard, and addressed to Admin, who is waiting on it.
  --     Only for somebody who has signed in: before that the invite is what
  --     is outstanding, and Admin resends it.
  insert into _current
  select 'onboarding_open:' || o.staff_id,
         'onboarding_open',
         'warn',
         s.name || ' has ' || cardinality(public.onboarding_open_steps(o.staff_id)) ||
           ' onboarding step' || case when cardinality(public.onboarding_open_steps(o.staff_id)) = 1 then '' else 's' end ||
           ' still to do.',
         array['Admin'],
         '/onboarding',
         null,
         o.staff_id
    from public.staff_onboarding o
    join public.staff s on s.id = o.staff_id
   where o.completed_at is null and s.active and s.accepted_at is not null
     and cardinality(public.onboarding_open_steps(o.staff_id)) > 0;

  -- 14. Onboarding finished, for a fortnight after, so Admin sees it however
  --     long they were away. Raised the moment it happens by refresh_onboarding;
  --     kept here so the nightly reconcile does not resolve it.
  insert into _current
  select 'onboarding_done:' || o.staff_id,
         'onboarding_done',
         'warn',
         s.name || ' finished onboarding.' ||
           case when exists (select 1 from public.staff_files f
                              where f.staff_id = o.staff_id and f.category = 'I-9' and f.inspected_at is null)
                then ' Their I-9 documents still need inspecting in person.' else '' end,
         array['Admin'],
         '/admin/people/' || o.staff_id,
         null,
         null
    from public.staff_onboarding o
    join public.staff s on s.id = o.staff_id
   where o.completed_at >= v_today - 14;

  -- 12. An account over its budget this month (E2).
  --
  -- Only cost accounts, only where somebody actually set a budget, and only
  -- past a tolerance the owner sets - because an account a penny over budget
  -- on the second of the month is noise, and an alert that is noise is one
  -- people learn to click past.
  insert into _current
  select 'budget_over:' || v.account_id || ':' || to_char(v_today, 'YYYY-MM'),
         'budget_over',
         'warn',
         v.name || ' is ' || to_char(v.actual - v.budget, 'FM999999990.00') || ' over its budget for '
           || to_char(v_today, 'FMMonth') || ' (' || to_char(v.actual, 'FM999999990.00')
           || ' against ' || to_char(v.budget, 'FM999999990.00') || ').',
         array['Admin'],
         '/books/budget',
         null,
         null
    from public.ledger_budget_variance(date_trunc('month', v_today)::date,
                                       (date_trunc('month', v_today) + interval '1 month - 1 day')::date) v
    cross join lateral (
      select coalesce(s.budget_tolerance, 10) as tolerance
        from public.ledger_settings s
        join public.ledger_entities e on e.id = s.entity_id and e.is_default
    ) t
   where v.over
     and v.budget > 0
     and v.actual > v.budget * (1 + t.tolerance / 100.0);

  -- 13. The cash forecast dropping below the floor the owner set (E2).
  --
  -- One alert, naming the first week it happens, rather than one per week:
  -- thirteen alerts saying the same thing is the same thing said thirteen
  -- times. Null floor means the owner has not asked to be warned.
  insert into _current
  select 'cash_floor:' || to_char(f.week, 'YYYY-MM-DD'),
         'cash_floor',
         'bad',
         'The cash forecast drops to ' || to_char(f.closing, 'FM999999990.00') || ' in the week of '
           || to_char(f.week, 'FMDD Month') || ', below the ' || to_char(f.floor_at, 'FM999999990.00')
           || ' floor.',
         array['Admin'],
         '/books/forecast',
         null,
         null
    from (
      select c.week, c.closing, s.cash_floor as floor_at,
             row_number() over (order by c.week) as rank
        from public.ledger_cash_forecast(90) c
        cross join (
          select s.cash_floor
            from public.ledger_settings s
            join public.ledger_entities e on e.id = s.entity_id and e.is_default
        ) s
       where s.cash_floor is not null and c.closing < s.cash_floor
    ) f
   where f.rank = 1;

  -- ── whose alert it is ───────────────────────────────────────
  -- A client's billing alerts are addressed to whoever bills for them
  -- (0121), and the rest of a client's to whoever works their job search.
  -- The roles above are unchanged: this says who it is for, not who may see
  -- it, so nothing is hidden from Admin or from Billing at large.
  update _current c
     set staff_id = coalesce(
           case when c.kind in ('auth_hours', 'auth_exhausted', 'auth_low', 'auth_ending', 'invoice_unpaid', 'monthly_forms')
                then cl.billing_staff_id else cl.assigned_staff_id end,
           cl.assigned_staff_id)
    from public.clients cl
   where cl.id = c.client_id and c.staff_id is null;

  -- ── reconcile ───────────────────────────────────────────────
  insert into public.notifications
    (dedupe_key, kind, level, text, roles, href, client_id, staff_id)
  select c.dedupe_key, c.kind, c.level, c.text, c.roles, c.href, c.client_id, c.staff_id
    from _current c
  on conflict (dedupe_key) do update set
    kind = excluded.kind, level = excluded.level, text = excluded.text,
    roles = excluded.roles, href = excluded.href, resolved_at = null;

  update public.notifications n
     set resolved_at = now()
   where n.resolved_at is null
     and not exists (select 1 from _current c where c.dedupe_key = n.dedupe_key);

  select count(*) into n_open from public.notifications where resolved_at is null;
  return n_open;
end;
$function$
;

revoke all on function public.generate_notifications_on(date) from public, anon, authenticated;
grant execute on function public.generate_notifications_on(date) to service_role;

comment on function public.generate_notifications_on(date) is
  'The nightly alert rules, dated from p_today. Thirteen of them, reading authorizations rather than billing items or invoices (§1, §10).';

-- ── the two remaining Open filters ─────────────────────────
--
-- One line each, so they are changed in place rather than recreated: Open
-- meant "not finished", which is now Authorized, Due or Submitted.

CREATE OR REPLACE FUNCTION public.client_next_actions(p_client uuid)
 RETURNS TABLE(kind text, title text, detail text, href text, urgency integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with c as (select * from public.clients where id = p_client)
  -- The next appointment, from client_next_up rather than from the events
  -- table: that view already knows an appointment being withdrawn from
  -- Outlook is not one, and a second definition here would forget.
  (select 'appointment',
         'Appointment ' || to_char(n.at at time zone 'America/Denver', 'Dy DD Mon, FMHH12:MIam'),
         n.title,
         '/clients/' || p_client || '?tab=activity',
         case when n.at < now() + interval '24 hours' then 1 else 4 end
    from public.client_next_up n
   where n.client_id = p_client and n.kind = 'Appointment'
   order by n.at limit 1)

  union all
  -- A form that is blocking billing: hours logged against an authorization
  -- with no form for them.
  select 'form', p.usor || ' needed',
         p.form_name || coalesce(' · ' || p.month, '') || ' · ' || trim(to_char(p.hours_logged, 'FM999990.9')) || ' hours logged',
         '/billing/report?client=' || p_client,
         2
    from public.client_paperwork p
   where p.client_id = p_client and p.state = 'Missing'

  union all
  -- An authorization running out with money on it not yet invoiced (0116):
  -- hours logged and not billed, a flat fee with no completion recorded, or
  -- nothing done at all. After its end date none of it can be earned, so
  -- this is the last month to finish the work, record it, or ask the
  -- counselor to extend.
  select 'authorization', 'Authorization ' || a.number || ' ends ' || to_char(a.end_date, 'FMDD Mon'),
         -- Said in the words each figure actually means (audit, 25 Sept 2026):
         -- "not yet earned" is work still to do, "earned and not yet invoiced"
         -- is the record header's own unbilled figure, and a flat fee is never
         -- short of hours - a completed one was being told it had none.
         case
           when a.rate_type = 'Flat Fee' and e.completed_on is null
             then 'No completion recorded - ' || trim(to_char(e.authorized - coalesce(e.invoiced, 0), 'FM$999,990.00'))
                  || ' not yet earned. Record it within the dates, or ask the counselor to extend'
           when a.rate_type = 'Flat Fee'
             then 'Completed ' || to_char(e.completed_on, 'FMDD Mon') || ' - '
                  || trim(to_char(greatest(e.unbilled, 0), 'FM$999,990.00')) || ' earned and not yet invoiced'
           when coalesce(u.hours, 0) = 0
             then 'No hours logged - ' || trim(to_char(e.authorized - coalesce(e.invoiced, 0), 'FM$999,990.00'))
                  || ' not yet earned. Log the work within the dates, or ask the counselor to extend'
           else trim(to_char(coalesce(u.hours, 0), 'FM999990.9')) || ' hours logged on it, '
                || trim(to_char(greatest(e.unbilled, 0), 'FM$999,990.00')) || ' earned and not yet invoiced'
         end,
         '/clients/' || p_client || '?tab=billing',
         case when a.end_date <= public.practice_today() + 14 then 1 else 3 end
    from public.authorizations a
    join public.authorization_economics e on e.auth_id = a.id
    left join lateral (
      select sum(se.hours) hours from public.service_entries se
       where se.auth_id = a.id and not se.non_billable) u on true
   where a.client_id = p_client and a.status in ('Authorized', 'Due', 'Submitted')
     and a.end_date is not null
     and a.end_date between public.practice_today() and public.practice_today() + 30
     and coalesce(e.authorized, 0) > coalesce(e.invoiced, 0)

  union all
  -- Five shifts kept: the placement may be billed, on USOR 92.
  select 'placement', 'Fifth shift reached',
         coalesce(nullif(pl.employer, ''), 'the placement') || ' · USOR 92 and the placement bill are due',
         '/billing/report?client=' || p_client, 2
    from public.placements pl
   where pl.client_id = p_client
     and pl.fifth_shift_on is not null
     and not exists (
       select 1 from public.forms f
        join public.authorizations a on a.id = f.auth_id
       where f.client_id = p_client and f.template_id = 'usor92'
         and f.status <> 'Draft' and a.service_type like 'Job Placement%')

  union all
  -- Thirty days of stability: the High Quality Indicators may be billed.
  select 'stability', 'Thirty days of stability',
         coalesce(nullif(pl.employer, ''), 'the placement')
           || coalesce(' · ' || nullif(pl.stability_basis, ''), '')
           || ' · High Quality Indicators may be billed',
         '/clients/' || p_client || '?tab=billing', 2
    from public.placements pl
   where pl.client_id = p_client
     and pl.stability_on is not null
     and pl.stability_on + 30 <= public.practice_today()
     -- "has the HQI been billed yet" used to mean "is there an invoice for
     -- it". With the invoice gone (§10) it means the authorization has been
     -- submitted or paid, which is the same question asked of the one
     -- record that now answers it.
     and not exists (
       select 1 from public.authorizations a
       where a.client_id = p_client
         and a.service_type like '%HQ Indicator%'
         and a.status in ('Submitted', 'Paid'))

  union all
  -- A text from them that nobody has answered.
  select 'text', 'Unanswered text', left(m.body, 80),
         '/clients/' || p_client || '?tab=messages', 1
    from public.conversations v
    join lateral (
      select body, sender_kind from public.messages
       where conversation_id = v.id order by seq desc limit 1) m on true
   where v.client_id = p_client and v.kind = 'sms' and m.sender_kind = 'client'

  union all
  -- Nobody has recorded whether they agreed to be texted.
  select 'consent', 'Texting consent not recorded',
         'They cannot be texted until it is', '/clients/' || p_client || '?tab=profile#texting', 3
    from c
   where not exists (select 1 from public.sms_consent_events e where e.client_id = p_client)

  union all
  -- A retention check that has come due on a placement.
  select 'retention', d.label || ' check due',
         coalesce(nullif(pl.employer, ''), 'a placement'),
         '/clients/' || p_client || '?tab=jobs', 2
    from public.placements pl
    cross join lateral (values
      (pl.check30, 30, '30 day'), (pl.check60, 60, '60 day'), (pl.check90, 90, '90 day')
    ) d(done, days, label)
   where pl.client_id = p_client and pl.start_date is not null
     and d.done is null and pl.start_date + d.days <= public.practice_today()

  order by 5, 1;
$function$;

grant execute on function public.client_next_actions(uuid) to authenticated;

/**
 * What a billing office needs chasing about.
 *
 * The unpaid leg read the invoice table, which §10 removes. It reads the
 * authorization's own submission instead. The signature is unchanged, so
 * nothing calling it breaks - and `invoice_number` comes back null, because
 * there is no invoice number any more and filling it with the authorization
 * number would put the same fact in two columns of one row. The column goes
 * when §9 rewrites the screen that reads it.
 */
create or replace function public.billing_office_reconciliation(
  p_billing_office uuid,
  p_within_days integer default 30
)
returns table (
  kind text, client_id uuid, client_name text, counselor_id uuid, counselor_name text,
  counselor_email text, auth_id uuid, auth_number text, service text, invoice_number text,
  amount numeric, sent_on date, days_outstanding integer, end_date date, unbilled numeric
) language sql stable security definer set search_path = public as $$
  select 'Unpaid invoice'::text, c.id, c.name, k.id, k.name, nullif(trim(k.email), ''),
         a.id, coalesce(nullif(a.number, ''), p.number, ''), a.service_type, null::text,
         public.authorization_amount(a.id), a.submitted_on,
         (public.practice_today() - a.submitted_on)::integer,
         a.end_date, null::numeric
    from public.authorizations a
    left join public.authorizations p on p.id = a.parent_id
    join public.clients c on c.id = a.client_id
    join public.client_billing_office cbo on cbo.client_id = c.id
    left join public.counselors k on k.id = c.counselor_id
   where a.status = 'Submitted'
     and a.submitted_on is not null
     and cbo.billing_office_id = p_billing_office
  union all
  select 'Ending soon, not fully invoiced'::text, c.id, c.name, k.id, k.name, nullif(trim(k.email), ''),
         a.id, a.number, a.service_type, null::text,
         null::numeric, null::date, null::integer,
         a.end_date, bp.not_yet_invoiced
    from public.billing_position bp
    join public.authorizations a on a.id = bp.auth_id
    join public.clients c on c.id = a.client_id
    join public.client_billing_office cbo on cbo.client_id = c.id
    left join public.counselors k on k.id = c.counselor_id
   where a.status in ('Authorized', 'Due', 'Submitted')
     and a.end_date between public.practice_today()
       and public.practice_today() + greatest(coalesce(p_within_days, 30), 0)
     and bp.not_yet_invoiced > 0
     and cbo.billing_office_id = p_billing_office
$$;

revoke all on function public.billing_office_reconciliation(uuid, integer) from anon, authenticated;
grant execute on function public.billing_office_reconciliation(uuid, integer) to authenticated;
