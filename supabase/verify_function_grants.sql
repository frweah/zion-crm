-- Zion Vocational Rehab CRM — no function is callable without signing in
--
-- What has to hold, each tried from the direction that would break it:
--
--   anon - a request with only the public key and nobody signed in - cannot
--   execute any function in public, including ones created after this.
--
--   The functions only the service role uses (Outlook tokens, logging synced
--   mail, what the document agent has seen) cannot be executed by a signed-in
--   user either.
--
--   generate_notifications refuses a signed-in user who is not active staff.
--
-- Runs inside a transaction that is rolled back. Nothing here is left behind.

begin;

do $$
declare
  v_open     text;
  v_uid      uuid := gen_random_uuid();
  failures   text[] := '{}';
begin
  -- ── anon executes nothing ──────────────────────────────────
  select string_agg(p.proname, ', ') into v_open
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.prokind in ('f', 'p')
     and has_function_privilege('anon', p.oid, 'execute');
  if v_open is not null then
    failures := failures || format('FAILED: anon can execute: %s', v_open)::text;
  else
    raise notice 'ok  nobody without a sign-in can execute any database function';
  end if;

  -- A function created now is not granted to anon either.
  create function public.zz_verify_new_function() returns int language sql as 'select 1';
  if has_function_privilege('anon', 'public.zz_verify_new_function()', 'execute') then
    failures := failures || 'FAILED: a newly created function is executable by anon by default'::text;
  else
    raise notice 'ok  a function created later is not given to anon by default';
  end if;

  -- ── the service role's own functions ───────────────────────
  select string_agg(p.proname, ', ') into v_open
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname in ('get_microsoft_tokens_for_sync', 'set_microsoft_tokens_for_sync', 'log_mail_message_for_sync',
                       'log_mail_message_internal', 'log_shared_mail_message', 'inbox_seen')
     and (has_function_privilege('authenticated', p.oid, 'execute') or not has_function_privilege('service_role', p.oid, 'execute'));
  if v_open is not null then
    failures := failures || format('FAILED: service-only functions open to signed-in users (or closed to the service role): %s', v_open)::text;
  else
    raise notice 'ok  Outlook tokens, synced mail and the agent''s lookups are the service role''s alone';
  end if;

  -- ── alerts are recalculated by staff, not anyone signed in ─
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
  begin
    perform public.generate_notifications();
    failures := failures || 'FAILED: a signed-in user who is not staff recalculated alerts'::text;
  exception when insufficient_privilege then
    raise notice 'ok  a signed-in user who is not staff cannot recalculate alerts';
  end;
  perform set_config('request.jwt.claims', '', true);
  perform set_config('role', 'postgres', true);

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- FUNCTION GRANTS VERIFIED ---';
end $$;

rollback;
