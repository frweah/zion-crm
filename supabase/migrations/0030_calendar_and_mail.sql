-- ─────────────────────────────────────────────────────────────
-- 0030 — calendar events and logged mail.
--
-- Two rules shape all of this, and both are the owner's.
--
-- A completed visit never logs service hours by itself. Hours are what USOR is
-- billed for; a calendar entry is evidence that something was scheduled, not
-- that it happened or how long it took. So a finished visit raises an offer
-- and a person answers it.
--
-- Mail is logged only where an address already matches a client or a
-- counselor, and only ever as subject, date, direction and a link. The body is
-- never read into this system. Mail with no match is not stored at all — not
-- stored and filtered, not stored (which is the same distinction as a form
-- that shows blank versus a form that was never filled in).
-- ─────────────────────────────────────────────────────────────

-- ─────────────────────────────────────────────────────────────
-- Calendar
-- ─────────────────────────────────────────────────────────────
create table if not exists public.calendar_events (
  id                uuid primary key default gen_random_uuid(),
  client_id         uuid references public.clients(id) on delete cascade,
  staff_id          uuid not null references public.staff(id) on delete cascade,
  kind              text not null default 'Coaching visit'
                      check (kind in ('Coaching visit', 'Intake appointment', 'Counselor call', 'Other')),
  title             text not null,
  starts_at         timestamptz not null,
  ends_at           timestamptz not null,
  location          text not null default '',
  note              text not null default '',

  -- Which side it came from. A CRM event is pushed out; an Outlook event is
  -- pulled in and must not be pushed back, or the two copies multiply.
  origin            text not null default 'CRM' check (origin in ('CRM', 'Outlook')),

  outlook_event_id  text,
  outlook_web_link  text,
  push_state        text not null default 'Pending'
                      check (push_state in ('Pending', 'Pushed', 'Failed', 'Not pushed')),
  push_error        text not null default '',

  -- Set when somebody has answered the offer, either way, so a visit stops
  -- asking. Declining is an answer.
  hours_prompt_answered_at timestamptz,

  created_by        uuid references public.staff(id) on delete set null,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),

  check (ends_at > starts_at),
  unique (staff_id, outlook_event_id)
);

create index if not exists calendar_events_client_idx on public.calendar_events (client_id, starts_at desc);
create index if not exists calendar_events_staff_idx on public.calendar_events (staff_id, starts_at desc);
create index if not exists calendar_events_pending_idx on public.calendar_events (push_state)
  where push_state = 'Pending';

drop trigger if exists calendar_events_updated_at on public.calendar_events;
create trigger calendar_events_updated_at before update on public.calendar_events
  for each row execute function public.set_updated_at();

alter table public.calendar_events enable row level security;

-- Client appointments are client information: every active staff member can
-- see them, the same as notes and tasks.
drop policy if exists calendar_events_read on public.calendar_events;
create policy calendar_events_read on public.calendar_events
  for select to authenticated using (public.is_active_staff());

drop policy if exists calendar_events_write on public.calendar_events;
create policy calendar_events_write on public.calendar_events
  for insert to authenticated
  with check (public.is_admin() or staff_id = public.current_staff_id());

drop policy if exists calendar_events_update on public.calendar_events;
create policy calendar_events_update on public.calendar_events
  for update to authenticated
  using (public.is_admin() or staff_id = public.current_staff_id())
  with check (public.is_admin() or staff_id = public.current_staff_id());

drop policy if exists calendar_events_delete on public.calendar_events;
create policy calendar_events_delete on public.calendar_events
  for delete to authenticated
  using (public.is_admin() or staff_id = public.current_staff_id());

-- ─────────────────────────────────────────────────────────────
-- Mail
--
-- Subject, date, direction, link. There is no column for a body, so no amount
-- of later carelessness can put one here.
-- ─────────────────────────────────────────────────────────────
create table if not exists public.mail_log (
  id                  uuid primary key default gen_random_uuid(),
  staff_id            uuid not null references public.staff(id) on delete cascade,
  client_id           uuid references public.clients(id) on delete cascade,
  counselor_id        uuid references public.counselors(id) on delete cascade,

  graph_message_id    text not null,
  conversation_id     text not null default '',
  subject             text not null default '',
  sent_at             timestamptz not null,
  direction           text not null check (direction in ('Incoming', 'Outgoing')),
  counterpart_email   text not null,
  web_link            text not null default '',

  created_at          timestamptz not null default now(),

  -- Logged against something, or it should not have been logged at all.
  check (client_id is not null or counselor_id is not null),
  unique (staff_id, graph_message_id)
);

create index if not exists mail_log_client_idx on public.mail_log (client_id, sent_at desc);
create index if not exists mail_log_counselor_idx on public.mail_log (counselor_id, sent_at desc);
create index if not exists mail_log_conversation_idx on public.mail_log (conversation_id);

alter table public.mail_log enable row level security;

drop policy if exists mail_log_read on public.mail_log;
create policy mail_log_read on public.mail_log
  for select to authenticated using (public.is_active_staff());

-- Only the sweep writes here. A person excludes a thread; they do not hand-log
-- correspondence, because a log somebody can compose is not a log.
drop policy if exists mail_log_delete on public.mail_log;
create policy mail_log_delete on public.mail_log
  for delete to authenticated
  using (public.is_admin() or staff_id = public.current_staff_id());

revoke insert, update on public.mail_log from authenticated;

/**
 * Threads that are not to be logged.
 *
 * Excluding removes what has already been logged and stops the sweep bringing
 * it back. Kept by conversation rather than by message, because a thread is
 * what a person means when they say "not this one".
 */
create table if not exists public.mail_exclusions (
  conversation_id text primary key,
  excluded_by     uuid references public.staff(id) on delete set null,
  excluded_at     timestamptz not null default now(),
  reason          text not null default ''
);

alter table public.mail_exclusions enable row level security;

drop policy if exists mail_exclusions_read on public.mail_exclusions;
create policy mail_exclusions_read on public.mail_exclusions
  for select to authenticated using (public.is_active_staff());
drop policy if exists mail_exclusions_write on public.mail_exclusions;
create policy mail_exclusions_write on public.mail_exclusions
  for all to authenticated using (public.is_active_staff()) with check (public.is_active_staff());

/** Excludes a thread and removes whatever it already logged. */
create or replace function public.exclude_mail_thread(p_conversation_id text, p_reason text default '')
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_active_staff() then
    raise exception 'You are not signed in.' using errcode = 'insufficient_privilege';
  end if;
  if coalesce(p_conversation_id, '') = '' then
    raise exception 'No thread given.' using errcode = 'check_violation';
  end if;

  insert into public.mail_exclusions (conversation_id, excluded_by, reason)
  values (p_conversation_id, public.current_staff_id(), coalesce(p_reason, ''))
  on conflict (conversation_id) do update
    set excluded_by = excluded.excluded_by, excluded_at = now(), reason = excluded.reason;

  delete from public.mail_log where conversation_id = p_conversation_id;
end;
$$;

revoke execute on function public.exclude_mail_thread(text, text) from public;
grant execute on function public.exclude_mail_thread(text, text) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- Sync state, per person
-- ─────────────────────────────────────────────────────────────
create table if not exists public.microsoft_sync_state (
  staff_id             uuid primary key references public.staff(id) on delete cascade,
  last_run_at          timestamptz,
  last_mail_sync_at    timestamptz,
  last_calendar_sync_at timestamptz,
  mail_logged          integer not null default 0,
  events_pulled        integer not null default 0,
  last_error           text not null default '',
  updated_at           timestamptz not null default now()
);

drop trigger if exists microsoft_sync_state_updated_at on public.microsoft_sync_state;
create trigger microsoft_sync_state_updated_at before update on public.microsoft_sync_state
  for each row execute function public.set_updated_at();

alter table public.microsoft_sync_state enable row level security;

drop policy if exists microsoft_sync_state_read on public.microsoft_sync_state;
create policy microsoft_sync_state_read on public.microsoft_sync_state
  for select to authenticated
  using (public.is_admin() or staff_id = public.current_staff_id());

-- ─────────────────────────────────────────────────────────────
-- Tokens for the unattended sweep.
--
-- get_microsoft_tokens refuses everybody except the person themselves, which
-- is right for a human caller and impossible for a cron run, where there is no
-- session at all.
--
-- This is the deliberate exception, and it is narrow: granted to service_role
-- only, never to authenticated, so it can be called by the server on a
-- schedule and by nothing a signed-in person can reach. The guarantee that
-- survives is the one that matters — no *person*, Admin included, can read
-- somebody else's token through this system.
-- ─────────────────────────────────────────────────────────────
create or replace function public.get_microsoft_tokens_for_sync(p_staff_id uuid)
returns table (access_token text, refresh_token text, expires_at timestamptz)
language plpgsql security definer set search_path = public, vault, extensions as $$
declare
  k text;
begin
  select decrypted_secret into k from vault.decrypted_secrets where name = 'zion_oauth_key';
  if k is null then
    raise exception 'The OAuth encryption key is missing from Vault.';
  end if;

  return query
    select case when c.access_encrypted is null then null
                else pgp_sym_decrypt(c.access_encrypted, k) end,
           case when c.refresh_encrypted is null then null
                else pgp_sym_decrypt(c.refresh_encrypted, k) end,
           c.access_expires_at
      from public.microsoft_connections c
      join public.staff s on s.id = c.staff_id and s.active
     where c.staff_id = p_staff_id;
end;
$$;

revoke execute on function public.get_microsoft_tokens_for_sync(uuid) from public;
revoke execute on function public.get_microsoft_tokens_for_sync(uuid) from authenticated;
grant execute on function public.get_microsoft_tokens_for_sync(uuid) to service_role;

/** The same, for storing what a refresh returned during an unattended run. */
create or replace function public.set_microsoft_tokens_for_sync(
  p_staff_id   uuid,
  p_access     text,
  p_refresh    text,
  p_expires_at timestamptz
)
returns void
language plpgsql security definer set search_path = public, vault, extensions as $$
declare
  k text;
begin
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
   where staff_id = p_staff_id;
end;
$$;

revoke execute on function public.set_microsoft_tokens_for_sync(uuid, text, text, timestamptz) from public;
revoke execute on function public.set_microsoft_tokens_for_sync(uuid, text, text, timestamptz) from authenticated;
grant execute on function public.set_microsoft_tokens_for_sync(uuid, text, text, timestamptz) to service_role;
