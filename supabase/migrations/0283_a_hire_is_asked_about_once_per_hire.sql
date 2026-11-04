-- A hire is asked about once per hire, not once ever
--
-- `notify_person` finds the My day item it has already raised by where it came
-- from:
--
--     where source_kind = p_kind
--       and source_ref is not distinct from p_source
--       and assigned_staff_id = p_staff
--       and status = 'Open'
--
-- which is right, and is how a re-poll over the same document leaves one line
-- rather than two. But `is not distinct from null` matches **every** open item
-- of that kind with no source on it. Every other caller passes the document
-- the item came from. `placement_clock_started` passed null, twice:
--
--   * Margaret's "Request a placement authorization for <name>"
--   * Rei's "Four weeks since <name> started at <employer>"
--
-- So the first hire that needed either one raised it, and from then on every
-- other hire matched that same open row and raised nothing. One client was
-- hired through this path on 2 November and holds both rows, which means the
-- next hire would have been the first to lose them: Margaret would not be
-- asked for the authorization and Rei would not be told the milestone date -
-- and the milestone is what the placement is billed on.
--
-- Nothing on screen would have said so. The notification bell was keyed on the
-- match all along, so the bell rang for the second hire while My day stayed
-- silent, and a missing task looks the same as a task nobody needed.
--
-- The fix is the source, not the lookup. Each item names the thing it is about:
-- the match for the authorization that was asked for, the placement for the
-- milestone that was set. Two different uuids, so the two items cannot collide
-- with each other even if one person is both the intake and the placement
-- staff member - and both are stable across a re-run, so the re-poll property
-- the lookup exists for still holds.
--
-- Found by `verify_the_chasing_rules.sql`, which started failing the day after
-- a real hire took the one row Margaret was allowed to have. The body below is
-- the live definition with those two arguments changed and nothing else.

CREATE OR REPLACE FUNCTION public.notify_person(p_staff uuid, p_kind text, p_text text, p_ref text, p_href text DEFAULT NULL::text, p_client uuid DEFAULT NULL::uuid, p_task_title text DEFAULT NULL::text, p_due date DEFAULT NULL::date, p_level text DEFAULT 'warn'::text, p_source uuid DEFAULT NULL::uuid)
 RETURNS TABLE(staff_name text, email text, message text, task_id uuid, already boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  st       public.staff;
  v_key    text := p_kind || ':' || p_ref;
  v_task   uuid;
  v_fresh  boolean := false;
begin
  select * into st from public.staff where id = p_staff and active;
  if not found then
    raise exception 'There is nobody active to notify (%).', p_staff
      using errcode = 'no_data_found';
  end if;
  if coalesce(btrim(p_text), '') = '' then
    raise exception 'A notification with no words in it says nothing.'
      using errcode = 'check_violation';
  end if;

  -- ── the bell ───────────────────────────────────────────────
  insert into public.notifications (dedupe_key, kind, level, text, roles, href, client_id, staff_id)
  values (v_key, p_kind, p_level, p_text, array[st.role], p_href, p_client, p_staff)
  on conflict (dedupe_key) do nothing;
  if found then
    v_fresh := true;
  end if;

  -- ── My day ─────────────────────────────────────────────────
  -- The same item, not a second one: looked for by where it came from before
  -- it is raised, so a re-send does not leave Margaret two identical lines.
  -- Keyed on the assignee as well as the source, because one document can
  -- raise an item for two people - a placement authorization is Margaret's to
  -- confirm and Rei's to act on - and those are two items, not a collision.
  if coalesce(btrim(p_task_title), '') <> '' then
    -- An item has to say what it is about, or the lookup below collapses every
    -- client's item into one. `is not distinct from null` matches every open
    -- item of the kind that has no source on it, so the first one raised takes
    -- the only row the kind is allowed, and every later one finds it and
    -- raises nothing. That is how one hire took the only "request a placement
    -- authorization" the practice would ever get (0282), and how the aggregate
    -- document task and the per-client chase task - both
    -- `authorization_missing` - took turns blocking each other.
    --
    -- Refused rather than worked around: a caller that cannot name the thing
    -- is a caller that has not decided what the item is about, and the one
    -- genuine whole-practice item names itself with a constant.
    if p_source is null then
      raise exception 'A My day item has to say what it is about (% for %).', p_task_title, p_kind
        using errcode = 'check_violation';
    end if;
    select id into v_task from public.tasks
     where source_kind = p_kind
       and source_ref is not distinct from p_source
       and assigned_staff_id = p_staff
       and status = 'Open';
    if v_task is null then
      insert into public.tasks
        (title, client_id, assigned_staff_id, due, status, system_generated, source_kind, source_ref)
      values (p_task_title, p_client, p_staff, coalesce(p_due, public.practice_today()),
              'Open', true, p_kind, p_source)
      returning id into v_task;
      v_fresh := true;
    end if;
  end if;

  -- ── and the words for the email ────────────────────────────
  -- Returned rather than sent: the words are written once, here. Nothing is
  -- returned when neither the bell nor My day had anything new, so a second
  -- poll over the same document sends no second email.
  if not v_fresh then
    return;
  end if;
  return query select st.name, st.email, p_text, v_task, false;
end;
$function$

;

CREATE OR REPLACE FUNCTION public.placement_clock_started(p_match uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  cfg        public.org_settings;
  m          public.lead_matches;
  v_client   public.clients;
  v_employer text := '';
  v_title    text := '';
  v_place    uuid;
  v_auth     uuid;
  v_hired    date;
  v_due      date;
  v_notify   jsonb := '[]'::jsonb;
  r          record;
begin
  select * into cfg from public.org_settings limit 1;
  select * into m from public.lead_matches where id = p_match;
  if not found or m.status <> 'Hired' then
    raise exception 'That job match is not a hire (%).', p_match using errcode = 'no_data_found';
  end if;
  select * into v_client from public.clients where id = m.client_id;

  v_hired := coalesce(m.decided_on, public.practice_today());

  -- Four weeks, and this is the retention milestone only: whether the
  -- placement held. It was the same number as the bill-by until 0188 moved
  -- that to seven days, which is exactly why the two are now named apart -
  -- one number serving two purposes is one of them changing and breaking the
  -- other. Billing's date is computed from bill_by_defaults, below.
  v_due := v_hired + 28;

  select l.title, e.name into v_title, v_employer
    from public.job_leads l join public.employers e on e.id = l.employer_id
   where l.id = m.lead_id;

  -- ── the four-week retention milestone ──────────────────────
  -- Rei's check on whether the placement held, and nothing to do with when
  -- the bill goes out (0188). Set as the match's own follow-up date: the existing
  -- reminder sync (0117) turns that field into a task and a calendar entry and
  -- pushes it to Outlook. Written as its own update statement naming the
  -- column, because that sync fires on `update of ... follow_up_on` - which is
  -- about the columns a statement names, not about what changed. A BEFORE
  -- trigger setting the field does not fire it, which is how the first version
  -- of this quietly put nothing on the calendar.
  if m.follow_up_on is null then
    update public.lead_matches set follow_up_on = v_due where id = p_match;
  end if;

  -- ── the placement, with its start date ─────────────────────
  v_place := m.placement_id;
  if v_place is null then
    insert into public.placements (client_id, employer, title, start_date)
    values (m.client_id, coalesce(v_employer, ''), coalesce(v_title, ''), v_hired)
    returning id into v_place;
    update public.lead_matches set placement_id = v_place where id = p_match;
  else
    -- An existing placement keeps everything except a start date it has not
    -- got. What somebody typed is not overwritten by a hire date.
    update public.placements set start_date = coalesce(start_date, v_hired)
     where id = v_place;
  end if;

  -- ── the placement authorization ────────────────────────────
  select a.id into v_auth
    from public.authorizations a
   where a.client_id = m.client_id
     and a.service_type in ('Job Placement', 'Job Placement (SE)')
     and a.status not in ('Paid', 'Closed')
     and a.parent_id is null
   order by a.start_date desc nulls last
   limit 1;

  if v_auth is null then
    -- The brief's carve-out: a hire does not conjure an authorization.
    for r in select * from public.notify_person(
      cfg.intake_staff_id, 'placement_authorization',
      format('%s was hired at %s on %s and has no placement authorization. Ask the counselor for one.',
             v_client.name, coalesce(nullif(v_employer, ''), 'an employer'),
             to_char(v_hired, 'FMDD FMMonth')),
      p_match::text, '/clients/' || m.client_id::text, m.client_id,
      format('Request a placement authorization for %s', v_client.name),
      public.practice_today(), 'bad', p_match)
    loop
      v_notify := v_notify || jsonb_build_object('name', r.staff_name, 'email', r.email, 'message', r.message);
    end loop;
  else
    -- The first day of work is the fact; the bill-by follows from it, computed
    -- by the same function the rest of the billing uses - a week, since 0188,
    -- and nothing here needs to know that.
    update public.authorizations a set
      first_work_day = coalesce(a.first_work_day, v_hired),
      bill_by = public.bill_by_for(a.service_type, coalesce(a.received_on, a.created_at::date),
                                   a.period, coalesce(a.first_work_day, v_hired))
     where a.id = v_auth;
  end if;

  -- ── Rei hears, with the milestone date ─────────────────────
  if cfg.placement_staff_id is not null then
    for r in select * from public.notify_person(
      cfg.placement_staff_id, 'placement_authorization',
      format('%s started at %s on %s. The four-week milestone is %s.',
             v_client.name, coalesce(nullif(v_employer, ''), 'an employer'),
             to_char(v_hired, 'FMDD FMMonth'), to_char(v_due, 'FMDD FMMonth')),
      p_match::text || ':hired', '/clients/' || m.client_id::text, m.client_id,
      format('Four weeks since %s started at %s', v_client.name,
             coalesce(nullif(v_employer, ''), 'an employer')),
      v_due, 'warn', v_place)
    loop
      v_notify := v_notify || jsonb_build_object('name', r.staff_name, 'email', r.email, 'message', r.message);
    end loop;
  end if;

  return jsonb_build_object(
    'placement_id', v_place,
    'authorization_id', v_auth,
    'started_on', v_hired,
    'milestone_on', v_due,
    'notify', v_notify);
end;
$function$

;

-- ─────────────────────────────────────────────────────────────
-- Two hires, two of each item
--
-- The fault put back is the point of this block: with `null` in place of the
-- match and the placement, the second hire raises nothing at all and both
-- counts below come back 1.

do $$
declare
  v_counsel uuid; v_lead uuid; v_employer uuid; v_rei uuid; v_margaret uuid;
  v_c1 uuid; v_c2 uuid; v_m1 uuid; v_m2 uuid;
  v_ask integer; v_mile integer;
begin
  select intake_staff_id, placement_staff_id into v_margaret, v_rei
    from public.org_settings limit 1;
  if v_margaret is null or v_rei is null then
    raise exception 'org_settings does not say who hears about intake and placements';
  end if;

  insert into public.counselors (name, email, office)
  values ('ZQ Hire Counselor', 'zq-hire@example.test', 'Salt Lake City')
  returning id into v_counsel;
  insert into public.employers (name) values ('ZZ Hire Employer') returning id into v_employer;
  insert into public.job_leads (employer_id, title) values (v_employer, 'ZZ Shelf Stacker')
  returning id into v_lead;

  insert into public.clients (name, stage, status, counselor_id, assigned_staff_id)
  values ('ZZ Hired First', 'Job Placement', 'Active', v_counsel, v_rei) returning id into v_c1;
  insert into public.clients (name, stage, status, counselor_id, assigned_staff_id)
  values ('ZZ Hired Second', 'Job Placement', 'Active', v_counsel, v_rei) returning id into v_c2;

  insert into public.lead_matches (lead_id, client_id, status)
  values (v_lead, v_c1, 'Applied') returning id into v_m1;
  insert into public.lead_matches (lead_id, client_id, status)
  values (v_lead, v_c2, 'Applied') returning id into v_m2;

  update public.lead_matches set status = 'Hired', decided_on = public.practice_today() where id = v_m1;
  update public.lead_matches set status = 'Hired', decided_on = public.practice_today() where id = v_m2;

  select count(*) into v_ask from public.tasks
   where assigned_staff_id = v_margaret and client_id in (v_c1, v_c2)
     and title like 'Request a placement authorization%';
  if v_ask <> 2 then
    raise exception 'two hires with no placement authorization raised % request(s), not two', v_ask;
  end if;

  select count(*) into v_mile from public.tasks
   where assigned_staff_id = v_rei and client_id in (v_c1, v_c2)
     and title like 'Four weeks since%';
  if v_mile <> 2 then
    raise exception 'two hires set % four-week milestone(s), not two', v_mile;
  end if;

  -- And the same hire asked about twice is still one item, which is what the
  -- lookup is there for.
  perform public.placement_clock_started(v_m2);
  select count(*) into v_ask from public.tasks
   where assigned_staff_id = v_margaret and client_id = v_c2
     and title like 'Request a placement authorization%';
  if v_ask <> 1 then
    raise exception 'the same hire was asked about % times', v_ask;
  end if;

  raise notice 'ok  two hires raise two requests and two milestones; one hire raises one of each';

  -- The fixtures go. This runs on production and leaves nothing behind.
  delete from public.clients where id in (v_c1, v_c2);
  delete from public.job_leads where id = v_lead;
  delete from public.employers where id = v_employer;
  delete from public.counselors where id = v_counsel;
end $$;

-- An item with no source is refused, so the next caller written finds out at
-- once rather than in a month when somebody notices a quiet My day. Asked of
-- the function rather than of the callers: a list of the five call sites would
-- have gone stale the first time a sixth was written.

do $$
declare v_staff uuid;
begin
  select id into v_staff from public.staff where active order by created_at limit 1;

  begin
    perform public.notify_person(v_staff, 'intake', 'ZQ words', 'zq-ref', null, null,
                                 'ZQ do something', public.practice_today(), 'warn', null);
    raise exception 'a My day item was raised without saying what it is about';
  exception when check_violation then
    raise notice 'ok  an item that cannot say what it is about is refused';
  end;
end $$;
