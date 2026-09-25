-- Zion Vocational Rehab CRM — one meaning for each figure on a record
--
-- From the audit (25 Sept 2026). A client's header says what has been earned
-- and not yet invoiced ("unbilled"); the cards beside it called money that had
-- not been earned at all "not invoiced", so one screen showed $560 in one
-- place and $1,460 in another for what read as the same thing. And a flat fee
-- that had been completed was told it had "no hours logged" - a flat fee has
-- none to log.
--
-- Nothing about what is due changes here; only the words each line uses.

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
   where a.client_id = p_client and a.status = 'Open'
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
     and not exists (
       select 1 from public.authorizations a
        join public.invoices i on i.auth_id = a.id
       where a.client_id = p_client and a.service_type like '%HQ Indicator%')

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
