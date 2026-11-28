-- The board asks the engine.
--
-- Tolerates the old code: every column clients_board_rows returned before is
-- still returned. The four new ones are additions, and the live board ignores
-- a column it does not read. The removals are 0407, once the code that reads
-- these is live.
--
-- Dropped and recreated rather than replaced, because adding a column to a
-- returns-table function is a new return type, and the grants go with the
-- drop - so they are written again below. Both inside one transaction: a
-- reader during the swap waits rather than meeting a function that is not
-- there.

begin;

drop function if exists public.clients_board_rows(date);

CREATE OR REPLACE FUNCTION public.clients_board_rows(p_today date DEFAULT NULL::date)
 RETURNS TABLE(client_id uuid, name text, stage text, counselor text, office text, assigned_staff_id uuid, assigned_to text, job_status text, job_status_on date, last_contact_at timestamp with time zone, last_contact_kind text, next_task_id uuid, next_task_title text, next_task_owner text, next_task_due date, days_in_stage integer, report_status text, report_due_on date, attention text, attention_urgency integer, goal text, services text[], funding_source text, availability text, applied_7d integer, next_interview date, last_note text, last_note_on date, authorization_ends_on date, flagged_for_review text, stage_request_id uuid, stage_request_to text, stage_request_by text, stage_request_at timestamp with time zone, stage_request_reason text, next_step text, next_step_severity integer, next_step_href text, next_kinds text[])
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with me as (select coalesce(p_today, public.practice_today()) as today),
  board as (
    select c.id, c.name, c.stage, c.target_jobs, c.counselor_id, c.assigned_staff_id,
           c.referring_office, c.funding_source, c.schedule, c.import_review
      from public.clients c
     where public.is_active_staff()
       and c.status = 'Active' and c.merged_into is null
  ),
  since as (
    select distinct on (h.client_id) h.client_id, coalesce(h.at_time::date, h.at) as since
      from public.client_stage_history h
      join board b on b.id = h.client_id and b.stage = h.stage
     order by h.client_id, h.at_time desc nulls last, h.at desc
  ),
  live as (
    select a.id, a.client_id, a.service_type, a.end_date
      from public.authorizations a
      join board b on b.id = a.client_id
     where a.status not in ('Paid', 'Closed')
  ),
  tags as (
    select l.client_id, array_agg(distinct l.service_type) as services
      from live l group by l.client_id
  ),
  ending as (
    select l.client_id, min(l.end_date) as ends_on
      from live l, me
     where l.end_date is not null
       and l.end_date >= me.today
       and l.end_date <= me.today + 30
     group by l.client_id
  ),
  alert as (
    select distinct on (l.client_id) l.client_id, t.attention, t.urgency
      from live l
      join public.authorization_attention_for(
             array(select id from live), (select today from me)) t on t.auth_id = l.id
     where coalesce(t.attention, '') <> ''
     order by l.client_id, t.urgency
  ),
  note as (
    select distinct on (g.client_id) g.client_id,
           nullif(btrim(coalesce(g.outcome, '')), '') as outcome, g.date
      from public.contact_log g
      join board b on b.id = g.client_id
     order by g.client_id, g.date desc, g.created_at desc
  ),
  -- Somebody was reached: a text, an email, a logged counselor contact, an
  -- appointment. The day and the word, never the body.
  contact as (
    select distinct on (a.client_id) a.client_id, a.at, a.kind
      from public.client_activity a
      join board b on b.id = a.client_id
     where a.kind in ('Text', 'Mail', 'Counselor', 'Appointment')
     order by a.client_id, a.at desc
  ),
  job as (
    select distinct on (s.client_id) s.client_id, s.status, s.at::date as at
      from public.client_application_status s
      join board b on b.id = s.client_id
     order by s.client_id, s.at desc
  ),
  task as (
    select distinct on (t.client_id) t.client_id, t.id, t.title, t.due, st.name as owner
      from public.tasks t
      join board b on b.id = t.client_id
      left join public.staff st on st.id = t.assigned_staff_id
     where t.status = 'Open'
     order by t.client_id, t.due nulls last, t.created_at
  ),
  report as (
    select distinct on (r.client_id) r.client_id, r.status, r.due_on
      from public.client_reports r
      join board b on b.id = r.client_id, me
     where r.period = date_trunc('month', me.today::timestamptz)::date
     order by r.client_id, r.created_at desc
  ),
  searching as (
    select m.client_id,
           count(*) filter (where m.applied_on >= (select today from me) - 7) as applied_7d,
           min(m.interview_on) filter (where m.interview_on >= (select today from me)) as next_interview
      from public.lead_matches m
      join board b on b.id = m.client_id
     group by m.client_id
  ),
  -- The oldest ask still waiting, which is the one to decide first. One per
  -- client on the row: a client with two waiting requests is two stages being
  -- argued about, and the row says the first of them.
  asked as (
    select distinct on (q.client_id) q.client_id, q.id, q.to_stage, q.requested_at, q.reason,
           rq.name as by_name
      from public.client_stage_requests q
      join board b on b.id = q.client_id
      left join public.staff rq on rq.id = q.requested_by
     where q.outcome = 'Waiting'
     order by q.client_id, q.requested_at
  ),
  /*
   * What needs doing, from the one engine (0405).
   *
   * The board used to work out two of these for itself - the authorization
   * sentence and the next open task - and a third, the fortnight of silence,
   * was decided in TypeScript by a tile. Three answers to a question the
   * practice asks on six screens.
   *
   * `next_step` is the worst of them, which is the single cell the owner
   * asked for; `next_kinds` carries every kind firing for that client, so a
   * tile filters on the same answer rather than deciding again. Ordered by
   * severity then kind, so the cell is stable between two things equally
   * urgent rather than changing each time the board is drawn.
   */
  steps as (
    select n.client_id,
           array_agg(distinct n.kind) as kinds,
           (array_agg(n.what order by n.severity, n.kind))[1] as what,
           min(n.severity) as severity,
           (array_agg(n.action_href order by n.severity, n.kind))[1] as href
      from public.next_steps('board', null, null) n
     where n.client_id is not null
     group by n.client_id
  )
  select b.id, b.name, b.stage,
         co.name,
         nullif(btrim(coalesce(b.referring_office, '')), ''),
         b.assigned_staff_id, st.name,
         j.status, j.at,
         ct.at, ct.kind,
         tk.id, tk.title, tk.owner, tk.due,
         greatest((select today from me) - coalesce(s.since, (select today from me)), 0)::int,
         rp.status, rp.due_on,
         al.attention, al.urgency,
         nullif(btrim(coalesce(b.target_jobs, '')), ''),
         coalesce(t.services, '{}'::text[]),
         nullif(btrim(coalesce(b.funding_source, '')), ''),
         nullif(btrim(coalesce(b.schedule, '')), ''),
         coalesce(sr.applied_7d, 0)::int,
         sr.next_interview,
         n.outcome, n.date,
         en.ends_on,
         nullif(btrim(coalesce(b.import_review, '')), ''),
         aq.id, aq.to_stage, aq.by_name, aq.requested_at, aq.reason,
         sp.what, sp.severity::int, sp.href, coalesce(sp.kinds, '{}'::text[])
    from board b
    left join public.counselors co on co.id = b.counselor_id
    left join public.staff st on st.id = b.assigned_staff_id
    left join since s on s.client_id = b.id
    left join tags t on t.client_id = b.id
    left join ending en on en.client_id = b.id
    left join alert al on al.client_id = b.id
    left join note n on n.client_id = b.id
    left join contact ct on ct.client_id = b.id
    left join job j on j.client_id = b.id
    left join task tk on tk.client_id = b.id
    left join report rp on rp.client_id = b.id
    left join searching sr on sr.client_id = b.id
    left join asked aq on aq.client_id = b.id
    left join steps sp on sp.client_id = b.id
   order by b.stage, b.name;
$function$
;

revoke all on function public.clients_board_rows(date) from public;
revoke all on function public.clients_board_rows(date) from anon;
grant execute on function public.clients_board_rows(date) to authenticated;
grant execute on function public.clients_board_rows(date) to service_role;

commit;
