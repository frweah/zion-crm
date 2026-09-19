-- Zion Vocational Rehab CRM — the messaging foundation (Messaging brief)
--
-- One model under all three channels still to come - client texting (A),
-- staff chat (B) and the website chat (C):
--
--   conversations   kind sms | internal | web; optionally about a client or a
--                   counselor; for texts and web chats, the outside party's
--                   number or address.
--   conversation_participants   who is in a staff conversation. (A text or a
--                   web chat is the team's, not a membership.)
--   messages        who sent it - staff, client, visitor or the system - its
--                   text, its attachments (by reference; B), its status.
--   read_receipts   how far each person has read in each conversation.
--
-- Who reads what, in the database:
--
--   A staff conversation (internal): its participants. Admin as well when it
--   is about a client - client messages are client information, as with
--   logged mail - but not a private conversation between colleagues. Admin
--   can see who is in any staff conversation (B's "Admin can see membership").
--   A text or web conversation: every active staff member, as with texts now
--   (0050): whoever picks up the phone sees what was said.
--
-- Presence: online, away or offline per staff member, from an open CRM
-- window, and nothing more - no last-seen time, no location, no keystrokes.
-- The row with the heartbeat's time is readable by its owner alone; everyone
-- else gets the word.
--
-- Retention: a conversation about a client is part of the client's record -
-- removed with it (on delete cascade; the retention module decides when, and
-- records it), and exported with it (records_request_bundle, below).

-- ── the tables ──────────────────────────────────────────────
create table if not exists public.conversations (
  id                uuid primary key default gen_random_uuid(),
  kind              text not null check (kind in ('sms', 'internal', 'web')),
  title             text not null default '',
  client_id         uuid references public.clients(id) on delete cascade,
  counselor_id      uuid references public.counselors(id) on delete set null,
  -- The other end of a text or web chat: a phone number or an address.
  external_address  text not null default '',
  assigned_staff_id uuid references public.staff(id) on delete set null,
  created_by        uuid references public.staff(id) on delete set null,
  created_at        timestamptz not null default now(),
  last_message_at   timestamptz,
  last_seq          bigint not null default 0,
  archived_at       timestamptz,
  archived_by       uuid references public.staff(id) on delete set null
);
create index if not exists conversations_client_idx on public.conversations (client_id) where client_id is not null;
create index if not exists conversations_recent_idx on public.conversations (last_message_at desc nulls last);

create table if not exists public.conversation_participants (
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  staff_id        uuid not null references public.staff(id) on delete cascade,
  joined_at       timestamptz not null default now(),
  left_at         timestamptz,
  added_by        uuid references public.staff(id) on delete set null,
  primary key (conversation_id, staff_id)
);
create index if not exists conversation_participants_staff_idx on public.conversation_participants (staff_id) where left_at is null;

create table if not exists public.messages (
  id              uuid primary key default gen_random_uuid(),
  seq             bigserial,
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  sender_kind     text not null check (sender_kind in ('staff', 'client', 'visitor', 'system')),
  sender_staff_id uuid references public.staff(id) on delete set null,
  -- The name as it was when sent, so a message still says who wrote it.
  sender_label    text not null default '',
  body            text not null default '',
  -- References, never copies (B): [{ "kind": "client_file" | "staff_file", "id": ..., "name": ... }]
  attachments     jsonb not null default '[]'::jsonb,
  status          text not null default 'sent'
                    check (status in ('queued', 'sent', 'delivered', 'received', 'failed', 'removed')),
  provider_message_id text,
  created_at      timestamptz not null default now(),
  edited_at       timestamptz,
  removed_at      timestamptz,
  check (sender_kind <> 'staff' or sender_staff_id is not null or status = 'removed'),
  check (jsonb_typeof(attachments) = 'array')
);
create index if not exists messages_conversation_idx on public.messages (conversation_id, seq desc);

create table if not exists public.read_receipts (
  conversation_id     uuid not null references public.conversations(id) on delete cascade,
  staff_id            uuid not null references public.staff(id) on delete cascade,
  last_read_seq       bigint not null default 0,
  read_at             timestamptz not null default now(),
  -- How far the unread-message email has already told them about.
  emailed_through_seq bigint not null default 0,
  primary key (conversation_id, staff_id)
);

create table if not exists public.staff_presence (
  staff_id  uuid primary key references public.staff(id) on delete cascade,
  state     text not null check (state in ('online', 'away')),
  last_seen timestamptz not null default now()
);

-- ── who is in it ────────────────────────────────────────────
-- Definer, so the conversation rule can ask without the participants rule
-- asking back.
create or replace function public.is_conversation_participant(p_conversation uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.conversation_participants
     where conversation_id = p_conversation
       and staff_id = public.current_staff_id()
       and left_at is null);
$$;

-- ── the rules ───────────────────────────────────────────────
alter table public.conversations enable row level security;
alter table public.conversation_participants enable row level security;
alter table public.messages enable row level security;
alter table public.read_receipts enable row level security;
alter table public.staff_presence enable row level security;

drop policy if exists conversations_read on public.conversations;
create policy conversations_read on public.conversations for select to authenticated
  using ((select public.is_active_staff())
         and (kind <> 'internal'
              or ((select public.is_admin()) and client_id is not null)
              or public.is_conversation_participant(id)));

drop policy if exists conversation_participants_read on public.conversation_participants;
create policy conversation_participants_read on public.conversation_participants for select to authenticated
  using ((select public.is_active_staff())
         and (staff_id = (select public.current_staff_id())
              or (select public.is_admin())
              or exists (select 1 from public.conversations c where c.id = conversation_id)));

-- A message is readable exactly when its conversation is.
drop policy if exists messages_read on public.messages;
create policy messages_read on public.messages for select to authenticated
  using (exists (select 1 from public.conversations c where c.id = conversation_id));

drop policy if exists read_receipts_read on public.read_receipts;
create policy read_receipts_read on public.read_receipts for select to authenticated
  using (exists (select 1 from public.conversations c where c.id = conversation_id));

drop policy if exists staff_presence_own on public.staff_presence;
create policy staff_presence_own on public.staff_presence for select to authenticated
  using (staff_id = (select public.current_staff_id()));

-- Nothing is written directly: every write is one of the functions below.
revoke all on public.conversations, public.conversation_participants, public.messages,
              public.read_receipts, public.staff_presence from anon;
revoke insert, update, delete, truncate on public.conversations, public.conversation_participants,
              public.messages, public.read_receipts, public.staff_presence from authenticated;
grant select on public.conversations, public.conversation_participants, public.messages,
               public.read_receipts, public.staff_presence to authenticated;
grant all on public.conversations, public.conversation_participants, public.messages,
             public.read_receipts, public.staff_presence to service_role;
grant usage on sequence public.messages_seq_seq to service_role;

-- ── starting a conversation between staff ───────────────────
-- A direct message: the one already open between the two, or a new one.
create or replace function public.start_direct_conversation(p_other uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_me   uuid := public.current_staff_id();
  v_conv uuid;
begin
  if v_me is null or not public.is_active_staff() then
    raise exception 'Only staff start a conversation.' using errcode = 'insufficient_privilege';
  end if;
  if p_other is null or p_other = v_me then
    raise exception 'Choose somebody else to message.' using errcode = 'check_violation';
  end if;
  if not exists (select 1 from public.staff where id = p_other and active) then
    raise exception 'That person is not an active member of staff.' using errcode = 'check_violation';
  end if;

  select c.id into v_conv
    from public.conversations c
   where c.kind = 'internal' and c.client_id is null and c.title = '' and c.archived_at is null
     and (select count(*) from public.conversation_participants p where p.conversation_id = c.id and p.left_at is null) = 2
     and exists (select 1 from public.conversation_participants p where p.conversation_id = c.id and p.staff_id = v_me and p.left_at is null)
     and exists (select 1 from public.conversation_participants p where p.conversation_id = c.id and p.staff_id = p_other and p.left_at is null)
   limit 1;
  if v_conv is not null then
    return v_conv;
  end if;

  insert into public.conversations (kind, created_by) values ('internal', v_me) returning id into v_conv;
  insert into public.conversation_participants (conversation_id, staff_id, added_by)
  values (v_conv, v_me, v_me), (v_conv, p_other, v_me);
  return v_conv;
end;
$$;

-- ── writing ─────────────────────────────────────────────────
-- A staff message in a staff conversation. Texts and web chats have their own
-- ways out (A and C), which carry their own gates - consent, quiet hours - so
-- they cannot be posted here.
create or replace function public.post_message(p_conversation uuid, p_body text, p_attachments jsonb default '[]'::jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_me   uuid := public.current_staff_id();
  v_name text;
  v_kind text;
  v_id   uuid;
  v_seq  bigint;
begin
  if v_me is null or not public.is_active_staff() then
    raise exception 'Only staff send messages.' using errcode = 'insufficient_privilege';
  end if;
  select kind into v_kind from public.conversations where id = p_conversation and archived_at is null;
  if v_kind is null then
    raise exception 'That conversation is not there, or has been archived.' using errcode = 'check_violation';
  end if;
  if v_kind <> 'internal' then
    raise exception 'A text or web chat is answered from its own screen, where its rules are checked.' using errcode = 'check_violation';
  end if;
  if not public.is_conversation_participant(p_conversation) then
    raise exception 'You are not in that conversation.' using errcode = 'insufficient_privilege';
  end if;
  if coalesce(btrim(p_body), '') = '' and coalesce(jsonb_array_length(p_attachments), 0) = 0 then
    raise exception 'The message is empty.' using errcode = 'check_violation';
  end if;
  if length(p_body) > 8000 then
    raise exception 'That message is too long - 8,000 characters at most.' using errcode = 'check_violation';
  end if;
  if coalesce(jsonb_array_length(p_attachments), 0) > 0 then
    -- Attaching is B's: a reference is checked against the recipient's access
    -- there. Until then, nothing is attached.
    raise exception 'Attachments come with staff chat.' using errcode = 'check_violation';
  end if;

  select name into v_name from public.staff where id = v_me;
  insert into public.messages (conversation_id, sender_kind, sender_staff_id, sender_label, body)
  values (p_conversation, 'staff', v_me, coalesce(v_name, ''), p_body)
  returning id, seq into v_id, v_seq;

  update public.conversations set last_message_at = now(), last_seq = v_seq where id = p_conversation;
  -- The sender has read their own message.
  insert into public.read_receipts (conversation_id, staff_id, last_read_seq, read_at)
  values (p_conversation, v_me, v_seq, now())
  on conflict (conversation_id, staff_id) do update
    set last_read_seq = greatest(public.read_receipts.last_read_seq, excluded.last_read_seq), read_at = now();
  return v_id;
end;
$$;

-- How far the person has read. Never backwards.
create or replace function public.mark_read(p_conversation uuid, p_seq bigint)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := public.current_staff_id();
begin
  if v_me is null or not public.is_active_staff() then
    raise exception 'Only staff read messages.' using errcode = 'insufficient_privilege';
  end if;
  -- Readable to them, or it is not theirs to mark.
  if not exists (
    select 1 from public.conversations c
     where c.id = p_conversation
       and (c.kind <> 'internal' or public.is_conversation_participant(c.id)
            or (public.is_admin() and c.client_id is not null))) then
    raise exception 'That conversation is not yours to read.' using errcode = 'insufficient_privilege';
  end if;
  insert into public.read_receipts (conversation_id, staff_id, last_read_seq, read_at)
  values (p_conversation, v_me, coalesce(p_seq, 0), now())
  on conflict (conversation_id, staff_id) do update
    set last_read_seq = greatest(public.read_receipts.last_read_seq, excluded.last_read_seq), read_at = now();
end;
$$;

-- ── unread, for the badge ───────────────────────────────────
-- Staff conversations the person is in; not the team's texts or web chats,
-- which have their own inbox counts (A, C).
create or replace function public.my_unread()
returns table (conversation_id uuid, unread integer)
language sql stable security definer set search_path = public as $$
  select p.conversation_id,
         (select count(*)::integer from public.messages m
           where m.conversation_id = p.conversation_id
             and m.seq > coalesce(r.last_read_seq, 0)
             and m.removed_at is null
             and m.sender_staff_id is distinct from public.current_staff_id())
    from public.conversation_participants p
    join public.conversations c on c.id = p.conversation_id and c.kind = 'internal' and c.archived_at is null
    left join public.read_receipts r on r.conversation_id = p.conversation_id and r.staff_id = p.staff_id
   where p.staff_id = public.current_staff_id() and p.left_at is null and public.is_active_staff();
$$;

-- ── presence ────────────────────────────────────────────────
-- A heartbeat from an open CRM window, about once a minute: online, or away
-- when there has been no input for five minutes. Only the state and the time
-- are kept, and only the owner can see the time.
create or replace function public.presence_heartbeat(p_state text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := public.current_staff_id();
begin
  if v_me is null or not public.is_active_staff() then
    return;
  end if;
  if p_state not in ('online', 'away') then
    raise exception 'Presence is online or away.' using errcode = 'check_violation';
  end if;
  insert into public.staff_presence (staff_id, state, last_seen) values (v_me, p_state, now())
  on conflict (staff_id) do update set state = excluded.state, last_seen = now();
end;
$$;

-- Everybody's presence, as one word each. No window has beaten in three
-- minutes: offline.
create or replace function public.staff_presence_status()
returns table (staff_id uuid, status text)
language sql stable security definer set search_path = public as $$
  select s.id,
         case when p.last_seen > now() - interval '3 minutes' then p.state else 'offline' end
    from public.staff s
    left join public.staff_presence p on p.staff_id = s.id
   where s.active and public.is_active_staff();
$$;

-- ── the unread-message email, for those who ask for it ──────
-- Somebody away (or offline) for thirty minutes with a staff message waiting
-- more than thirty minutes, who has asked for the email (staff_prefs
-- messages:email_digest), and has not already been told about it. Counts and
-- conversation names only: a message's text never goes by email. For the
-- cron route, as the service role.
create or replace function public.messages_digest_due()
returns table (staff_id uuid, email text, name text, conversation_id uuid, conversation_label text, unread integer, through_seq bigint)
language sql stable security definer set search_path = public as $$
  select s.id, s.email, s.name, c.id,
         case
           when c.title <> '' then c.title
           when c.client_id is not null then 'About ' || coalesce((select cl.name from public.clients cl where cl.id = c.client_id), 'a client')
           else 'From ' || coalesce((select string_agg(o.name, ', ') from public.conversation_participants op
                                       join public.staff o on o.id = op.staff_id
                                      where op.conversation_id = c.id and op.staff_id <> s.id and op.left_at is null), 'a colleague')
         end,
         (select count(*)::integer from public.messages m
           where m.conversation_id = c.id and m.seq > greatest(coalesce(r.last_read_seq, 0), coalesce(r.emailed_through_seq, 0))
             and m.removed_at is null and m.sender_staff_id is distinct from s.id),
         c.last_seq
    from public.staff s
    join public.staff_prefs pref on pref.staff_id = s.id and pref.key = 'messages:email_digest' and pref.value = 'true'::jsonb
    join public.conversation_participants p on p.staff_id = s.id and p.left_at is null
    join public.conversations c on c.id = p.conversation_id and c.kind = 'internal' and c.archived_at is null
    left join public.read_receipts r on r.conversation_id = c.id and r.staff_id = s.id
    left join public.staff_presence pr on pr.staff_id = s.id
   where s.active and s.email is not null
     and (pr.last_seen is null or pr.last_seen < now() - interval '30 minutes' or pr.state = 'away')
     and exists (select 1 from public.messages m
                  where m.conversation_id = c.id
                    and m.seq > greatest(coalesce(r.last_read_seq, 0), coalesce(r.emailed_through_seq, 0))
                    and m.removed_at is null and m.sender_staff_id is distinct from s.id
                    and m.created_at < now() - interval '30 minutes');
$$;

create or replace function public.messages_digest_sent(p_staff uuid, p_conversation uuid, p_through bigint)
returns void language sql security definer set search_path = public as $$
  insert into public.read_receipts (conversation_id, staff_id, emailed_through_seq)
  values (p_conversation, p_staff, p_through)
  on conflict (conversation_id, staff_id) do update
    set emailed_through_seq = greatest(public.read_receipts.emailed_through_seq, excluded.emailed_through_seq);
$$;

-- ── live delivery ───────────────────────────────────────────
-- Supabase Realtime sends each change only to those whose rules above let
-- them read the row.
do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'messages') then
    alter publication supabase_realtime add table public.messages;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'conversations') then
    alter publication supabase_realtime add table public.conversations;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'read_receipts') then
    alter publication supabase_realtime add table public.read_receipts;
  end if;
end $$;

-- ── function access ─────────────────────────────────────────
revoke execute on function public.is_conversation_participant(uuid) from public, anon;
revoke execute on function public.start_direct_conversation(uuid) from public, anon;
revoke execute on function public.post_message(uuid, text, jsonb) from public, anon;
revoke execute on function public.mark_read(uuid, bigint) from public, anon;
revoke execute on function public.my_unread() from public, anon;
revoke execute on function public.presence_heartbeat(text) from public, anon;
revoke execute on function public.staff_presence_status() from public, anon;
revoke execute on function public.messages_digest_due() from public, anon, authenticated;
revoke execute on function public.messages_digest_sent(uuid, uuid, bigint) from public, anon, authenticated;
grant execute on function public.is_conversation_participant(uuid) to authenticated, service_role;
grant execute on function public.start_direct_conversation(uuid) to authenticated;
grant execute on function public.post_message(uuid, text, jsonb) to authenticated;
grant execute on function public.mark_read(uuid, bigint) to authenticated;
grant execute on function public.my_unread() to authenticated;
grant execute on function public.presence_heartbeat(text) to authenticated;
grant execute on function public.staff_presence_status() to authenticated;
grant execute on function public.messages_digest_due() to service_role;
grant execute on function public.messages_digest_sent(uuid, uuid, bigint) to service_role;

-- ── exported with the client (records request) ──────────────
-- records_request_bundle as it stood (0070), with the client's conversations added.
-- records_request_bundle(uuid,text)
CREATE OR REPLACE FUNCTION public.records_request_bundle(p_client uuid, p_purpose text DEFAULT 'Records request'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'vault', 'extensions'
AS $function$
declare
  v_out    jsonb;
  v_client jsonb;
begin
  if not public.is_admin() then
    raise exception 'Only Admin produces a records request.'
      using errcode = 'insufficient_privilege';
  end if;

  select to_jsonb(c) - 'legacy_id' - 'ghl_id' - 'import_review'
    into v_client
    from public.clients c where c.id = p_client;

  if v_client is null then
    raise exception 'That client does not exist.' using errcode = 'no_data_found';
  end if;

  perform public.log_access('Records request', p_client, null, p_purpose);

  select jsonb_build_object(
    'produced_at', now(),
    'client', v_client,

    'restricted_details', (
      select to_jsonb(p) from public.client_private p where p.client_id = p_client
    ),

    'intake', (
      select to_jsonb(i) - 'id' from public.intakes i where i.client_id = p_client
    ),

    'stage_history', (
      select coalesce(jsonb_agg(to_jsonb(h) - 'id' order by h.at), '[]'::jsonb)
        from public.client_stage_history h where h.client_id = p_client
    ),

    'notes', (
      select coalesce(jsonb_agg(to_jsonb(n) - 'id' - 'legacy_id' order by n.ts), '[]'::jsonb)
        from public.notes n where n.client_id = p_client
    ),

    'counselor_contacts', (
      select coalesce(jsonb_agg(to_jsonb(cl) - 'id' - 'legacy_id' order by cl.date), '[]'::jsonb)
        from public.contact_log cl where cl.client_id = p_client
    ),

    'tasks', (
      select coalesce(jsonb_agg(to_jsonb(t) - 'id' - 'legacy_id' order by t.created_at), '[]'::jsonb)
        from public.tasks t where t.client_id = p_client
    ),

    'authorizations', (
      select coalesce(jsonb_agg(to_jsonb(a) - 'legacy_id' order by a.start_date), '[]'::jsonb)
        from public.authorizations a where a.client_id = p_client
    ),

    'invoices', (
      select coalesce(jsonb_agg(to_jsonb(inv) - 'legacy_id' order by inv.date), '[]'::jsonb)
        from public.invoices inv
        join public.authorizations a on a.id = inv.auth_id
       where a.client_id = p_client
    ),

    'service_hours', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'worked_on', w.worked_on, 'hours', w.hours,
               'description', w.description, 'category', w.category,
               'voided', w.voided) order by w.worked_on), '[]'::jsonb)
        from public.work_sessions w where w.client_id = p_client
    ),

    'forms', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'template_id', f.template_id, 'month', f.month, 'status', f.status,
               'completed_at', f.completed_at, 'sent_at', f.sent_at, 'sent_to', f.sent_to,
               'data', f.data) order by f.created_at), '[]'::jsonb)
        from public.forms f where f.client_id = p_client
    ),

    'placements', (
      select coalesce(jsonb_agg(to_jsonb(pl) - 'id' - 'legacy_id' order by pl.start_date), '[]'::jsonb)
        from public.placements pl where pl.client_id = p_client
    ),

    'jobs_applied_for', (
      select coalesce(jsonb_agg(to_jsonb(m) - 'id' order by m.created_at), '[]'::jsonb)
        from public.lead_matches m where m.client_id = p_client
    ),

    'appointments', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'kind', e.kind, 'title', e.title, 'starts_at', e.starts_at,
               'ends_at', e.ends_at, 'location', e.location, 'note', e.note)
               order by e.starts_at), '[]'::jsonb)
        from public.calendar_events e where e.client_id = p_client
    ),

    'texts', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'direction', m.direction, 'phone', m.phone, 'body', m.body,
               'kind', m.kind, 'status', m.status,
               'at', coalesce(m.sent_at, m.created_at)) order by m.created_at), '[]'::jsonb)
        from public.sms_messages m where m.client_id = p_client
    ),

    'texting_consent', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'state', ev.state, 'method', ev.method, 'note', ev.note, 'at', ev.at)
               order by ev.seq), '[]'::jsonb)
        from public.sms_consent_events ev where ev.client_id = p_client
    ),

    'email', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'subject', ml.subject, 'direction', ml.direction,
               'counterpart', ml.counterpart_email, 'sent_at', ml.sent_at)
               order by ml.sent_at), '[]'::jsonb)
        from public.mail_log ml where ml.client_id = p_client
    ),

    -- Conversations about the client (0104): texts, web chats and staff
    -- threads about them, every message, removed ones as the marker they left.
    'conversations', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'kind', cv.kind, 'title', cv.title, 'started', cv.created_at,
               'messages', (select coalesce(jsonb_agg(jsonb_build_object(
                                 'from', case msg.sender_kind when 'staff' then msg.sender_label else msg.sender_kind end,
                                 'at', msg.created_at,
                                 'text', case when msg.removed_at is null then msg.body else '(message removed)' end)
                               order by msg.seq), '[]'::jsonb)
                          from public.messages msg where msg.conversation_id = cv.id))
               order by cv.created_at), '[]'::jsonb)
        from public.conversations cv where cv.client_id = p_client
    ),

    'files', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'filename', at2.filename, 'category', at2.category,
               'note', at2.note, 'size_bytes', at2.size_bytes,
               'restricted', at2.restricted, 'added', at2.created_at)
               order by at2.created_at), '[]'::jsonb)
        from public.attachments at2 where at2.client_id = p_client
    ),

    'who_read_this_record', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'at', l.at, 'who', l.staff_name, 'role', l.staff_role,
               'what', l.subject, 'why', l.purpose) order by l.at), '[]'::jsonb)
        from public.access_log l where l.client_id = p_client
    ),

    -- Who can sign in to the portal for this person, including guardians.
    'portal_access', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'kind', pa.kind, 'name', pa.name, 'relationship', pa.relationship,
               'phone', pa.phone, 'email', pa.email,
               'given_by', pa.invited_by_name, 'given_at', pa.invited_at,
               'first_signed_in_at', pa.first_signed_in_at, 'last_signed_in_at', pa.last_signed_in_at,
               'turned_off_at', pa.disabled_at, 'turned_off_because', pa.disabled_reason)
               order by pa.invited_at), '[]'::jsonb)
        from public.portal_accounts pa where pa.client_id = p_client
    ),

    -- Every consent choice, in the order made, with what it was made against.
    'portal_consent', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'kind', pc.kind, 'given', pc.given, 'at', pc.at,
               'terms_version', pc.terms_version, 'by', pc.actor_name,
               'acting_as', pc.acting_as, 'ip', pc.ip, 'browser', pc.user_agent)
               order by pc.seq), '[]'::jsonb)
        from public.portal_consents pc where pc.client_id = p_client
    ),

    'portal_activity', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'at', pv.at, 'what', pv.action, 'detail', pv.detail,
               'by', pv.actor_name, 'acting_as', pv.acting_as)
               order by pv.seq), '[]'::jsonb)
        from public.portal_activity pv where pv.client_id = p_client
    )
  ) into v_out;

  return v_out;
end;
$function$;
