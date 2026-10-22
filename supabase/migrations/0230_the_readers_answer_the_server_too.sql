-- Zion Vocational Rehab CRM — 0230 the readers answer the server too
--
-- 0226 guarded twenty-three staff-only readers with `is_active_staff()`, and
-- that predicate is wrong in one important way: it is false for the server
-- itself. The nightly sweep, the cron routes and every server action that
-- uses the admin client run as the service role with nobody signed in, and
-- they call these readers. So did fifteen verification scripts, which is how
-- this was found about four minutes after it was written rather than in
-- production a fortnight later.
--
-- The question a reader has to ask is not "are you staff" but "are you an
-- end user who is not staff". A request with no identity at all is the
-- server; a request carrying the service role is the server acting as
-- itself; a request carrying a signed-in user is a person, and a person has
-- to be staff. `reader_may_answer()` says exactly that, in one place.

/**
 * May this reader answer the caller?
 *
 * Three cases, and only the third is a judgement:
 *   no claims at all  - a migration, a sweep, psql. The server.
 *   the service role  - the server acting as itself through PostgREST.
 *   a signed-in user  - a person, and only staff are let through. A client
 *                       with a portal login is signed in and is not staff.
 */
create or replace function public.reader_may_answer()
returns boolean language sql stable set search_path = public as $$
  select case coalesce(
           nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', '')
         when ''             then true
         when 'service_role' then true
         else public.is_active_staff()
         end;
$$;

comment on function public.reader_may_answer is
  'Whether a staff-only reader may answer: yes to the server, yes to staff, no to anybody else signed in (0230).';

revoke all on function public.reader_may_answer() from anon;
grant execute on function public.reader_may_answer() to authenticated;

-- authorization_attention
CREATE OR REPLACE FUNCTION public.authorization_attention(p_auth uuid, p_today date DEFAULT NULL::date)
 RETURNS TABLE(attention text, urgency integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select * from (
    select f.attention, f.urgency
        from public.authorization_attention_for(array[p_auth], p_today) f
  ) as rows_for_staff
   where public.reader_may_answer();
$function$;

-- authorization_attention_for
CREATE OR REPLACE FUNCTION public.authorization_attention_for(p_auths uuid[], p_today date DEFAULT NULL::date)
 RETURNS TABLE(auth_id uuid, attention text, urgency integer, blocked boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select * from (
    with me as (select coalesce(p_today, public.practice_today()) as today),
      settings as (
        select stale_grace_days, stale_soon_days from public.org_settings where id
      ),
      r as (
        select a.id,
               a.status, a.bill_by, a.stale_date, a.submitted_on, a.followup_due,
               coalesce(p.total_hours, a.total_hours) as authorized,
               u.used,
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
               a.status = 'Submitted'
                 and ((a.followup_due is not null and a.followup_due <= (select today from me))
                      or (a.submitted_on is not null
                          and (select today from me) - a.submitted_on >= 14)) as needs_chasing,
               a.stale_date is not null and a.status not in ('Submitted', 'Paid')
                 and a.stale_date >= (select today from me)
                 and a.stale_date <= (select today from me) + (select stale_soon_days from settings)
                 as stale_soon
          from public.authorizations a
          left join public.authorizations p on p.id = a.parent_id
          left join public.authorization_hours_used(p_auths) u on u.auth_id = a.id
         where a.id = any(p_auths)
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
      select h.id,
             case
               when h.is_blocked then 'Cannot be submitted - ended ' || h.stale_date
                                      || ', more than ' || (select stale_grace_days from settings)
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
             end,
             -- The same `is_blocked` the first branch above is chosen by, said
             -- plainly so a screen never has to read the sentence to know.
             coalesce(h.is_blocked, false)
        from h
  ) as rows_for_staff
   where public.reader_may_answer();
$function$;

-- authorization_can_submit
CREATE OR REPLACE FUNCTION public.authorization_can_submit(p_auth uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select case when public.reader_may_answer() then (
    select not exists (
        select 1 from public.authorization_gate(p_auth) g
         where g.blocking and not coalesce(g.passed, false))
  ) end;
$function$;

-- authorization_entries
CREATE OR REPLACE FUNCTION public.authorization_entries(p_auth uuid)
 RETURNS SETOF service_entries
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select * from (
    select e.*
        from public.service_entries e
       where e.auth_id = p_auth
          or (exists (select 1 from public.authorizations p
                       where p.id = p_auth and p.parent_id is null)
              and e.auth_id in (select id from public.authorizations where parent_id = p_auth))
  ) as rows_for_staff
   where public.reader_may_answer();
$function$;

-- authorization_gate_met
CREATE OR REPLACE FUNCTION public.authorization_gate_met(p_auth uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select case when public.reader_may_answer() then (
    select not exists (
        select 1 from public.authorization_gate(p_auth) g where not coalesce(g.passed, false))
  ) end;
$function$;

-- authorization_is_coaching
CREATE OR REPLACE FUNCTION public.authorization_is_coaching(p_auth uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select case when public.reader_may_answer() then (
    select exists (
        select 1 from public.authorizations a
         where a.id = p_auth and a.service_type like 'Job Coaching%'
      )
  ) end;
$function$;

-- authorization_missing_forms
CREATE OR REPLACE FUNCTION public.authorization_missing_forms(p_auth uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select case when public.reader_may_answer() then (
    select string_agg(t.usor, ' + ' order by t.sort_order)
        from public.authorizations a
        join public.form_templates t
          on t.required_for_billing and a.service_type = any (t.services)
       where a.id = p_auth
         and not exists (
           select 1 from public.forms f
            where f.auth_id = a.id and f.template_id = t.id and f.status <> 'Draft')
         and not exists (
           select 1 from public.attachments x
            where x.auth_id = a.id and x.category = 'Signed USOR form')
  ) end;
$function$;

-- authorizations_ending_soon
CREATE OR REPLACE FUNCTION public.authorizations_ending_soon(p_today date DEFAULT NULL::date)
 RETURNS TABLE(auth_id uuid, client_id uuid, client_name text, auth_number text, service_type text, end_date date, days_left integer, hours_left numeric, counselor_name text, counselor_email text, body text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select * from (
    with today as (select coalesce(p_today, public.practice_today()) as d)
      select e.auth_id, e.client_id, c.name, e.auth_number, e.service_type, e.end_date,
             e.end_date - (select d from today) as days_left,
             e.hours_left,
             coalesce(co.name, ''), coalesce(co.email, ''),
             format(
               'Hi %s — %s''s authorization %s for %s runs to %s. %s Could we arrange a renewal so the work can continue? Thank you.',
               coalesce(nullif(split_part(btrim(coalesce(co.name, '')), ' ', 1), ''), 'there'),
               c.name,
               coalesce(nullif(btrim(e.auth_number), ''), '(no number)'),
               e.service_type,
               to_char(e.end_date, 'FMDD FMMonth YYYY'),
               case when e.hours_left is not null
                    then format('There are %s hours left on it.', public.fmt_hours(e.hours_left))
                    else 'The service is not yet submitted.' end
             ) as body
        from public.authorization_economics e
        join public.clients c on c.id = e.client_id
        left join public.counselors co on co.id = c.counselor_id
       where e.end_date is not null
         and e.end_date - (select d from today) between 0 and 30
         and e.status not in ('Paid', 'Closed', 'Submitted')
         and c.status <> 'Closed'
         and not exists (select 1 from public.authorizations p where p.parent_id = e.auth_id)
         and (
           (e.rate_type = 'Hourly' and coalesce(e.hours_left, 0) > 0)
           or (e.rate_type = 'Flat Fee' and e.status <> 'Submitted')
         )
       order by e.end_date, c.name
  ) as rows_for_staff
   where public.reader_may_answer();
$function$;

-- billing_needs_action
CREATE OR REPLACE FUNCTION public.billing_needs_action(p_today date DEFAULT NULL::date)
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select case when public.reader_may_answer() then (
    select count(*)::int from public.billing_worklist(p_today) w where coalesce(w.attention, '') <> ''
  ) end;
$function$;

-- billing_office_reconciliation
CREATE OR REPLACE FUNCTION public.billing_office_reconciliation(p_billing_office uuid, p_within_days integer DEFAULT 30)
 RETURNS TABLE(kind text, client_id uuid, client_name text, counselor_id uuid, counselor_name text, counselor_email text, auth_id uuid, auth_number text, service text, amount numeric, sent_on date, days_outstanding integer, end_date date, unbilled numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select * from (
    select 'unpaid'::text, c.id, c.name, k.id, k.name, nullif(trim(k.email), ''),
             a.id, coalesce(nullif(a.number, ''), p.number, ''), a.service_type,
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
      select 'ending'::text, c.id, c.name, k.id, k.name, nullif(trim(k.email), ''),
             a.id, a.number, a.service_type,
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
  ) as rows_for_staff
   where public.reader_may_answer();
$function$;

-- can_staff_see_restricted
CREATE OR REPLACE FUNCTION public.can_staff_see_restricted(p_staff uuid, p_client uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select case when public.reader_may_answer() then (
    select exists (
        select 1 from public.staff s
          left join public.clients c on c.id = p_client
         where s.id = p_staff and s.active
           and (s.role in ('Admin', 'Reports') or c.assigned_staff_id = s.id))
  ) end;
$function$;

-- client_next_actions
CREATE OR REPLACE FUNCTION public.client_next_actions(p_client uuid)
 RETURNS TABLE(kind text, title text, detail text, href text, urgency integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select * from (
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
    
      order by 5, 1
  ) as rows_for_staff
   where public.reader_may_answer();
$function$;

-- client_next_actions_for
CREATE OR REPLACE FUNCTION public.client_next_actions_for(p_clients uuid[])
 RETURNS TABLE(client_id uuid, kind text, title text, detail text, href text, urgency integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select * from (
    select c.id, a.kind, a.title, a.detail, a.href, a.urgency
        from unnest(coalesce(p_clients, '{}'::uuid[])) as c(id)
        cross join lateral public.client_next_actions(c.id) a
  ) as rows_for_staff
   where public.reader_may_answer();
$function$;

-- hqi_for_placement
CREATE OR REPLACE FUNCTION public.hqi_for_placement(p_placement uuid)
 RETURNS TABLE(key text, label text, met boolean, detail text, amount numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select * from (
    with p as (
        select pl.*,
               nullif(pl.stability_basis, '') as basis
          from public.placements pl
         where pl.id = p_placement
      ),
      -- The job development authorization this placement followed, for the
      -- sixty-day test. The earliest one: development starts once.
      dev as (
        select min(a.start_date) as started
          from public.authorizations a
          join p on p.client_id = a.client_id
         where a.service_type like 'Job Development%'
      )
      select 'hours', 'Hours',
             case when p.basis is null or p.hours_week is null then null
                  when p.basis = 'SJBT' then p.hours_week >= 30
                  else p.hours_week >= 20 end,
             case when p.basis is null then 'Which stability rule applies has not been recorded'
                  when p.hours_week is null then 'No hours a week on the placement'
                  else p.hours_week || ' hrs/wk · ' || p.basis || ' asks for '
                       || (case when p.basis = 'SJBT' then '30' else '20' end) end,
             560
        from p
    
      union all
      select 'wages', 'Wages',
             case when p.basis is null or p.wage is null then null
                  when p.basis = 'SJBT' then p.wage >= 14
                  else p.wage >= 10 end,
             case when p.basis is null then 'Which stability rule applies has not been recorded'
                  when p.wage is null then 'No wage on the placement'
                  else '$' || trim(to_char(p.wage, 'FM999990.00')) || '/hr · ' || p.basis || ' asks for $'
                       || (case when p.basis = 'SJBT' then '14' else '10' end) end,
             560
        from p
    
      union all
      select 'benefits', 'Benefits', p.employer_benefits,
             case when p.employer_benefits is null then 'Nobody has answered whether the employer pays health benefits'
                  when p.employer_benefits then 'The employer pays health benefits'
                  else 'The employer does not pay health benefits' end,
             560
        from p
    
      union all
      select 'days', 'Days to placement',
             case when d.started is null or p.start_date is null then null
                  else p.start_date - d.started <= 60 end,
             case when d.started is null then 'No job development authorization to measure from'
                  when p.start_date is null then 'No start date on the placement'
                  else (p.start_date - d.started) || ' days from the development authorization · 60 or fewer qualifies' end,
             560
        from p cross join dev d
    
      union all
      select 'stem', 'STEM', p.stem_occupation,
             case when p.stem_occupation is null then 'Nobody has answered whether O*NET lists this as STEM'
                  when p.stem_occupation then 'O*NET lists the occupation as STEM'
                  else 'O*NET does not list the occupation as STEM' end,
             560
        from p
    
      union all
      select 'rural', 'Rural', p.rural_client,
             case when p.rural_client is null then 'Nobody has answered whether the client lives rurally'
                  when p.rural_client then 'The client lives in a rural area'
                  else 'The client does not live in a rural area' end,
             560
        from p
  ) as rows_for_staff
   where public.reader_may_answer();
$function$;

-- hqi_total
CREATE OR REPLACE FUNCTION public.hqi_total(p_placement uuid)
 RETURNS TABLE(met integer, unanswered integer, total numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select * from (
    select count(*) filter (where i.met)::integer,
             count(*) filter (where i.met is null)::integer,
             coalesce(sum(i.amount) filter (where i.met), 0)
        from public.hqi_for_placement(p_placement) i
  ) as rows_for_staff
   where public.reader_may_answer();
$function$;

-- intake_scans_now_readable
CREATE OR REPLACE FUNCTION public.intake_scans_now_readable()
 RETURNS TABLE(document_id uuid, message_id text, from_address text, subject text, received_at timestamp with time zone, sha256 text, ocr_text text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select * from (
    select d.id, m.message_id, m.from_address, m.subject, m.received_at, d.sha256, d.ocr_text
        from public.intake_mail m
        join public.inbox_documents d on d.id = m.document_id
       where m.decision = 'unreadable'
         and m.client_id is null
         and coalesce(d.ocr_text, '') <> ''
       order by m.received_at
       limit 20
  ) as rows_for_staff
   where public.reader_may_answer();
$function$;

-- referral_received_on
CREATE OR REPLACE FUNCTION public.referral_received_on(p_client uuid)
 RETURNS date
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select case when public.reader_may_answer() then (
    select least(
        coalesce((select min(l.date) from public.contact_log l
                   where l.client_id = p_client and l.topic = 'Referral received'), 'infinity'::date),
        coalesce((select min(h.at)::date from public.client_stage_history h
                   where h.client_id = p_client and h.stage = 'Intake'), 'infinity'::date),
        coalesce((select c.created_at::date from public.clients c where c.id = p_client), 'infinity'::date)
      )
  ) end;
$function$;

-- referrals_without_authorization
CREATE OR REPLACE FUNCTION public.referrals_without_authorization(p_today date DEFAULT NULL::date)
 RETURNS TABLE(client_id uuid, client_name text, counselor_id uuid, counselor_name text, counselor_email text, received_on date, days_waiting integer, nth integer, send boolean, body text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select * from (
    with today as (select coalesce(p_today, public.practice_today()) as d),
      waiting as (
        select c.id, c.name, c.counselor_id, co.name as counselor_name, co.email as counselor_email,
               public.referral_received_on(c.id) as received_on,
               (select d from today) - public.referral_received_on(c.id) as days_waiting
          from public.clients c
          left join public.counselors co on co.id = c.counselor_id
         where c.stage = 'Intake'
           and c.status = 'Active'
           and c.merged_into is null
           and not exists (
             select 1 from public.authorizations a
              where a.client_id = c.id and a.parent_id is null
           )
      )
      select w.id, w.name, w.counselor_id, coalesce(w.counselor_name, ''), coalesce(w.counselor_email, ''),
             w.received_on, w.days_waiting,
             case when w.days_waiting >= 14 then 2 else 1 end as nth,
             -- Sent on the seventh and the fourteenth day only, and only once each.
             (w.days_waiting in (7, 14)
              and coalesce(w.counselor_email, '') <> ''
              and not exists (
                select 1 from public.chase_sent s
                 where s.rule = 'referral nudge' and s.client_id = w.id
                   and s.nth = case when w.days_waiting >= 14 then 2 else 1 end
              )) as send,
             format(
               'Hi %s — we received %s''s referral on %s and wanted to check whether an authorization is on its way. Thank you.',
               coalesce(nullif(split_part(btrim(coalesce(w.counselor_name, '')), ' ', 1), ''), 'there'),
               w.name,
               to_char(w.received_on, 'FMDD FMMonth YYYY')
             ) as body
        from waiting w
       where w.days_waiting >= 7
       order by w.days_waiting desc, w.name
  ) as rows_for_staff
   where public.reader_may_answer();
$function$;

-- service_rate
CREATE OR REPLACE FUNCTION public.service_rate(p_service text)
 RETURNS TABLE(fee numeric, rate_type text, basis text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select * from (
    select max(r.fee),
             case when max(r.unit) = 'per hour' then 'Hourly' else 'Flat Fee' end,
             'The rate schedule: ' || max(r.service)
               || case when count(*) > 1 then format(' (%s rows, all %s)', count(*), max(r.fee))
                       else coalesce(', ' || max(r.sub), '') end
        from public.rate_schedule r
       where r.crm_service = p_service
         and (r.effective_from is null or r.effective_from <= public.practice_today())
         and (r.effective_to is null or r.effective_to >= public.practice_today())
      having count(*) > 0
  ) as rows_for_staff
   where public.reader_may_answer();
$function$;

-- staff_by_email
CREATE OR REPLACE FUNCTION public.staff_by_email(p_address text)
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select case when public.reader_may_answer() then (
    select s.id from public.staff s
       where lower(s.email) = lower(btrim(coalesce(p_address, '')))
         and btrim(coalesce(p_address, '')) <> ''
      union all
      select e.staff_id from public.staff_emails e
       where lower(e.address) = lower(btrim(coalesce(p_address, '')))
         and btrim(coalesce(p_address, '')) <> ''
      limit 1
  ) end;
$function$;

-- staff_day_summary
CREATE OR REPLACE FUNCTION public.staff_day_summary(p_day_id uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select case when public.reader_may_answer() then (
    with d as (
        select sd.*, s.name as staff_name, m.name as manager_name
          from public.staff_days sd
          join public.staff s on s.id = sd.staff_id
          left join public.staff m on m.id = sd.manager_id
         where sd.id = p_day_id
      ),
      lines as (
        select l.status, l.description, l.notes, c.name as client_name, l.sort_order, l.created_at
          from public.staff_day_lines l
          left join public.clients c on c.id = l.client_id
         where l.day_id = p_day_id
      )
      select concat_ws(E'\n',
        'END OF THE DAY REPORT',
        '',
        'Name of the Employee: ' || d.staff_name,
        'Department/Agency: ' || coalesce(nullif(d.role_at_time, ''), '-'),
        'Date Prepared: ' || to_char(d.day, 'FMMonth FMDD, YYYY'),
        'Assigned Manager/Team Leader: ' || coalesce(d.manager_name, '-'),
        '',
        'TASKS LIST',
        coalesce((
          select string_agg(
                   '- [' || l.status || '] ' || l.description
                   || case when l.client_name is not null then ' (' || l.client_name || ')' else '' end
                   || case when nullif(l.notes, '') is not null then E'\n    ' || l.notes else '' end,
                   E'\n' order by l.sort_order, l.created_at)
            from lines l), '- nothing recorded'),
        '',
        'BOTTLENECKS',
        coalesce(nullif(d.bottlenecks, ''), 'None.'),
        '',
        'ACTIONS TAKEN/SUGGESTIONS',
        coalesce(nullif(d.actions_taken, ''), 'None.')
      )
      from d
  ) end;
$function$;

-- web_chat_live
CREATE OR REPLACE FUNCTION public.web_chat_live()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select case when public.reader_may_answer() then (
    select o.web_chat_enabled
         and extract(isodow from public.practice_now())::integer = any (o.web_chat_days)
         and public.practice_now()::time between o.web_chat_open and o.web_chat_close
         and exists (select 1 from public.web_chat_takers_online())
        from public.org_settings o
  ) end;
$function$;

-- work_categories_for
CREATE OR REPLACE FUNCTION public.work_categories_for(p_role text)
 RETURNS TABLE(key text, label text, detail text, billable boolean, sort_order integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select * from (
    select c.key, c.label, c.detail, c.billable, c.sort_order
        from public.work_categories c
       where c.active
         and (p_role = 'Admin' or cardinality(c.roles) = 0 or p_role = any (c.roles))
       order by c.sort_order, c.label
  ) as rows_for_staff
   where public.reader_may_answer();
$function$;

-- authorization_is_coaching comes back out of the wrapper.
--
-- It is used inside the RLS policy on service_entries, and a policy helper
-- cannot carry a gate of its own: the policy already decides who the rule
-- applies to, and a second rule inside the helper can only disagree with it.
-- Wrapped, it returned null instead of false whenever its own gate said no,
-- and a null in a policy is a refusal - so a Job Coach could not log coaching
-- hours.
--
-- There is nothing to protect here anyway. It answers whether a service type
-- begins with "Job Coaching", for an authorization id the caller already has.
create or replace function public.authorization_is_coaching(p_auth uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.authorizations a
     where a.id = p_auth and a.service_type like 'Job Coaching%'
  )
$$;

-- And it goes back to volatile, which is not an oversight in the original.
--
-- 0225 marked authorization_is_coaching STABLE on the grounds that it only
-- reads. It does only read - and it is called from the WITH CHECK on
-- service_entries, after a BEFORE trigger has routed the entry to that
-- month's authorization, creating that authorization in the same statement.
-- A STABLE function uses the statement's snapshot and cannot see a row the
-- statement itself has just made; a VOLATILE one takes a fresh one and can.
--
-- So marked STABLE it answered false for a month that exists, the policy
-- refused, and a Job Coach could not log coaching hours. The volatility was
-- load-bearing.
create or replace function public.authorization_is_coaching(p_auth uuid)
returns boolean language sql volatile security definer set search_path = public as $$
  select exists (
    select 1 from public.authorizations a
     where a.id = p_auth and a.service_type like 'Job Coaching%'
  )
$$;
