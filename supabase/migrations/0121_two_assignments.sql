-- Zion Vocational Rehab CRM — two people on a client: job search, and billing
--
-- A client had one assigned staff member, and it carried two different jobs:
-- who works their job search, and who bills for them. Billing is nobody's
-- caseload, so Billing could not edit a client at all - the client's own rule
-- named Admin, Job Search and Intake & Reports, and no Billing seat is ever
-- the assigned one (owner, 25 Sept 2026):
--
--   Billing edits on a client do not depend on who the client is assigned to.
--   The Billing role, or a billing edit grant, is enough on any client.
--
--   The assignment is two fields. The one that was there is the job search
--   assignment (the column keeps its name, assigned_staff_id, because
--   nineteen functions and five views read it); billing_staff_id is new.
--
--   Both are the client's people: both appear on the record, both count as
--   "mine", and the billing alerts a client raises are addressed to the
--   billing one rather than to the Billing role at large.
--
-- What this deliberately does not change: the restricted personal details
-- (can_see_restricted) stay with Admin, Intake & Reports and the job search
-- assignment. Being the billing contact is a reason to bill for somebody,
-- not a reason to read their intake.

alter table public.clients
  add column if not exists billing_staff_id uuid references public.staff(id) on delete set null;

comment on column public.clients.assigned_staff_id is
  'The job search assignment: who works this client''s job search (0121).';
comment on column public.clients.billing_staff_id is
  'Who bills for this client (0121). Independent of what Billing may edit, which is the role''s.';

create index if not exists clients_billing_staff_idx on public.clients (billing_staff_id);

-- ── Billing edits a client, whoever it is assigned to ──────
drop policy if exists clients_update on public.clients;
create policy clients_update on public.clients for update to authenticated
  using (
    (select public.current_staff_role()) = any (array['Admin', 'Job Search', 'Reports'])
    or (select public.current_staff_role()) = 'Billing'
    or (select public.staff_has_area('billing', 'edit'))
  )
  with check (
    (select public.current_staff_role()) = any (array['Admin', 'Job Search', 'Reports'])
    or (select public.current_staff_role()) = 'Billing'
    or (select public.staff_has_area('billing', 'edit'))
  );

-- ── who bills, to start with ───────────────────────────────
-- Margaret, on every active client (owner, 25 Sept 2026). Where somebody
-- else bills for a client, it is changed on the record.
update public.clients
   set billing_staff_id = (select id from public.staff where name = 'Margaret Paasa' and active)
 where status = 'Active' and billing_staff_id is null and merged_into is null;

-- ── a client's alerts know which of the two they are for ──
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
             where e.auth_id = a.id and not e.non_billable), 0) as used
    from public.authorizations a
   where a.status = 'Open';

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

  -- 3. Invoices sent and unpaid, escalating at 30 / 60 / 90.
  insert into _current
  select 'invoice_unpaid:' || i.id || ':' ||
         case when v_today - i.date >= 90 then '90'
              when v_today - i.date >= 60 then '60' else '30' end,
         'invoice_unpaid',
         case when v_today - i.date >= 90 then 'bad' else 'warn' end,
         'Invoice ' || i.number || ' unpaid ' || (v_today - i.date) || ' days.',
         array['Admin','Billing'], '/billing?tab=invoices', a.client_id, null
    from public.invoices i
    join public.authorizations a on a.id = i.auth_id
   where i.status = 'Sent' and v_today - i.date >= 30;

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
$function$;
