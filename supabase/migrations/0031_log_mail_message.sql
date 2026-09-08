-- ─────────────────────────────────────────────────────────────
-- 0031 — the only two ways a mail record gets written.
--
-- 0030 revoked insert on mail_log from the application role, so that a log of
-- correspondence cannot be composed by hand: a record somebody can write is
-- not a record of what happened. That left the on-demand sync unable to write
-- anything, because it runs as the signed-in person.
--
-- Two functions, the same split as the token functions. One is granted to
-- signed-in staff and takes the mailbox owner from the session, so it can only
-- ever write rows for the person calling it. The other is granted to the
-- service role alone, for the unattended sweep, and takes the staff id
-- explicitly because there is no session to take it from.
--
-- Both refuse a message on an excluded thread, so exclusion holds wherever the
-- write comes from rather than only where the caller remembered to check.
-- ─────────────────────────────────────────────────────────────

create or replace function public.log_mail_message_internal(
  p_staff_id        uuid,
  p_client_id       uuid,
  p_counselor_id    uuid,
  p_message_id      text,
  p_conversation_id text,
  p_subject         text,
  p_sent_at         timestamptz,
  p_direction       text,
  p_counterpart     text,
  p_web_link        text
)
returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if p_client_id is null and p_counselor_id is null then
    raise exception 'Mail is logged against a client or a counselor, never on its own.'
      using errcode = 'check_violation';
  end if;
  if p_direction not in ('Incoming', 'Outgoing') then
    raise exception 'A message is Incoming or Outgoing.' using errcode = 'check_violation';
  end if;

  if coalesce(p_conversation_id, '') <> ''
     and exists (select 1 from public.mail_exclusions where conversation_id = p_conversation_id) then
    return false;
  end if;

  insert into public.mail_log (
    staff_id, client_id, counselor_id, graph_message_id, conversation_id,
    subject, sent_at, direction, counterpart_email, web_link
  )
  values (
    p_staff_id, p_client_id, p_counselor_id, p_message_id, coalesce(p_conversation_id, ''),
    left(coalesce(p_subject, ''), 500), p_sent_at, p_direction,
    coalesce(p_counterpart, ''), coalesce(p_web_link, '')
  )
  on conflict (staff_id, graph_message_id) do nothing;

  return found;
end;
$$;

-- Not callable directly by anybody. The two wrappers below are the doors.
revoke execute on function public.log_mail_message_internal(
  uuid, uuid, uuid, text, text, text, timestamptz, text, text, text) from public;

/** For a signed-in person syncing their own mailbox. */
create or replace function public.log_mail_message(
  p_client_id       uuid,
  p_counselor_id    uuid,
  p_message_id      text,
  p_conversation_id text,
  p_subject         text,
  p_sent_at         timestamptz,
  p_direction       text,
  p_counterpart     text,
  p_web_link        text
)
returns boolean
language plpgsql security definer set search_path = public as $$
declare
  v_staff uuid := public.current_staff_id();
begin
  if v_staff is null then
    raise exception 'You are not signed in.' using errcode = 'insufficient_privilege';
  end if;
  return public.log_mail_message_internal(
    v_staff, p_client_id, p_counselor_id, p_message_id, p_conversation_id,
    p_subject, p_sent_at, p_direction, p_counterpart, p_web_link);
end;
$$;

revoke execute on function public.log_mail_message(
  uuid, uuid, text, text, text, timestamptz, text, text, text) from public;
grant execute on function public.log_mail_message(
  uuid, uuid, text, text, text, timestamptz, text, text, text) to authenticated;

/** For the unattended sweep, which has no session to take a staff id from. */
create or replace function public.log_mail_message_for_sync(
  p_staff_id        uuid,
  p_client_id       uuid,
  p_counselor_id    uuid,
  p_message_id      text,
  p_conversation_id text,
  p_subject         text,
  p_sent_at         timestamptz,
  p_direction       text,
  p_counterpart     text,
  p_web_link        text
)
returns boolean
language plpgsql security definer set search_path = public as $$
begin
  return public.log_mail_message_internal(
    p_staff_id, p_client_id, p_counselor_id, p_message_id, p_conversation_id,
    p_subject, p_sent_at, p_direction, p_counterpart, p_web_link);
end;
$$;

revoke execute on function public.log_mail_message_for_sync(
  uuid, uuid, uuid, text, text, text, timestamptz, text, text, text) from public;
revoke execute on function public.log_mail_message_for_sync(
  uuid, uuid, uuid, text, text, text, timestamptz, text, text, text) from authenticated;
grant execute on function public.log_mail_message_for_sync(
  uuid, uuid, uuid, text, text, text, timestamptz, text, text, text) to service_role;

-- The sweep also records its own state; the person's own run does it through
-- RLS, but an unattended run has no session and needs the same door.
grant insert, update on public.microsoft_sync_state to service_role;

-- 0030 gave microsoft_sync_state a read policy and no write policy, so a
-- person's own sync could not record that it had run. Their own row, theirs to
-- write; everybody else's stays out of reach.
drop policy if exists microsoft_sync_state_write on public.microsoft_sync_state;
create policy microsoft_sync_state_write on public.microsoft_sync_state
  for all to authenticated
  using (staff_id = public.current_staff_id())
  with check (staff_id = public.current_staff_id());

/**
 * Storing a refreshed token, without touching anything else.
 *
 * set_microsoft_tokens exists for the moment somebody connects, and it writes
 * the whole row — account id, address, display name, scopes. Calling it to
 * store a refreshed token would overwrite all of that with whatever the caller
 * happened to pass, which for a refresh is nothing. The connection would keep
 * working and quietly forget whose mailbox it was.
 */
create or replace function public.refresh_microsoft_tokens(
  p_access     text,
  p_refresh    text,
  p_expires_at timestamptz
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

  update public.microsoft_connections
     set access_encrypted  = case when p_access is null then null
                                  else pgp_sym_encrypt(p_access, k) end,
         refresh_encrypted = case when p_refresh is null then refresh_encrypted
                                  else pgp_sym_encrypt(p_refresh, k) end,
         access_expires_at = p_expires_at,
         last_refreshed_at = now(),
         last_error        = ''
   where staff_id = v_staff;
end;
$$;

revoke execute on function public.refresh_microsoft_tokens(text, text, timestamptz) from public;
grant execute on function public.refresh_microsoft_tokens(text, text, timestamptz) to authenticated;
