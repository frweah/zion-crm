-- Zion Vocational Rehab CRM — 0010 durable notifications
--
-- The alert rules were computed in the app when someone opened the dashboard.
-- That means an authorization can run out of hours on a Friday and nobody
-- learns of it until Monday, and it means nothing can be emailed.
--
-- The rules move here, and here only. The dashboard reads what this produced
-- rather than recomputing it, so there is one implementation of "what needs
-- attention" and cron, the dashboard and the email digest cannot disagree.

create table public.notifications (
  id           uuid primary key default gen_random_uuid(),
  dedupe_key   text not null unique,
  kind         text not null,
  level        text not null check (level in ('bad', 'warn')),
  text         text not null,
  roles        text[] not null,
  href         text,
  client_id    uuid references public.clients(id) on delete cascade,
  staff_id     uuid references public.staff(id) on delete set null,
  created_at   timestamptz not null default now(),
  resolved_at  timestamptz,
  emailed_at   timestamptz
);
create index notifications_open_idx on public.notifications (level) where resolved_at is null;
create index notifications_roles_idx on public.notifications using gin (roles);
create index notifications_unemailed_idx on public.notifications (created_at)
  where resolved_at is null and emailed_at is null;

alter table public.notifications enable row level security;

create policy notifications_read on public.notifications
  for select to authenticated
  using (
    public.is_active_staff()
    and (public.is_admin() or public.current_staff_role() = any (roles))
  );

-- Notifications are derived, not authored: they appear and clear on their own
-- as the underlying facts change. Nobody edits them by hand.
create policy notifications_admin_write on public.notifications
  for all to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- ─────────────────────────────────────────────────────────────
-- The rules
--
-- Ported from the prototype's alerts memo. Each produces a stable dedupe_key
-- so re-running does not duplicate: an alert raised on Monday keeps its
-- original created_at all week, and clears itself once the condition passes.
-- ─────────────────────────────────────────────────────────────
create or replace function public.generate_notifications()
returns integer
language plpgsql security definer set search_path = public
as $$
declare
  n_open     integer;
  v_today    date := current_date;
  last_month text := to_char((date_trunc('month', v_today) - interval '1 day'), 'YYYY-MM');
begin
  create temporary table _current (
    dedupe_key text primary key,
    kind text, level text, text text, roles text[], href text,
    client_id uuid, staff_id uuid
  ) on commit drop;

  -- Hours used per open authorization: carried over at migration, plus every
  -- billable entry logged since.
  create temporary table _used on commit drop as
  select a.id,
         a.client_id,
         a.number,
         a.service_type,
         a.total_hours,
         a.end_date,
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
             ') is under 10% remaining (' || trim(to_char(u.total_hours - u.used, 'FM9999990.99')) || ' hrs).'
         end,
         case when u.total_hours - u.used <= 0
              then array['Admin','Billing','Job Search']
              else array['Admin','Billing'] end,
         '/clients/' || u.client_id || '?tab=authorizations',
         u.client_id,
         null
    from _used u
   where u.total_hours is not null
     and u.total_hours - u.used <= u.total_hours * 0.1;

  -- 2. Authorizations ending within a fortnight.
  insert into _current
  select 'auth_ending:' || u.id, 'auth_ending', 'warn',
         coalesce(nullif(u.number, ''), u.service_type) || ' ends ' || u.end_date ||
         ' — unbilled work after that date will not be paid.',
         array['Admin','Billing'],
         '/clients/' || u.client_id || '?tab=authorizations',
         u.client_id, null
    from _used u
   where u.end_date is not null
     and u.end_date >= v_today
     and u.end_date <= v_today + 14;

  -- 3. Invoices sent and unpaid. The bucket is in the key so 60 and 90 days
  --    each raise their own flag rather than quietly rewriting the first.
  insert into _current
  select 'invoice_unpaid:' || i.id || ':' ||
         case when v_today - i.date >= 90 then '90'
              when v_today - i.date >= 60 then '60' else '30' end,
         'invoice_unpaid',
         case when v_today - i.date >= 90 then 'bad' else 'warn' end,
         'Invoice ' || i.number || ' unpaid ' || (v_today - i.date) || ' days.',
         array['Admin','Billing'],
         '/billing?tab=invoices',
         a.client_id, null
    from public.invoices i
    join public.authorizations a on a.id = i.auth_id
   where i.status = 'Sent' and v_today - i.date >= 30;

  -- 4. Overdue tasks, to Admin and to the role the task sits with.
  insert into _current
  select 'task_overdue:' || t.id, 'task_overdue', 'warn',
         'Overdue task: ' || t.title,
         array_remove(array['Admin', s.role], null),
         '/tasks', t.client_id, t.assigned_staff_id
    from public.tasks t
    left join public.staff s on s.id = t.assigned_staff_id
   where t.status = 'Open' and t.due is not null and t.due < v_today;

  -- 5. Monthly USOR reports, due by the 15th, where there was activity to
  --    report on. Silent for a client with no activity last month.
  if extract(day from v_today) <= 15 then
    insert into _current
    select 'monthly_forms:' || u.id || ':' || last_month, 'monthly_forms', 'warn',
           missing.usors || ' for ' || last_month || ' due by the 15th — ' ||
           c.name || ' (' || coalesce(nullif(u.number, ''), u.service_type) || ')',
           array['Admin','Billing','Job Search'],
           '/clients/' || u.client_id || '?tab=forms',
           u.client_id, null
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

  -- 6. Counselor follow-ups now due, to Admin and whoever logged them.
  insert into _current
  select 'followup:' || cl.id, 'followup_due', 'warn',
         'Counselor follow-up due: ' || cl.topic,
         array_remove(array['Admin', s.role], null),
         '/counselors', cl.client_id, cl.staff_id
    from public.contact_log cl
    left join public.staff s on s.id = cl.staff_id
   where cl.follow_up is not null
     and not cl.follow_up_done
     and cl.follow_up <= v_today;

  -- ── reconcile ───────────────────────────────────────────────
  -- New conditions are inserted; ones that still hold keep their original
  -- created_at, so "unpaid since" does not reset every night; ones that no
  -- longer hold are resolved rather than deleted, leaving a history of what
  -- was flagged and when it cleared.
  insert into public.notifications
    (dedupe_key, kind, level, text, roles, href, client_id, staff_id)
  select c.dedupe_key, c.kind, c.level, c.text, c.roles, c.href, c.client_id, c.staff_id
    from _current c
  on conflict (dedupe_key) do update set
    level = excluded.level,
    text  = excluded.text,
    roles = excluded.roles,
    href  = excluded.href,
    resolved_at = null;

  update public.notifications n
     set resolved_at = now()
   where n.resolved_at is null
     and not exists (select 1 from _current c where c.dedupe_key = n.dedupe_key);

  select count(*) into n_open from public.notifications where resolved_at is null;
  return n_open;
end;
$$;

revoke execute on function public.generate_notifications() from public;
grant execute on function public.generate_notifications() to authenticated, service_role;

-- ─────────────────────────────────────────────────────────────
-- Run it nightly, so a Friday problem is waiting on Monday morning rather
-- than being noticed on Monday afternoon.
-- 13:00 UTC is 07:00 in Utah during daylight saving, 06:00 otherwise.
-- ─────────────────────────────────────────────────────────────
create extension if not exists pg_cron;

do $$
begin
  perform cron.unschedule('zion-nightly-alerts');
exception when others then
  null;
end $$;

select cron.schedule(
  'zion-nightly-alerts',
  '0 13 * * *',
  $$select public.generate_notifications()$$
);

-- Populate immediately so the table reflects reality from the moment this runs.
select public.generate_notifications();
