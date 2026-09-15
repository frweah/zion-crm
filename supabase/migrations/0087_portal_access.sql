-- Zion Vocational Rehab CRM — the client portal: access and consent (Phase 9, section 1)
--
-- The first people to sign in who are not staff. They sign in as ordinary
-- authenticated users, and nothing else about them is ordinary: a portal
-- account is not a staff row, so every rule that already asks "is this active
-- staff?" answers no, and the only rows they can reach are the ones below,
-- which each ask "is this your own account, in a session that is still live?"
--
--   An account belongs to one client. It is the client, or a guardian with a
--   guardianship document on that client's file; a guardian is labelled as
--   such on everything they do.
--
--   Sign-in is a one-time code sent to the account's phone (GoHighLevel) or
--   email (Resend). The codes live in a table only the service role touches.
--
--   A session is live for 30 minutes after the last thing done in it. Staff
--   can end every session for a client from the record.
--
--   Terms are versioned and their text cannot be changed once stored. Consent
--   to electronic communication and to text messages is recorded with the time,
--   the IP address and who gave it, append-only. Nothing in the portal beyond
--   the consent screen works without consent to electronic communication on
--   the current terms, and a new version asks again.
--
-- A separate database role for clients would need Supabase's custom access
-- token hook, a project setting outside these migrations. The account-and-
-- session rule does the same job from here; verify_portal_rls.sql proves it.

-- ── what the rest of the system needs to know about ─────────
alter table public.attachments drop constraint if exists attachments_category_check;
alter table public.attachments add constraint attachments_category_check check (category in (
  'Signed USOR form', 'Work schedule', 'Authorization', 'Signed intake', 'Employer verification',
  'Invoice', 'Guardianship document', 'Other'));

alter table public.sms_consent_events drop constraint if exists sms_consent_events_method_check;
alter table public.sms_consent_events add constraint sms_consent_events_method_check check (method in (
  'Verbal', 'Written', 'Intake form', 'Text reply', 'Staff', 'Portal'));

-- ── accounts ─────────────────────────────────────────────────
create table if not exists public.portal_accounts (
  id                         uuid primary key default gen_random_uuid(),
  client_id                  uuid not null references public.clients(id) on delete cascade,
  kind                       text not null check (kind in ('Client', 'Guardian')),
  name                       text not null,
  relationship               text not null default '',
  phone                      text,
  email                      text,
  guardianship_attachment_id uuid references public.attachments(id) on delete restrict,
  auth_user_id               uuid unique references auth.users(id) on delete set null,
  invited_by                 uuid references public.staff(id),
  invited_by_name            text not null default '',
  invited_at                 timestamptz not null default now(),
  first_signed_in_at         timestamptz,
  last_signed_in_at          timestamptz,
  disabled_at                timestamptz,
  disabled_by                uuid references public.staff(id),
  disabled_reason            text not null default '',
  constraint portal_accounts_reachable check (phone is not null or email is not null),
  constraint portal_accounts_guardian check (
    kind = 'Client' or (relationship <> '' and guardianship_attachment_id is not null)),
  constraint portal_accounts_phone_normal check (phone is null or phone = public.normalize_phone(phone)),
  constraint portal_accounts_email_lower check (email is null or email = lower(email))
);

-- One live client account per client; a phone or email opens one live account.
create unique index if not exists portal_accounts_one_client
  on public.portal_accounts (client_id) where kind = 'Client' and disabled_at is null;
create unique index if not exists portal_accounts_phone
  on public.portal_accounts (phone) where disabled_at is null and phone is not null;
create unique index if not exists portal_accounts_email
  on public.portal_accounts (email) where disabled_at is null and email is not null;

-- ── sign-in codes: the service role's alone ────────────────
create table if not exists public.portal_login_codes (
  id          uuid primary key default gen_random_uuid(),
  -- Null when nobody has portal access at what was typed: the attempt is still
  -- written down, so guessing at addresses is limited like guessing at codes.
  account_id  uuid references public.portal_accounts(id) on delete cascade,
  code_hash   text,
  channel     text not null check (channel in ('Text', 'Email')),
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null,
  attempts    integer not null default 0,
  used_at     timestamptz,
  ip          text not null default '',
  sent        boolean not null default false,
  send_error  text not null default ''
);
create index if not exists portal_login_codes_account on public.portal_login_codes (account_id, created_at desc);
create index if not exists portal_login_codes_ip on public.portal_login_codes (ip, created_at desc);

-- ── sessions ─────────────────────────────────────────────────
-- Keyed by the session id Supabase puts in the access token, so the rules can
-- tell this session from another one of the same person.
create table if not exists public.portal_sessions (
  id            uuid primary key,
  account_id    uuid not null references public.portal_accounts(id) on delete cascade,
  auth_user_id  uuid not null,
  created_at    timestamptz not null default now(),
  last_seen_at  timestamptz not null default now(),
  ip            text not null default '',
  user_agent    text not null default '',
  ended_at      timestamptz,
  ended_reason  text check (ended_reason in ('Signed out', 'Idle', 'Signed out everywhere', 'Account disabled'))
);
create index if not exists portal_sessions_account on public.portal_sessions (account_id);

-- ── terms ────────────────────────────────────────────────────
create table if not exists public.portal_terms (
  version      text primary key,
  title        text not null,
  source_file  text not null,
  body         jsonb not null,
  text_sha256  text not null unique,
  published_at timestamptz,
  is_current   boolean not null default false,
  created_at   timestamptz not null default now()
);
create unique index if not exists portal_terms_one_current on public.portal_terms (is_current) where is_current;

create or replace function public.portal_terms_frozen()
returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'Terms version % was shown to people; it is kept, not deleted.', old.version
      using errcode = 'insufficient_privilege';
  end if;
  if new.version is distinct from old.version or new.body is distinct from old.body
     or new.text_sha256 is distinct from old.text_sha256 or new.title is distinct from old.title
     or new.source_file is distinct from old.source_file then
    raise exception 'The text of terms version % cannot change. Store the new text as a new version.', old.version
      using errcode = 'insufficient_privilege';
  end if;
  return new;
end;
$$;
drop trigger if exists portal_terms_frozen on public.portal_terms;
create trigger portal_terms_frozen before update or delete on public.portal_terms
  for each row execute function public.portal_terms_frozen();

-- ── consent and what happened: append-only ─────────────────
create table if not exists public.portal_consents (
  id            uuid primary key default gen_random_uuid(),
  seq           bigserial,
  account_id    uuid not null references public.portal_accounts(id) on delete restrict,
  client_id     uuid not null references public.clients(id) on delete restrict,
  terms_version text not null references public.portal_terms(version),
  kind          text not null check (kind in ('Electronic communication', 'Text messages')),
  given         boolean not null,
  at            timestamptz not null default now(),
  ip            text not null,
  user_agent    text not null default '',
  acting_as     text not null check (acting_as in ('Client', 'Guardian')),
  actor_name    text not null
);
create index if not exists portal_consents_account on public.portal_consents (account_id, kind, seq desc);

create table if not exists public.portal_activity (
  id          uuid primary key default gen_random_uuid(),
  seq         bigserial,
  account_id  uuid references public.portal_accounts(id) on delete restrict,
  client_id   uuid not null references public.clients(id) on delete restrict,
  at          timestamptz not null default now(),
  action      text not null check (action in (
                'Invited', 'Code sent', 'Code refused', 'Signed in', 'Signed out', 'Session expired',
                'Signed out everywhere', 'Consent given', 'Consent withdrawn', 'Account disabled')),
  detail      text not null default '',
  ip          text not null default '',
  acting_as   text not null check (acting_as in ('Client', 'Guardian', 'Staff', 'System')),
  actor_name  text not null default ''
);
create index if not exists portal_activity_client on public.portal_activity (client_id, seq desc);

create or replace function public.portal_append_only()
returns trigger language plpgsql as $$
begin
  raise exception '% is a record of what happened; it is added to, never changed or removed.', tg_table_name
    using errcode = 'insufficient_privilege';
end;
$$;
drop trigger if exists portal_consents_append_only on public.portal_consents;
create trigger portal_consents_append_only before update or delete on public.portal_consents
  for each row execute function public.portal_append_only();
drop trigger if exists portal_activity_append_only on public.portal_activity;
create trigger portal_activity_append_only before update or delete on public.portal_activity
  for each row execute function public.portal_append_only();

-- ── who is signed in, from the database's side ─────────────
-- The account behind this request, only while its session is live: signed in,
-- not signed out or ended, used within 30 minutes, account not disabled.
create or replace function public.portal_session_account_id()
returns uuid language sql stable security definer set search_path = public as $$
  select a.id
    from public.portal_accounts a
    join public.portal_sessions s on s.account_id = a.id
   where a.auth_user_id = auth.uid()
     and a.disabled_at is null
     and s.id = nullif(auth.jwt() ->> 'session_id', '')::uuid
     and s.ended_at is null
     and s.last_seen_at > now() - interval '30 minutes'
   limit 1;
$$;

-- Consent to electronic communication, and to texts, on the current terms -
-- for the signed-in account only.
create or replace function public.portal_my_consent(p_kind text)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((
    select c.given
      from public.portal_consents c
      join public.portal_terms t on t.version = c.terms_version and t.is_current
     where c.account_id = public.portal_session_account_id()
       and c.kind = p_kind
     order by c.seq desc
     limit 1), false);
$$;

-- The client this session may see - and only once consent to electronic
-- communication has been given on the current terms. Every portal feature
-- after the consent screen reads its rows through this.
create or replace function public.portal_client_id()
returns uuid language sql stable security definer set search_path = public as $$
  select a.client_id
    from public.portal_accounts a
   where a.id = public.portal_session_account_id()
     and public.portal_my_consent('Electronic communication');
$$;

-- Called on every portal request: keeps a live session live, and ends one
-- that has been idle for 30 minutes.
create or replace function public.portal_touch_session()
returns text language plpgsql security definer set search_path = public as $$
declare
  v_sid uuid := nullif(auth.jwt() ->> 'session_id', '')::uuid;
  v_s   public.portal_sessions%rowtype;
  v_a   public.portal_accounts%rowtype;
begin
  if v_sid is null then return 'none'; end if;
  select * into v_s from public.portal_sessions where id = v_sid;
  if not found then return 'none'; end if;
  select * into v_a from public.portal_accounts where id = v_s.account_id;
  if v_a.auth_user_id is distinct from auth.uid() then return 'none'; end if;
  if v_s.ended_at is not null then return 'ended'; end if;
  if v_a.disabled_at is not null then
    update public.portal_sessions set ended_at = now(), ended_reason = 'Account disabled' where id = v_sid;
    return 'ended';
  end if;
  if v_s.last_seen_at <= now() - interval '30 minutes' then
    update public.portal_sessions set ended_at = now(), ended_reason = 'Idle' where id = v_sid;
    insert into public.portal_activity (account_id, client_id, action, detail, acting_as, actor_name)
    values (v_a.id, v_a.client_id, 'Session expired', 'Nothing done for 30 minutes', v_a.kind, v_a.name);
    return 'expired';
  end if;
  update public.portal_sessions set last_seen_at = now() where id = v_sid;
  return 'ok';
end;
$$;

-- ── what staff can do ───────────────────────────────────────
-- Admin, Intake & Client Reports, or the client's assigned staff member.
create or replace function public.can_manage_portal(p_client uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1
      from public.staff s
      left join public.clients c on c.id = p_client
     where s.user_id = auth.uid() and s.active
       and (s.role in ('Admin', 'Reports') or c.assigned_staff_id = s.id));
$$;

create or replace function public.portal_invite(
  p_client       uuid,
  p_kind         text,
  p_name         text default null,
  p_relationship text default '',
  p_phone        text default null,
  p_email        text default null,
  p_attachment   uuid default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_client public.clients%rowtype;
  v_staff  public.staff%rowtype;
  v_phone  text;
  v_email  text;
  v_name   text;
  v_id     uuid;
begin
  if not public.can_manage_portal(p_client) then
    raise exception 'Only Admin, Intake & Client Reports, or the client''s assigned staff member can give portal access.'
      using errcode = 'insufficient_privilege';
  end if;
  select * into v_client from public.clients where id = p_client;
  if not found then
    raise exception 'That client is not on file.' using errcode = 'check_violation';
  end if;
  if p_kind not in ('Client', 'Guardian') then
    raise exception 'Portal access is for the client or their guardian.' using errcode = 'check_violation';
  end if;

  v_phone := public.normalize_phone(nullif(trim(coalesce(p_phone, case when p_kind = 'Client' then v_client.phone end)), ''));
  if nullif(trim(coalesce(p_phone, '')), '') is not null and v_phone is null then
    raise exception 'That phone number does not look right.' using errcode = 'check_violation';
  end if;
  v_email := lower(nullif(trim(coalesce(p_email, case when p_kind = 'Client' then v_client.email end)), ''));
  if v_email is not null and v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'That email address does not look right.' using errcode = 'check_violation';
  end if;
  if v_phone is null and v_email is null then
    raise exception 'A sign-in code goes to a phone number or an email address. Add one first.'
      using errcode = 'check_violation';
  end if;

  v_name := nullif(trim(coalesce(p_name, case when p_kind = 'Client' then v_client.name end)), '');
  if p_kind = 'Guardian' then
    if v_name is null or nullif(trim(coalesce(p_relationship, '')), '') is null then
      raise exception 'A guardian needs a name and their relationship to the client.' using errcode = 'check_violation';
    end if;
    if p_attachment is null or not exists (
      select 1 from public.attachments
       where id = p_attachment and client_id = p_client and category = 'Guardianship document') then
      raise exception 'A guardian is given access only with a guardianship document on this client''s file.'
        using errcode = 'check_violation';
    end if;
  end if;

  select * into v_staff from public.staff where user_id = auth.uid() and active;

  begin
    insert into public.portal_accounts
      (client_id, kind, name, relationship, phone, email, guardianship_attachment_id, invited_by, invited_by_name)
    values
      (p_client, p_kind, v_name, coalesce(trim(p_relationship), ''), v_phone, v_email,
       case when p_kind = 'Guardian' then p_attachment end, v_staff.id, v_staff.name)
    returning id into v_id;
  exception when unique_violation then
    raise exception 'Someone already has portal access with that phone number or email address, or this client already has an account.'
      using errcode = 'unique_violation';
  end;

  insert into public.portal_activity (account_id, client_id, action, detail, acting_as, actor_name)
  values (v_id, p_client, 'Invited', format('%s given portal access (%s)', v_name, lower(p_kind)), 'Staff', v_staff.name);
  return v_id;
end;
$$;

-- End sessions, and the refresh tokens behind them, so nobody stays signed in.
create or replace function public.portal_end_sessions(p_account uuid, p_reason text)
returns integer language plpgsql security definer set search_path = public as $$
declare
  v_user  uuid;
  v_count integer;
begin
  select auth_user_id into v_user from public.portal_accounts where id = p_account;
  update public.portal_sessions set ended_at = now(), ended_reason = p_reason
   where account_id = p_account and ended_at is null;
  get diagnostics v_count = row_count;
  if v_user is not null then
    delete from auth.sessions where user_id = v_user;
  end if;
  return v_count;
end;
$$;

create or replace function public.portal_disable_account(p_account uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_a     public.portal_accounts%rowtype;
  v_staff public.staff%rowtype;
begin
  select * into v_a from public.portal_accounts where id = p_account;
  if not found then
    raise exception 'That portal account is not on file.' using errcode = 'check_violation';
  end if;
  if not public.can_manage_portal(v_a.client_id) then
    raise exception 'Only Admin, Intake & Client Reports, or the client''s assigned staff member can turn off portal access.'
      using errcode = 'insufficient_privilege';
  end if;
  if nullif(trim(coalesce(p_reason, '')), '') is null then
    raise exception 'Say why portal access is being turned off.' using errcode = 'check_violation';
  end if;
  select * into v_staff from public.staff where user_id = auth.uid() and active;
  update public.portal_accounts
     set disabled_at = now(), disabled_by = v_staff.id, disabled_reason = trim(p_reason)
   where id = p_account and disabled_at is null;
  perform public.portal_end_sessions(p_account, 'Account disabled');
  insert into public.portal_activity (account_id, client_id, action, detail, acting_as, actor_name)
  values (p_account, v_a.client_id, 'Account disabled', trim(p_reason), 'Staff', v_staff.name);
end;
$$;

create or replace function public.portal_sign_out_everywhere(p_client uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare
  v_staff public.staff%rowtype;
  v_a     record;
  v_total integer := 0;
begin
  if not public.can_manage_portal(p_client) then
    raise exception 'Only Admin, Intake & Client Reports, or the client''s assigned staff member can sign people out of the portal.'
      using errcode = 'insufficient_privilege';
  end if;
  select * into v_staff from public.staff where user_id = auth.uid() and active;
  for v_a in select id from public.portal_accounts where client_id = p_client loop
    v_total := v_total + public.portal_end_sessions(v_a.id, 'Signed out everywhere');
  end loop;
  insert into public.portal_activity (client_id, action, detail, acting_as, actor_name)
  values (p_client, 'Signed out everywhere', format('%s session(s) ended', v_total), 'Staff', v_staff.name);
  return v_total;
end;
$$;

-- ── rules ────────────────────────────────────────────────────
alter table public.portal_accounts    enable row level security;
alter table public.portal_login_codes enable row level security;
alter table public.portal_sessions    enable row level security;
alter table public.portal_terms       enable row level security;
alter table public.portal_consents    enable row level security;
alter table public.portal_activity    enable row level security;

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

-- portal_login_codes has no policy at all: nobody but the service role.

revoke all on public.portal_accounts, public.portal_login_codes, public.portal_sessions,
  public.portal_terms, public.portal_consents, public.portal_activity from anon;
revoke insert, update, delete, truncate on public.portal_accounts, public.portal_sessions,
  public.portal_terms, public.portal_consents, public.portal_activity from authenticated;
revoke all on public.portal_login_codes from authenticated;
grant select on public.portal_accounts, public.portal_sessions, public.portal_terms,
  public.portal_consents, public.portal_activity to authenticated;
grant all on public.portal_accounts, public.portal_login_codes, public.portal_sessions,
  public.portal_terms, public.portal_consents, public.portal_activity to service_role;

revoke execute on function public.portal_terms_frozen() from public, anon, authenticated;
revoke execute on function public.portal_append_only() from public, anon, authenticated;
revoke execute on function public.portal_end_sessions(uuid, text) from public, anon, authenticated;
grant execute on function public.portal_end_sessions(uuid, text) to service_role;

revoke execute on function public.portal_session_account_id() from public, anon;
revoke execute on function public.portal_my_consent(text) from public, anon;
revoke execute on function public.portal_client_id() from public, anon;
revoke execute on function public.portal_touch_session() from public, anon;
revoke execute on function public.can_manage_portal(uuid) from public, anon;
revoke execute on function public.portal_invite(uuid, text, text, text, text, text, uuid) from public, anon;
revoke execute on function public.portal_disable_account(uuid, text) from public, anon;
revoke execute on function public.portal_sign_out_everywhere(uuid) from public, anon;
grant execute on function public.portal_session_account_id(), public.portal_my_consent(text),
  public.portal_client_id(), public.portal_touch_session(), public.can_manage_portal(uuid),
  public.portal_invite(uuid, text, text, text, text, text, uuid), public.portal_disable_account(uuid, text),
  public.portal_sign_out_everywhere(uuid)
  to authenticated, service_role;

alter table public.portal_login_codes alter column account_id drop not null;
alter table public.portal_login_codes alter column code_hash drop not null;

-- ── a portal client's sign-in user ─────────────────────────
-- 0005 made invite-only a property of the database: a sign-in user can only
-- exist for an active staff row. The portal adds exactly one more kind, and
-- nothing else changes: the address p-<account id>@portal.zionvocrehab.com, for
-- a live portal account that has no sign-in user yet. Nobody receives mail
-- there; it is the name the sign-in service knows the account by, so a client's
-- real email address never has to be a login.
create or replace function public.link_staff_account()
returns trigger language plpgsql security definer set search_path = public
as $$
declare
  v_staff public.staff%rowtype;
begin
  if lower(new.email) ~ '^p-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}@portal\.zionvocrehab\.com$' then
    update public.portal_accounts
       set auth_user_id = new.id
     where id = substring(lower(new.email) from '^p-([0-9a-f-]{36})@')::uuid
       and disabled_at is null
       and auth_user_id is null;
    if not found then
      raise exception 'No portal account is waiting for %.', new.email
        using errcode = 'insufficient_privilege';
    end if;
    return new;
  end if;

  select * into v_staff
    from public.staff
   where lower(email) = lower(new.email)
   limit 1;

  if v_staff.id is null then
    raise exception 'No staff account exists for %. Accounts are created by the administrator.',
      new.email using errcode = 'insufficient_privilege';
  end if;

  if not v_staff.active then
    raise exception 'The staff account for % is closed.', new.email
      using errcode = 'insufficient_privilege';
  end if;

  if v_staff.user_id is not null and v_staff.user_id <> new.id then
    raise exception 'The staff account for % is already linked to a login.', new.email
      using errcode = 'insufficient_privilege';
  end if;

  update public.staff
     set user_id     = new.id,
         invited_at  = coalesce(invited_at, now()),
         accepted_at = case
                         when new.email_confirmed_at is not null then coalesce(accepted_at, now())
                         else accepted_at
                       end
   where id = v_staff.id;

  return new;
end;
$$;

-- ── sign-in codes ────────────────────────────────────────────
-- Six digits, good for ten minutes and five tries, one new code a minute and
-- five an hour per account, thirty attempts an hour from one address. Only the
-- server calls these, as the service role; the code itself is returned once,
-- to be sent, and only its hash is kept.
--
-- What was typed is answered the same way whether or not anybody has access
-- at it: an attempt id comes back either way, and the sign-in page says the
-- same sentence. Only the server knows whether there was a code to send.
create or replace function public.portal_issue_code(p_identifier text, p_ip text)
returns table (attempt_id uuid, account_id uuid, channel text, destination text, account_name text, code text)
language plpgsql security definer set search_path = public as $$
declare
  v_raw     text := trim(coalesce(p_identifier, ''));
  v_email   text := case when position('@' in v_raw) > 0 then lower(v_raw) end;
  v_phone   text := case when v_email is null then public.normalize_phone(v_raw) end;
  v_channel text := case when v_email is not null then 'Email' else 'Text' end;
  v_ip      text := left(coalesce(p_ip, ''), 100);
  v_a       public.portal_accounts%rowtype;
  v_latest  public.portal_login_codes%rowtype;
  v_id      uuid := gen_random_uuid();
  v_code    text;
begin
  if (select count(*) from public.portal_login_codes c
       where c.ip = v_ip and c.created_at > now() - interval '1 hour') >= 30 then
    return query select v_id, null::uuid, v_channel, null::text, null::text, null::text;
    return;
  end if;

  if v_email is not null then
    select * into v_a from public.portal_accounts a where a.email = v_email and a.disabled_at is null;
  elsif v_phone is not null then
    select * into v_a from public.portal_accounts a where a.phone = v_phone and a.disabled_at is null;
  end if;

  if v_a.id is null then
    insert into public.portal_login_codes (id, channel, expires_at, ip)
    values (v_id, v_channel, now() + interval '10 minutes', v_ip);
    return query select v_id, null::uuid, v_channel, null::text, null::text, null::text;
    return;
  end if;

  select * into v_latest from public.portal_login_codes c
   where c.account_id = v_a.id order by c.created_at desc limit 1;

  -- Asked again within a minute, or too often this hour: no new message. The
  -- code already sent still works.
  if (v_latest.id is not null and v_latest.created_at > now() - interval '60 seconds')
     or (select count(*) from public.portal_login_codes c
          where c.account_id = v_a.id and c.created_at > now() - interval '1 hour') >= 5 then
    return query select coalesce(case when v_latest.used_at is null and v_latest.expires_at > now() then v_latest.id end, v_id),
                        v_a.id, v_channel, null::text, v_a.name, null::text;
    return;
  end if;

  -- Random from gen_random_uuid(): its first 32 bits come from the system's
  -- strong random source, which random() does not.
  v_code := lpad(((('x' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8))::bit(32)::bigint) % 1000000)::text, 6, '0');

  -- Only the newest code works.
  update public.portal_login_codes c set expires_at = now()
   where c.account_id = v_a.id and c.used_at is null and c.expires_at > now();

  insert into public.portal_login_codes (id, account_id, code_hash, channel, expires_at, ip)
  values (v_id, v_a.id, encode(sha256(convert_to(v_a.id::text || ':' || v_code, 'UTF8')), 'hex'),
          v_channel, now() + interval '10 minutes', v_ip);

  insert into public.portal_activity (account_id, client_id, action, detail, ip, acting_as, actor_name)
  values (v_a.id, v_a.client_id, 'Code sent', case when v_channel = 'Email' then 'by email' else 'by text' end,
          v_ip, 'System', '');

  return query select v_id, v_a.id, v_channel,
                      case when v_channel = 'Email' then v_a.email else v_a.phone end,
                      v_a.name, v_code;
end;
$$;

-- 'ok' with the account's sign-in address, or 'wrong', 'expired', 'locked'.
create or replace function public.portal_check_code(p_attempt uuid, p_code text, p_ip text)
returns table (result text, account_id uuid, sign_in_email text)
language plpgsql security definer set search_path = public as $$
declare
  v_c    public.portal_login_codes%rowtype;
  v_a    public.portal_accounts%rowtype;
  v_code text := regexp_replace(coalesce(p_code, ''), '\D', '', 'g');
begin
  select * into v_c from public.portal_login_codes c where c.id = p_attempt for update;
  if not found then
    return query select 'wrong'::text, null::uuid, null::text;
    return;
  end if;
  if v_c.attempts >= 5 then
    return query select 'locked'::text, null::uuid, null::text;
    return;
  end if;
  if v_c.used_at is not null or v_c.expires_at <= now() then
    return query select 'expired'::text, null::uuid, null::text;
    return;
  end if;

  update public.portal_login_codes c set attempts = c.attempts + 1 where c.id = v_c.id;

  if v_c.account_id is not null
     and v_c.code_hash = encode(sha256(convert_to(v_c.account_id::text || ':' || v_code, 'UTF8')), 'hex') then
    select * into v_a from public.portal_accounts a where a.id = v_c.account_id and a.disabled_at is null;
    if v_a.id is null then
      return query select 'expired'::text, null::uuid, null::text;
      return;
    end if;
    update public.portal_login_codes c set used_at = now() where c.id = v_c.id;
    return query select 'ok'::text, v_a.id, 'p-' || v_a.id::text || '@portal.zionvocrehab.com';
    return;
  end if;

  if v_c.attempts + 1 >= 5 then
    if v_c.account_id is not null then
      insert into public.portal_activity (account_id, client_id, action, detail, ip, acting_as, actor_name)
      select a.id, a.client_id, 'Code refused', 'Five wrong codes; a new code is needed', left(coalesce(p_ip, ''), 100), 'System', ''
        from public.portal_accounts a where a.id = v_c.account_id;
    end if;
    return query select 'locked'::text, null::uuid, null::text;
    return;
  end if;
  return query select 'wrong'::text, null::uuid, null::text;
end;
$$;

-- ── starting and ending a session ──────────────────────────
-- Called as the client straight after the code is accepted. A session id that
-- has ended stays ended: this never revives one.
create or replace function public.portal_begin_session(p_ip text, p_user_agent text)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_sid uuid := nullif(auth.jwt() ->> 'session_id', '')::uuid;
  v_a   public.portal_accounts%rowtype;
begin
  select * into v_a from public.portal_accounts where auth_user_id = auth.uid() and disabled_at is null;
  if v_a.id is null or v_sid is null then
    raise exception 'This sign-in is not for the client portal.' using errcode = 'insufficient_privilege';
  end if;
  insert into public.portal_sessions (id, account_id, auth_user_id, ip, user_agent)
  values (v_sid, v_a.id, auth.uid(), left(coalesce(p_ip, ''), 100), left(coalesce(p_user_agent, ''), 400))
  on conflict (id) do nothing;
  if found then
    update public.portal_accounts
       set first_signed_in_at = coalesce(first_signed_in_at, now()), last_signed_in_at = now()
     where id = v_a.id;
    insert into public.portal_activity (account_id, client_id, action, ip, acting_as, actor_name)
    values (v_a.id, v_a.client_id, 'Signed in', left(coalesce(p_ip, ''), 100), v_a.kind, v_a.name);
  end if;
  return v_a.id;
end;
$$;

create or replace function public.portal_end_my_session()
returns void language plpgsql security definer set search_path = public as $$
declare
  v_s public.portal_sessions%rowtype;
begin
  update public.portal_sessions
     set ended_at = now(), ended_reason = 'Signed out'
   where id = nullif(auth.jwt() ->> 'session_id', '')::uuid
     and auth_user_id = auth.uid()
     and ended_at is null
  returning * into v_s;
  if v_s.id is not null then
    insert into public.portal_activity (account_id, client_id, action, acting_as, actor_name)
    select a.id, a.client_id, 'Signed out', a.kind, a.name from public.portal_accounts a where a.id = v_s.account_id;
  end if;
end;
$$;

-- ── consent, from the client ────────────────────────────────
-- Recorded against the terms in force, with who gave it. Consent to texts is
-- also written where texting already looks - sms_consent_events, method
-- 'Portal' - for the number on the client's record, so the one rule that
-- decides whether a text may go out stays the only one.
create or replace function public.portal_record_consent(p_kind text, p_given boolean, p_ip text, p_user_agent text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_a     public.portal_accounts%rowtype;
  v_terms text;
  v_phone text;
begin
  select * into v_a from public.portal_accounts where id = public.portal_session_account_id();
  if v_a.id is null then
    raise exception 'Your portal session has ended. Sign in again.' using errcode = 'insufficient_privilege';
  end if;
  if p_kind not in ('Electronic communication', 'Text messages') or p_given is null then
    raise exception 'That is not a choice the portal records.' using errcode = 'check_violation';
  end if;
  select version into v_terms from public.portal_terms where is_current;
  if v_terms is null then
    raise exception 'The portal terms are not in force yet.' using errcode = 'check_violation';
  end if;
  if p_kind = 'Text messages' and p_given and not public.portal_my_consent('Electronic communication') then
    raise exception 'Agree to the terms before choosing text messages.' using errcode = 'check_violation';
  end if;

  if p_kind = 'Text messages' then
    select public.normalize_phone(nullif(phone, '')) into v_phone from public.clients where id = v_a.client_id;
    if p_given and v_phone is null then
      raise exception 'There is no phone number on your record to text. Call us at 385-406-3432 to add one.'
        using errcode = 'check_violation';
    end if;
  end if;

  insert into public.portal_consents (account_id, client_id, terms_version, kind, given, ip, user_agent, acting_as, actor_name)
  values (v_a.id, v_a.client_id, v_terms, p_kind, p_given, left(coalesce(p_ip, ''), 100),
          left(coalesce(p_user_agent, ''), 400), v_a.kind, v_a.name);

  insert into public.portal_activity (account_id, client_id, action, detail, ip, acting_as, actor_name)
  values (v_a.id, v_a.client_id, case when p_given then 'Consent given' else 'Consent withdrawn' end,
          p_kind || ' · terms ' || v_terms, left(coalesce(p_ip, ''), 100), v_a.kind, v_a.name);

  if p_kind = 'Text messages' and v_phone is not null then
    insert into public.sms_consent_events (client_id, state, phone, method, note)
    values (v_a.client_id, case when p_given then 'Granted' else 'Withdrawn' end, v_phone, 'Portal',
            format('%s in the client portal by %s%s, terms %s',
                   case when p_given then 'Agreed' else 'Withdrawn' end, v_a.name,
                   case when v_a.kind = 'Guardian' then ' (guardian, ' || v_a.relationship || ')' else '' end,
                   v_terms));
  end if;
end;
$$;

-- ── what the portal knows about the person signed in ───────
-- Their own account, the first name on the record they act for, and where
-- their consent stands. The assigned staff member's name only once they have
-- agreed to the terms.
create or replace function public.portal_me()
returns table (
  account_id uuid, kind text, name text, relationship text, client_first_name text,
  staff_first_name text, terms_version text, electronic boolean, texts boolean, phone_last4 text)
language sql stable security definer set search_path = public as $$
  select a.id, a.kind, a.name, a.relationship,
         split_part(trim(c.name), ' ', 1),
         case when public.portal_my_consent('Electronic communication') then split_part(trim(s.name), ' ', 1) end,
         (select t.version from public.portal_terms t where t.is_current),
         public.portal_my_consent('Electronic communication'),
         coalesce((select e.state = 'Granted' from public.sms_consent_events e
                    where e.client_id = c.id order by e.at desc, e.seq desc limit 1), false),
         right(public.normalize_phone(nullif(c.phone, '')), 4)
    from public.portal_accounts a
    join public.clients c on c.id = a.client_id
    left join public.staff s on s.id = c.assigned_staff_id
   where a.id = public.portal_session_account_id();
$$;

revoke execute on function public.link_staff_account() from public, anon, authenticated;
revoke execute on function public.portal_issue_code(text, text) from public, anon, authenticated;
revoke execute on function public.portal_check_code(uuid, text, text) from public, anon, authenticated;
grant execute on function public.portal_issue_code(text, text), public.portal_check_code(uuid, text, text) to service_role;

revoke execute on function public.portal_begin_session(text, text) from public, anon;
revoke execute on function public.portal_end_my_session() from public, anon;
revoke execute on function public.portal_record_consent(text, boolean, text, text) from public, anon;
revoke execute on function public.portal_me() from public, anon;
grant execute on function public.portal_begin_session(text, text), public.portal_end_my_session(),
  public.portal_record_consent(text, boolean, text, text), public.portal_me()
  to authenticated, service_role;
