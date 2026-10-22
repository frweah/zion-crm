-- Zion Vocational Rehab CRM — 0223 the clients board
--
-- Clients opens on a board of the active caseload, one card per person under
-- the stage they are in (owner, 22 Oct 2026). Seven columns, fixed, in the
-- order the work happens.
--
-- Three things live here rather than in the screen, because all three are
-- rules rather than decoration:
--
--   A move needs a note. Not "the form asks for one" - the database refuses
--   the move without one, so a stage cannot change by any route without
--   somebody saying why. That is enforced in the trigger that already writes
--   the stage history, which means it covers the board, the record screen,
--   an import and a hand-written update alike.
--
--   Closing a client refuses while an authorization is Submitted and unpaid.
--   Money that is out with USOR is not somebody's to tidy away.
--
--   The board is one query. Not one per column and not one per card: the
--   screen has to hold under a second at 500 clients and the only way to be
--   sure of that is to ask once.
--
-- ─────────────────────────────────────────────────────────────
-- The seven stages, and what the old ones become
-- ─────────────────────────────────────────────────────────────
--
-- Referral, Placement and Follow-Along were the practice's words for three of
-- these; Closed was a stage as well as a status, which is the one that had to
-- go. A client whose stage said Closed keeps the last stage they were really
-- in, read out of their own history, and falls back to Intake only if there
-- is nothing to read. Job Search and Life Skills are new and start empty.
--
--   Referral        -> Intake
--   Intake          -> Intake
--   Assessment      -> Assessment          (shown as "Assessment (WSA)")
--   Job Development -> Job Development
--   Placement       -> Job Placement
--   Job Coaching    -> Job Coaching
--   Follow-Along    -> Job Coaching        (owner, 22 Oct: it is coaching)
--   Closed          -> their last real stage, else Intake
--
-- The stored value stays "Assessment". The column is headed "Assessment
-- (WSA)" because that is what the practice calls it out loud, and a heading
-- is where a clarification belongs - not in every history row written since
-- February.

-- The trigger is stood down for the remapping: these are not moves anybody
-- made and there is nobody to attribute a note to.
-- Only the stage-history trigger is stood down, and only on clients: the
-- foreign-key triggers on the history table are the system's and not ours to
-- touch. The client change log is left running and told what this is.
-- The old constraint comes off first: the remap below writes names it was
-- never told about, and a check constraint does not care that the row is
-- on its way somewhere allowed.
alter table public.clients drop constraint if exists clients_stage_check;
alter table public.clients disable trigger clients_stage_history;
select set_config('zion.directory_reason', 'Stage renamed by 0223 (the clients board)', false);

update public.clients set stage = 'Intake'         where stage = 'Referral';
update public.clients set stage = 'Job Placement'  where stage = 'Placement';
update public.clients set stage = 'Job Coaching'   where stage = 'Follow-Along';

-- The ones whose stage was Closed: the last stage they were in that was not
-- Closed, mapped the same way, and Intake when there is none.
with last_real as (
  select distinct on (h.client_id) h.client_id, h.stage
    from public.client_stage_history h
   where h.stage <> 'Closed'
   order by h.client_id, h.at desc, h.created_at desc
)
update public.clients c
   set stage = coalesce(
     case l.stage
       when 'Referral'     then 'Intake'
       when 'Placement'    then 'Job Placement'
       when 'Follow-Along' then 'Job Coaching'
       else l.stage
     end, 'Intake')
  from last_real l
 where c.id = l.client_id and c.stage = 'Closed';

update public.clients set stage = 'Intake' where stage = 'Closed';

-- The history is remapped too, so a card's past reads in the same words as
-- its present.
update public.client_stage_history set stage = 'Intake'        where stage = 'Referral';
update public.client_stage_history set stage = 'Job Placement' where stage = 'Placement';
update public.client_stage_history set stage = 'Job Coaching'  where stage = 'Follow-Along';
update public.client_stage_history set stage = 'Intake'        where stage = 'Closed';

alter table public.clients enable trigger clients_stage_history;
select set_config('zion.directory_reason', '', false);

alter table public.clients add constraint clients_stage_check
  check (stage = any (array[
    'Intake'::text, 'Assessment'::text, 'Job Development'::text, 'Job Search'::text,
    'Life Skills'::text, 'Job Placement'::text, 'Job Coaching'::text]));

-- The history is deliberately NOT constrained to the seven.
--
-- It is a record of what happened, not a list of what is allowed. Constrain
-- it and the next time the stages change, every row written before becomes
-- invalid and the table cannot be read back without rewriting the past. The
-- column that has to be one of the seven is clients.stage, which is the one
-- the board reads.
alter table public.client_stage_history drop constraint if exists client_stage_history_stage_check;

alter table public.clients alter column stage set default 'Intake';

-- ─────────────────────────────────────────────────────────────
-- A move is a record, not a field change
-- ─────────────────────────────────────────────────────────────
alter table public.client_stage_history
  add column if not exists from_stage  text,
  add column if not exists note        text not null default '',
  add column if not exists document_id uuid references public.attachments(id) on delete set null,
  add column if not exists at_time     timestamptz not null default now();

comment on column public.client_stage_history.from_stage is
  'The stage they came from. Null on the first row, which is an arrival rather than a move.';
comment on column public.client_stage_history.note is
  'Why. Required on every move by log_stage_change (0223); empty only on the rows written before it.';
-- Every row that existed before this migration took now() from the column
-- default, which made every card nought days old on the first board anybody
-- looked at. The real date is in `at`, so the mis-stamped rows are exactly
-- the ones whose two dates disagree.
update public.client_stage_history
   set at_time = at::timestamptz
 where at_time::date <> at;

comment on column public.client_stage_history.at_time is
  'When, to the second. `at` is a date and two moves in a morning were indistinguishable.';

/**
 * The stage history, and the refusal.
 *
 * The note arrives on `zion.stage_note`, the way the client change log takes
 * its reason, because a trigger cannot be passed an argument. move_client()
 * sets it; anything else that changes a stage has to set it too, and that is
 * the point rather than an inconvenience.
 *
 * An INSERT is exempt: a new client arriving in Intake has not moved from
 * anywhere and there is nobody to explain.
 */
create or replace function public.log_stage_change()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_note text := coalesce(nullif(current_setting('zion.stage_note', true), ''), '');
  v_doc  uuid := nullif(current_setting('zion.stage_document', true), '')::uuid;
begin
  if tg_op = 'INSERT' then
    insert into public.client_stage_history (client_id, stage, from_stage, note, staff_id)
    values (new.id, new.stage, null, '', public.current_staff_id());
    return new;
  end if;

  if new.stage is distinct from old.stage then
    if v_note = '' then
      raise exception 'Say why % is moving to %. A move without a note is not a move anybody can follow.',
        coalesce(new.name, 'this client'), new.stage
        using errcode = 'check_violation';
    end if;
    insert into public.client_stage_history
      (client_id, stage, from_stage, note, document_id, staff_id)
    values (new.id, new.stage, old.stage, v_note, v_doc, public.current_staff_id());
  end if;
  return new;
end;
$$;

-- ─────────────────────────────────────────────────────────────
-- Moving a client
-- ─────────────────────────────────────────────────────────────
/**
 * One move: the stage, the note, and the line in the contact log.
 *
 * Everybody who can see Clients can move a card (owner, 22 Oct). The refusal
 * that matters is the note, and it is the trigger's, so this function cannot
 * forget it.
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
begin
  if public.current_staff_id() is null then
    raise exception 'Only a member of staff moves a client.' using errcode = 'insufficient_privilege';
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

  from_stage := v_from;
  to_stage := p_stage;
  at_time := now();
  return next;
end;
$$;

comment on function public.move_client is
  'Moves a client to a stage with a note, writes the stage history and the contact log, and refuses an empty note (0223).';

revoke all on function public.move_client(uuid, text, text, uuid) from anon, authenticated;
grant execute on function public.move_client(uuid, text, text, uuid) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- Closing a client, and bringing one back
-- ─────────────────────────────────────────────────────────────
/**
 * Close: a reason, and a refusal while money is out.
 *
 * A Submitted authorization that has not been paid is with USOR. Closing the
 * client would take the person off the board and close the authorization with
 * them, and then nobody is chasing a payment that is still owed. So it
 * refuses, and says which one.
 *
 * Admin, Intake & Client Reports, and Billing (owner, 22 Oct).
 */
create or replace function public.close_client(p_client uuid, p_reason text)
returns table (closed_authorizations integer)
language plpgsql security definer set search_path = public as $$
declare
  v_role    text := public.current_staff_role();
  v_name    text;
  v_waiting text;
  v_id      uuid;
  v_n       integer := 0;
begin
  if v_role not in ('Admin', 'Reports', 'Billing') then
    raise exception 'Closing a client is for Admin, Intake & Client Reports, or Billing.'
      using errcode = 'insufficient_privilege';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'Say why they are being closed.' using errcode = 'check_violation';
  end if;

  select c.name into v_name from public.clients c where c.id = p_client for update;
  if not found then raise exception 'That client is not there.'; end if;

  select string_agg(coalesce(nullif(a.number, ''), '(no number)'), ', ')
    into v_waiting
    from public.authorizations a
   where a.client_id = p_client and a.status = 'Submitted' and a.paid_on is null;

  if v_waiting is not null then
    raise exception '% has % still with USOR and unpaid. Chase or record the payment before closing them.',
      v_name, v_waiting using errcode = 'check_violation';
  end if;

  for v_id in
    select a.id from public.authorizations a
     where a.client_id = p_client and a.status in ('Authorized', 'Due')
  loop
    perform public.set_authorization_status(v_id, 'Closed', btrim(p_reason), null);
    v_n := v_n + 1;
  end loop;

  perform set_config('zion.directory_reason', btrim(p_reason), true);
  update public.clients set status = 'Inactive' where id = p_client;
  perform set_config('zion.directory_reason', '', true);

  insert into public.contact_log (client_id, date, method, topic, outcome, staff_id)
  values (p_client, public.practice_today(), 'Closed', 'Taken off the board',
          btrim(p_reason), public.current_staff_id());

  closed_authorizations := v_n;
  return next;
end;
$$;

comment on function public.close_client is
  'Takes a client off the board with a reason, closing their open authorizations. Refuses while one is Submitted and unpaid (0223).';

revoke all on function public.close_client(uuid, text) from anon, authenticated;
grant execute on function public.close_client(uuid, text) to authenticated;

/**
 * Back on the board, into a stage somebody chose.
 *
 * The note goes through the same trigger as any other move when the stage
 * changes; when they come back to the stage they left, there is no move to
 * record and the note lands in the contact log alone.
 */
create or replace function public.reactivate_client(p_client uuid, p_stage text, p_note text)
returns table (stage text)
language plpgsql security definer set search_path = public as $$
declare
  v_from text;
begin
  if public.current_staff_id() is null then
    raise exception 'Only a member of staff reactivates a client.' using errcode = 'insufficient_privilege';
  end if;
  if coalesce(btrim(p_note), '') = '' then
    raise exception 'Say why they are coming back.' using errcode = 'check_violation';
  end if;

  select c.stage into v_from from public.clients c where c.id = p_client for update;
  if not found then raise exception 'That client is not there.'; end if;

  perform set_config('zion.directory_reason', btrim(p_note), true);
  perform set_config('zion.stage_note', btrim(p_note), true);
  update public.clients set status = 'Active', stage = p_stage where id = p_client;
  perform set_config('zion.stage_note', '', true);
  perform set_config('zion.directory_reason', '', true);

  insert into public.contact_log (client_id, date, method, topic, outcome, staff_id)
  values (p_client, public.practice_today(), 'Reactivated',
          'Back on the board in ' || p_stage, btrim(p_note), public.current_staff_id());

  stage := p_stage;
  return next;
end;
$$;

comment on function public.reactivate_client is
  'Puts a client back on the board in a chosen stage with a note (0223).';

revoke all on function public.reactivate_client(uuid, text, text) from anon, authenticated;
grant execute on function public.reactivate_client(uuid, text, text) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- The board, in one query
-- ─────────────────────────────────────────────────────────────
/**
 * Every card on the board, with everything a card shows.
 *
 * One query, because the screen has to hold under a second at 500 clients and
 * a query per column is seven, a query per card is five hundred. The two
 * things that could have been per-card - the services currently authorized
 * and the one alert - are aggregated here over the whole caseload at once,
 * the way billing_worklist learned to in 0206.
 *
 * The chip is not stored and cannot be set by hand: it is the lowest-urgency
 * line authorization_attention_for gives for any of that client's live
 * authorizations, which is the same single-alert rule the record screen and
 * the working list already show.
 */
drop function if exists public.clients_board(date);

create or replace function public.clients_board(p_today date default null)
returns table (
  client_id    uuid,
  name         text,
  stage        text,
  goal         text,
  counselor    text,
  assigned_to  text,
  days_in_stage integer,
  services     text[],
  chip         text,
  chip_urgency integer,
  last_note    text,
  last_note_on date
)
language sql stable security definer set search_path = public as $$
  with me as (select coalesce(p_today, public.practice_today()) as today),
  board as (
    select c.id, c.name, c.stage, c.target_jobs, c.counselor_id, c.assigned_staff_id
      from public.clients c
      -- Staff only, said here rather than left to the tables. This function
      -- is security definer, which is what lets it gather the whole caseload
      -- in one pass - and would also let any signed-in account ask for it,
      -- including a client with a portal login. Asserted by
      -- verify_portal_rls, which counts elevated functions that never check
      -- who is calling.
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
    select a.id, a.client_id, a.service_type
      from public.authorizations a
      join board b on b.id = a.client_id
     where a.status not in ('Paid', 'Closed')
  ),
  tags as (
    select l.client_id, array_agg(distinct l.service_type) as services
      from live l group by l.client_id
  ),
  alert as (
    select distinct on (l.client_id) l.client_id, t.attention, t.urgency
      from live l
      join public.authorization_attention_for(
             array(select id from live), (select today from me)) t on t.auth_id = l.id
     where coalesce(t.attention, '') <> ''
     order by l.client_id, t.urgency
  ),
  -- The latest line of the client's own log, for the panel that opens when
  -- somebody clicks a card. Gathered here rather than fetched on the click:
  -- it is one more lateral over a caseload, against a round trip per card.
  note as (
    select distinct on (g.client_id) g.client_id,
           nullif(btrim(coalesce(g.outcome, '')), '') as outcome, g.date
      from public.contact_log g
      join board b on b.id = g.client_id
     order by g.client_id, g.date desc, g.created_at desc
  )
  select b.id, b.name, b.stage,
         nullif(btrim(coalesce(b.target_jobs, '')), ''),
         co.name, st.name,
         greatest((select today from me) - coalesce(s.since, (select today from me)), 0)::int,
         coalesce(t.services, '{}'::text[]),
         al.attention, al.urgency,
         n.outcome, n.date
    from board b
    left join public.counselors co on co.id = b.counselor_id
    left join public.staff st on st.id = b.assigned_staff_id
    left join since s on s.client_id = b.id
    left join tags t on t.client_id = b.id
    left join alert al on al.client_id = b.id
    left join note n on n.client_id = b.id
   order by b.stage, b.name;
$$;

comment on function public.clients_board is
  'Every active client as a card: stage, goal, counselor, assigned staff, days in stage, the services currently authorized, and the one alert (0223). One query for the whole board.';

revoke all on function public.clients_board(date) from anon, authenticated;
grant execute on function public.clients_board(date) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- The ladder the reports climb
-- ─────────────────────────────────────────────────────────────
--
-- stage_rank and client_stages_reached both held the old eight by name, so
-- after the remap they ranked nothing and credited nobody. They take the
-- board's order now, which is the order the owner put the columns in and the
-- order the work happens.

create or replace function public.stage_rank(p_stage text)
returns integer language sql immutable as $$
  select case p_stage
    when 'Intake'          then 1
    when 'Assessment'      then 2
    when 'Job Development' then 3
    when 'Job Search'      then 4
    when 'Life Skills'     then 5
    when 'Job Placement'   then 6
    when 'Job Coaching'    then 7
    else null
  end;
$$;

comment on function public.stage_rank is
  'Where a stage sits on the board, left to right (0223). Null for anything that is not one of the seven.';

create or replace view public.client_stages_reached as
  select c.id as client_id, s.stage
    from public.clients c
   cross join lateral (
     select unnest(array[
       'Intake'::text, 'Assessment'::text, 'Job Development'::text, 'Job Search'::text,
       'Life Skills'::text, 'Job Placement'::text, 'Job Coaching'::text]) as stage
   ) s
   where exists (
           select 1 from public.client_stage_history sh
            where sh.client_id = c.id and sh.stage = s.stage)
      or (public.stage_rank(c.stage) is not null
          and public.stage_rank(c.stage) >= public.stage_rank(s.stage));

-- `create or replace view` does not carry the view's options over, and the
-- one this view had is the one that matters: without security_invoker the
-- view reads as its owner and a portal client can see all 303 rows of who
-- reached what. Put back, and asserted by verify_portal_rls.
alter view public.client_stages_reached set (security_invoker = true);
grant select on public.client_stages_reached to authenticated;
