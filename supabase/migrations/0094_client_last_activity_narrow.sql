-- Zion Vocational Rehab CRM — "last activity" without building the whole feed
--
-- The Clients list shows when each client last had anything happen. It was
-- max(at) over client_activity - the whole activity feed, every note's text,
-- every job with its employer's name, every payment formatted as a sentence -
-- built for every client on every load and then thrown away but for one date.
-- Measured on 18 Sept 2026 at 30-44 ms to run and 14-29 ms to plan: the
-- slowest single thing on the page.
--
-- This reads only the dates, from the same sources with the same rules, and
-- keeps every join that could hide a row (a job through its opening, hours and
-- payments through their authorization), so what each person can see decides
-- the answer exactly as before. Where a source has several dates the latest
-- is taken with greatest(), which ignores the empty ones just as max() did.
-- verify_last_activity.sql compares the two for every client, as Admin and as
-- somebody who is not, and fails on any difference.

create or replace view public.client_last_activity with (security_invoker = true) as
select c.id          as client_id,
       max(a.at)     as last_activity_at
  from public.clients c
  left join (
    select n.client_id, coalesce(n.at::timestamptz, n.created_at) as at
      from public.notes n
    union all
    select h.client_id, coalesce(h.at::timestamptz, h.created_at)
      from public.client_stage_history h
    union all
    select m.client_id, greatest(m.applied_on, m.interview_on, m.follow_up_on, m.decided_on)::timestamptz
      from public.lead_matches m
      join public.job_leads l on l.id = m.lead_id
    union all
    select t.client_id, t.done_at
      from public.tasks t
     where t.status = 'Done' and t.done_at is not null
    union all
    select f.client_id, greatest(f.completed_at, f.sent_at)
      from public.forms f
    union all
    select cl.client_id, cl.date::timestamptz
      from public.contact_log cl
     where cl.client_id is not null
    union all
    select p.client_id, greatest(p.start_date, p.check30, p.check60, p.check90)::timestamptz
      from public.placements p
    union all
    select au.client_id, se.date::timestamptz
      from public.service_entries se
      join public.authorizations au on au.id = se.auth_id
    union all
    select ce.client_id, ce.starts_at
      from public.calendar_events ce
     where ce.client_id is not null
    union all
    select ml.client_id, ml.sent_at
      from public.mail_log ml
     where ml.client_id is not null
    union all
    select sm.client_id, coalesce(sm.sent_at, sm.created_at)
      from public.sms_messages sm
     where sm.client_id is not null
    union all
    select au.client_id, coalesce(pay.warrant_date::timestamptz, pay.created_at)
      from public.payments pay
      join public.authorizations au on au.id = pay.auth_id
  ) a on a.client_id = c.id
 group by c.id;

comment on view public.client_last_activity is
  'When each client last had anything on their activity feed - the same answer as max(at) over client_activity, read from the dates alone (0094).';

revoke all on public.client_last_activity from anon;
grant select on public.client_last_activity to authenticated;
