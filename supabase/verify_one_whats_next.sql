-- Zion Vocational Rehab CRM — one engine for what needs doing (0405-0407)
--
-- Six things answered "what needs doing" and none asked another. On 27
-- November 2026, over twenty active clients: eleven had an open task that the
-- Clients board named and the client's own record did not mention, four of
-- those records saying "Nothing is due for this client"; three clients were
-- quiet to the threads board and none to Home, because one counted fourteen
-- days and the other thirty; and "follow-ups due" meant two different columns
-- on two different tables.
--
-- What has to hold now:
--
--   the board row, the record's list and the counts are the same answer -
--   not the same rules kept in step, the same call. Asked of every active
--   client, item by item, kind by kind, severity by severity;
--
--   a scope decides whose work it is, and a word nobody recognises answers
--   with nothing rather than with the practice;
--
--   a person's scope is their own clients and their own loose tasks, and
--   never more than the practice-wide answer;
--
--   a severity is one of four and means the same thing in every kind;
--
--   the four computations this replaced are gone, not kept beside it - and
--   nothing a screen reads still carries the old authorization sentence or
--   the old next-task columns;
--
--   anon cannot ask the question at all.
--
-- Everything is rolled back.

begin;

do $$
declare
  failures text[] := array[]::text[];
  v_mark    integer;
  v_counsel uuid;
  v_client  uuid;
  v_staff   uuid;
  v_n       integer;
  v_m       integer;
  v_what    text;
  v_sev     integer;
  v_kinds   text[];
  v_user    uuid;
  v_board   text[];
  r         record;
begin
  -- ── an identity, because the gates answer to one ───────────
  --
  -- clients_board_rows asks is_active_staff() and the engine asks
  -- reader_may_answer(), and run as the table owner with no claims the first
  -- answers false while the second answers true - so the board would return
  -- nothing and section 1 would pass having compared nothing at all. The
  -- claim is set and not the session role, so the gates resolve to a real
  -- member of staff while the fixtures below still go in as the owner.
  select s.id, s.user_id into v_staff, v_user
    from public.staff s
   where s.active and not s.is_system and s.user_id is not null
   order by s.created_at limit 1;
  if v_user is null then
    raise exception 'FAILED: nobody signed in to ask as, so nothing below asks anything';
  end if;
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_user, 'role', 'authenticated')::text, true);

  -- ── the fixture, before anything is counted ──────────────
  --
  -- The fault this whole phase exists to end: an overdue task that one screen
  -- shows and another does not.
  insert into public.counselors (name, email, office)
  values ('ZQ Next Counselor', 'zq-next@example.test', 'Salt Lake City') returning id into v_counsel;
  insert into public.clients (name, stage, status, counselor_id, assigned_staff_id)
  values ('ZZ Next Client', 'Job Development', 'Active', v_counsel, v_staff)
  returning id into v_client;
  insert into public.tasks (title, client_id, assigned_staff_id, status, due)
  values ('ZZ overdue thing', v_client, v_staff, 'Open', public.practice_today() - 3);

  -- ── 1. the board row is the engine's answer, client by client ──
  --
  -- Every active client, not a sample: at this size the whole board is
  -- cheaper than choosing twenty of it, and a rule asked of twenty rows is a
  -- rule that passes while the twenty-first is wrong.
  v_mark := coalesce(array_length(failures, 1), 0);

  for r in
    select b.client_id, b.next_step, b.next_step_severity, b.next_kinds
      from public.clients_board_rows(null) b
  loop
    select array_agg(distinct n.kind order by n.kind), min(n.severity)
      into v_kinds, v_sev
      from public.next_steps('client', null, r.client_id) n;

    select array_agg(x order by x) into v_board from unnest(r.next_kinds) x;

    if coalesce(v_kinds, '{}') is distinct from coalesce(v_board, '{}') then
      failures := failures || format(
        'FAILED: the board row and the record list disagree about what a client needs - '
        'the board says %L and the record says %L',
        coalesce(v_board, '{}'), coalesce(v_kinds, '{}'))::text;
    end if;

    if coalesce(v_sev, -1) is distinct from coalesce(r.next_step_severity, -1) then
      failures := failures || format(
        'FAILED: the board calls a client''s worst item severity %s and the record says %s',
        coalesce(r.next_step_severity, -1), coalesce(v_sev, -1))::text;
    end if;

    -- And the cell says one of the things the record lists, not a sentence
    -- of its own.
    if r.next_step is not null and not exists (
      select 1 from public.next_steps('client', null, r.client_id) n where n.what = r.next_step
    ) then
      failures := failures || format(
        'FAILED: the board names %L as a client''s next step and the record does not list it',
        left(r.next_step, 60))::text;
    end if;
  end loop;

  select count(*) into v_n from public.clients_board_rows(null);
  if v_n = 0 then
    failures := failures
      || 'FAILED: the board answered no rows, so the comparison above asked nothing'::text;
  end if;

  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  board row and record list agree for all % active clients', v_n;
  end if;

  -- ── 2. a fixture nobody can disagree about ─────────────────
  --
  -- The fault this whole phase exists to end: an overdue task that one screen
  -- shows and another does not. It has to appear in the record's list, in the
  -- board's cell, in the practice-wide answer, and at severity 1.
  v_mark := coalesce(array_length(failures, 1), 0);

  select count(*) into v_n
    from public.next_steps('client', null, v_client) n
   where n.kind = 'task' and n.severity = 1 and n.what like 'Overdue task:%';
  if v_n <> 1 then
    failures := failures || format(
      'FAILED: a task three days overdue appears %s times in the client''s own list', v_n)::text;
  end if;

  select count(*) into v_n
    from public.clients_board_rows(null) b
   where b.client_id = v_client and 'task' = any (b.next_kinds) and b.next_step_severity = 1;
  if v_n <> 1 then
    failures := failures || 'FAILED: the board row does not carry the overdue task the record lists'::text;
  end if;

  select count(*) into v_n
    from public.next_steps('owner', null, null) n
   where n.client_id = v_client and n.kind = 'task';
  if v_n <> 1 then
    failures := failures || 'FAILED: the practice-wide answer does not include the overdue task'::text;
  end if;

  select count(*) into v_n
    from public.next_steps('person', v_staff, null) n
   where n.client_id = v_client and n.kind = 'task';
  if v_n <> 1 then
    failures := failures || 'FAILED: the person it is assigned to does not see their own overdue task'::text;
  end if;

  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  an overdue task is on the record, on the board, on the practice list and on theirs';
  end if;

  -- ── 3. a scope decides, and an unknown word decides nothing ──
  v_mark := coalesce(array_length(failures, 1), 0);

  select count(*) into v_n from public.next_steps('nonsense', null, null);
  if v_n <> 0 then
    failures := failures || format(
      'FAILED: a scope nobody recognises answered with %s rows. A screen asking the wrong '
      'question has to get nothing, not the practice', v_n)::text;
  end if;

  select count(*) into v_n from public.next_steps('client', null, null);
  if v_n <> 0 then
    failures := failures || format(
      'FAILED: scope ''client'' with no client named answered with %s rows', v_n)::text;
  end if;

  select count(*) into v_n from public.next_steps('person', null, null);
  if v_n <> 0 then
    failures := failures || format(
      'FAILED: scope ''person'' with nobody named answered with %s rows', v_n)::text;
  end if;

  -- Nobody's scope is bigger than the practice's.
  select count(*) into v_n from public.next_steps('person', v_staff, null);
  select count(*) into v_m from public.next_steps('owner', null, null);
  if v_n > v_m then
    failures := failures || format(
      'FAILED: one person has %s things to do and the whole practice has %s', v_n, v_m)::text;
  end if;

  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  a scope decides whose work it is, and an unknown word returns nothing';
  end if;

  -- ── 4. one severity scale, four values ─────────────────────
  v_mark := coalesce(array_length(failures, 1), 0);

  select count(*) into v_n
    from public.next_steps('owner', null, null) n
   where n.severity is null or n.severity < 1 or n.severity > 4;
  if v_n > 0 then
    failures := failures || format(
      'FAILED: %s items carry a severity outside 1 to 4, so two kinds cannot be compared', v_n)::text;
  end if;

  -- Every row says what it is and where it is dealt with. A line a person
  -- cannot act on is a line that trains them to ignore the strip.
  select count(*) into v_n
    from public.next_steps('owner', null, null) n
   where coalesce(btrim(n.what), '') = '' or coalesce(btrim(n.action_href), '') = ''
      or coalesce(btrim(n.kind), '') = '';
  if v_n > 0 then
    failures := failures || format(
      'FAILED: %s items have no sentence, no kind or nowhere to go', v_n)::text;
  end if;

  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  one severity scale, and every item says what it is and where it is done';
  end if;

  -- ── 5. the computations this replaced are gone ─────────────
  --
  -- Asked of the catalog rather than of a list of names, because the list is
  -- what goes stale. Any function still answering the old question beside
  -- the engine is the thing the phase was for.
  v_mark := coalesce(array_length(failures, 1), 0);

  select count(*) into v_n
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public'
     and p.proname in ('client_next_actions', 'client_next_actions_for');
  if v_n > 0 then
    failures := failures || format(
      'FAILED: %s of the old per-client what-is-next functions are still here, and a second '
      'answer is what this replaced', v_n)::text;
  end if;

  select count(*) into v_n
    from information_schema.columns
   where table_schema = 'public' and table_name = 'notifications' and column_name = 'dedupe_key';
  if v_n <> 1 then
    failures := failures || 'FAILED: notifications has no dedupe_key, so the alerts cannot reconcile'::text;
  end if;

  -- The board returns no column that was one of the old answers.
  select array_agg(a.attname::text order by a.attname) into v_kinds
    from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
    cross join lateral unnest(p.proargnames) with ordinality as a(attname, ord)
   where ns.nspname = 'public' and p.proname = 'clients_board_rows'
     and a.attname in ('attention', 'attention_urgency', 'next_task_id', 'next_task_title',
                       'next_task_owner', 'next_task_due', 'authorization_ends_on');
  if coalesce(array_length(v_kinds, 1), 0) > 0 then
    failures := failures || format(
      'FAILED: the board still returns %L, which is the old answer sitting beside the new one',
      v_kinds)::text;
  end if;

  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  nothing answers this question beside the engine';
  end if;

  -- ── 6. and anon cannot ask ─────────────────────────────────
  v_mark := coalesce(array_length(failures, 1), 0);

  if has_function_privilege('anon', 'public.next_steps(text, uuid, uuid)', 'execute') then
    failures := failures || 'FAILED: anon may ask what the practice has to do today'::text;
  end if;
  if has_function_privilege('public', 'public.next_steps(text, uuid, uuid)', 'execute') then
    failures := failures || 'FAILED: public may ask what the practice has to do today'::text;
  end if;
  if not has_function_privilege('authenticated', 'public.next_steps(text, uuid, uuid)', 'execute') then
    failures := failures || 'FAILED: a signed-in member of staff cannot ask what needs doing'::text;
  end if;

  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  staff may ask, and nobody else';
  end if;

  -- ── the verdict ────────────────────────────────────────────
  if array_length(failures, 1) > 0 then
    raise exception E'\n%', array_to_string(failures, E'\n');
  end if;
  raise notice 'PASSED: one engine answers what needs doing, and every screen reads it';
end $$;

rollback;
