-- Zion Vocational Rehab CRM — the practice's own forms (0139)
--
-- What has to hold, each tried from the direction that would break it:
--
--   A filled form cannot be changed afterwards. It records what somebody saw
--   at the time, and one that can be rewritten is not a record.
--
--   Somebody can only file one as themselves.
--
--   A form for one role is not offered to another; one for nobody in
--   particular is offered to everybody.
--
--   A form template that has been used cannot be deleted out from under its
--   entries.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_staff uuid; v_staff_uid uuid := gen_random_uuid();
  v_other uuid;
  v_client uuid;
  v_entry uuid;
  v_n integer;
  failures text[] := '{}';
begin
  insert into public.staff (name, email, role, active) values ('ZZ Form Staff', 'zz-form@example.test', 'Job Search', true) returning id into v_staff;
  insert into public.staff (name, email, role, active) values ('ZZ Form Other', 'zz-form2@example.test', 'Job Search', true) returning id into v_other;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_staff_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-form@example.test', '{}', '{}', now(), now());
  update public.staff set user_id = v_staff_uid where id = v_staff;
  insert into public.clients (name, stage, status, assigned_staff_id)
  values ('ZZ Form Client', 'Placement', 'Active', v_staff) returning id into v_client;

  insert into public.practice_forms (key, name, purpose, fields, roles)
  values ('zz_billing_only', 'ZZ Billing form', 'ZZ', '[]'::jsonb, array['Billing']);

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_staff_uid, 'role', 'authenticated')::text, true);

  -- ── a form for another role is not offered ────────────────
  select count(*) into v_n from public.practice_forms where key = 'zz_billing_only';
  if v_n <> 0 then
    failures := failures || 'FAILED: a form for Billing was offered to Job Search'::text;
  end if;
  select count(*) into v_n from public.practice_forms where key = 'client_visit';
  if v_n <> 1 then
    failures := failures || 'FAILED: a form for nobody in particular was not offered to everybody'::text;
  else
    raise notice 'ok  a form for a role is that role''s; one for nobody in particular is everybody''s';
  end if;

  -- ── filing one is filing it as yourself ───────────────────
  begin
    insert into public.practice_form_entries (form_key, client_id, staff_id, staff_name, answers)
    values ('client_visit', v_client, v_other, 'ZZ Form Other', '{"where":"ZZ"}'::jsonb);
    failures := failures || 'FAILED: somebody filed a form as a colleague'::text;
  exception when insufficient_privilege then null;
  end;

  insert into public.practice_form_entries (form_key, client_id, staff_id, staff_name, answers)
  values ('client_visit', v_client, v_staff, 'ZZ Form Staff', '{"where":"ZZ the library","what":"ZZ applications"}'::jsonb)
  returning id into v_entry;
  raise notice 'ok  a form is filed as the person filing it, and nobody else';

  -- ── and it cannot be changed afterwards ───────────────────
  update public.practice_form_entries set answers = '{"where":"ZZ somewhere else"}'::jsonb where id = v_entry;
  get diagnostics v_n = row_count;
  if v_n > 0 then
    failures := failures || 'FAILED: a filled form was rewritten after the fact'::text;
  else
    raise notice 'ok  a filled form cannot be rewritten - it is a record of what somebody saw';
  end if;

  perform set_config('role', 'postgres', true);

  -- ── a used template is not deleted out from under it ──────
  begin
    delete from public.practice_forms where key = 'client_visit';
    failures := failures || 'FAILED: a form template with entries was deleted'::text;
  exception when foreign_key_violation then
    raise notice 'ok  a template that has been used cannot be deleted out from under its entries';
  end;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
