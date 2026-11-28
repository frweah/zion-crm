-- Consent is asked of the consent, not of the threads board.
--
-- Tolerates the old code: one branch of next_steps changes which rows it
-- returns. Nothing a screen sends changes, and no column moves.
--
-- The engine took "nobody has recorded whether they may be texted" from
-- client_threads_board, on the principle that a rule already written down
-- once should not be written twice. It was the wrong source for this one.
--
-- The board only sees a client it has something to show for - a
-- conversation, a number in client_phones, a weekly update, a voicemail -
-- so a client whose number is on their record and was never added to the
-- numbers table is invisible to it, and the engine stopped raising their
-- missing consent. verify_record_centre has held since it was written that
-- such a client is raised, and it stopped passing.
--
-- The practice's consent rule does not live on the threads board. It lives
-- in sms_consent_events, and that is what this reads: no consent event at
-- all, and some way to reach them. The board's own nuance - which *number*
-- is consented - is a different question, and the board is still the place
-- it is answered.
--
-- A client with no number at all is not raised. They cannot be texted
-- whatever anybody records, and a line telling somebody to record consent
-- for a client who has no telephone is a line that teaches people to ignore
-- the strip.

begin;

create or replace function public.next_steps(
  p_scope text,
  p_person uuid,
  p_client uuid
)
 returns table (
   client_id uuid,
   "when" timestamptz,
   what text,
   who text,
   kind text,
   action_href text,
   severity integer,
   whose uuid
 )
 language sql
 stable
 security definer
 set search_path to 'public'
as $function$
  select * from (
    with day as (select public.practice_today() as today),
    scope_clients as (
      select c.id, c.name, c.phone,
             coalesce(sa.name, sb.name) as owner_name,
             sb.name as billing_name,
             sa.name as search_name,
             coalesce(c.assigned_staff_id, c.billing_staff_id) as owner_id,
             c.billing_staff_id as billing_id,
             c.assigned_staff_id as search_id
        from public.clients c
        left join public.staff sa on sa.id = c.assigned_staff_id
        left join public.staff sb on sb.id = c.billing_staff_id
       where c.merged_into is null
         and case p_scope
               when 'client' then p_client is not null and c.id = p_client
               when 'person' then p_person is not null
                                  and c.status = 'Active'
                                  and (c.assigned_staff_id = p_person
                                       or c.billing_staff_id = p_person)
               when 'board' then c.status = 'Active'
               when 'owner' then c.status = 'Active'
               else false
             end
    ),
    threads as (
      select t.client_id,
             max(t.waiting_hours) as waiting_hours,
             min(t.quiet_days) as quiet_days
        from public.client_threads_board() t
        join scope_clients s on s.id = t.client_id
       group by t.client_id
    ),
    live_auths as (
      select a.id, a.client_id, coalesce(nullif(a.number, ''), a.service_type) as label
        from public.authorizations a
        join scope_clients s on s.id = a.client_id
       where a.status in ('Authorized', 'Due', 'Submitted')
         and not a.is_placeholder
    )

    select s.id, now(), 'Unanswered - they spoke ' || t.waiting_hours || ' hours ago',
           s.owner_name, 'reply',
           '/clients/' || s.id || '?tab=messages', 1, s.owner_id
      from scope_clients s
      join threads t on t.client_id = s.id
     where t.waiting_hours is not null

    union all
    select s.id,
           (k.due::timestamp at time zone 'America/Denver'),
           case when k.due is null then 'Task: ' || k.title
                when k.due < (select today from day) then 'Overdue task: ' || k.title
                else 'Task: ' || k.title end,
           coalesce(ts.name, s.owner_name), 'task',
           '/clients/' || s.id || '?tab=dashboard',
           case
             when k.due is null then 4
             when k.due <= (select today from day) then 1
             when k.due <= (select today from day) + 7 then 2
             else 3
           end,
           coalesce(k.assigned_staff_id, s.owner_id)
      from scope_clients s
      join public.tasks k on k.client_id = s.id and k.status = 'Open'
      left join public.staff ts on ts.id = k.assigned_staff_id
     where p_scope <> 'person' or k.assigned_staff_id is null or k.assigned_staff_id = p_person

    union all
    select null::uuid,
           (k.due::timestamp at time zone 'America/Denver'),
           case when k.due is not null and k.due < (select today from day)
                  then 'Overdue task: ' || k.title else 'Task: ' || k.title end,
           ts.name, 'task', '/tasks',
           case
             when k.due is null then 4
             when k.due <= (select today from day) then 1
             when k.due <= (select today from day) + 7 then 2
             else 3
           end,
           k.assigned_staff_id
      from public.tasks k
      left join public.staff ts on ts.id = k.assigned_staff_id
     where k.status = 'Open' and k.client_id is null
       and (p_scope = 'owner'
            or (p_scope = 'person' and k.assigned_staff_id = p_person))

    union all
    select s.id, null::timestamptz,
           a.label || ' - ' || t.attention,
           s.billing_name, 'authorization',
           '/billing/authorizations/' || a.id,
           case
             when t.urgency <= 1 then 1
             when t.urgency <= 3 then 2
             when t.urgency <= 6 then 3
             else 4
           end,
           s.billing_id
      from scope_clients s
      join live_auths a on a.client_id = s.id
      join public.authorization_attention_for(
             array(select id from live_auths), (select today from day)) t on t.auth_id = a.id
     where coalesce(t.attention, '') <> ''

    union all
    select s.id, null::timestamptz,
           p.usor || ' needed - ' || p.form_name
             || coalesce(' for ' || p.month, '')
             || ' - ' || trim(to_char(p.hours_logged, 'FM999990.9')) || ' hours logged',
           s.billing_name, 'form',
           '/billing/report?client=' || s.id, 2, s.billing_id
      from scope_clients s
      join public.client_paperwork p on p.client_id = s.id
     where p.state = 'Missing'

    union all
    select s.id, n.at,
           'Appointment - ' || n.title, s.owner_name, 'appointment',
           '/clients/' || s.id || '?tab=dashboard',
           case when n.at < now() + interval '24 hours' then 1 else 3 end,
           s.owner_id
      from scope_clients s
      join public.client_next_up n on n.client_id = s.id and n.kind = 'Appointment'

    union all
    select s.id, (g.follow_up::timestamp at time zone 'America/Denver'),
           'Counselor follow-up due: ' || coalesce(nullif(g.topic, ''), 'no topic recorded'),
           coalesce(gs.name, s.owner_name), 'followup',
           '/clients/' || s.id || '?tab=notes', 1, coalesce(g.staff_id, s.owner_id)
      from scope_clients s
      join public.contact_log g on g.client_id = s.id
      left join public.staff gs on gs.id = g.staff_id
     where g.follow_up is not null and not g.follow_up_done
       and g.follow_up <= (select today from day)

    union all
    select s.id, (m.interview_on::timestamp at time zone 'America/Denver'),
           'Interview - ' || coalesce(e.name, l.title, 'a job'),
           s.search_name, 'interview',
           '/clients/' || s.id || '?tab=jobs', 2, s.search_id
      from scope_clients s
      join public.lead_matches m on m.client_id = s.id
      join public.job_leads l on l.id = m.lead_id
      left join public.employers e on e.id = l.employer_id
     where m.interview_on between (select today from day) and (select today from day) + 7

    union all
    select s.id, null::timestamptz,
           'Fifth shift reached - '
             || coalesce(nullif(pl.employer, ''), 'the placement')
             || ' - USOR 92 and the placement bill are due',
           s.billing_name, 'placement',
           '/billing/report?client=' || s.id, 2, s.billing_id
      from scope_clients s
      join public.placements pl on pl.client_id = s.id
     where pl.fifth_shift_on is not null
       and not exists (
         select 1 from public.forms f
          join public.authorizations a on a.id = f.auth_id
         where f.client_id = s.id and f.template_id = 'usor92'
           and f.status <> 'Draft' and a.service_type like 'Job Placement%')

    union all
    select s.id, null::timestamptz,
           'Thirty days of stability - '
             || coalesce(nullif(pl.employer, ''), 'the placement')
             || coalesce(' - ' || nullif(pl.stability_basis, ''), '')
             || ' - High Quality Indicators may be billed',
           s.billing_name, 'stability',
           '/clients/' || s.id || '?tab=billing', 2, s.billing_id
      from scope_clients s
      join public.placements pl on pl.client_id = s.id
     where pl.stability_on is not null
       and pl.stability_on + 30 <= (select today from day)
       and not exists (
         select 1 from public.authorizations a
         where a.client_id = s.id
           and a.service_type like '%HQ Indicator%'
           and a.status in ('Submitted', 'Paid'))

    union all
    select s.id, ((pl.start_date + d.days)::timestamp at time zone 'America/Denver'),
           d.label || ' check due - ' || coalesce(nullif(pl.employer, ''), 'a placement'),
           s.search_name, 'retention',
           '/clients/' || s.id || '?tab=jobs', 2, s.search_id
      from scope_clients s
      join public.placements pl on pl.client_id = s.id
      cross join lateral (values
        (pl.check30, 30, '30 day'), (pl.check60, 60, '60 day'), (pl.check90, 90, '90 day')
      ) d(done, days, label)
     where pl.start_date is not null and d.done is null
       and pl.start_date + d.days <= (select today from day)

    union all
    -- Nobody has recorded whether they agreed to be texted, and there is a
    -- number to text. Read from the consent itself: the threads board only
    -- sees a client it has something to show for, so a number that lives on
    -- the record and never reached client_phones was invisible to it.
    select s.id, null::timestamptz,
           'Texting consent not recorded - they cannot be texted until it is',
           s.owner_name, 'consent',
           '/clients/' || s.id || '?tab=profile#texting', 3, s.owner_id
      from scope_clients s
     where not exists (select 1 from public.sms_consent_events e where e.client_id = s.id)
       and (nullif(btrim(coalesce(s.phone, '')), '') is not null
            or exists (select 1 from public.client_phones p where p.client_id = s.id))

    union all
    select s.id, null::timestamptz,
           case when t.quiet_days is null then 'Nothing recorded with them at all'
                else 'Quiet ' || t.quiet_days || ' days' end,
           s.owner_name, 'quiet',
           '/clients/' || s.id || '?tab=dashboard', 3, s.owner_id
      from scope_clients s
      join threads t on t.client_id = s.id
     where t.quiet_days is null or t.quiet_days >= 14
  ) as rows_for_staff
   where public.reader_may_answer();
$function$;

commit;
