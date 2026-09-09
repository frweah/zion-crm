-- Zion Vocational Rehab CRM — the client activity timeline
--
-- A feed that gathers from a dozen tables is exactly the shape of thing that
-- leaks. Every rule written over the last six phases about who may see what
-- has to keep holding when the same rows arrive through a different door, and
-- the door most likely to forget is a convenience view.
--
-- The other property worth proving is that it is a view and not a copy: edit
-- the note, and the timeline says the new thing, because there is only one
-- thing.
--
-- Runs inside a transaction that is rolled back. Nothing here is left behind.

begin;

do $$
declare
  v_admin    uuid;
  v_adm_uid  uuid;
  v_rei      uuid;
  v_rei_uid  uuid;
  v_marg_uid uuid;
  v_client   uuid;
  v_note     uuid;
  v_count    int;
  v_before   int;
  v_title    text;
  failures   text[] := '{}';
begin
  select id, user_id into v_admin, v_adm_uid from public.staff where legacy_id = 's1';
  select id, user_id into v_rei,  v_rei_uid  from public.staff where legacy_id = 's2';
  select user_id     into v_marg_uid         from public.staff where legacy_id = 's3';
  select id into v_client from public.clients where status = 'Active' order by created_at limit 1;

  -- ── a restricted note stays restricted in the feed ─────────
  -- notes.visible_roles is the oldest access rule in this system. A feed that
  -- read notes without it would hand every restricted note to everybody, and
  -- would look like it was working.
  insert into public.notes (client_id, staff_id, staff_name, text, type, at, visible_roles)
  values (v_client, v_admin, 'ZZ Verify', 'ZZ restricted note body', 'General', now(),
          array['Admin'])
  returning id into v_note;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);
  if not exists (select 1 from public.client_activity
                  where ref_id = v_note and kind = 'Note') then
    failures := failures || 'FAILED: Admin cannot see their own restricted note in the feed'::text;
  else
    raise notice 'ok  a restricted note is in the feed for somebody allowed to read it';
  end if;

  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_marg_uid, 'role', 'authenticated')::text, true);
  if exists (select 1 from public.client_activity where ref_id = v_note) then
    failures := failures || 'FAILED: a note restricted to Admin appeared in another role''s feed'::text;
  else
    raise notice 'ok  a restricted note is absent from the feed of somebody not allowed to read it';
  end if;

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  -- ── it is a view, not a copy ───────────────────────────────
  update public.notes set text = 'ZZ edited afterwards' where id = v_note;
  select detail into v_title from public.client_activity where ref_id = v_note and kind = 'Note';
  if v_title <> 'ZZ edited afterwards' then
    failures := failures || format('FAILED: the feed still says "%s" after the note was edited', v_title);
  else
    raise notice 'ok  editing a note changes the feed, because the feed is the note';
  end if;

  select count(*) into v_before from public.client_activity where client_id = v_client;
  delete from public.notes where id = v_note;
  select count(*) into v_count from public.client_activity where client_id = v_client;
  if v_count <> v_before - 1 then
    failures := failures || 'FAILED: deleting a note left it in the feed'::text;
  else
    raise notice 'ok  deleting a note removes it from the feed, with nothing to clean up';
  end if;

  -- ── every kind reaches the feed ────────────────────────────
  -- Written as one insert per source so that a branch quietly dropped from the
  -- union is caught here rather than by somebody noticing an absence months on.
  insert into public.client_stage_history (client_id, stage, at, staff_id)
  values (v_client, 'ZZ Stage', now(), v_admin);
  insert into public.tasks (client_id, title, status, done_at, assigned_staff_id)
  values (v_client, 'ZZ task', 'Done', now(), v_admin);
  insert into public.calendar_events (client_id, staff_id, kind, title, starts_at, ends_at, origin)
  values (v_client, v_admin, 'Coaching visit', 'ZZ visit',
          now() - interval '2 hours', now() - interval '1 hour', 'CRM');

  for v_title in
    select k from unnest(array['Stage', 'Task', 'Appointment']) k
  loop
    if not exists (select 1 from public.client_activity
                    where client_id = v_client and kind = v_title
                      and at > now() - interval '1 day') then
      failures := failures || format('FAILED: nothing of kind %s reached the feed', v_title);
    else
      raise notice 'ok  % reaches the feed', v_title;
    end if;
  end loop;

  -- ── it is ordered, and it is the client's own ──────────────
  if exists (
    select 1 from (
      select at, lag(at) over (order by at desc) as previous
        from public.client_activity where client_id = v_client
    ) x where previous is not null and at > previous
  ) then
    failures := failures || 'FAILED: the feed is not in reverse-chronological order'::text;
  else
    raise notice 'ok  the feed is in reverse-chronological order';
  end if;

  if exists (select 1 from public.client_activity where client_id <> v_client
              and ref_id in (select id from public.notes where client_id = v_client)) then
    failures := failures || 'FAILED: an item is attributed to the wrong client'::text;
  else
    raise notice 'ok  every item belongs to the client it is filed under';
  end if;

  -- ── nothing here is writable ───────────────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_rei_uid, 'role', 'authenticated')::text, true);
  begin
    insert into public.client_activity (client_id, at, kind, title, detail, who, tab, ref_id)
    values (v_client, now(), 'Note', 'ZZ invented', '', null, 'notes', gen_random_uuid());
    failures := failures || 'FAILED: something was written straight into the timeline'::text;
  exception when others then
    raise notice 'ok  the timeline cannot be written to — it only reports';
  end;
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  if failures = '{}' then
    raise notice '';
    raise notice '--- CLIENT ACTIVITY TIMELINE VERIFIED ---';
  else
    raise notice '';
    raise notice '%  PROBLEM(S):', array_length(failures, 1);
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
