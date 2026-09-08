-- ─────────────────────────────────────────────────────────────
-- 0032 — the shared mailbox.
--
-- Counselor correspondence arrives at service@zionvocrehab.com, not in
-- anybody's personal mailbox, so the sweep has to be able to read a mailbox
-- that belongs to the practice rather than to a person.
--
-- Delegated, not application. The shared mailbox is read using an Admin's own
-- token under Mail.Read.Shared, which works only because Exchange has given
-- that person access to it. So the practice's ability to read its own shared
-- mailbox rests on a permission an Exchange administrator granted and can take
-- away — not on this application holding a key to every mailbox in the tenant,
-- which is what the application-level alternative would have meant.
--
-- A logged message now belongs either to a person's mailbox or to a shared
-- one, never to neither, and the pair that has to be unique is the mailbox and
-- the message rather than the person and the message.
-- ─────────────────────────────────────────────────────────────

create table if not exists public.shared_mailboxes (
  address           text primary key,
  label             text not null default '',
  -- Whose delegated access is used to read it. Their token, their Exchange
  -- permission; if they lose access the sweep stops and says so.
  connected_by      uuid references public.staff(id) on delete set null,
  active            boolean not null default true,
  last_mail_sync_at timestamptz,
  last_run_at       timestamptz,
  mail_logged       integer not null default 0,
  last_error        text not null default '',
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

drop trigger if exists shared_mailboxes_updated_at on public.shared_mailboxes;
create trigger shared_mailboxes_updated_at before update on public.shared_mailboxes
  for each row execute function public.set_updated_at();

alter table public.shared_mailboxes enable row level security;

-- Everyone can see that the practice reads a shared mailbox — it is not a
-- secret, and knowing it explains why counselor mail appears on records.
drop policy if exists shared_mailboxes_read on public.shared_mailboxes;
create policy shared_mailboxes_read on public.shared_mailboxes
  for select to authenticated using (public.is_active_staff());

drop policy if exists shared_mailboxes_write on public.shared_mailboxes;
create policy shared_mailboxes_write on public.shared_mailboxes
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

grant insert, update on public.shared_mailboxes to service_role;

-- ─────────────────────────────────────────────────────────────
-- mail_log: a message belongs to a mailbox, which may not be a person's
-- ─────────────────────────────────────────────────────────────
alter table public.mail_log
  alter column staff_id drop not null;

alter table public.mail_log
  add column if not exists mailbox_address text not null default '';

-- Which mailbox a message came from, whoever or whatever owns it. Generated so
-- it cannot disagree with the two columns it is derived from.
alter table public.mail_log
  add column if not exists mailbox_key text
  generated always as (coalesce(staff_id::text, mailbox_address)) stored;

alter table public.mail_log drop constraint if exists mail_log_staff_id_graph_message_id_key;
drop index if exists mail_log_mailbox_message_idx;
create unique index mail_log_mailbox_message_idx
  on public.mail_log (mailbox_key, graph_message_id);

alter table public.mail_log drop constraint if exists mail_log_has_a_mailbox;
alter table public.mail_log add constraint mail_log_has_a_mailbox
  check (staff_id is not null or mailbox_address <> '');

create index if not exists mail_log_mailbox_address_idx on public.mail_log (mailbox_address);

-- A person may still delete what came from their own mailbox; Admin may delete
-- anything, which now includes what came from the shared one.
drop policy if exists mail_log_delete on public.mail_log;
create policy mail_log_delete on public.mail_log
  for delete to authenticated
  using (public.is_admin() or staff_id = public.current_staff_id());

-- ─────────────────────────────────────────────────────────────
-- Writing a shared-mailbox message
-- ─────────────────────────────────────────────────────────────
create or replace function public.log_mail_message_internal(
  p_staff_id        uuid,
  p_mailbox         text,
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
  if p_staff_id is null and coalesce(p_mailbox, '') = '' then
    raise exception 'A logged message comes from some mailbox.' using errcode = 'check_violation';
  end if;

  if coalesce(p_conversation_id, '') <> ''
     and exists (select 1 from public.mail_exclusions where conversation_id = p_conversation_id) then
    return false;
  end if;

  insert into public.mail_log (
    staff_id, mailbox_address, client_id, counselor_id, graph_message_id, conversation_id,
    subject, sent_at, direction, counterpart_email, web_link
  )
  values (
    p_staff_id, coalesce(p_mailbox, ''), p_client_id, p_counselor_id, p_message_id,
    coalesce(p_conversation_id, ''), left(coalesce(p_subject, ''), 500), p_sent_at,
    p_direction, coalesce(p_counterpart, ''), coalesce(p_web_link, '')
  )
  on conflict (mailbox_key, graph_message_id) do nothing;

  return found;
end;
$$;

revoke execute on function public.log_mail_message_internal(
  uuid, text, uuid, uuid, text, text, text, timestamptz, text, text, text) from public;

-- The old three-argument shapes are replaced, so drop them rather than leave
-- two versions of the same idea for somebody to call the wrong one of.
drop function if exists public.log_mail_message_internal(
  uuid, uuid, uuid, text, text, text, timestamptz, text, text, text);

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
    v_staff, '', p_client_id, p_counselor_id, p_message_id, p_conversation_id,
    p_subject, p_sent_at, p_direction, p_counterpart, p_web_link);
end;
$$;

grant execute on function public.log_mail_message(
  uuid, uuid, text, text, text, timestamptz, text, text, text) to authenticated;

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
    p_staff_id, '', p_client_id, p_counselor_id, p_message_id, p_conversation_id,
    p_subject, p_sent_at, p_direction, p_counterpart, p_web_link);
end;
$$;

revoke execute on function public.log_mail_message_for_sync(
  uuid, uuid, uuid, text, text, text, timestamptz, text, text, text) from authenticated;
grant execute on function public.log_mail_message_for_sync(
  uuid, uuid, uuid, text, text, text, timestamptz, text, text, text) to service_role;

/** The shared mailbox's own door. Sweep only — there is no session behind it. */
create or replace function public.log_shared_mail_message(
  p_mailbox         text,
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
  if not exists (select 1 from public.shared_mailboxes where address = p_mailbox and active) then
    raise exception 'That is not a shared mailbox this practice reads.'
      using errcode = 'check_violation';
  end if;
  return public.log_mail_message_internal(
    null, p_mailbox, p_client_id, p_counselor_id, p_message_id, p_conversation_id,
    p_subject, p_sent_at, p_direction, p_counterpart, p_web_link);
end;
$$;

revoke execute on function public.log_shared_mail_message(
  text, uuid, uuid, text, text, text, timestamptz, text, text, text) from public;
revoke execute on function public.log_shared_mail_message(
  text, uuid, uuid, text, text, text, timestamptz, text, text, text) from authenticated;
grant execute on function public.log_shared_mail_message(
  text, uuid, uuid, text, text, text, timestamptz, text, text, text) to service_role;
