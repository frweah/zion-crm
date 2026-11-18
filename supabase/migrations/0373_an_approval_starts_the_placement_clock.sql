-- ─────────────────────────────────────────────────────────────
-- An approval starts the placement clock
-- ─────────────────────────────────────────────────────────────
-- Owner, 18 November 2026, on the gap the Part 3 report named: "Approving a
-- request into Job Placement asks for employer and start date, same as Move,
-- and writes the placements row."
--
-- The board's Move dialog has asked those two questions since the kanban card
-- did, and the *screen* wrote the placements row - which meant the other door
-- into Job Placement, an administrator approving somebody else's request,
-- wrote none. A client could reach Job Placement with no placement row, and
-- the retention checks and the placement fee both hang off that row, so the
-- clock simply never started.
--
-- So the row is written here, in `move_client`, for the reason the "already
-- moved" tidying up is here: this is the only door a stage changes through.
-- One place writes it, one rule governs it, and both doors get it for free.
--
-- Two signatures change, so both functions are dropped and recreated rather
-- than replaced. A defaulted parameter added to a live function is a *second*
-- function with the old one's grants still on it (0295's lesson), and a
-- changed return type will not replace at all.
--
--   move_client           gains p_employer and p_start, and returns `said` -
--                         one sentence about the placement, or nothing when
--                         the stage is not Job Placement.
--   decide_stage_request  gains the same two and passes them through.
--
-- What is deliberately *not* here: a refusal. An employer is asked for and
-- not insisted on, which is what Move has always done. A move into Job
-- Placement with the field left blank still goes through - and now says so,
-- rather than recording nothing and looking like it worked.

begin;

-- ─────────────────────────────────────────────────────────────
-- The one door a stage changes through
-- ─────────────────────────────────────────────────────────────
drop function if exists public.move_client(uuid, text, text, uuid);

/**
 * Moves a client to a stage, with a note, as 0223; the administrator's
 * signature on it, as 0372; and the placement clock, as of here.
 *
 * The note is still the trigger's refusal, so this function cannot forget it.
 */
create function public.move_client(
  p_client   uuid,
  p_stage    text,
  p_note     text,
  p_document uuid default null,
  p_employer text default null,
  p_start    date default null
)
returns table (from_stage text, to_stage text, at_time timestamptz, said text)
language plpgsql security definer set search_path = public as $$
declare
  v_from     text;
  v_name     text;
  v_employer text := btrim(coalesce(p_employer, ''));
  v_place    uuid;
  r          record;
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
   * And the placement clock, which is what Job Placement means (owner, 18 Nov
   * 2026).
   *
   * `placement_clock_started` (0283) is the other way a placement begins - the
   * hire that came from a job match - and it does far more: the four-week
   * retention milestone, the placement authorization, the bill-by date. This
   * is the lighter case, somebody typing where they started, and it leaves the
   * row that path later fills in rather than a second row beside it. Which is
   * why an employer they already have a placement at is not a new one, and why
   * a start date already on the row is not overwritten: what somebody typed
   * beats what was inferred from a move.
   */
  if p_stage = 'Job Placement' then
    if v_employer = '' then
      said := 'no employer, so no placement is recorded and the fee clock has not started';
    else
      select pl.id into v_place
        from public.placements pl
       where pl.client_id = p_client
         and lower(btrim(pl.employer)) = lower(v_employer)
       order by pl.created_at desc
       limit 1;

      if v_place is null then
        insert into public.placements (client_id, employer, start_date)
        values (p_client, v_employer, p_start);
      else
        update public.placements pl
           set start_date = coalesce(pl.start_date, p_start)
         where pl.id = v_place;
      end if;
      said := format('the placement at %s is recorded', v_employer);
    end if;
  end if;

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
  'Moves a client to a stage with a note, writes the stage history and the contact log, refuses an empty note, refuses anybody but an administrator, closes any request that asked for the stage it reached, and records the placement when the stage reached is Job Placement (0223, 0372, 0373).';

revoke all on function public.move_client(uuid, text, text, uuid, text, date) from public, anon;
grant execute on function public.move_client(uuid, text, text, uuid, text, date) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- Deciding one
-- ─────────────────────────────────────────────────────────────
drop function if exists public.decide_stage_request(uuid, boolean, text);

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
 * `p_employer` and `p_start` are the same two questions Move asks, for the
 * same reason: an approval into Job Placement is how somebody reaches that
 * stage, and the placement clock starts there or not at all. They are passed
 * through rather than used here, so there is one rule about placements and it
 * is in `move_client`.
 *
 * None of the three has a default on purpose: a defaulted argument is a second
 * signature, and the screens always send the field.
 */
create function public.decide_stage_request(
  p_request  uuid,
  p_approve  boolean,
  p_reason   text,
  p_employer text,
  p_start    date
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
  v_moved   record;
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
    select * into v_moved
      from public.move_client(q.client_id, q.to_stage, v_note, null, p_employer, p_start);

    update public.tasks set status = 'Done', done_at = now()
     where id = q.task_id and status = 'Open';

    outcome := 'Approved';
    -- What the move had to say about the placement, where there was anything
    -- to say. An approval into Job Placement with the employer left blank is
    -- the one worth reading: it went through, and the clock did not start.
    said := format('%s moved to %s%s.', v_name, q.to_stage,
                   case when coalesce(v_moved.said, '') = '' then '' else ' — ' || v_moved.said end);
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
  'An administrator approves a stage request - which moves the client, with both reasons and both names on the note, and records the placement where the stage asked for was Job Placement - or declines it with a reason the asker is given as a task (0372, 0373).';

revoke all on function public.decide_stage_request(uuid, boolean, text, text, date) from public, anon;
grant execute on function public.decide_stage_request(uuid, boolean, text, text, date) to authenticated;

commit;
