-- What the client threads board says right now, counted rather than guessed.
--
-- A fixture staff member is made inside the transaction so the board can be
-- asked as somebody - it is SECURITY INVOKER and gated on `is_active_staff`,
-- which is the point of it - and everything is rolled back. It reads; it
-- writes nothing a rollback does not take away.
--
--   node --env-file=.env.local scripts/run-sql.mjs supabase/report_threads_board_today.sql

begin;

do $$
declare
  v_me  uuid; v_uid uuid := gen_random_uuid();
  r     record;
begin
  insert into public.staff (name, email, role, active)
  values ('ZZ Board Reader', 'zz-board-reader@example.test', 'Job Search', true)
  returning id into v_me;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'zz-board-reader@example.test', '{}', '{}', now(), now());
  update public.staff set user_id = v_uid where id = v_me;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);

  raise notice 'group                 rows   longest wait';
  for r in
    select grp,
           count(*) as rows,
           max(waiting_hours) as longest
      from public.client_threads_board()
     group by grp
     order by case grp
                when 'needs-reply' then 1 when 'approval' then 2 when 'stuck' then 3
                when 'quiet' then 4 when 'stranger' then 5 else 6 end
  loop
    raise notice '%  %  %',
      rpad(r.grp, 20), lpad(r.rows::text, 5),
      case when r.longest is null then '' else (r.longest / 24)::int || ' days' end;
  end loop;

  raise notice '';
  for r in
    select count(*) filter (where consent_missing and kind = 'client') as consent_missing,
           count(*) filter (where opted_out) as opted_out,
           count(*) filter (where failed > 0) as with_a_failed_text,
           count(*) filter (where kind = 'draft') as drafts,
           count(*) filter (where kind = 'stranger') as strangers,
           count(*) as rows_in_all
      from public.client_threads_board()
  loop
    raise notice 'consent missing %, opted out %, a text that did not go %, drafts %, strangers %, rows %',
      r.consent_missing, r.opted_out, r.with_a_failed_text, r.drafts, r.strangers, r.rows_in_all;
  end loop;

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
end $$;

rollback;
