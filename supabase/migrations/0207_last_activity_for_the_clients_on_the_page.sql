-- Zion Vocational Rehab CRM — last activity, for the clients on the page
-- (stress test, finding 4, owner 16 Oct 2026)
--
-- client_last_activity (0094) answers "when did each client last have
-- anything happen" by taking twelve unions across most of the database and
-- grouping them per client. The Clients list asks it for every client on
-- every load, and at ten times the practice's size that was measured at
-- 309 ms - the second most expensive thing on the screen.
--
-- The obvious fix does not work, and the measurement is why this function
-- exists rather than a WHERE clause. Asking the view for fifty clients
-- instead of all of them:
--
--   client_last_activity, every client   595 rows   309 ms
--   client_last_activity, 50 ids          50 rows   299 ms
--
-- Ten milliseconds. The union is built in full and then filtered, so
-- narrowing the question does not narrow the work. The same answer with the
-- client ids pushed down into each of the twelve branches, so every one is an
-- indexed lookup rather than a scan:
--
--   this function, 50 ids                 50 rows   9.8 ms
--
-- Thirty times faster, same answer. The branches, their coalesces and their
-- conditions are 0094's, unchanged - only where the filtering happens moved.
--
-- The view stays. It is the honest definition of the idea and other things
-- read it; this is how a screen asks about the clients it is showing.

create or replace function public.client_last_activity_for(p_clients uuid[])
returns table (client_id uuid, last_activity_at timestamptz)
language sql stable set search_path = public as $$
  select c.id, max(a.at)
    from public.clients c
    left join lateral (
      select coalesce(n.at::timestamptz, n.created_at) as at
        from public.notes n where n.client_id = c.id
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
    ) a on true
   where c.id = any(p_clients)
   group by c.id;
$$;

comment on function public.client_last_activity_for(uuid[]) is
  'When each of these clients last had anything on their activity feed - the same answer as client_last_activity, asked only about the clients a screen is showing (0207).';

revoke all on function public.client_last_activity_for(uuid[]) from anon, authenticated;
grant execute on function public.client_last_activity_for(uuid[]) to authenticated;

do $$
declare
  v_ids uuid[];
  v_n   integer;
begin
  v_ids := array(select id from public.clients limit 25);
  select count(*) into v_n from public.client_last_activity_for(v_ids);
  raise notice 'ok  last activity answers for % of % clients asked about', v_n, coalesce(array_length(v_ids, 1), 0);
end $$;
