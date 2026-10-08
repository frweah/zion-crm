-- Zion Vocational Rehab CRM — one alert per record
-- (Billing Simplification Brief §13.11)
--
-- "Overdue, stale, follow-up, hours-low collapse into a single line on the
-- record and one dashboard count; never four alerts for one authorization."
--
-- The record already shows one line, and the working list shows one column -
-- both from authorization_attention(). The alerts did not: there were three
-- separate kinds raised per authorization, and one authorization ending soon
-- with its hours nearly gone raised two of them. Somebody clearing their
-- notifications would see the same piece of work twice and have no way to know
-- it was once.
--
-- So the alert reads the same function as the record and the list. And because
-- it does, hours-low has to be in that function - it is one of the four §13.11
-- names, and the one that was missing.
--
-- Adding it moves the urgency numbers. Running out of hours sits just below
-- "cannot be submitted", because it is the one of these that means stop
-- serving somebody rather than get on with billing; running low sits under
-- overdue. Everything else shifts down by one, and the two places in the app
-- that colour a row by urgency shift with it.

-- ── the attention line, with the hours on it ──

create or replace function public.authorization_attention(p_auth uuid, p_today date default null)
returns table (attention text, urgency integer)
language sql stable security definer set search_path = public as $$
  with me as (select coalesce(p_today, public.practice_today()) as today),
  r as (
    select a.status, a.bill_by, a.stale_date, a.submitted_on, a.followup_due,
           -- The hours, counted across a coaching parent and all its months,
           -- as the alert used to count them.
           coalesce(p.total_hours, a.total_hours) as authorized,
           coalesce(p.carried_used, a.carried_used, 0) + coalesce(
             (select sum(e.hours) from public.service_entries e
               join public.authorizations c on c.id = e.auth_id
              where (c.id = coalesce(a.parent_id, a.id)
                     or c.parent_id = coalesce(a.parent_id, a.id))
                and not e.non_billable), 0) as used,
           public.authorization_blocked_from(a.stale_date) is not null
             and public.authorization_blocked_from(a.stale_date) < (select today from me)
             and a.status not in ('Submitted', 'Paid') as is_blocked,
           a.stale_date is not null and a.stale_date < (select today from me)
             and (public.authorization_blocked_from(a.stale_date) is null
                  or public.authorization_blocked_from(a.stale_date) >= (select today from me))
             and a.status not in ('Submitted', 'Paid') as is_expired,
           a.stale_date is null and a.status not in ('Submitted', 'Paid') as no_end_date,
           a.bill_by is not null and a.bill_by < (select today from me)
             and a.status in ('Authorized', 'Due') as is_overdue,
           -- Chased on the submission's own age as well as on the follow-up
           -- date. The date is set when the status moves, so it is normally
           -- there - but an authorization submitted ninety days ago with no
           -- follow-up date would otherwise be chased by nobody, and the
           -- alert this replaced keyed off the submission date rather than a
           -- column derived from it.
           a.status = 'Submitted'
             and ((a.followup_due is not null and a.followup_due <= (select today from me))
                  or (a.submitted_on is not null
                      and (select today from me) - a.submitted_on >= 14)) as needs_chasing,
           a.stale_date is not null and a.status not in ('Submitted', 'Paid')
             and a.stale_date >= (select today from me)
             and a.stale_date <= (select today from me)
               + (select stale_soon_days from public.org_settings where id) as stale_soon
      from public.authorizations a
      left join public.authorizations p on p.id = a.parent_id
     where a.id = p_auth
  ),
  h as (
    select r.*,
           r.authorized is not null and r.authorized - r.used <= 0
             and r.status not in ('Paid', 'Closed') as out_of_hours,
           r.authorized is not null and r.authorized - r.used > 0
             and r.authorized - r.used <= r.authorized * 0.1
             and r.status not in ('Paid', 'Closed') as hours_low
      from r
  )
  select case
           when h.is_blocked then 'Cannot be submitted - ended ' || h.stale_date
                                  || ', more than ' || (select stale_grace_days from public.org_settings where id)
                                  || ' days ago'
           when h.out_of_hours then 'No hours left - request more before any further service'
           when h.needs_chasing then 'Submitted ' || h.submitted_on || ', no payment after 14 days'
           when h.is_overdue then 'Overdue - meant to be billed by ' || h.bill_by
           when h.hours_low then 'Under a tenth of the hours left ('
                                  || public.fmt_hours(h.authorized - h.used) || ' of '
                                  || public.fmt_hours(h.authorized) || ')'
           when h.is_expired then 'Past its end date (' || h.stale_date || ') - can still be submitted until '
                                  || public.authorization_blocked_from(h.stale_date)
           when h.stale_soon then 'Ends ' || h.stale_date
           when h.no_end_date then 'No end date on the authorization'
           when h.status = 'Due' then 'Due to be billed'
           else ''
         end,
         case
           when h.is_blocked then 0
           when h.out_of_hours then 1
           when h.needs_chasing then 2
           when h.is_overdue then 3
           when h.hours_low then 4
           when h.is_expired then 5
           when h.stale_soon then 6
           when h.no_end_date then 7
           when h.status = 'Due' then 8
           else 9
         end
    from h;
$$;

comment on function public.authorization_attention is
  'The one thing worth saying about an authorization, and how pressing (§13.11). Read by the working list, the record and the alerts, so none of the three can tell a different story about the same work.';

revoke all on function public.authorization_attention(uuid, date) from anon, authenticated;
grant execute on function public.authorization_attention(uuid, date) to authenticated;

-- ── and the alerts that read it ──

create or replace function public.generate_notifications_on(p_today date)
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
     and a.parent_id is null
     -- A kept placeholder is history, not work (§9). It is off the working
     -- list, so it has no business raising an alert either.
     and not a.is_placeholder;

  /**
   * 1. One alert per authorization (§13.11).
   *
   * There were three: out of hours, ending soon, and submitted-and-unpaid -
   * and one authorization could raise two of them at once, which is the
   * "never four alerts for one authorization" §13.11 is about. They are one
   * now, and the line it carries is authorization_attention(): the same
   * sentence the record shows at the top and the working list shows in its
   * last column, so the alert, the list and the record cannot tell somebody
   * three different stories about the same piece of work.
   *
   * The dedupe key carries the urgency, so an alert that gets worse replaces
   * itself rather than sitting at its old level.
   *
   * Who sees it: Admin and Billing, and Job Search too when an authorization
   * has run out of hours - because that is the one of these that is about
   * whether to keep serving somebody, not about billing.
   */
  insert into _current
  select 'authorization:' || u.id || ':' || t.urgency,
         'authorization',
         case when t.urgency <= 3 then 'bad' else 'warn' end,
         coalesce(nullif(u.number, ''), u.service_type) || ' - ' || t.attention,
         case when t.urgency = 1 then array['Admin','Billing','Job Search']
              else array['Admin','Billing'] end,
         '/billing/authorizations/' || u.id,
         u.client_id, null
    from _used u
   cross join lateral public.authorization_attention(u.id) t
   where coalesce(t.attention, '') <> '';

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
           missing.usors || ' for ' || last_month || ' due by the 15th â€” ' ||
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

  -- â”€â”€ 7. A foreign contractor with no W-8BEN on file â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  insert into _current
  select 'w8ben_missing:' || s.id, 'w8ben_missing', 'warn',
         s.name || ' is a foreign person with no W-8BEN on file. One is needed before payment.',
         array['Admin'], '/staff', null, s.id
    from public.staff s
    join public.contractor_profiles p on p.staff_id = s.id
   where s.active and p.tax_status = 'Foreign person' and p.w8ben_received_on is null;

  -- â”€â”€ 8. A W-8BEN expiring, or already expired â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  --      Valid through the last day of the third succeeding calendar year;
  --      60 days' notice is enough to get a fresh one signed and returned.
  insert into _current
  select 'w8ben_expiry:' || s.id || ':' || to_char(p.w8ben_expires_on, 'YYYY'),
         case when p.w8ben_expires_on < v_today then 'w8ben_expired' else 'w8ben_expiring' end,
         case when p.w8ben_expires_on < v_today then 'bad' else 'warn' end,
         case when p.w8ben_expires_on < v_today
              then s.name || '''s W-8BEN expired on ' || p.w8ben_expires_on || '. A new one is needed.'
              else s.name || '''s W-8BEN expires ' || p.w8ben_expires_on || ' â€” ask for a new one.'
         end,
         array['Admin'], '/staff', null, s.id
    from public.staff s
    join public.contractor_profiles p on p.staff_id = s.id
   where s.active
     and p.tax_status = 'Foreign person'
     and p.w8ben_expires_on is not null
     and p.w8ben_expires_on <= v_today + 60;

  -- â”€â”€ 9. January: the threshold the CPA confirms â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  if in_season then
    select federal_threshold into v_threshold from public.tax_years where year = tax_year;

    if v_threshold is null then
      insert into _current values (
        'tax_threshold:' || tax_year, 'tax_threshold_unconfirmed', 'warn',
        'Confirm the ' || tax_year || ' federal 1099-NEC threshold with your CPA, and whether Utah requires a state copy. Nothing can be generated until it is entered.',
        array['Admin'], '/staff?tab=tax', null, null);
    else
      -- â”€â”€ 10. January: the run itself â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
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
               then 'Past the 15 January target â€” recipient copies and filing are due by 31 January.'
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

  -- â”€â”€ whose alert it is â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  -- A client's billing alerts are addressed to whoever bills for them
  -- (0121), and the rest of a client's to whoever works their job search.
  -- The roles above are unchanged: this says who it is for, not who may see
  -- it, so nothing is hidden from Admin or from Billing at large.
  update _current c
     set staff_id = coalesce(
           case when c.kind in ('authorization', 'monthly_forms')
                then cl.billing_staff_id else cl.assigned_staff_id end,
           cl.assigned_staff_id)
    from public.clients cl
   where cl.id = c.client_id and c.staff_id is null;

  -- â”€â”€ reconcile â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
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
