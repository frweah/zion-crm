-- Zion Vocational Rehab CRM — a stage change is Admin's, and everybody asks (0372)
--
-- Part 3 of the clients board brief, asked of the database rather than of the
-- screen. What has to hold:
--
--   move_client is Admin's. Every active account that is not Admin is refused
--     in a sentence, and the Admin is not - which is the control that keeps
--     the refusal meaning something.
--   request_stage_change writes the ask, raises the administrator's task and
--     puts the reason on it; an administrator and an automated account are
--     both refused.
--   one ask at a time per client and stage, refused in words, with a unique
--     index behind the words.
--   approve moves the client, with both reasons and both names on the note.
--   decline needs a reason, closes the administrator's task, and leaves the
--     reason on a task for whoever asked.
--   a client moved to the stage that was asked for closes the ask as approved
--     with "already moved", and closes its task.
--   the board's row carries a waiting ask and stops carrying a decided one.
--   an approval into Job Placement records the placement and its start date,
--     and the same employer twice is one placement (0373).
--   Job Placement without an employer or without a start date is refused, on
--     the Approve path and the Move path alike, in a sentence naming what is
--     missing and nothing else - and the refusal leaves the client where they
--     were with the request still waiting (0374).
--   and nothing writes the table except those two functions.
--
-- Everything is rolled back.

begin;

do $$
declare
  failures  text[] := '{}';
  v_admin   record;
  v_asker   record;
  v_system  record;
  v_client  uuid;
  v_name    text;
  v_from    text;
  v_to      text := 'Life Skills';
  v_other   text := 'Job Development';
  -- A third stage, for the control move. Every row of the stage history and
  -- every line of the contact log written in one transaction carries the same
  -- `now()`, so two moves to the same stage cannot be told apart by time -
  -- which is how the first run of this script read the control's note and
  -- called the approval's note missing.
  v_control text := 'Job Search';
  v_req     uuid;
  v_task    uuid;
  v_their   uuid;
  v_text    text;
  -- The placement fixture: one employer and one start date, named so that
  -- a row that escaped the rollback would be obvious.
  v_emp     text := 'ZZ Verify Employer';
  v_rows    integer;
  v_day     date := public.practice_today() - 7;
  n         integer;
  v_refused integer := 0;
  v_tried   integer := 0;
  r         record;
begin
  select s.id, s.user_id, s.name into v_admin
    from public.staff s
   where s.role = 'Admin' and s.active and s.user_id is not null and not coalesce(s.is_system, false)
   order by s.created_at limit 1;
  select s.id, s.user_id, s.name into v_asker
    from public.staff s
   where s.role <> 'Admin' and s.active and s.user_id is not null and not coalesce(s.is_system, false)
   order by s.created_at limit 1;
  select s.id, s.user_id, s.name into v_system
    from public.staff s
   where s.active and s.user_id is not null and coalesce(s.is_system, false)
   order by s.created_at limit 1;
  if v_admin.user_id is null or v_asker.user_id is null then
    raise exception 'This needs an Admin and one other signed-in member of staff to ask as.';
  end if;

  -- A client who is in none of the stages this script moves between, and not
  -- in Job Placement either.
  --
  -- Job Placement is on that list for a reason worth keeping: the script puts
  -- the client back where it found them, and since 0374 a move into Job
  -- Placement without an employer and a start date is refused - so a client
  -- who started there could not be put back without this script inventing an
  -- employer for a real person. It borrows the next one instead.
  select c.id, c.name, c.stage into v_client, v_name, v_from
    from public.clients c
   where c.status = 'Active' and c.merged_into is null
     and c.stage not in ('Life Skills', 'Job Development', 'Job Search', 'Job Placement')
   order by c.created_at limit 1;
  if v_client is null then
    raise exception 'This needs one active client who is not already in Life Skills, Job Development or Job Placement.';
  end if;

  -- ── 1. the move is Admin's, for every other account ────────
  -- Every active account with a sign-in that is not Admin, counted rather
  -- than named: an account added next month is in this loop without anybody
  -- remembering to add it.
  for r in
    select s.id, s.user_id, s.name, s.role
      from public.staff s
     where s.active and s.user_id is not null and s.role <> 'Admin'
     order by s.created_at
  loop
    v_tried := v_tried + 1;
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims',
      json_build_object('sub', r.user_id, 'role', 'authenticated')::text, true);
    begin
      perform 1 from public.move_client(v_client, v_to, 'ZZ verify: this must be refused');
      failures := failures || format('FAILED: %s (%s) moved a client between stages', r.name, r.role)::text;
    exception when others then
      if sqlerrm like '%administrator%' then
        v_refused := v_refused + 1;
      else
        failures := failures || format('FAILED: %s (%s) was refused, but not for being one: %s', r.name, r.role, sqlerrm)::text;
      end if;
    end;
    perform set_config('role', 'postgres', true);
    perform set_config('request.jwt.claims', '', true);
  end loop;

  if v_refused = v_tried and v_tried >= 6 then
    raise notice 'ok  all % accounts that are not Admin are refused the move, in a sentence that says so', v_tried;
  elsif v_refused = v_tried then
    failures := failures || format('FAILED: only %s non-Admin accounts were tried, and the brief says six', v_tried)::text;
  end if;

  -- The control. If the Admin cannot move either, the loop above proves
  -- nothing but that the function is broken.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin.user_id, 'role', 'authenticated')::text, true);
  select count(*) into n from public.move_client(v_client, v_control, 'ZZ verify: the Admin control');
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
  if n <> 1 then
    failures := failures || 'FAILED: the Admin could not move a client either, so the refusals above say nothing'::text;
  else
    raise notice 'ok  the Admin can, which is what makes those refusals mean something';
  end if;
  -- Back where they started, so the rest reads from a known stage.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin.user_id, 'role', 'authenticated')::text, true);
  perform 1 from public.move_client(v_client, v_from, 'ZZ verify: put them back');
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  -- ── 2. asking writes the ask, the task and the reason ──────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_asker.user_id, 'role', 'authenticated')::text, true);
  select q.request_id, q.task_id into v_req, v_task
    from public.request_stage_change(v_client, v_to, 'ZZ verify: they are ready for it') q;
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  select count(*) into n from public.client_stage_requests q
   where q.id = v_req and q.client_id = v_client and q.to_stage = v_to
     and q.outcome = 'Waiting' and q.requested_by = v_asker.id
     and q.decided_by is null and q.decided_at is null and q.task_id = v_task;
  if n <> 1 then
    failures := failures || 'FAILED: the ask was not written as one waiting request with its task'::text;
  else
    raise notice 'ok  asking writes one waiting request, with who asked and the task it raised';
  end if;

  select count(*) into n from public.tasks t
   where t.id = v_task and t.status = 'Open' and t.assigned_staff_id = v_admin.id
     and t.client_id = v_client and t.source_kind = 'stage_request' and t.source_ref = v_req;
  if n <> 1 then
    failures := failures || 'FAILED: the administrator has no open task for the ask'::text;
  else
    raise notice 'ok  the administrator gets the task, named after the request it came from';
  end if;

  select count(*) into n from public.task_comments c
   where c.task_id = v_task and c.said = 'ZZ verify: they are ready for it';
  if n <> 1 then
    failures := failures || 'FAILED: the reason was not put on the task'::text;
  else
    raise notice 'ok  the reason is on the task, in the asker''s words';
  end if;

  -- ── 3. one ask at a time, in words and in an index ─────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_asker.user_id, 'role', 'authenticated')::text, true);
  begin
    perform 1 from public.request_stage_change(v_client, v_to, 'ZZ verify: asking twice');
    failures := failures || 'FAILED: a second ask for the same client and stage was accepted'::text;
  exception when others then
    if sqlerrm like '%already asked%' and sqlerrm like '%' || v_name || '%' then
      raise notice 'ok  a second ask is refused, naming who asked and when';
    else
      failures := failures || format('FAILED: the second ask was refused without saying who is waiting: %s', sqlerrm)::text;
    end if;
  end;
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  select count(*) into n from pg_indexes
   where schemaname = 'public' and tablename = 'client_stage_requests'
     and indexdef ~* 'unique' and indexdef ~* 'client_id' and indexdef ~* 'to_stage'
     and indexdef ~* 'Waiting';
  if n <> 1 then
    failures := failures || 'FAILED: nothing but the function stops two waiting asks for one stage'::text;
  else
    raise notice 'ok  and an index says the same, so two at once cannot slip through';
  end if;

  -- ── 4. who may not ask ─────────────────────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin.user_id, 'role', 'authenticated')::text, true);
  begin
    perform 1 from public.request_stage_change(v_client, v_other, 'ZZ verify: Admin asking itself');
    failures := failures || 'FAILED: an administrator was allowed to ask themselves for a move'::text;
  exception when insufficient_privilege then
    raise notice 'ok  an administrator moves rather than asking';
  end;
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  if v_system.user_id is not null then
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_system.user_id, 'role', 'authenticated')::text, true);
    begin
      perform 1 from public.request_stage_change(v_client, v_other, 'ZZ verify: an automated ask');
      failures := failures || 'FAILED: an automated account asked for a client to be moved'::text;
    exception when insufficient_privilege then
      raise notice 'ok  an automated account does not ask either';
    end;
    perform set_config('role', 'postgres', true);
    perform set_config('request.jwt.claims', '', true);
  end if;

  -- ── 5. the board's row carries the waiting ask ─────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_asker.user_id, 'role', 'authenticated')::text, true);
  select count(*) into n from public.clients_board_rows() b
   where b.client_id = v_client and b.stage_request_id = v_req
     and b.stage_request_to = v_to and b.stage_request_by = v_asker.name
     and b.stage_request_reason = 'ZZ verify: they are ready for it';
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
  if n <> 1 then
    failures := failures || 'FAILED: the board''s row does not carry the waiting ask'::text;
  else
    raise notice 'ok  the row carries the ask, the stage, who asked and why';
  end if;

  -- ── 6. nobody writes the table by hand ─────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin.user_id, 'role', 'authenticated')::text, true);
  begin
    insert into public.client_stage_requests (client_id, to_stage, reason, requested_by)
    values (v_client, v_other, 'ZZ verify: written by hand', v_admin.id);
    failures := failures || 'FAILED: a request can be written without going through the function'::text;
  exception when others then
    raise notice 'ok  the table takes no insert of its own (%)', left(sqlerrm, 40);
  end;
  begin
    update public.client_stage_requests set outcome = 'Approved' where id = v_req;
    if found then
      failures := failures || 'FAILED: a request can be decided with an update'::text;
    else
      raise notice 'ok  and no update either';
    end if;
  exception when others then
    raise notice 'ok  and no update either (%)', left(sqlerrm, 40);
  end;
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  -- ── 7. a decline needs a reason, and carries it ────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin.user_id, 'role', 'authenticated')::text, true);
  begin
    perform 1 from public.decide_stage_request(v_req, false, '   ', null, null);
    failures := failures || 'FAILED: a request was declined with nothing said about why'::text;
  exception when check_violation then
    raise notice 'ok  a decline with no reason is refused';
  end;

  select d.said into v_text from public.decide_stage_request(v_req, false, 'ZZ verify: the authorization has not come back', null, null) d;
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  select count(*) into n from public.client_stage_requests q
   where q.id = v_req and q.outcome = 'Declined' and q.decided_by = v_admin.id
     and q.decided_at is not null
     and q.decision_reason = 'ZZ verify: the authorization has not come back';
  if n <> 1 then
    failures := failures || 'FAILED: the decline was not recorded with its reason and its decider'::text;
  else
    raise notice 'ok  a decline records the reason, the decider and the time';
  end if;

  select count(*) into n from public.tasks t where t.id = v_task and t.status = 'Done' and t.done_at is not null;
  if n <> 1 then
    failures := failures || 'FAILED: the administrator''s task is still open after the decision'::text;
  else
    raise notice 'ok  and the administrator''s task closes with it';
  end if;

  select t.id into v_their from public.tasks t
   where t.source_kind = 'stage_request_declined' and t.source_ref = v_req
     and t.assigned_staff_id = v_asker.id and t.status = 'Open';
  if v_their is null then
    failures := failures || 'FAILED: whoever asked was not told the decision on their own list'::text;
  else
    select count(*) into n from public.task_comments c
     where c.task_id = v_their and c.said = 'ZZ verify: the authorization has not come back';
    if n <> 1 then
      failures := failures || 'FAILED: the decline reason is not the note on the asker''s task'::text;
    else
      raise notice 'ok  the asker gets a task with the reason on it';
    end if;
  end if;

  -- And a decided ask is off the board's row.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_asker.user_id, 'role', 'authenticated')::text, true);
  select count(*) into n from public.clients_board_rows() b
   where b.client_id = v_client and b.stage_request_id is not null;
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
  if n <> 0 then
    failures := failures || 'FAILED: a decided ask is still on the board''s row'::text;
  else
    raise notice 'ok  a decided ask is off the row';
  end if;

  -- ── 8. an approval moves them, with both lines and both names ──
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_asker.user_id, 'role', 'authenticated')::text, true);
  select q.request_id into v_req
    from public.request_stage_change(v_client, v_to, 'ZZ verify: the assessment is done') q;
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin.user_id, 'role', 'authenticated')::text, true);
  perform 1 from public.decide_stage_request(v_req, true, 'ZZ verify: agreed', null, null);
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  select count(*) into n from public.clients c where c.id = v_client and c.stage = v_to;
  if n <> 1 then
    failures := failures || 'FAILED: approving did not move the client'::text;
  else
    raise notice 'ok  approving moves them, through the move itself';
  end if;

  -- The one history row for this stage written today: the control went to a
  -- different stage on purpose, so there is no tie to break.
  select h.note into v_text from public.client_stage_history h
   where h.client_id = v_client and h.stage = v_to
   order by h.at desc limit 1;
  if v_text is null
     or v_text not like '%' || v_asker.name || '%'
     or v_text not like '%' || v_admin.name || '%'
     or v_text not like '%the assessment is done%'
     or v_text not like '%agreed%' then
    failures := failures || format('FAILED: the move note does not carry both names and both lines: %s', coalesce(v_text, '(none)'))::text;
  else
    raise notice 'ok  the move log carries who asked, why, who approved and why';
  end if;

  -- Named by the move it recorded rather than by being the most recent,
  -- for the same reason.
  select g.outcome into v_text from public.contact_log g
   where g.client_id = v_client and g.method = 'Stage change'
     and g.topic = v_from || ' to ' || v_to
   order by g.created_at desc limit 1;
  if v_text is null or v_text not like '%' || v_asker.name || '%' or v_text not like '%' || v_admin.name || '%' then
    failures := failures || 'FAILED: the client''s own log does not carry both names'::text;
  else
    raise notice 'ok  and so does the client''s own log';
  end if;

  select count(*) into n from public.client_stage_requests q
   where q.id = v_req and q.outcome = 'Approved' and q.decided_by = v_admin.id
     and q.decision_reason = 'ZZ verify: agreed';
  if n <> 1 then
    failures := failures || 'FAILED: the approved request does not carry the decision'::text;
  else
    raise notice 'ok  the request carries the decision as well as the ask';
  end if;

  -- ── 9. a client already moved closes the ask ───────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_asker.user_id, 'role', 'authenticated')::text, true);
  select q.request_id, q.task_id into v_req, v_task
    from public.request_stage_change(v_client, v_other, 'ZZ verify: and on to the next one') q;
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  -- The administrator moves them there without opening the request.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin.user_id, 'role', 'authenticated')::text, true);
  perform 1 from public.move_client(v_client, v_other, 'ZZ verify: moved without reading the ask');
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  select count(*) into n from public.client_stage_requests q
   where q.id = v_req and q.outcome = 'Approved' and q.decision_reason = 'already moved'
     and q.decided_by = v_admin.id and q.decided_at is not null;
  if n <> 1 then
    failures := failures || 'FAILED: a request whose stage has been reached is still waiting'::text;
  else
    raise notice 'ok  a client moved to the stage that was asked for closes the ask as approved';
  end if;

  select count(*) into n from public.tasks t where t.id = v_task and t.status = 'Done';
  if n <> 1 then
    failures := failures || 'FAILED: the task for a request that closed itself is still open'::text;
  else
    raise notice 'ok  and its task closes with it';
  end if;

  -- ── 10. an approval into Job Placement starts the clock ────
  -- The gap the Part 3 report named, and the owner's answer to it (18 Nov
  -- 2026). The board's Move dialog asked for the employer and the *screen*
  -- wrote the placements row, so an approval - the other door into that stage
  -- - wrote none, and the retention checks and the placement fee both hang off
  -- that row. 0373 moved the writing into `move_client`, which is why this
  -- asks the approve path and the move path for the same thing.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_asker.user_id, 'role', 'authenticated')::text, true);
  select q.request_id into v_req
    from public.request_stage_change(v_client, 'Job Placement', 'ZZ verify: they start on the second') q;
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin.user_id, 'role', 'authenticated')::text, true);
  select d.said into v_text
    from public.decide_stage_request(v_req, true, 'ZZ verify: agreed', v_emp, v_day) d;
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  select count(*) into n from public.placements pl
   where pl.client_id = v_client and pl.employer = v_emp and pl.start_date = v_day;
  if n <> 1 then
    failures := failures || 'FAILED: approving a move into Job Placement left no placement row'::text;
  else
    raise notice 'ok  an approval into Job Placement records the placement and its start date';
  end if;

  if v_text is null or v_text not like '%' || v_emp || '%' then
    failures := failures || format('FAILED: the approval did not say the placement was recorded: %s', coalesce(v_text, '(nothing)'))::text;
  else
    raise notice 'ok  and says so, so nobody has to go and look';
  end if;

  -- Out and back in at the same employer. A second spell at the same place is
  -- not a second placement, and a start date somebody typed is not replaced by
  -- one inferred from a later move (0283 holds the same line on the hire path).
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin.user_id, 'role', 'authenticated')::text, true);
  perform 1 from public.move_client(v_client, v_other, 'ZZ verify: out of placement for a moment');
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_asker.user_id, 'role', 'authenticated')::text, true);
  select q.request_id into v_req
    from public.request_stage_change(v_client, 'Job Placement', 'ZZ verify: back at the same employer') q;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin.user_id, 'role', 'authenticated')::text, true);
  perform 1 from public.decide_stage_request(v_req, true, 'ZZ verify: agreed again', v_emp, v_day + 30);
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  select count(*) into n from public.placements pl
   where pl.client_id = v_client and pl.employer = v_emp;
  if n <> 1 then
    failures := failures || format('FAILED: the same employer twice left %s placement rows', n)::text;
  else
    select count(*) into n from public.placements pl
     where pl.client_id = v_client and pl.employer = v_emp and pl.start_date = v_day;
    if n <> 1 then
      failures := failures || 'FAILED: a later move overwrote the start date somebody typed'::text;
    else
      raise notice 'ok  the same employer again is the same placement, with the start date it already had';
    end if;
  end if;

  -- And Job Placement without the two things the stage means (owner, 19 Nov
  -- 2026). 0373 asked for the employer and insisted on neither, so a client
  -- could reach the stage with no placement, no retention milestone and no fee
  -- to claim - and a sentence saying so. It is a refusal now.
  --
  -- Asked of the approve path three times, because "what is missing" is three
  -- different facts and a person who typed the employer should not be told to
  -- add the employer. The refusal lives in `move_client`, which is how the
  -- approve path gets it without `decide_stage_request` knowing anything about
  -- placements.
  --
  -- Counted before and after rather than against a number. The client this
  -- script borrows is a real one and may already have placements of their own,
  -- so "one row" was an assertion that held only while the table was empty.
  select count(*) into v_rows from public.placements pl where pl.client_id = v_client;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin.user_id, 'role', 'authenticated')::text, true);
  perform 1 from public.move_client(v_client, v_other, 'ZZ verify: out again');
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_asker.user_id, 'role', 'authenticated')::text, true);
  select q.request_id into v_req
    from public.request_stage_change(v_client, 'Job Placement', 'ZZ verify: hired, employer to follow') q;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_admin.user_id, 'role', 'authenticated')::text, true);

  v_text := null;
  begin
    perform 1 from public.decide_stage_request(v_req, true, 'ZZ verify: agreed', '   ', null);
    failures := failures || 'FAILED: an approval into Job Placement with neither the employer nor the start date went through'::text;
  exception when others then
    v_text := sqlerrm;
  end;
  if v_text is not null then
    if v_text not like '%employer%' or v_text not like '%started%' then
      failures := failures || format('FAILED: the refusal did not name both the employer and the day: %s', v_text)::text;
    else
      raise notice 'ok  an approval into Job Placement with neither is refused, naming both';
    end if;
  end if;

  v_text := null;
  begin
    perform 1 from public.decide_stage_request(v_req, true, 'ZZ verify: agreed', '   ', v_day);
    failures := failures || 'FAILED: an approval into Job Placement with no employer went through'::text;
  exception when others then
    v_text := sqlerrm;
  end;
  if v_text is not null then
    if v_text not like '%employer%' or v_text like '%started%' then
      failures := failures || format('FAILED: the refusal for a missing employer named the wrong thing: %s', v_text)::text;
    else
      raise notice 'ok  with the start date and no employer it names the employer, and only that';
    end if;
  end if;

  v_text := null;
  begin
    perform 1 from public.decide_stage_request(v_req, true, 'ZZ verify: agreed', v_emp, null);
    failures := failures || 'FAILED: an approval into Job Placement with no start date went through'::text;
  exception when others then
    v_text := sqlerrm;
  end;
  if v_text is not null then
    if v_text not like '%started%' or v_text like '%employer%' then
      failures := failures || format('FAILED: the refusal for a missing start date named the wrong thing: %s', v_text)::text;
    else
      raise notice 'ok  with the employer and no start date it names the day, and only that';
    end if;
  end if;

  -- And a refusal leaves nothing behind. `decide_stage_request` marks the
  -- request approved before it calls the move, so a refusal that did not undo
  -- itself would close the request and leave the client where they were -
  -- which is the request lost rather than the move refused.
  select c.stage into v_from from public.clients c where c.id = v_client;
  select count(*) into n from public.client_stage_requests q
   where q.id = v_req and q.outcome = 'Waiting';
  if v_from = 'Job Placement' or n <> 1 then
    failures := failures || format('FAILED: a refused approval left them in %s and the request %s', v_from,
                                   case when n = 1 then 'waiting' else 'decided' end)::text;
  else
    raise notice 'ok  and a refused approval leaves them where they were, with the request still waiting';
  end if;

  select count(*) into n from public.placements pl where pl.client_id = v_client;
  if n <> v_rows then
    failures := failures || format('FAILED: a refused approval wrote %s placement row(s)', n - v_rows)::text;
  end if;

  -- The other door, asked the same question. Move is where the two fields were
  -- first asked for and never insisted on, so this is the half of the ruling
  -- that changes an existing screen rather than adding to a new one.
  v_text := null;
  begin
    perform 1 from public.move_client(v_client, 'Job Placement', 'ZZ verify: hired, nothing else known');
    failures := failures || 'FAILED: a move into Job Placement with neither the employer nor the start date went through'::text;
  exception when others then
    v_text := sqlerrm;
  end;
  if v_text is not null then
    if v_text not like '%employer%' or v_text not like '%started%' then
      failures := failures || format('FAILED: the move refusal did not name both: %s', v_text)::text;
    else
      raise notice 'ok  and the Move path is refused in the same words';
    end if;
  end if;

  -- ── 10a. a request already satisfied closes in one click ───
  --
  -- Owner, 19 November 2026: "a stage-change request whose client is already
  -- in the requested stage closes in one click from the requests panel, no
  -- employer/date asked, logged as already there."
  --
  -- The state is reachable, which is why this is a test and not a guard.
  -- `move_client` closes a matching waiting request itself (section 9), but it
  -- is not the only thing that writes a client's stage: `reactivate_client`
  -- writes it directly, so a client who was asked for and then came back into
  -- that very stage leaves the ask waiting with nothing to do.
  --
  -- And the stage is Job Placement on purpose. `decide_stage_request` closes
  -- such a request before it reaches the move, so it reads neither the
  -- employer nor the start date - which is the whole point: the two questions
  -- 0374 added were being asked about a placement that had already happened.
  select count(*) into n from public.client_stage_requests q
   where q.id = v_req and q.outcome = 'Waiting' and q.to_stage = 'Job Placement';
  if n <> 1 then
    failures := failures || 'FAILED: this section needs the refused request still waiting for Job Placement'::text;
  else
    perform 1 from public.reactivate_client(v_client, 'Job Placement',
                                            'ZZ verify: back, and already placed');

    select c.stage into v_from from public.clients c where c.id = v_client;
    select count(*) into n from public.client_stage_requests q
     where q.id = v_req and q.outcome = 'Waiting';
    if v_from <> 'Job Placement' or n <> 1 then
      failures := failures || format('FAILED: the fixture did not reach "already there": stage %s, request %s',
                                     v_from, case when n = 1 then 'waiting' else 'decided' end)::text;
    else
      raise notice 'ok  a client can come back into the stage somebody asked for, leaving the ask waiting';

      select count(*) into v_rows from public.placements pl where pl.client_id = v_client;
      v_text := null;
      begin
        select d.said into v_text
          from public.decide_stage_request(v_req, true, '', null, null) d;
      exception when others then
        failures := failures || format('FAILED: closing a satisfied request was refused: %s', sqlerrm)::text;
      end;

      if v_text is not null then
        select count(*) into n from public.client_stage_requests q
         where q.id = v_req and q.outcome = 'Approved' and q.decision_reason = 'already moved'
           and q.decided_by = v_admin.id and q.decided_at is not null;
        if n <> 1 then
          failures := failures || 'FAILED: approving a satisfied request did not close it as already moved'::text;
        elsif v_text not like '%already in Job Placement%' then
          failures := failures || format('FAILED: closing it did not say they were already there: %s', v_text)::text;
        else
          raise notice 'ok  and Approve closes it in one click, with no employer and no start date, saying they are already there';
        end if;

        select count(*) into n from public.placements pl where pl.client_id = v_client;
        if n <> v_rows then
          failures := failures || format('FAILED: closing a satisfied request wrote %s placement row(s)', n - v_rows)::text;
        else
          raise notice 'ok  and writes no placement, because nobody moved';
        end if;
      end if;
    end if;
  end if;

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  -- ── 11. and anon cannot touch any of it ────────────────────
  perform set_config('role', 'anon', true);
  begin
    perform 1 from public.request_stage_change(v_client, v_to, 'ZZ verify: anon');
    failures := failures || 'FAILED: anon can ask for a client to be moved'::text;
  exception when others then
    raise notice 'ok  anon cannot ask (%)', left(sqlerrm, 40);
  end;
  begin
    perform 1 from public.decide_stage_request(v_req, true, 'ZZ verify: anon', null, null);
    failures := failures || 'FAILED: anon can decide a stage request'::text;
  exception when others then
    raise notice 'ok  anon cannot decide either (%)', left(sqlerrm, 40);
  end;
  perform set_config('role', 'postgres', true);

  if failures = '{}' then
    raise notice '';
    raise notice '--- STAGE REQUESTS VERIFIED ---';
  else
    raise notice '';
    raise notice '%  PROBLEM(S):', array_length(failures, 1);
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
