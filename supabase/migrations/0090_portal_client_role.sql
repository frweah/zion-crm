-- Zion Vocational Rehab CRM — clients sign in as a role of their own
--
-- Until now a portal client was an `authenticated` user like any staff member,
-- kept to their own rows by the rules in 0087. That holds - verify_portal_rls
-- proves it - but it rests on every policy on all eighty-odd tables being right
-- forever. This is the belt to those braces: a database role, portal_client,
-- granted nothing at all outside the portal's own five tables. A policy written
-- wrong, or a table added with no policy, is then still unreadable to a client,
-- because there is no table privilege for the rules to be asked about.
--
-- One setting turns it on, and only the owner can:
--
--   Supabase dashboard > Authentication > Hooks (Auth Hooks)
--   > "Customize Access Token (JWT) Claims" > Postgres function
--   > public.portal_access_token_hook > enable.
--
-- Until that is switched on the hook is never called and clients keep signing
-- in as `authenticated`. Every policy names both roles, so it can be switched
-- on - or back off - with nobody signed out and nothing else to change.
--
-- Staff are untouched either way: the hook hands their token back as it found it.

-- ── the role ────────────────────────────────────────────────
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'portal_client') then
    create role portal_client nologin noinherit;
  end if;
end $$;

-- PostgREST switches into it for a request whose token asks for it, and
-- postgres must be a member to be able to test as one.
grant portal_client to authenticator;
grant portal_client to postgres;

grant usage on schema public to portal_client;

-- Exactly the portal's own tables, read-only. Nothing else in the database is
-- granted to this role, storage included: a client's request for any other
-- table is refused before a policy is consulted.
grant select on public.portal_accounts, public.portal_sessions, public.portal_terms,
  public.portal_consents, public.portal_activity to portal_client;

grant execute on function public.portal_session_account_id(), public.portal_my_consent(text),
  public.portal_client_id(), public.portal_touch_session(), public.portal_me(),
  public.portal_begin_session(text, text), public.portal_end_my_session(),
  public.portal_record_consent(text, boolean, text, text)
  to portal_client;

-- A function created later must not be granted to it by default.
alter default privileges in schema public revoke execute on functions from portal_client;
alter default privileges for role postgres in schema public revoke execute on functions from portal_client;

-- ── a rule of their own ─────────────────────────────────────
-- Not one policy naming both roles. A policy is evaluated as whoever is
-- asking, so a shared one would make a client's every read call
-- is_active_staff() - and the role would need permission to ask a question
-- about staff, which is exactly what it should not have. Staff keep 0087's
-- policies; the client role gets the same sentence with the staff half
-- removed, which is all it was ever going to mean for them.
-- Staff's policies, exactly as 0087 wrote them. (An earlier run of this
-- migration added portal_client to each of them, which is the mistake this
-- comment exists to undo: the client role would then have needed permission to
-- run is_active_staff.)
drop policy if exists portal_accounts_read on public.portal_accounts;
create policy portal_accounts_read on public.portal_accounts for select to authenticated
  using (public.is_active_staff() or id = public.portal_session_account_id());

drop policy if exists portal_sessions_read on public.portal_sessions;
create policy portal_sessions_read on public.portal_sessions for select to authenticated
  using (public.is_active_staff() or account_id = public.portal_session_account_id());

drop policy if exists portal_terms_read on public.portal_terms;
create policy portal_terms_read on public.portal_terms for select to authenticated
  using (published_at is not null and (public.is_active_staff() or public.portal_session_account_id() is not null));

drop policy if exists portal_consents_read on public.portal_consents;
create policy portal_consents_read on public.portal_consents for select to authenticated
  using (public.is_active_staff() or account_id = public.portal_session_account_id());

drop policy if exists portal_activity_read on public.portal_activity;
create policy portal_activity_read on public.portal_activity for select to authenticated
  using (public.is_active_staff() or account_id = public.portal_session_account_id());

drop policy if exists portal_accounts_own on public.portal_accounts;
create policy portal_accounts_own on public.portal_accounts for select to portal_client
  using (id = public.portal_session_account_id());

drop policy if exists portal_sessions_own on public.portal_sessions;
create policy portal_sessions_own on public.portal_sessions for select to portal_client
  using (account_id = public.portal_session_account_id());

drop policy if exists portal_terms_own on public.portal_terms;
create policy portal_terms_own on public.portal_terms for select to portal_client
  using (published_at is not null and public.portal_session_account_id() is not null);

drop policy if exists portal_consents_own on public.portal_consents;
create policy portal_consents_own on public.portal_consents for select to portal_client
  using (account_id = public.portal_session_account_id());

drop policy if exists portal_activity_own on public.portal_activity;
create policy portal_activity_own on public.portal_activity for select to portal_client
  using (account_id = public.portal_session_account_id());

-- ── the hook ────────────────────────────────────────────────
-- Called by the sign-in service while it mints an access token. It changes one
-- claim, and only for a live portal account: the role the database will run
-- that person's requests as. Anything else - a staff member, a portal account
-- that has been turned off - comes back exactly as it went in.
create or replace function public.portal_access_token_hook(event jsonb)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if exists (
    select 1 from public.portal_accounts a
     where a.auth_user_id = (event ->> 'user_id')::uuid
       and a.disabled_at is null)
  then
    return jsonb_set(event, '{claims,role}', '"portal_client"'::jsonb);
  end if;
  return event;
end;
$$;

grant usage on schema public to supabase_auth_admin;
grant execute on function public.portal_access_token_hook(jsonb) to supabase_auth_admin;
revoke execute on function public.portal_access_token_hook(jsonb)
  from public, anon, authenticated, portal_client, service_role;
-- The hook reads this table as itself, so the sign-in service needs it.
grant select on public.portal_accounts to supabase_auth_admin;

comment on function public.portal_access_token_hook(jsonb) is
  'Supabase access-token hook: a live portal account gets the portal_client role in its token. Turn on at Authentication > Hooks > Customize Access Token (JWT) Claims.';

-- ── an invitation, written down ────────────────────────────
-- Whether the person was told, and how. The rule is the owner's: email where
-- there is an address, a text only where texting consent already exists, and
-- otherwise staff tell them in person - which is a thing that happened to this
-- record, so it belongs in the record like the rest.
alter table public.portal_activity drop constraint if exists portal_activity_action_check;
alter table public.portal_activity add constraint portal_activity_action_check check (action in (
  'Invited', 'Invitation sent', 'Invitation not sent', 'Code sent', 'Code refused', 'Signed in',
  'Signed out', 'Session expired', 'Signed out everywhere', 'Consent given', 'Consent withdrawn',
  'Account disabled'));

create or replace function public.portal_note_invitation(p_account uuid, p_sent boolean, p_detail text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_a     public.portal_accounts%rowtype;
  v_staff public.staff%rowtype;
begin
  select * into v_a from public.portal_accounts where id = p_account;
  if v_a.id is null then
    raise exception 'That portal account is not on file.' using errcode = 'check_violation';
  end if;
  if not public.can_manage_portal(v_a.client_id) then
    raise exception 'Only Admin, Intake & Client Reports, or the client''s assigned staff member can invite someone to the portal.'
      using errcode = 'insufficient_privilege';
  end if;
  select * into v_staff from public.staff where user_id = auth.uid() and active;
  insert into public.portal_activity (account_id, client_id, action, detail, acting_as, actor_name)
  values (p_account, v_a.client_id,
          case when p_sent then 'Invitation sent' else 'Invitation not sent' end,
          left(coalesce(p_detail, ''), 300), 'Staff', coalesce(v_staff.name, ''));
end;
$$;

revoke execute on function public.portal_note_invitation(uuid, boolean, text) from public, anon, portal_client;
grant execute on function public.portal_note_invitation(uuid, boolean, text) to authenticated, service_role;
