-- The alerts read the engine, and what is left over comes out.
--
-- Needs the new code live first: `next_step`
-- The code that sends it: lib/clients-board-shape.ts, app/(app)/clients/stage-board.tsx
--
-- The second half of Phase A. The four old computations come out now that the
-- code reading `next_steps` and `clients_board_rows.next_step` is live:
-- applied before the push, the board would have been drawing two columns the
-- function no longer returns.
--
--   * generate_notifications_on's four client categories become one, read
--     from the engine, and the temporary table two of them needed goes with
--     them.
--   * client_next_actions and client_next_actions_for are dropped. The
--     record's strip, the texts card, Home and My clients all read the engine.
--   * clients_board_rows loses the seven columns nothing reads any more: the
--     four next_task_*, attention and attention_urgency, and
--     authorization_ends_on, whose tile now filters on the engine's kinds.

begin;

CREATE OR REPLACE FUNCTION public.generate_notifications_on(p_today date)
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

  create temporary table _current (
    dedupe_key text primary key,
    kind text, level text, text text, roles text[], href text,
    client_id uuid, staff_id uuid
  ) on commit drop;

  /*
   * 1. Everything a client needs, from the one engine (0405).
   *
   * Four categories stood here: an authorization needing attention, an
   * overdue task, a monthly USOR form missing, and a counselor follow-up come
   * due. Each was a rule of its own, and three of the four disagreed with the
   * screen asking the same question - most plainly the task, which the bell
   * raised only once it was overdue, while the board named it whatever its
   * date and the client's own record never mentioned it at all.
   *
   * The engine answers for the whole practice in one call, so a new kind of
   * work reaches the bell without a category being added here.
   *
   * ── the dedupe key ──────────────────────────────────────
   *
   * The sentence is in the key, which is how the old authorization alert
   * carried its urgency: an item whose wording changes raises a new flag and
   * resolves the old one, rather than the first being quietly rewritten and
   * the date it started being lost. Hashed, because a key is an index and not
   * something anybody reads.
   *
   * ── who it reaches ──────────────────────────────────────
   *
   * Unchanged for the two categories addressed by role. An authorization goes
   * to Admin and Billing, and to Job Search as well when it is bad enough to
   * stop the work - the one of these that is about whether to keep serving
   * somebody rather than about billing. A form blocking billing goes to all
   * three, as the monthly-forms alert did.
   *
   * Changed for the two that were addressed by the holder's own role. An
   * overdue task and a counselor follow-up went to Admin plus the role of
   * whoever held it, and the engine's columns carry a name rather than a
   * staff id, so that role cannot be resolved from a row. They go to Admin
   * plus the roles that work the client. Somebody holding a task on a client
   * who is neither theirs to bill nor theirs to place therefore stops getting
   * the bell for it, and still sees it on Home and on My clients, where scope
   * 'person' includes every task assigned to them. This is the one change to
   * who sees what in this phase, and the owner was told of it.
   */
  insert into _current
  select 'step:' || n.kind || ':' || coalesce(n.client_id::text, 'none') || ':' || md5(n.what),
         n.kind,
         case when n.severity <= 2 then 'bad' else 'warn' end,
         coalesce(c.name || ' - ', '') || n.what,
         case
           when n.kind = 'authorization' and n.severity <= 1
             then array['Admin', 'Billing', 'Job Search']
           when n.kind in ('authorization', 'placement', 'stability')
             then array['Admin', 'Billing']
           when n.kind = 'form' then array['Admin', 'Billing', 'Job Search']
           else array_remove(array['Admin', sb.role, sa.role], null)
         end,
         n.action_href,
         n.client_id,
         null
    from public.next_steps('owner', null, null) n
    left join public.clients c on c.id = n.client_id
    left join public.staff sb on sb.id = c.billing_staff_id
    left join public.staff sa on sa.id = c.assigned_staff_id
  on conflict (dedupe_key) do nothing;

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

drop function if exists public.clients_board_rows(date);

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
  last_contact_at timestamp with time zone,
  last_contact_kind text,
  days_in_stage integer,
  report_status text,
  report_due_on date,
  goal text,
  services text[],
  funding_source text,
  availability text,
  applied_7d integer,
  next_interview date,
  last_note text,
  last_note_on date,
  flagged_for_review text,
  stage_request_id uuid,
  stage_request_to text,
  stage_request_by text,
  stage_request_at timestamp with time zone,
  stage_request_reason text,
  next_step text,
  next_step_severity integer,
  next_step_href text,
  next_kinds text[]
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
         greatest((select today from me) - coalesce(s.since, (select today from me)), 0)::int,
         rp.status, rp.due_on,
         nullif(btrim(coalesce(b.target_jobs, '')), ''),
         coalesce(t.services, '{}'::text[]),
         nullif(btrim(coalesce(b.funding_source, '')), ''),
         nullif(btrim(coalesce(b.schedule, '')), ''),
         coalesce(sr.applied_7d, 0)::int,
         sr.next_interview,
         n.outcome, n.date,
         nullif(btrim(coalesce(b.import_review, '')), ''),
         aq.id, aq.to_stage, aq.by_name, aq.requested_at, aq.reason,
         sp.what, sp.severity::int, sp.href, coalesce(sp.kinds, '{}'::text[])
    from board b
    left join public.counselors co on co.id = b.counselor_id
    left join public.staff st on st.id = b.assigned_staff_id
    left join since s on s.client_id = b.id
    left join tags t on t.client_id = b.id
    left join note n on n.client_id = b.id
    left join contact ct on ct.client_id = b.id
    left join job j on j.client_id = b.id
    left join report rp on rp.client_id = b.id
    left join searching sr on sr.client_id = b.id
    left join asked aq on aq.client_id = b.id
    left join steps sp on sp.client_id = b.id
   order by b.stage, b.name;
$function$;

revoke all on function public.clients_board_rows(date) from public;
revoke all on function public.clients_board_rows(date) from anon;
grant execute on function public.clients_board_rows(date) to authenticated;
grant execute on function public.clients_board_rows(date) to service_role;

-- ── and the computations that are gone ──────────────────────

drop function if exists public.client_next_actions(uuid);
drop function if exists public.client_next_actions_for(uuid[]);

commit;
