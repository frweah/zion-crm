-- Zion Vocational Rehab CRM — no function is callable without signing in
--
-- Found on 15 Sept 2026 while designing the client portal's rules: every
-- function in public was executable by anon - the role PostgREST uses for a
-- request carrying only the public anon key, with nobody signed in. Among
-- them, functions that run with elevated rights and check no caller:
--
--   get_microsoft_tokens_for_sync   returns a staff member's Outlook tokens
--   set_microsoft_tokens_for_sync   overwrites them
--   log_mail_message_for_sync,
--   log_mail_message_internal,
--   log_shared_mail_message         write mail log entries onto any record
--   inbox_seen                      says which document fingerprints exist
--   generate_notifications          recomputes everybody's alerts
--
-- The migrations that made them did revoke execute "from public" and "from
-- authenticated". Supabase grants new functions to anon directly as well, and
-- revoking from public does not touch a direct grant - the same trap noted
-- for this project before: revoke from anon and authenticated explicitly.
--
-- Nothing in the application calls a database function without a session or
-- the service role: sign-in goes through the auth API, and every machine route
-- (cron, the agent, the texting webhook) uses the service role. So anon loses
-- every function, and future functions are not granted to it by default.
-- The service-only functions lose authenticated too, which matters from the
-- day clients sign in to the portal as authenticated users.

-- ── anon: nothing ───────────────────────────────────────────
-- Two routes in: a direct grant to anon, and the grant every Postgres function
-- is born with, to PUBLIC - which anon inherits like every role. Both go.
-- Signed-in users and the service role get what they had through PUBLIC back
-- as explicit grants, so nothing that works for staff stops working.
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig
      from pg_proc p
     where p.pronamespace = 'public'::regnamespace
       and p.prokind in ('f', 'p')
  loop
    execute format('revoke execute on function %s from public, anon', f.sig);
    execute format('grant execute on function %s to authenticated, service_role', f.sig);
  end loop;
end $$;

-- The blanket grant above must not reopen what earlier migrations kept from
-- signed-in users on purpose: the access log's writer, alerts for a chosen day,
-- the incoming-text recorder, the service role's own functions, and trigger
-- functions nobody should call. Read from the migrations that closed them.
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig
      from pg_proc p
     where p.pronamespace = 'public'::regnamespace
       and p.proname in (
         'generate_notifications_on', 'get_microsoft_tokens_for_sync', 'inbox_seen', 'inbox_warrant_guard',
         'log_access', 'log_mail_message_for_sync', 'log_mail_message_internal', 'log_shared_mail_message',
         'record_incoming_sms', 'set_microsoft_tokens_for_sync', 'staff_record_frozen')
  loop
    execute format('revoke execute on function %s from authenticated', f.sig);
  end loop;
end $$;

-- And a function created later starts closed to everyone but those two. The
-- "execute to PUBLIC" every function is born with is a database-wide default,
-- so it is revoked without "in schema"; the schema-level lines cover the grant
-- Supabase adds to anon. (Functions created by supabase_admin - the platform,
-- not our migrations - keep Supabase's own defaults, which postgres cannot alter.)
alter default privileges for role postgres revoke execute on functions from public;
alter default privileges in schema public revoke execute on functions from public, anon;
alter default privileges for role postgres in schema public revoke execute on functions from public, anon;
alter default privileges for role postgres in schema public grant execute on functions to authenticated, service_role;

-- ── the service role's own functions ───────────────────────
revoke execute on function public.get_microsoft_tokens_for_sync(uuid) from public, anon, authenticated;
grant execute on function public.get_microsoft_tokens_for_sync(uuid) to service_role;

revoke execute on function public.set_microsoft_tokens_for_sync(uuid, text, text, timestamptz) from public, anon, authenticated;
grant execute on function public.set_microsoft_tokens_for_sync(uuid, text, text, timestamptz) to service_role;

do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig
      from pg_proc p
     where p.pronamespace = 'public'::regnamespace
       and p.proname in ('log_mail_message_for_sync', 'log_mail_message_internal', 'log_shared_mail_message', 'inbox_seen')
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- ── generate_notifications: staff and the nightly job only ──
-- The dashboard calls it as the signed-in staff member, and pg_cron runs it
-- with no auth context at all. A signed-in person who is not active staff - a
-- portal client, once there are any - is refused.
create or replace function public.generate_notifications()
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if auth.uid() is not null
     and coalesce(auth.role(), '') <> 'service_role'
     and not public.is_active_staff() then
    raise exception 'Only staff recalculate alerts.' using errcode = 'insufficient_privilege';
  end if;
  return public.generate_notifications_on(public.practice_today());
end;
$function$;

revoke execute on function public.generate_notifications() from public, anon;
grant execute on function public.generate_notifications() to authenticated, service_role;
