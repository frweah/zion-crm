-- Zion Vocational Rehab CRM — case note templates
--
-- The headings are a documentation standard, and a standard has two failure
-- modes. It can be too weak to matter, or it can start acting like a rule and
-- change the record. The second is the one worth guarding against here.
--
--   Changing the headings changes nothing already written. A note is its
--   text; there is no link from a note back to a template, deliberately, so
--   there is nothing that could rewrite one.
--
--   Switching a template off keeps its wording, and stops it being offered.
--
--   One person keeps the standard. Everybody reads it.
--
-- The rule about not overwriting somebody's typing lives in the browser and
-- is checked in scripts/check-note-template.mjs — it is a rule about a text
-- box, and this file cannot see one.
--
-- Runs inside a transaction that is rolled back. Nothing here is left behind.

begin;

do $$
declare
  v_admin    uuid;
  v_adm_uid  uuid;
  v_other    uuid;
  v_oth_uid  uuid;
  v_role     text;
  v_client   uuid;
  v_note     uuid;
  v_text     text;
  v_body     text;
  v_count    int;
  failures   text[] := '{}';
begin
  select id, user_id into v_admin, v_adm_uid from public.staff
   where role = 'Admin' and active order by created_at limit 1;
  select id, user_id, role into v_other, v_oth_uid, v_role from public.staff
   where active and role <> 'Admin' order by created_at limit 1;

  insert into public.clients (name, stage, status, assigned_staff_id)
  values ('ZZ Template Testperson', 'Referral', 'Active', v_admin)
  returning id into v_client;

  -- ── what a note of each type starts with ───────────────────
  if public.note_template_for('Coaching session') is null then
    failures := failures || 'FAILED: a coaching session note starts with nothing'::text;
  elsif public.note_template_for('Coaching session') not like '%Next step and by when:%' then
    failures := failures || 'FAILED: the coaching headings do not ask what happens next'::text;
  else
    raise notice 'ok  a coaching session note starts with the questions an auditor asks';
  end if;

  -- "General" is the type people pick when what happened has no shape.
  -- Handing them a shape anyway is the one case where this makes notes worse,
  -- so it is checked rather than left to whoever edits the seed list next.
  if public.note_template_for('General') is not null then
    failures := failures || 'FAILED: the General type has headings, which defeats having it'::text;
  else
    raise notice 'ok  "General" starts blank, because that is what it is for';
  end if;

  if public.note_template_for('Something nobody has heard of') is not null then
    failures := failures || 'FAILED: an unknown type came back with headings'::text;
  else
    raise notice 'ok  an unknown type gets nothing, rather than somebody else''s questions';
  end if;

  -- ── a note keeps no link to a template ─────────────────────
  -- This is what makes the rest of it safe. Nothing can rewrite a note in
  -- response to a template changing, because nothing knows which note came
  -- from which template.
  select count(*) into v_count
    from information_schema.columns
   where table_schema = 'public' and table_name = 'notes'
     and column_name in ('template', 'template_id', 'note_template', 'templated');
  if v_count <> 0 then
    failures := failures || 'FAILED: a note records which template it came from, which invites rewriting it'::text;
  else
    raise notice 'ok  a note is its text — it holds no link back to a template';
  end if;

  -- ── changing the headings leaves written notes alone ───────
  insert into public.notes (client_id, staff_id, staff_name, text, type)
  values (v_client, v_admin, 'ZZ Test',
          E'Where, and how long:\nAt the store, an hour.\n\nWhat was worked on:\nThe register.',
          'Coaching session')
  returning id, text into v_note, v_text;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);

  update public.note_templates
     set body = E'Something else entirely:\n', updated_by = v_admin
   where note_type = 'Coaching session';
  get diagnostics v_count = row_count;
  if v_count <> 1 then
    failures := failures || 'FAILED: Admin cannot change the headings'::text;
  else
    raise notice 'ok  Admin changes the headings';
  end if;

  if (select text from public.notes where id = v_note) is distinct from v_text then
    failures := failures || 'FAILED: changing a template altered a note already written'::text;
  else
    raise notice 'ok  and every note already written is exactly as it was';
  end if;

  -- ── switching one off keeps its wording ────────────────────
  update public.note_templates set active = false where note_type = 'Phone call';

  if public.note_template_for('Phone call') is not null then
    failures := failures || 'FAILED: a template switched off is still offered'::text;
  else
    raise notice 'ok  a template switched off stops being offered';
  end if;

  select body into v_body from public.note_templates where note_type = 'Phone call';
  if coalesce(v_body, '') = '' then
    failures := failures || 'FAILED: switching a template off lost its wording'::text;
  else
    raise notice 'ok  — and its wording is kept, so turning it back on is not rewriting it';
  end if;

  -- ── who keeps the standard ─────────────────────────────────
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_oth_uid, 'role', 'authenticated')::text, true);

  select count(*) into v_count from public.note_templates;
  if v_count = 0 then
    failures := failures || format('FAILED: %s cannot read the headings they are meant to write to', v_role);
  else
    raise notice 'ok  everybody who writes a note can read the headings';
  end if;

  -- No policy for anybody but Admin, so this affects nothing and raises
  -- nothing. Counted rather than caught: RLS with no matching policy is
  -- silent, and an assertion waiting for an error would pass forever.
  update public.note_templates set body = 'Say whatever you like' where note_type = 'Meeting';
  get diagnostics v_count = row_count;
  if v_count <> 0 then
    failures := failures || format('FAILED: %s rewrote the practice''s documentation standard', v_role);
  else
    raise notice 'ok  but only Admin changes them';
  end if;

  -- An insert is refused outright rather than silently dropped: there is a
  -- policy on this table, it just does not admit anybody else, and a WITH
  -- CHECK that fails raises. The difference between this and the update above
  -- is worth keeping in the test, because assuming one shape for both is how
  -- a check ends up passing forever.
  begin
    insert into public.note_templates (note_type, body) values ('Invented', 'x');
    failures := failures || format('FAILED: %s added a template of their own', v_role);
  exception when insufficient_privilege then
    raise notice 'ok  and only Admin adds one';
  end;

  -- ── an account that has been switched off ──────────────────
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
  update public.staff set active = false where id = v_other;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_oth_uid, 'role', 'authenticated')::text, true);

  select count(*) into v_count from public.note_templates;
  if v_count <> 0 then
    failures := failures || 'FAILED: a deactivated account still reads the templates'::text;
  else
    raise notice 'ok  a deactivated account reads nothing here either';
  end if;

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  if failures = '{}' then
    raise notice '';
    raise notice '--- NOTE TEMPLATES VERIFIED ---';
  else
    raise notice '';
    raise notice '%  PROBLEM(S):', array_length(failures, 1);
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
