-- ─────────────────────────────────────────────────────────────
-- 0029 — connecting a Microsoft account.
--
-- Each staff member connects their own mailbox and calendar. Nobody connects
-- anybody else's: the consent is theirs to give, the same reasoning as the
-- 1099 electronic-delivery consent, and for the same reason it is recorded
-- against them rather than set by Admin.
--
-- A refresh token is a standing key to somebody's mail and calendar. It is
-- worth more than a TIN — a TIN identifies a person, a refresh token acts as
-- them — so it gets the same treatment or better: encrypted at rest under a
-- Vault key, never selectable by the application role, and readable only
-- through a definer function that the server calls and the browser cannot.
--
-- Deactivating a staff account already revokes their CRM sessions. It now
-- drops their tokens too, because an offboarded person whose refresh token is
-- still on file is still connected to this system by anything that runs on a
-- schedule.
-- ─────────────────────────────────────────────────────────────

create table if not exists public.microsoft_connections (
  staff_id            uuid primary key references public.staff(id) on delete cascade,
  microsoft_user_id   text not null,
  microsoft_email     text not null default '',
  display_name        text not null default '',
  scopes              text not null default '',
  access_encrypted    bytea,
  refresh_encrypted   bytea,
  access_expires_at   timestamptz,
  connected_at        timestamptz not null default now(),
  last_refreshed_at   timestamptz,
  last_error          text not null default '',
  updated_at          timestamptz not null default now()
);

drop trigger if exists microsoft_connections_updated_at on public.microsoft_connections;
create trigger microsoft_connections_updated_at before update on public.microsoft_connections
  for each row execute function public.set_updated_at();

alter table public.microsoft_connections enable row level security;

-- Who is connected is not a secret — Admin needs to see it to know whether a
-- sync will work. The tokens are, and they are handled below.
drop policy if exists microsoft_connections_read on public.microsoft_connections;
create policy microsoft_connections_read on public.microsoft_connections
  for select to authenticated
  using (public.is_admin() or staff_id = public.current_staff_id());

-- Disconnecting is the person's own, and Admin's when offboarding somebody.
drop policy if exists microsoft_connections_delete on public.microsoft_connections;
create policy microsoft_connections_delete on public.microsoft_connections
  for delete to authenticated
  using (public.is_admin() or staff_id = public.current_staff_id());

-- Nothing writes these columns directly. The functions below are the only way
-- in, so a token cannot be stored unencrypted by any route.
revoke insert, update on public.microsoft_connections from authenticated;
revoke select (access_encrypted, refresh_encrypted) on public.microsoft_connections
  from authenticated;

-- The key lives in Vault, not in this file and not in the table.
do $$
begin
  if not exists (select 1 from vault.secrets where name = 'zion_oauth_key') then
    perform vault.create_secret(
      encode(gen_random_bytes(32), 'base64'),
      'zion_oauth_key',
      'Encrypts Microsoft OAuth tokens at rest (migration 0029)'
    );
  end if;
end $$;

/**
 * Stores a freshly issued set of tokens.
 *
 * Called by the server after a token exchange or refresh. The person can only
 * ever write their own row: the staff id is taken from the session rather than
 * from an argument, so there is no parameter to get wrong or to tamper with.
 */
create or replace function public.set_microsoft_tokens(
  p_microsoft_user_id text,
  p_email             text,
  p_display_name      text,
  p_scopes            text,
  p_access            text,
  p_refresh           text,
  p_expires_at        timestamptz
)
returns void
language plpgsql security definer set search_path = public, vault, extensions as $$
declare
  k       text;
  v_staff uuid := public.current_staff_id();
begin
  if v_staff is null then
    raise exception 'You are not signed in.' using errcode = 'insufficient_privilege';
  end if;

  select decrypted_secret into k from vault.decrypted_secrets where name = 'zion_oauth_key';
  if k is null then
    raise exception 'The OAuth encryption key is missing from Vault.';
  end if;

  insert into public.microsoft_connections (
    staff_id, microsoft_user_id, microsoft_email, display_name, scopes,
    access_encrypted, refresh_encrypted, access_expires_at, last_refreshed_at, last_error
  )
  values (
    v_staff, p_microsoft_user_id, coalesce(p_email, ''), coalesce(p_display_name, ''),
    coalesce(p_scopes, ''),
    case when p_access is null then null else pgp_sym_encrypt(p_access, k) end,
    case when p_refresh is null then null else pgp_sym_encrypt(p_refresh, k) end,
    p_expires_at, now(), ''
  )
  on conflict (staff_id) do update set
    microsoft_user_id = excluded.microsoft_user_id,
    microsoft_email   = excluded.microsoft_email,
    display_name      = excluded.display_name,
    scopes            = excluded.scopes,
    access_encrypted  = excluded.access_encrypted,
    -- Microsoft does not always return a new refresh token. Keeping the old
    -- one is correct; overwriting it with null would silently disconnect
    -- somebody on their next refresh.
    refresh_encrypted = coalesce(excluded.refresh_encrypted,
                                 public.microsoft_connections.refresh_encrypted),
    access_expires_at = excluded.access_expires_at,
    last_refreshed_at = now(),
    last_error        = '';
end;
$$;

/**
 * Reads one person's tokens back.
 *
 * Admin is deliberately not allowed. Admin can see that somebody is connected
 * and can disconnect them, but reading their token would be reading their mail
 * as them, which is a different thing entirely and not something this system
 * should make easy.
 */
create or replace function public.get_microsoft_tokens(p_staff_id uuid)
returns table (access_token text, refresh_token text, expires_at timestamptz)
language plpgsql security definer set search_path = public, vault, extensions as $$
declare
  k text;
begin
  if p_staff_id is distinct from public.current_staff_id() then
    raise exception 'A Microsoft token can only be read by the person it belongs to.'
      using errcode = 'insufficient_privilege';
  end if;

  select decrypted_secret into k from vault.decrypted_secrets where name = 'zion_oauth_key';
  if k is null then
    raise exception 'The OAuth encryption key is missing from Vault.';
  end if;

  return query
    select case when access_encrypted is null then null
                else pgp_sym_decrypt(access_encrypted, k) end,
           case when refresh_encrypted is null then null
                else pgp_sym_decrypt(refresh_encrypted, k) end,
           access_expires_at
      from public.microsoft_connections
     where staff_id = p_staff_id;
end;
$$;

/** Records why a refresh failed, so a silent breakage becomes a visible one. */
create or replace function public.set_microsoft_error(p_staff_id uuid, p_error text)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_staff_id is distinct from public.current_staff_id() and not public.is_admin() then
    raise exception 'Not yours to change.' using errcode = 'insufficient_privilege';
  end if;
  update public.microsoft_connections
     set last_error = coalesce(p_error, '')
   where staff_id = p_staff_id;
end;
$$;

revoke execute on function public.set_microsoft_tokens(text, text, text, text, text, text, timestamptz) from public;
revoke execute on function public.get_microsoft_tokens(uuid) from public;
revoke execute on function public.set_microsoft_error(uuid, text) from public;
grant execute on function public.set_microsoft_tokens(text, text, text, text, text, text, timestamptz) to authenticated;
grant execute on function public.get_microsoft_tokens(uuid) to authenticated;
grant execute on function public.set_microsoft_error(uuid, text) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- Deactivating an account drops the connection with it.
--
-- Offboarding already revokes CRM sessions. A refresh token left behind would
-- keep this system able to act as somebody who no longer works here, on any
-- schedule that runs unattended.
-- ─────────────────────────────────────────────────────────────
create or replace function public.drop_microsoft_on_deactivate()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if old.active and not new.active then
    delete from public.microsoft_connections where staff_id = new.id;
  end if;
  return new;
end;
$$;

drop trigger if exists staff_drop_microsoft on public.staff;
create trigger staff_drop_microsoft after update of active on public.staff
  for each row execute function public.drop_microsoft_on_deactivate();
