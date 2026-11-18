-- A stage change is Admin's, and everybody else asks (clients board brief, Part 3)
--
-- Until now anybody who could see Clients could move a client between stages.
-- The owner's ruling 6: the move is Admin's alone, and every other role gets
-- "Request change" - which raises a task for the administrator and a row
-- saying what was asked, by whom, and what came of it.
--
-- Three things live here.
--
--   `move_client` gains an Admin gate. In the function, not on the screen: the
--   screens are one caller, and the import, the agent and a hand-written
--   statement are others. It is the same function with the same signature, so
--   every caller keeps working and every non-Admin caller is now refused in a
--   sentence that says what to do instead.
--
--   `client_stage_requests` is the ask: the target stage, the reason, who
--   asked and when, the outcome, who decided and when, their reason, and the
--   task the administrator was given. The stage and the reason cannot live on
--   a task, which has a title and a due date and nothing else - that is the
--   whole reason there is a table. `outcome` is one column rather than two
--   booleans so that "waiting" is a state rather than an absence, and both
--   names are kept because the move's own history records who moved the
--   client while this records who asked for it.
--
--   `request_stage_change` and `decide_stage_request` are the two doors.
--   Nothing writes the table directly: there is no insert or update grant on
--   it, so the rules below are the only way a request comes into being or
--   ends, whoever is calling.
--
-- **A request the world has moved past closes itself.** If the client is
-- already in the stage that was asked for - because the administrator moved
-- them without going through the request - the request is closed as Approved
-- with "already moved" and the administrator's task closes with it. That is
-- done inside `move_client`, which is the only door a stage can change
-- through: the history trigger refuses a move with no note, and the note is
-- set by this function and nothing else.

-- ─────────────────────────────────────────────────────────────
-- The ask
-- ─────────────────────────────────────────────────────────────
create table if not exists public.client_stage_requests (
  id              uuid primary key default gen_random_uuid(),
  client_id       uuid not null references public.clients(id) on delete cascade,
  to_stage        text not null,
  reason          text not null,
  requested_by    uuid not null references public.staff(id),
  requested_at    timestamptz not null default now(),
  outcome         text not null default 'Waiting',
  decided_by      uuid references public.staff(id),
  decided_at      timestamptz,
  decision_reason text,
  -- The administrator's task, so that deciding here closes the thing on their
  -- list rather than leaving it open beside a decision that has been made.
  task_id         uuid references public.tasks(id) on delete set null,

  constraint client_stage_requests_stage check (to_stage = any (array[
    'Intake', 'Assessment', 'Job Development', 'Job Search',
    'Life Skills', 'Job Placement', 'Job Coaching'
  ])),
  constraint client_stage_requests_reason check (btrim(reason) <> ''),
  constraint client_stage_requests_outcome check (outcome = any (array['Waiting', 'Approved', 'Declined'])),
  -- Decided means decided: a name and a time, or neither.
  constraint client_stage_requests_decided check (
    (outcome = 'Waiting') = (decided_by is null and decided_at is null)
  ),
  -- A decline says why. The owner's ruling 2, held by the table as well as by
  -- the function, because the person who asked has to be told what to do
  -- instead and a blank reason tells them nothing.
  constraint client_stage_requests_declined_says_why check (
    outcome <> 'Declined' or btrim(coalesce(decision_reason, '')) <> ''
  )
);

comment on table public.client_stage_requests is
  'Somebody who is not an administrator asking for a client to be moved, and what came of it (0372).';

-- One waiting request per client per stage. The function refuses the second
-- one in its own words before it gets here; this is the backstop, and it is
-- what makes "a second ask while one is waiting" impossible rather than
-- merely discouraged.
create unique index if not exists client_stage_requests_one_waiting
  on public.client_stage_requests (client_id, to_stage)
  where outcome = 'Waiting';

create index if not exists client_stage_requests_waiting_idx
  on public.client_stage_requests (outcome, requested_at desc);

alter table public.client_stage_requests enable row level security;

-- Everybody who can see Clients can see what has been asked about them: the
-- board draws it on the row, and a request nobody can see is a request
-- somebody asks for twice.
drop policy if exists client_stage_requests_select on public.client_stage_requests;
create policy client_stage_requests_select on public.client_stage_requests
  for select to authenticated
  using ((select public.is_active_staff()));

-- No insert, update or delete policy, and no grant for them either. The two
-- functions below are security definer and are the only way in.
revoke all on table public.client_stage_requests from public, anon;
grant select on table public.client_stage_requests to authenticated;

select public.apply_system_read_only('public.client_stage_requests'::regclass);

-- ─────────────────────────────────────────────────────────────
-- Moving a client: Admin only
-- ─────────────────────────────────────────────────────────────
/**
 * One move: the stage, the note, the line in the contact log - and, since
 * 0372, the administrator's signature on it.
 *
 * The note is still the trigger's refusal, so this function cannot forget it.
 * What is new is the gate and the tidying up after it: any request that asked
 * for the stage this move has just reached is closed as approved, because the
 * thing it asked for has happened.
 */
create or replace function public.move_client(
  p_client   uuid,
  p_stage    text,
  p_note     text,
  p_document uuid default null
)
returns table (from_stage text, to_stage text, at_time timestamptz)
language plpgsql security definer set search_path = public as $$
declare
  v_from text;
  v_name text;
  r      record;
begin
  if public.current_staff_id() is null then
    raise exception 'Only a member of staff moves a client.' using errcode = 'insufficient_privilege';
  end if;
  /*
   * Ruling 6, enforced here rather than on the screen.
   *
   * `is_admin()` rather than the role read off the row, because it asks the
   * two questions that matter together - Admin, and still active.
   */
  if not public.is_admin() then
    raise exception 'Only an administrator moves a client between stages. Ask for the change and it goes to Admin to decide.'
      using errcode = 'insufficient_privilege';
  end if;
  if coalesce(btrim(p_note), '') = '' then
    raise exception 'Say why they are moving. A move without a note is not a move anybody can follow.'
      using errcode = 'check_violation';
  end if;

  select c.stage, c.name into v_from, v_name from public.clients c where c.id = p_client for update;
  if not found then raise exception 'That client is not there.'; end if;
  if v_from = p_stage then
    raise exception '% is already in %.', v_name, p_stage using errcode = 'check_violation';
  end if;

  perform set_config('zion.stage_note', btrim(p_note), true);
  perform set_config('zion.stage_document', coalesce(p_document::text, ''), true);
  update public.clients set stage = p_stage where id = p_client;
  perform set_config('zion.stage_note', '', true);
  perform set_config('zion.stage_document', '', true);

  -- The client's own log, so the move reads beside the calls and the visits
  -- rather than only in a history tab.
  insert into public.contact_log (client_id, date, method, topic, outcome, staff_id)
  values (p_client, public.practice_today(), 'Stage change',
          v_from || ' to ' || p_stage, btrim(p_note), public.current_staff_id());

  /*
   * And a request that asked for this stage has got what it asked for (0372).
   *
   * "already moved" rather than the administrator's own words, because there
   * were none: this is the path where the move happened without the request
   * being opened. `decide_stage_request` marks its own row before it calls
   * this function, so an approval never lands here.
   */
  for r in
    update public.client_stage_requests q
       set outcome = 'Approved',
           decided_by = public.current_staff_id(),
           decided_at = now(),
           decision_reason = 'already moved'
     where q.client_id = p_client and q.to_stage = p_stage and q.outcome = 'Waiting'
    returning q.task_id
  loop
    update public.tasks t set status = 'Done', done_at = now()
     where t.id = r.task_id and t.status = 'Open';
  end loop;

  from_stage := v_from;
  to_stage := p_stage;
  at_time := now();
  return next;
end;
$$;

comment on function public.move_client is
  'Moves a client to a stage with a note, writes the stage history and the contact log, refuses an empty note, refuses anybody but an administrator, and closes any request that asked for the stage it reached (0223, 0372).';

revoke all on function public.move_client(uuid, text, text, uuid) from public, anon;
grant execute on function public.move_client(uuid, text, text, uuid) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- Asking for one
-- ─────────────────────────────────────────────────────────────
/**
 * Request change: the row, the administrator's task, and the bell.
 *
 * `notify_person` does the telling, which is the house door for it: one row
 * in the bell, one item on My day, deduped on the request so a retry leaves
 * one of each. The reason is put on that task as a comment, so the
 * administrator reads why without opening another screen.
 *
 * An administrator who calls this is refused. They move the client; a request
 * from the person who would decide it is a round trip to themselves, and
 * offering it would be a screen that does not know who is looking at it.
 */
create or replace function public.request_stage_change(
  p_client uuid,
  p_stage  text,
  p_reason text
)
returns table (request_id uuid, task_id uuid, said text)
language plpgsql security definer set search_path = public as $$
declare
  v_me     uuid := public.current_staff_id();
  v_myname text;
  v_name   text;
  v_now    text;
  v_admin  uuid;
  v_who    text;
  v_when   timestamptz;
  v_req    uuid;
  v_task   uuid;
begin
  if not public.is_active_staff() or v_me is null then
    raise exception 'Only a member of staff asks for a client to be moved.' using errcode = 'insufficient_privilege';
  end if;
  if public.is_admin() then
    raise exception 'An administrator moves a client rather than asking. Use Move on the row.'
      using errcode = 'insufficient_privilege';
  end if;
  -- 0120: an automated account is given nothing beyond its role, and asking
  -- for a client to be moved is a judgement rather than a reading.
  if public.current_staff_is_system() then
    raise exception 'An automated account does not ask for a client to be moved.'
      using errcode = 'insufficient_privilege';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'Say why it should move. An administrator has to decide on something.'
      using errcode = 'check_violation';
  end if;
  if p_stage is null or not (p_stage = any (array[
       'Intake', 'Assessment', 'Job Development', 'Job Search',
       'Life Skills', 'Job Placement', 'Job Coaching'])) then
    raise exception '% is not one of the seven stages.', coalesce(p_stage, 'That')
      using errcode = 'check_violation';
  end if;

  select c.name, c.stage into v_name, v_now from public.clients c
   where c.id = p_client and c.merged_into is null;
  if not found then raise exception 'That client is not there.'; end if;
  if v_now = p_stage then
    raise exception '% is already in %.', v_name, p_stage using errcode = 'check_violation';
  end if;

  -- Ruling 3: one ask at a time, and the refusal names who is waiting on whom.
  select st.name, q.requested_at into v_who, v_when
    from public.client_stage_requests q
    left join public.staff st on st.id = q.requested_by
   where q.client_id = p_client and q.to_stage = p_stage and q.outcome = 'Waiting'
   limit 1;
  if v_when is not null then
    raise exception '% already asked on % to move % to % — Admin has that one to decide.',
      coalesce(v_who, 'Somebody'), to_char(v_when, 'FMMon FMDD'), v_name, p_stage
      using errcode = 'unique_violation';
  end if;

  select s.id into v_admin from public.staff s
   where s.role = 'Admin' and s.active and not s.is_system
   order by s.created_at limit 1;
  if v_admin is null then
    raise exception 'There is no administrator to decide this.' using errcode = 'no_data_found';
  end if;

  select s.name into v_myname from public.staff s where s.id = v_me;

  insert into public.client_stage_requests (client_id, to_stage, reason, requested_by)
  values (p_client, p_stage, btrim(p_reason), v_me)
  returning id into v_req;

  select n.task_id into v_task from public.notify_person(
    v_admin,
    'stage_request',
    format('%s asks to move %s from %s to %s.', coalesce(v_myname, 'Somebody'), v_name, v_now, p_stage),
    v_req::text,
    '/clients',
    p_client,
    format('Decide: move %s to %s', v_name, p_stage),
    public.practice_today(),
    'warn',
    v_req
  ) n;

  update public.client_stage_requests set task_id = v_task where id = v_req;

  -- Why, in the asker's words, where the decision is made.
  if v_task is not null then
    insert into public.task_comments (task_id, staff_id, staff_name, said)
    values (v_task, v_me, coalesce(v_myname, 'Somebody'), btrim(p_reason));
  end if;

  request_id := v_req;
  task_id := v_task;
  said := format('Asked to move %s to %s. Admin decides.', v_name, p_stage);
  return next;
end;
$$;

comment on function public.request_stage_change is
  'Asks for a client to be moved: the request, the administrator''s task and the bell, with the reason as a comment on the task (0372).';

revoke all on function public.request_stage_change(uuid, text, text) from public, anon;
grant execute on function public.request_stage_change(uuid, text, text) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- Deciding one
-- ─────────────────────────────────────────────────────────────
/**
 * Approve or decline, by the administrator and nobody else.
 *
 * Approve moves the client through `move_client` - as the administrator, which
 * is what makes it allowed - with a note carrying both lines and both names,
 * so the stage history reads "<who asked>: <why> — approved by <who decided>:
 * <why>" rather than losing half the conversation. The request row is marked
 * before the move so that `move_client`'s own tidying up does not mistake an
 * approval for a move the request never heard about.
 *
 * Decline needs a reason, writes it on a task for the person who asked, and
 * closes the administrator's. A decline with nothing to act on is the same as
 * silence, and silence is what this whole path exists to replace.
 *
 * `p_reason` has no default on purpose: a defaulted argument is a second
 * signature, and the screens always send the field.
 */
create or replace function public.decide_stage_request(
  p_request uuid,
  p_approve boolean,
  p_reason  text
)
returns table (outcome text, said text)
language plpgsql security definer set search_path = public as $$
declare
  v_me      uuid := public.current_staff_id();
  v_myname  text;
  q         public.client_stage_requests;
  v_name    text;
  v_now     text;
  v_asked   text;
  v_active  boolean;
  v_reason  text := btrim(coalesce(p_reason, ''));
  v_note    text;
  v_task    uuid;
begin
  if not public.is_admin() then
    raise exception 'Only an administrator decides a stage change.' using errcode = 'insufficient_privilege';
  end if;

  select * into q from public.client_stage_requests where id = p_request for update;
  if not found then raise exception 'That request is not there.'; end if;
  if q.outcome <> 'Waiting' then
    raise exception 'That request was already %.', lower(q.outcome) using errcode = 'check_violation';
  end if;

  select c.name, c.stage into v_name, v_now from public.clients c where c.id = q.client_id;
  select s.name into v_myname from public.staff s where s.id = v_me;
  select s.name, s.active into v_asked, v_active from public.staff s where s.id = q.requested_by;

  /*
   * Ruling 3: the client is already where the request asked for.
   *
   * The same words `move_client` uses on the same situation, because it is the
   * same situation reached from the other side - and calling the move here
   * would be refused as "already in".
   */
  if v_now = q.to_stage then
    update public.client_stage_requests
       set outcome = 'Approved', decided_by = v_me, decided_at = now(),
           decision_reason = 'already moved'
     where id = q.id;
    update public.tasks set status = 'Done', done_at = now()
     where id = q.task_id and status = 'Open';
    outcome := 'Approved';
    said := format('%s is already in %s, so the request is closed.', v_name, q.to_stage);
    return next;
    return;
  end if;

  if p_approve then
    update public.client_stage_requests
       set outcome = 'Approved', decided_by = v_me, decided_at = now(),
           decision_reason = nullif(v_reason, '')
     where id = q.id;

    -- Both lines and both names, which is what the move log has to carry.
    v_note := format('%s asked: %s — approved by %s%s',
                     coalesce(v_asked, 'Somebody'), q.reason, coalesce(v_myname, 'Admin'),
                     case when v_reason = '' then '' else ': ' || v_reason end);
    perform 1 from public.move_client(q.client_id, q.to_stage, v_note);

    update public.tasks set status = 'Done', done_at = now()
     where id = q.task_id and status = 'Open';

    outcome := 'Approved';
    said := format('%s moved to %s.', v_name, q.to_stage);
    return next;
    return;
  end if;

  -- ── declined ───────────────────────────────────────────────
  if v_reason = '' then
    raise exception 'Say why it is declined. Whoever asked needs to know what to do instead.'
      using errcode = 'check_violation';
  end if;

  update public.client_stage_requests
     set outcome = 'Declined', decided_by = v_me, decided_at = now(), decision_reason = v_reason
   where id = q.id;

  update public.tasks set status = 'Done', done_at = now()
   where id = q.task_id and status = 'Open';

  /*
   * And the person who asked is told, on their own list.
   *
   * A task rather than only a notification, because the bell is read when
   * somebody looks at it and this is a thing to act on: the move did not
   * happen and whatever they were going to do next has to change. The reason
   * is the comment on it, in the administrator's words.
   *
   * Only if they are still here. A decline that fails because the asker has
   * left would leave the request waiting forever, which is worse than a
   * decline nobody is told about - and the row carries the words either way.
   */
  if coalesce(v_active, false) then
    select n.task_id into v_task from public.notify_person(
      q.requested_by,
      'stage_request_declined',
      format('Moving %s to %s was declined: %s', v_name, q.to_stage, v_reason),
      q.id::text,
      '/clients',
      q.client_id,
      format('Declined: moving %s to %s', v_name, q.to_stage),
      public.practice_today(),
      'warn',
      q.id
    ) n;
    if v_task is not null then
      insert into public.task_comments (task_id, staff_id, staff_name, said)
      values (v_task, v_me, coalesce(v_myname, 'Admin'), v_reason);
    end if;
  end if;

  outcome := 'Declined';
  said := format('Declined. %s has been told.', coalesce(v_asked, 'Whoever asked'));
  return next;
end;
$$;

comment on function public.decide_stage_request is
  'An administrator approves a stage request - which moves the client, with both reasons and both names on the note - or declines it with a reason the asker is given as a task (0372).';

revoke all on function public.decide_stage_request(uuid, boolean, text) from public, anon;
grant execute on function public.decide_stage_request(uuid, boolean, text) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- The board's row carries the waiting request
-- ─────────────────────────────────────────────────────────────
-- Dropped rather than replaced: the return type gains five columns, and a
-- changed return type cannot be replaced in place. The grants go with the
-- function, so they are written again below.
drop function if exists public.clients_board_rows(date);

create function public.clients_board_rows(p_today date default null)
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
  flagged_for_review text,
  -- The waiting request, which is the sixth tile and the Stage cell's
  -- Approve / Decline (0372). The reason comes with it because the decision
  -- is made on the row and sending somebody to another screen to read one
  -- sentence is how a decision gets made without it.
  stage_request_id uuid,
  stage_request_to text,
  stage_request_by text,
  stage_request_at timestamptz,
  stage_request_reason text
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
         aq.id, aq.to_stage, aq.by_name, aq.requested_at, aq.reason
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
   order by b.stage, b.name;
$function$;

comment on function public.clients_board_rows is
  'One row per active client for the stage board: stage and days in it, who it is assigned to, the job search, last contact and its channel, the next open task, this month''s report, the alert chip, the facts the tiles count, and any waiting stage request (0371, 0372).';

-- Staff only, and said twice: the body asks, and the grant stops anon before
-- the body runs.
revoke all on function public.clients_board_rows(date) from public, anon;
grant execute on function public.clients_board_rows(date) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- Two more kinds of task
-- ─────────────────────────────────────────────────────────────
-- `tasks.source_kind` is a closed list, which is what stops a typo becoming a
-- kind nothing ever looks for. The two the request path raises are added
-- here, and the list is the live one dumped before it was rewritten rather
-- than the one 0335 wrote - the two happened to be the same, and checking
-- rather than assuming is the rule.
alter table public.tasks drop constraint if exists tasks_source_kind_check;
alter table public.tasks add constraint tasks_source_kind_check
  check (source_kind = any (array[
    'Interview prep', 'Interview day', 'Follow-up', 'billing_item',
    'text_unanswered', 'intake', 'authorization_received', 'authorization_missing',
    'authorization_ending', 'placement_authorization', 'portal_upload',
    'portal_resume', 'mail_reply', 'clock_not_closed', 'clock_running_long',
    'clock_not_started', 'hours_correction', 'invoice_unpaid', 'invoice_unpaid_45',
    'invoice_short_paid', 'invoice_due',
    'invoice_number_missing', 'service_hours_from_paper', 'client_has_no_phone',
    'service_not_delivered',
    -- 0372: the administrator's decision, and the answer the asker gets.
    'stage_request', 'stage_request_declined']));
