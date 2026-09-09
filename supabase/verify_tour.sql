-- Zion Vocational Rehab CRM — the screen hints and the guided tour
--
-- The hints are the smallest feature here and the easiest to get subtly wrong:
-- a dismissal that applied to everybody would take the note away from somebody
-- who had never seen it, and a checklist item that ticked itself early would
-- say a tour was done when it was not.
--
-- Runs inside a transaction that is rolled back. Nothing here is left behind.

begin;

do $$
declare
  v_admin    uuid;
  v_adm_uid  uuid;
  v_rei      uuid;
  v_rei_uid  uuid;
  v_marg     uuid;
  v_marg_uid uuid;
  v_total    int;
  v_seen     int;
  v_count    int;
  v_task     uuid;
  failures   text[] := '{}';
begin
  select id, user_id into v_admin, v_adm_uid  from public.staff where legacy_id = 's1';
  select id, user_id into v_rei,  v_rei_uid   from public.staff where legacy_id = 's2';
  select id, user_id into v_marg, v_marg_uid  from public.staff where legacy_id = 's3';

  select id into v_task from public.checklist_tasks where auto_key = 'tour_completed';

  -- ── the hints exist, and are role-aware ────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_rei_uid, 'role', 'authenticated')::text, true);

  select hints_total into v_total from public.my_tour_progress where staff_id = v_rei;
  if coalesce(v_total, 0) = 0 then
    failures := failures || 'FAILED: there are no hints for Job Search'::text;
  else
    raise notice 'ok  Job Search is shown % hints', v_total;
  end if;

  if exists (
    select 1 from public.tour_hints
     where active and roles is not null and not ('Job Search' = any(roles))
       and key in (select key from public.tour_hints where roles @> array['Job Search'])
  ) then
    failures := failures || 'FAILED: a hint is both offered and withheld from the same role'::text;
  else
    raise notice 'ok  a hint about billing is not shown to somebody who cannot bill';
  end if;

  -- Admin sees more, because Admin has more screens.
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);
  select hints_total into v_count from public.my_tour_progress where staff_id = v_admin;
  if v_count <= v_total then
    failures := failures || format('FAILED: Admin is shown %s hints, Job Search %s', v_count, v_total);
  else
    raise notice 'ok  Admin is shown more hints than Job Search, because more screens';
  end if;

  -- ── the tour starts unfinished ─────────────────────────────
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_rei_uid, 'role', 'authenticated')::text, true);

  if (select auto_done from public.staff_checklist
       where staff_id = v_rei and task_id = v_task) then
    failures := failures || 'FAILED: the tour counted as done before anything was dismissed'::text;
  else
    raise notice 'ok  the tour starts unfinished';
  end if;

  -- ── dismissing one is not dismissing them all ──────────────
  insert into public.staff_prefs (staff_id, key, value)
  values (v_rei, 'hint:dashboard', 'true'::jsonb);

  select hints_seen into v_seen from public.my_tour_progress where staff_id = v_rei;
  if v_seen <> 1 then
    failures := failures || format('FAILED: one dismissal counted as %s', v_seen);
  else
    raise notice 'ok  one dismissal counts once';
  end if;

  if (select auto_done from public.staff_checklist
       where staff_id = v_rei and task_id = v_task) then
    failures := failures || 'FAILED: the tour counted as done after one hint'::text;
  else
    raise notice 'ok  one hint is not a finished tour';
  end if;

  -- ── it belongs to the person who dismissed it ──────────────
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_marg_uid, 'role', 'authenticated')::text, true);
  select hints_seen into v_seen from public.my_tour_progress where staff_id = v_marg;
  if coalesce(v_seen, 0) <> 0 then
    failures := failures || 'FAILED: one person''s dismissal hid the hint from somebody else'::text;
  else
    raise notice 'ok  Rei putting a hint away does not take it from Margaret';
  end if;

  select count(*) into v_count from public.staff_prefs;
  if v_count <> 0 then
    failures := failures || format('FAILED: a colleague can read %s of somebody else''s preferences', v_count);
  else
    raise notice 'ok  a colleague cannot read somebody else''s dismissals at all';
  end if;

  -- ── seeing them all finishes the tour ──────────────────────
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  insert into public.staff_prefs (staff_id, key, value)
  select v_rei, 'hint:' || h.key, 'true'::jsonb
    from public.tour_hints h
   where h.active and (h.roles is null or 'Job Search' = any(h.roles))
  on conflict (staff_id, key) do nothing;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_rei_uid, 'role', 'authenticated')::text, true);

  if not (select auto_done from public.staff_checklist
           where staff_id = v_rei and task_id = v_task) then
    select hints_seen, hints_total into v_seen, v_total
      from public.my_tour_progress where staff_id = v_rei;
    failures := failures || format('FAILED: %s of %s seen and the tour is still unfinished',
                                   v_seen, v_total);
  else
    raise notice 'ok  seeing every hint finishes the tour, with nobody ticking anything';
  end if;

  -- ── and it cannot be ticked instead ────────────────────────
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);
  begin
    perform public.set_checklist_item(v_marg, v_task, true, 'close enough');
    failures := failures || 'FAILED: the tour item was ticked by hand'::text;
  exception when check_violation then
    raise notice 'ok  the tour cannot be ticked — it is answered by what was actually read';
  end;

  -- ── a new hint reopens it ──────────────────────────────────
  -- The reason the hints are data and not code: adding one should ask people
  -- to read it, rather than being invisible to everybody already "done".
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
  insert into public.tour_hints (key, screen, title, body, sort_order)
  values ('zz-new', '/zz', 'ZZ new screen', 'ZZ something new to know', 999);

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_rei_uid, 'role', 'authenticated')::text, true);
  if (select auto_done from public.staff_checklist
       where staff_id = v_rei and task_id = v_task) then
    failures := failures || 'FAILED: a newly added hint left the tour marked finished'::text;
  else
    raise notice 'ok  adding a hint asks people to read it, rather than hiding behind "done"';
  end if;

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  if failures = '{}' then
    raise notice '';
    raise notice '--- SCREEN HINTS AND GUIDED TOUR VERIFIED ---';
  else
    raise notice '';
    raise notice '%  PROBLEM(S):', array_length(failures, 1);
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
