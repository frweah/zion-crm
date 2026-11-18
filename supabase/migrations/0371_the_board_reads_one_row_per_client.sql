-- One row per client, for the stage board (clients board brief, Part 2).
--
-- The same shape as `billing_board`, and for the same reason: the board asks
-- one question of the database instead of a question per card. `clients_board`
-- answers the kanban - name, stage, goal, counselor, days in stage, the alert
-- chip - and the board needs seven more things it has never carried: where the
-- job search is, when somebody last reached the client and how, what the next
-- open task is and whose, where this month's report stands, whether an
-- authorization runs out inside a month, and the few columns the Clients list
-- has that this row hides until somebody asks for them.
--
-- So this replaces the read rather than joining onto it: one pass over the
-- caseload, one lateral per question, ordered by stage and then by name.
--
-- **Elevated on purpose, and gated.** Security definer, because gathering the
-- whole caseload one client at a time through RLS is what made the old list
-- take 309ms. `is_active_staff()` is therefore checked here, in the body - a
-- definer function without that check is a door a portal login can walk
-- through, which `verify_portal_rls` counts.
--
-- **Last contact is a date and a channel, and nothing else.** It reads the
-- four kinds of the stream that mean somebody was actually reached - a text,
-- an email, a logged counselor contact, an appointment - and returns when and
-- which. Not a note: writing a meeting up a week later would otherwise move
-- "last contact" to today. Being definer, it sees those four for every client
-- whether or not the reader could open the message itself; what it hands back
-- is a day and a word, never a body, and this screen is the whole team's.
--
-- **No money on it at all**: no amount, no invoice, no warrant, no voucher.
-- The only thing here that touches an authorization is whether one ends inside
-- thirty days, which is a date. `scripts/check-clients-board.mjs` holds that.

create or replace function public.clients_board_rows(p_today date default null)
returns table (
  client_id uuid,
  name text,
  stage text,
  counselor text,
  office text,
  assigned_staff_id uuid,
  assigned_to text,
  job_status text,
  job_status_on date,
  last_contact_at timestamptz,
  last_contact_kind text,
  next_task_id uuid,
  next_task_title text,
  next_task_owner text,
  next_task_due date,
  days_in_stage integer,
  report_status text,
  report_due_on date,
  attention text,
  attention_urgency integer,
  -- The columns the row hides until somebody turns them on.
  goal text,
  services text[],
  funding_source text,
  availability text,
  applied_7d integer,
  next_interview date,
  last_note text,
  last_note_on date,
  -- What the attention tiles count. Each one is a fact about the row, so a
  -- tile and the rows it filters to cannot disagree.
  authorization_ends_on date,
  flagged_for_review text
)
language sql
stable
security definer
set search_path to 'public'
as $function$
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
         nullif(btrim(coalesce(b.import_review, '')), '')
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
   order by b.stage, b.name;
$function$;

-- Staff only, and said twice: the body asks, and the grant stops anon before
-- the body runs.
revoke all on function public.clients_board_rows(date) from public, anon;
grant execute on function public.clients_board_rows(date) to authenticated;
