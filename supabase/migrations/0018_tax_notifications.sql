-- Zion Vocational Rehab CRM — 0018 W-8BEN and 1099 season alerts
--
-- Adds five rules to the nightly generator:
--   * a foreign contractor with no W-8BEN on file
--   * a W-8BEN expiring within 60 days, and one already expired
--   * in January, a federal threshold not yet confirmed with the CPA
--   * in January, a 1099-NEC run not yet generated — a reminder from the 2nd,
--     turning urgent on the 15th, because the 31st is the deadline for both
--     delivering the recipient copy and filing
--
-- The whole function is restated because that is what CREATE OR REPLACE means;
-- the first six rules are unchanged from 0011.

create or replace function public.generate_notifications()
returns integer
language plpgsql security definer set search_path = public
as $$
declare
  n_open      integer;
  v_today     date := current_date;
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

  -- ── reconcile ───────────────────────────────────────────────
  insert into public.notifications
    (dedupe_key, kind, level, text, roles, href, client_id, staff_id)
  select c.dedupe_key, c.kind, c.level, c.text, c.roles, c.href, c.client_id, c.staff_id
    from _current c
  on conflict (dedupe_key) do update set
    level = excluded.level, text = excluded.text,
    roles = excluded.roles, href = excluded.href, resolved_at = null;

  update public.notifications n
     set resolved_at = now()
   where n.resolved_at is null
     and not exists (select 1 from _current c where c.dedupe_key = n.dedupe_key);

  select count(*) into n_open from public.notifications where resolved_at is null;
  return n_open;
end;
$$;

select public.generate_notifications();
