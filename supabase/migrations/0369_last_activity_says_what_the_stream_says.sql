-- Last activity says what the stream says (0368, and verify_last_activity).
--
-- "Last activity" is answered twice: by `client_last_activity` for one client
-- and by `client_last_activity_for` for a page of them, both reading the
-- tables underneath rather than the stream, because asking the stream for a
-- hundred clients took 309ms and this takes 9.8.
--
-- Two readings of the same question have to be kept level by hand, and 0368
-- moved one of them: the stream stopped showing a Personal note and started
-- showing recordings, reports sent and invoices raised. The suite caught it
-- within the hour - "read as Admin, 1 clients' last activity differs from
-- their feed" - which is the whole reason that assertion exists.
--
-- So the same four changes, here. What the Clients list prints in its Last
-- activity column is what somebody sees at the top of the record when they
-- open it, which is the rule, and a Personal note moves neither.

create or replace view public.client_last_activity as
select c.id as client_id, max(a.at) as last_activity_at
  from clients c
  left join (
    select n.client_id, coalesce(n.at::timestamptz, n.created_at) as at
      from notes n
     where n.category is distinct from 'Personal'
    union all
    select h.client_id, coalesce(h.at::timestamptz, h.created_at)
      from client_stage_history h
    union all
    select m.client_id,
           greatest(m.applied_on, m.interview_on, m.follow_up_on, m.decided_on)::timestamptz
      from lead_matches m
      join job_leads l on l.id = m.lead_id
    union all
    select t.client_id, t.done_at
      from tasks t
     where t.status = 'Done' and t.done_at is not null
    union all
    select f.client_id, greatest(f.completed_at, f.sent_at)
      from forms f
    union all
    select cl.client_id, cl.date::timestamptz
      from contact_log cl
     where cl.client_id is not null
    union all
    select p.client_id, greatest(p.start_date, p.check30, p.check60, p.check90)::timestamptz
      from placements p
    union all
    select au.client_id, se.date::timestamptz
      from service_entries se
      join authorizations au on au.id = se.auth_id
    union all
    select ce.client_id, ce.starts_at
      from calendar_events ce
     where ce.client_id is not null
    union all
    select ml.client_id, ml.sent_at
      from mail_log ml
     where ml.client_id is not null
    union all
    select sm.client_id, coalesce(sm.sent_at, sm.created_at)
      from sms_messages sm
     where sm.client_id is not null
    union all
    select au.client_id, coalesce(pay.warrant_date::timestamptz, pay.created_at)
      from payments pay
      join authorizations au on au.id = pay.auth_id
    -- The three the stream gained in 0368.
    union all
    select r.client_id, coalesce(r.confirmed_at, r.created_at)
      from recordings r
     where r.client_id is not null
    union all
    select cr.client_id, cr.sent_at
      from client_reports cr
     where cr.sent_at is not null
    union all
    select i.client_id, i.submitted_on::timestamptz
      from invoices i
     where i.submitted_on is not null and i.client_id is not null
  ) a on a.client_id = c.id
 group by c.id;

create or replace function public.client_last_activity_for(p_clients uuid[])
returns table(client_id uuid, last_activity_at timestamptz)
language sql
stable
set search_path to 'public'
as $function$
  select c.id, max(a.at)
    from public.clients c
    left join lateral (
      select coalesce(n.at::timestamptz, n.created_at) as at
        from public.notes n
       where n.client_id = c.id and n.category is distinct from 'Personal'
      union all
      select coalesce(h.at::timestamptz, h.created_at)
        from public.client_stage_history h where h.client_id = c.id
      union all
      select greatest(m.applied_on, m.interview_on, m.follow_up_on, m.decided_on)::timestamptz
        from public.lead_matches m
        join public.job_leads l on l.id = m.lead_id
       where m.client_id = c.id
      union all
      select t.done_at
        from public.tasks t
       where t.client_id = c.id and t.status = 'Done' and t.done_at is not null
      union all
      select greatest(f.completed_at, f.sent_at)
        from public.forms f where f.client_id = c.id
      union all
      select cl.date::timestamptz
        from public.contact_log cl where cl.client_id = c.id
      union all
      select greatest(p.start_date, p.check30, p.check60, p.check90)::timestamptz
        from public.placements p where p.client_id = c.id
      union all
      select se.date::timestamptz
        from public.service_entries se
        join public.authorizations au on au.id = se.auth_id
       where au.client_id = c.id
      union all
      select ce.starts_at
        from public.calendar_events ce where ce.client_id = c.id
      union all
      select ml.sent_at
        from public.mail_log ml where ml.client_id = c.id
      union all
      select coalesce(sm.sent_at, sm.created_at)
        from public.sms_messages sm where sm.client_id = c.id
      union all
      select coalesce(pay.warrant_date::timestamptz, pay.created_at)
        from public.payments pay
        join public.authorizations au2 on au2.id = pay.auth_id
       where au2.client_id = c.id
      union all
      select coalesce(r.confirmed_at, r.created_at)
        from public.recordings r where r.client_id = c.id
      union all
      select cr.sent_at
        from public.client_reports cr
       where cr.client_id = c.id and cr.sent_at is not null
      union all
      select i.submitted_on::timestamptz
        from public.invoices i
       where i.client_id = c.id and i.submitted_on is not null
    ) a on true
   where c.id = any(p_clients)
   group by c.id;
$function$;

alter view public.client_last_activity set (security_invoker = true);
revoke all on public.client_last_activity from anon;
grant select on public.client_last_activity to authenticated;
