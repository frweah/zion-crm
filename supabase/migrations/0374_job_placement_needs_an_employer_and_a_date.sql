-- ─────────────────────────────────────────────────────────────
-- Job Placement needs an employer and a start date
-- ─────────────────────────────────────────────────────────────
-- Owner, 19 November 2026, answering the question 0373 left open: "Job
-- Placement requires an employer and a start date - move_client refuses
-- without them, on both the Move and the Approve path, with a sentence saying
-- what is missing."
--
-- 0373 asked for both and insisted on neither, on the grounds that Move had
-- never insisted either. That left a stage somebody could reach with nothing
-- recorded and a sentence saying so - better than silence, and still a client
-- sitting in Job Placement with no placement, no retention milestone and no
-- fee to claim. The stage *means* a job at an employer on a day. A move that
-- cannot name either is not a move into Job Placement; it is a note.
--
-- So it is a refusal, and it is here rather than on a screen for the reason
-- the rest of this function is here: this is the only door a stage changes
-- through, and there are three screens behind it. The board's Move dialog,
-- the administrator's Approve, and the record's own stage picker all get the
-- same answer, and a fourth door added next month gets it without being
-- told.
--
-- Three sentences rather than one, because "what is missing" is three
-- different facts and a person reading "Job Placement needs the employer and
-- the day they started" when they typed the employer will go looking for the
-- field they already filled in.
--
-- The signature does not change, so this replaces rather than drops: no new
-- overload, and the grants stay where 0373 put them.

begin;

/**
 * Moves a client to a stage, with a note, as 0223; the administrator's
 * signature on it, as 0372; the placement clock, as 0373; and the two things
 * Job Placement means, as of here.
 *
 * The note is still the trigger's refusal, so this function cannot forget it.
 */
create or replace function public.move_client(
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

  /*
   * And what Job Placement means (owner, 19 November 2026).
   *
   * With the other refusals rather than beside the write below, because it is
   * the same kind of thing: a precondition for the move, not a decision about
   * the placement. Nothing has been written when this raises, and nothing
   * will be - a move that cannot say where and when is refused whole.
   */
  if p_stage = 'Job Placement' then
    if v_employer = '' and p_start is null then
      raise exception 'Job Placement needs the employer and the day they started. Add both and move again.'
        using errcode = 'check_violation';
    elsif v_employer = '' then
      raise exception 'Job Placement needs the employer. Add it and move again.'
        using errcode = 'check_violation';
    elsif p_start is null then
      raise exception 'Job Placement needs the day they started. Add it and move again.'
        using errcode = 'check_violation';
    end if;
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
   *
   * There is no "no employer" branch here any more. The refusal above means
   * both are in hand by the time this runs.
   */
  if p_stage = 'Job Placement' then
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
  'Moves a client to a stage with a note, writes the stage history and the contact log, refuses an empty note, refuses anybody but an administrator, refuses Job Placement without an employer and a start date, closes any request that asked for the stage it reached, and records the placement when the stage reached is Job Placement (0223, 0372, 0373, 0374).';

commit;
