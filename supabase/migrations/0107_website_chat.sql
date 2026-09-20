-- Zion Vocational Rehab CRM — the website chat (Messaging brief, C)
--
-- Somebody on zionrehabcenter.com with a question. A bubble opens, they give
-- a name and a way to reach them, and what they say arrives in the same inbox
-- the texts do - because the person answering should not have to remember
-- which door somebody came through.
--
-- What this adds, and what it deliberately does not:
--
--   The visitor is not signed in and never will be. Nothing they touch goes
--   through the row rules: every one of their calls is made by the server
--   with the service role, through the four functions below, and each one is
--   handed only the conversation their token opens. There is no anonymous
--   read of any table.
--
--   Live, or a contact form. If the bubble is on, inside its hours, and
--   somebody who takes web chats is online, the conversation goes to them -
--   the one with the least on, so it is shared out rather than always landing
--   on the same person. If nobody is online it is still kept: it sits in the
--   inbox unmatched, a task is raised, and the visitor is told when to expect
--   an answer rather than being left to wonder.
--
--   Whoever they already are. A number or an address the practice already has
--   attaches the conversation to that client's record, so it is on their
--   Activity like anything else. Otherwise it waits to be matched, made into
--   a referral, or marked spam - the same three ways out an unknown number
--   has had since 0105.
--
--   Consent is kept with the conversation: the exact line they were shown and
--   the moment they agreed to it, and it is said again in the thread, so
--   somebody reading it later sees what was agreed without going looking.
--
--   Arriving by chat is not consent to be texted. That gate is untouched.
--
-- The inbox is no longer only texts, so the five functions behind it lose
-- "text" from their names. Same rules, same roles, two kinds of conversation.

-- ── what the practice has decided about the bubble ──────────
alter table public.org_settings
  add column if not exists web_chat_enabled boolean not null default false,
  -- Empty means anybody active who is online. A list means those people.
  add column if not exists web_chat_takers uuid[] not null default '{}'::uuid[],
  add column if not exists web_chat_open time not null default '09:00',
  add column if not exists web_chat_close time not null default '17:00',
  -- 1 = Monday … 7 = Sunday, as ISO counts them.
  add column if not exists web_chat_days integer[] not null default '{1,2,3,4,5}'::integer[],
  add column if not exists web_chat_promise text not null default 'by the end of the next business day',
  add column if not exists web_chat_greeting text not null default 'Hello. Ask us anything about vocational rehabilitation services, and somebody here will answer.';

-- org_settings has column-level grants, because 0022 held the EIN back from
-- everybody. The moment one column is revoked Postgres stops granting the
-- table and starts granting the columns, so a column added afterwards is
-- readable by nobody - and PostgREST's refusal arrives as an empty row, which
-- looks exactly like a setting nobody has filled in yet. Every new column on
-- this table has to say this line. The EIN stays where 0022 put it.
grant select (web_chat_enabled, web_chat_takers, web_chat_open, web_chat_close,
              web_chat_days, web_chat_promise, web_chat_greeting)
  on public.org_settings to authenticated;

-- ── the visitor, and what they agreed to ────────────────────
create table if not exists public.web_chats (
  conversation_id uuid primary key references public.conversations(id) on delete cascade,
  visitor_name    text not null,
  -- What they gave: a phone number (normalised) or an email address.
  contact         text not null,
  contact_kind    text not null check (contact_kind in ('phone', 'email')),
  -- The line they were shown, word for word, and when they agreed to it.
  consent_text    text not null,
  consent_at      timestamptz not null default now(),
  -- Not the address itself: enough to stop one machine opening a hundred
  -- conversations, and nothing that says where anybody was.
  ip_hash         text not null default '',
  created_at      timestamptz not null default now()
);
create index if not exists web_chats_ip_idx on public.web_chats (ip_hash, created_at desc);

-- The token in the visitor's tab, hashed. It opens one conversation and
-- nothing else, and it stops working after a day.
create table if not exists public.web_chat_sessions (
  token_hash      text primary key,
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  created_at      timestamptz not null default now(),
  expires_at      timestamptz not null default now() + interval '24 hours'
);

alter table public.web_chats enable row level security;
alter table public.web_chat_sessions enable row level security;

-- Staff read the visitor's details exactly when they can read the
-- conversation (0104: a web conversation is the team's).
drop policy if exists web_chats_read on public.web_chats;
create policy web_chats_read on public.web_chats for select to authenticated
  using (exists (select 1 from public.conversations c where c.id = conversation_id));

-- Nobody reads the sessions table but the server. Not staff either: a token
-- is a key, and a key is not something to have lying about on a screen.
revoke all on public.web_chats, public.web_chat_sessions from anon, authenticated;
grant select on public.web_chats to authenticated;
grant all on public.web_chats, public.web_chat_sessions to service_role;

-- ── is the bubble live right now ────────────────────────────
-- practice_today's companion: the clock where the practice is, not where the
-- server is. "Live until five" has to mean five in Utah.
create or replace function public.practice_now()
returns timestamp language sql stable as $$
  select (now() at time zone 'America/Denver');
$$;

/** Somebody who takes web chats, online, inside the hours the practice set. */
create or replace function public.web_chat_takers_online()
returns setof uuid language sql stable security definer set search_path = public as $$
  select s.id
    from public.staff s
    join public.staff_presence p on p.staff_id = s.id
    cross join public.org_settings o
   where s.active
     and p.state = 'online' and p.last_seen > now() - interval '3 minutes'
     and (cardinality(o.web_chat_takers) = 0 or s.id = any (o.web_chat_takers));
$$;

create or replace function public.web_chat_live()
returns boolean language sql stable security definer set search_path = public as $$
  select o.web_chat_enabled
     and extract(isodow from public.practice_now())::integer = any (o.web_chat_days)
     and public.practice_now()::time between o.web_chat_open and o.web_chat_close
     and exists (select 1 from public.web_chat_takers_online())
    from public.org_settings o;
$$;

/** What the widget needs before anybody has typed anything. */
create or replace function public.web_chat_config()
returns table (enabled boolean, live boolean, greeting text, promise text)
language sql stable security definer set search_path = public as $$
  select o.web_chat_enabled, public.web_chat_live(), o.web_chat_greeting, o.web_chat_promise
    from public.org_settings o;
$$;

-- ── starting one ────────────────────────────────────────────
/**
 * A visitor says who they are. Called by the server, never by a browser.
 *
 * Returns the conversation, whether anybody is there, and what to tell them
 * if nobody is.
 */
create or replace function public.start_web_chat(
  p_name text, p_contact text, p_consent text, p_token_hash text, p_ip_hash text default ''
)
returns table (conversation_id uuid, live boolean, promise text, assigned_name text)
language plpgsql security definer set search_path = public as $$
declare
  v_name    text := btrim(coalesce(p_name, ''));
  v_raw     text := btrim(coalesce(p_contact, ''));
  v_kind    text;
  v_contact text;
  v_client  uuid;
  v_taker   uuid;
  v_conv    uuid;
  v_live    boolean;
  v_promise text;
  v_seq     bigint;
begin
  if not (select web_chat_enabled from public.org_settings) then
    raise exception 'The website chat is switched off.' using errcode = 'check_violation';
  end if;
  if v_name = '' or length(v_name) > 80 then
    raise exception 'Please give us your name.' using errcode = 'check_violation';
  end if;
  if v_raw = '' or length(v_raw) > 120 then
    raise exception 'Please give us a phone number or an email address.' using errcode = 'check_violation';
  end if;
  if coalesce(btrim(p_consent), '') = '' then
    raise exception 'The notice somebody agreed to has to be recorded with what they said.' using errcode = 'check_violation';
  end if;

  if position('@' in v_raw) > 1 then
    v_kind := 'email';
    v_contact := lower(v_raw);
  else
    v_kind := 'phone';
    v_contact := public.normalize_phone(v_raw);
    if v_contact is null or length(v_contact) < 10 then
      raise exception 'That does not look like a phone number or an email address.' using errcode = 'check_violation';
    end if;
  end if;

  -- One machine, a handful of conversations an hour. Past that it is not a
  -- person with a question.
  if p_ip_hash <> '' and (
       select count(*) from public.web_chats
        where ip_hash = p_ip_hash and created_at > now() - interval '1 hour') >= 5 then
    raise exception 'Too many chats have been started from here. Please call us instead.' using errcode = 'check_violation';
  end if;

  -- Somebody the practice already knows.
  if v_kind = 'email' then
    select id into v_client from public.clients where lower(email) = v_contact and status <> 'Closed' order by created_at limit 1;
  else
    select id into v_client from public.clients where public.normalize_phone(phone) = v_contact and status <> 'Closed' order by created_at limit 1;
  end if;

  select public.web_chat_live() into v_live;
  if v_live then
    -- Round robin by load: whoever has the least open web chats takes it.
    select t into v_taker from public.web_chat_takers_online() t
     order by (select count(*) from public.conversations c
                where c.kind = 'web' and c.assigned_staff_id = t and not c.spam
                  and c.archived_at is null), random()
     limit 1;
  end if;

  insert into public.conversations (kind, client_id, external_address, assigned_staff_id, last_message_at)
  values ('web', v_client, v_contact, v_taker, now())
  returning id into v_conv;

  insert into public.web_chats (conversation_id, visitor_name, contact, contact_kind, consent_text, ip_hash)
  values (v_conv, v_name, v_contact, v_kind, btrim(p_consent), coalesce(p_ip_hash, ''));

  insert into public.web_chat_sessions (token_hash, conversation_id) values (p_token_hash, v_conv);

  -- Said in the thread as well as kept in the row, so whoever reads it later
  -- sees what was agreed without having to go and look.
  insert into public.messages (conversation_id, sender_kind, sender_label, body)
  values (v_conv, 'system', 'Website',
          v_name || ' started a chat on the website and agreed: "' || btrim(p_consent) || '"')
  returning seq into v_seq;
  update public.conversations set last_seq = v_seq where id = v_conv;

  select web_chat_promise into v_promise from public.org_settings;

  -- Nobody there: it is a contact form, and somebody has to answer it.
  if not v_live then
    insert into public.tasks (client_id, title, assigned_staff_id, status, due, system_generated)
    values (v_client,
            'Website chat - answer ' || v_name || ' (' || v_contact || ')',
            (select t from unnest((select web_chat_takers from public.org_settings)) t limit 1),
            'Open', public.practice_today(), true);
  end if;

  return query select v_conv, v_live, v_promise, (select name from public.staff where id = v_taker);
end;
$$;

/** What the visitor typed. Called by the server, for one conversation. */
create or replace function public.post_visitor_message(p_conversation uuid, p_body text)
returns bigint language plpgsql security definer set search_path = public as $$
declare
  v_seq  bigint;
  v_name text;
begin
  select visitor_name into v_name from public.web_chats where conversation_id = p_conversation;
  if v_name is null then
    raise exception 'That is not a website chat.' using errcode = 'no_data_found';
  end if;
  if coalesce(btrim(p_body), '') = '' or length(p_body) > 2000 then
    raise exception 'A message is between one and two thousand characters.' using errcode = 'check_violation';
  end if;
  if (select count(*) from public.messages where conversation_id = p_conversation and sender_kind = 'visitor') >= 100 then
    raise exception 'This chat has gone on long enough for a phone call. Please ring us.' using errcode = 'check_violation';
  end if;

  insert into public.messages (conversation_id, sender_kind, sender_label, body, status)
  values (p_conversation, 'visitor', v_name, btrim(p_body), 'received')
  returning seq into v_seq;
  update public.conversations set last_message_at = now(), last_seq = v_seq where id = p_conversation;
  return v_seq;
end;
$$;

/** What the visitor's own tab reads back: their conversation, nothing else. */
create or replace function public.web_chat_thread(p_conversation uuid, p_since bigint default 0)
returns table (seq bigint, who text, sender_label text, body text, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select m.seq,
         case m.sender_kind when 'visitor' then 'you' when 'staff' then 'them' else 'system' end,
         case m.sender_kind when 'staff' then split_part(m.sender_label, ' ', 1) else m.sender_label end,
         case when m.removed_at is null then m.body else '' end,
         m.created_at
    from public.messages m
    join public.conversations c on c.id = m.conversation_id and c.kind = 'web'
   where m.conversation_id = p_conversation
     and m.seq > coalesce(p_since, 0)
     and m.removed_at is null
   order by m.seq;
$$;

/** The session a token opens, if it is still open. */
create or replace function public.web_chat_session(p_token_hash text)
returns uuid language sql stable security definer set search_path = public as $$
  select conversation_id from public.web_chat_sessions
   where token_hash = p_token_hash and expires_at > now();
$$;

/** Answering a visitor, from the inbox. */
create or replace function public.post_web_reply(p_conversation uuid, p_body text)
returns bigint language plpgsql security definer set search_path = public as $$
declare
  v_me   uuid := public.current_staff_id();
  v_name text;
  v_seq  bigint;
begin
  if (select public.current_staff_role()) not in ('Admin', 'Job Search', 'Reports') then
    raise exception 'Your role does not answer the website chat.' using errcode = 'insufficient_privilege';
  end if;
  if not exists (select 1 from public.conversations where id = p_conversation and kind = 'web' and archived_at is null) then
    raise exception 'That is not an open website chat.' using errcode = 'check_violation';
  end if;
  if coalesce(btrim(p_body), '') = '' or length(p_body) > 2000 then
    raise exception 'A reply is between one and two thousand characters.' using errcode = 'check_violation';
  end if;

  select name into v_name from public.staff where id = v_me;
  insert into public.messages (conversation_id, sender_kind, sender_staff_id, sender_label, body)
  values (p_conversation, 'staff', v_me, coalesce(v_name, ''), btrim(p_body))
  returning seq into v_seq;
  update public.conversations
     set last_message_at = now(), last_seq = v_seq,
         -- Whoever answers first is looking after it.
         assigned_staff_id = coalesce(assigned_staff_id, v_me)
   where id = p_conversation;
  insert into public.read_receipts (conversation_id, staff_id, last_read_seq, read_at)
  values (p_conversation, v_me, v_seq, now())
  on conflict (conversation_id, staff_id) do update
    set last_read_seq = greatest(public.read_receipts.last_read_seq, excluded.last_read_seq), read_at = now();
  return v_seq;
end;
$$;

-- ── the inbox is no longer only texts ───────────────────────
-- Same rules and the same three ways out of an unmatched conversation; it now
-- holds both kinds, and says which each one is.
create or replace function public.message_inbox(p_show text default 'open')
returns table (
  conversation_id uuid, kind text, client_id uuid, client_name text, who text,
  assigned_staff_id uuid, assigned_name text, last_message_at timestamptz,
  last_body text, unread integer, unmatched boolean, spam boolean, can_text boolean
)
language sql stable security definer set search_path = public as $$
  select c.id, c.kind, c.client_id, cl.name,
         coalesce(w.visitor_name || ' · ' || c.external_address, c.external_address),
         c.assigned_staff_id, st.name, c.last_message_at,
         (select m.body from public.messages m where m.conversation_id = c.id order by m.seq desc limit 1),
         (select count(*)::integer from public.messages m
           left join public.read_receipts r on r.conversation_id = c.id and r.staff_id = public.current_staff_id()
          where m.conversation_id = c.id and m.seq > coalesce(r.last_read_seq, 0)
            and m.sender_kind in ('client', 'visitor')),
         c.client_id is null, c.spam,
         coalesce((select can_text from public.client_sms_consent v where v.client_id = c.client_id), false)
    from public.conversations c
    left join public.clients cl on cl.id = c.client_id
    left join public.staff st on st.id = c.assigned_staff_id
    left join public.web_chats w on w.conversation_id = c.id
   where c.kind in ('sms', 'web')
     and public.is_active_staff()
     and case p_show
           when 'spam' then c.spam
           when 'mine' then not c.spam and c.assigned_staff_id = public.current_staff_id()
           when 'unmatched' then not c.spam and c.client_id is null
           when 'web' then not c.spam and c.kind = 'web'
           when 'texts' then not c.spam and c.kind = 'sms'
           else not c.spam
         end
   order by c.last_message_at desc nulls last;
$$;

create or replace function public.assign_conversation(p_conversation uuid, p_staff uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if (select public.current_staff_role()) not in ('Admin', 'Job Search', 'Reports') then
    raise exception 'Your role does not work the inbox.' using errcode = 'insufficient_privilege';
  end if;
  if p_staff is not null and not exists (select 1 from public.staff where id = p_staff and active) then
    raise exception 'That person is not active staff.' using errcode = 'check_violation';
  end if;
  update public.conversations set assigned_staff_id = p_staff
   where id = p_conversation and kind in ('sms', 'web');
end;
$$;

/** Whose it is, after all: the thread and its texts join their record. */
create or replace function public.match_conversation(p_conversation uuid, p_client uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_who  text;
  v_kind text;
begin
  if (select public.current_staff_role()) not in ('Admin', 'Job Search', 'Reports') then
    raise exception 'Your role does not work the inbox.' using errcode = 'insufficient_privilege';
  end if;
  select external_address, kind into v_who, v_kind
    from public.conversations where id = p_conversation and kind in ('sms', 'web') and client_id is null;
  if v_who is null then
    raise exception 'That conversation is not an unmatched one.' using errcode = 'check_violation';
  end if;
  if not exists (select 1 from public.clients where id = p_client) then
    raise exception 'That client is not on file.' using errcode = 'check_violation';
  end if;
  update public.conversations set client_id = p_client, spam = false where id = p_conversation;
  -- Only a text has texts of its own to move; a web chat is already where it
  -- lives, and attaching it puts it on the client's Activity.
  if v_kind = 'sms' then
    update public.sms_messages set client_id = p_client
     where client_id is null and public.normalize_phone(phone) = v_who;
  end if;
end;
$$;

/** A new person, arriving: a referral, with what they said already on it. */
create or replace function public.referral_from_conversation(p_conversation uuid, p_name text)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_who    text;
  v_kind   text;
  v_email  text;
  v_phone  text;
  v_client uuid;
  v_me     uuid := public.current_staff_id();
begin
  if (select public.current_staff_role()) not in ('Admin', 'Job Search', 'Reports') then
    raise exception 'Your role does not take referrals.' using errcode = 'insufficient_privilege';
  end if;
  if coalesce(btrim(p_name), '') = '' then
    raise exception 'A referral needs a name.' using errcode = 'check_violation';
  end if;
  select c.external_address, c.kind into v_who, v_kind
    from public.conversations c where c.id = p_conversation and c.kind in ('sms', 'web') and c.client_id is null;
  if v_who is null then
    raise exception 'That conversation is already somebody''s.' using errcode = 'check_violation';
  end if;

  if (select contact_kind from public.web_chats where conversation_id = p_conversation) = 'email' then
    v_email := v_who;
  else
    v_phone := v_who;
  end if;

  insert into public.clients (name, phone, email, stage, status, assigned_staff_id)
  values (btrim(p_name), coalesce(v_phone, ''), coalesce(v_email, ''), 'Referral', 'Active', v_me)
  returning id into v_client;

  -- Writing to them still needs their consent: arriving is not it.
  perform public.match_conversation(p_conversation, v_client);
  insert into public.tasks (client_id, title, assigned_staff_id, status, due)
  values (v_client,
          case when v_kind = 'web' then 'Intake call - asked on the website' else 'Intake call - texted in' end,
          v_me, 'Open', public.practice_today() + 1);
  return v_client;
end;
$$;

/** Not somebody we deal with. Kept, not deleted; a mistake here is undoable. */
create or replace function public.mark_conversation_spam(p_conversation uuid, p_spam boolean default true)
returns void language plpgsql security definer set search_path = public as $$
begin
  if (select public.current_staff_role()) not in ('Admin', 'Job Search', 'Reports') then
    raise exception 'Your role does not work the inbox.' using errcode = 'insufficient_privilege';
  end if;
  update public.conversations set spam = coalesce(p_spam, true)
   where id = p_conversation and kind in ('sms', 'web') and client_id is null;
  if not found then
    raise exception 'Only an unmatched conversation is marked spam.' using errcode = 'check_violation';
  end if;
end;
$$;

-- The old names went with the old shape of the screen.
drop function if exists public.texts_inbox(text);
drop function if exists public.assign_text_conversation(uuid, uuid);
drop function if exists public.match_text_conversation(uuid, uuid);
drop function if exists public.referral_from_text(uuid, text);
drop function if exists public.mark_text_spam(uuid, boolean);

-- ── who may call what ───────────────────────────────────────
-- The visitor's four functions are the server's alone. An anonymous caller
-- has no way in: not to these, and not to any table.
revoke execute on function public.practice_now() from public, anon;
grant execute on function public.practice_now() to authenticated, service_role;
revoke execute on function public.web_chat_takers_online() from public, anon, authenticated;
revoke execute on function public.start_web_chat(text, text, text, text, text) from public, anon, authenticated;
revoke execute on function public.post_visitor_message(uuid, text) from public, anon, authenticated;
revoke execute on function public.web_chat_thread(uuid, bigint) from public, anon, authenticated;
revoke execute on function public.web_chat_session(text) from public, anon, authenticated;
revoke execute on function public.web_chat_config() from public, anon, authenticated;
revoke execute on function public.web_chat_live() from public, anon;
revoke execute on function public.post_web_reply(uuid, text) from public, anon;
revoke execute on function public.message_inbox(text) from public, anon;
revoke execute on function public.assign_conversation(uuid, uuid) from public, anon;
revoke execute on function public.match_conversation(uuid, uuid) from public, anon;
revoke execute on function public.referral_from_conversation(uuid, text) from public, anon;
revoke execute on function public.mark_conversation_spam(uuid, boolean) from public, anon;

grant execute on function public.web_chat_takers_online() to service_role;
grant execute on function public.start_web_chat(text, text, text, text, text) to service_role;
grant execute on function public.post_visitor_message(uuid, text) to service_role;
grant execute on function public.web_chat_thread(uuid, bigint) to service_role;
grant execute on function public.web_chat_session(text) to service_role;
grant execute on function public.web_chat_config() to service_role;
grant execute on function public.web_chat_live() to authenticated, service_role;
grant execute on function public.post_web_reply(uuid, text) to authenticated;
grant execute on function public.message_inbox(text) to authenticated;
grant execute on function public.assign_conversation(uuid, uuid) to authenticated;
grant execute on function public.match_conversation(uuid, uuid) to authenticated;
grant execute on function public.referral_from_conversation(uuid, text) to authenticated;
grant execute on function public.mark_conversation_spam(uuid, boolean) to authenticated;

-- ── a website chat, on the client's Activity ────────────────
-- A chat that turned out to be somebody already on file is part of what has
-- happened to them, like a text or a logged email. Restated in full, as 0034,
-- 0050, 0081, 0083 and 0106 did before it: this view is the one definition of
-- what has happened to a client.
create or replace view public.client_activity as
select * from (SELECT n.client_id,
            COALESCE(n.at::timestamp with time zone, n.created_at) AS at,
            'Note'::text AS kind,
            n.type AS title,
            n.text AS detail,
            n.staff_name AS who,
            'notes'::text AS tab,
            n.id AS ref_id
           FROM notes n
        UNION ALL
         SELECT h.client_id,
            COALESCE(h.at::timestamp with time zone, h.created_at) AS "coalesce",
            'Stage'::text AS text,
            'Moved to '::text || h.stage,
            ''::text AS text,
            s.name,
            'overview'::text AS text,
            h.id
           FROM client_stage_history h
             LEFT JOIN staff s ON s.id = h.staff_id
        UNION ALL
         SELECT m.client_id,
            m.applied_on::timestamp with time zone AS applied_on,
            'Job'::text AS text,
            'Applied — '::text || COALESCE(e.name, l.title, 'a job'::text),
            COALESCE(l.title, ''::text) AS "coalesce",
            s.name,
            'overview'::text AS text,
            m.id
           FROM lead_matches m
             JOIN job_leads l ON l.id = m.lead_id
             LEFT JOIN employers e ON e.id = l.employer_id
             LEFT JOIN staff s ON s.id = m.created_by
          WHERE m.applied_on IS NOT NULL
        UNION ALL
         SELECT m.client_id,
            m.interview_on::timestamp with time zone AS interview_on,
            'Interview'::text AS text,
            'Interview — '::text || COALESCE(e.name, l.title, 'a job'::text),
            COALESCE(l.title, ''::text) AS "coalesce",
            s.name,
            'overview'::text AS text,
            m.id
           FROM lead_matches m
             JOIN job_leads l ON l.id = m.lead_id
             LEFT JOIN employers e ON e.id = l.employer_id
             LEFT JOIN staff s ON s.id = m.created_by
          WHERE m.interview_on IS NOT NULL
        UNION ALL
         SELECT m.client_id,
            m.follow_up_on::timestamp with time zone AS follow_up_on,
            'Follow-up'::text AS text,
            'Follow up — '::text || COALESCE(e.name, l.title, 'a job'::text),
            COALESCE(l.title, ''::text) AS "coalesce",
            s.name,
            'overview'::text AS text,
            m.id
           FROM lead_matches m
             JOIN job_leads l ON l.id = m.lead_id
             LEFT JOIN employers e ON e.id = l.employer_id
             LEFT JOIN staff s ON s.id = m.created_by
          WHERE m.follow_up_on IS NOT NULL
        UNION ALL
         SELECT m.client_id,
            m.decided_on::timestamp with time zone AS decided_on,
            'Job'::text AS text,
            (m.status || ' — '::text) || COALESCE(e.name, l.title, 'a job'::text),
            COALESCE(NULLIF(m.outcome, ''::text), m.notes, ''::text) AS "coalesce",
            s.name,
            'overview'::text AS text,
            m.id
           FROM lead_matches m
             JOIN job_leads l ON l.id = m.lead_id
             LEFT JOIN employers e ON e.id = l.employer_id
             LEFT JOIN staff s ON s.id = m.created_by
          WHERE m.decided_on IS NOT NULL
        UNION ALL
         SELECT t.client_id,
            t.done_at,
            'Task'::text AS text,
            'Done — '::text || t.title,
            ''::text AS text,
            s.name,
            'tasks'::text AS text,
            t.id
           FROM tasks t
             LEFT JOIN staff s ON s.id = t.assigned_staff_id
          WHERE t.status = 'Done'::text AND t.done_at IS NOT NULL
        UNION ALL
         SELECT f.client_id,
            f.completed_at,
            'Form'::text AS text,
            'Completed — '::text || COALESCE(ft.name, 'form'::text),
            ''::text AS text,
            f.completed_by_name,
            'forms'::text AS text,
            f.id
           FROM forms f
             LEFT JOIN form_templates ft ON ft.id = f.template_id
          WHERE f.completed_at IS NOT NULL
        UNION ALL
         SELECT f.client_id,
            f.sent_at,
            'Form'::text AS text,
            'Sent — '::text || COALESCE(ft.name, 'form'::text),
            COALESCE(f.sent_to, ''::text) AS "coalesce",
            f.completed_by_name,
            'forms'::text AS text,
            f.id
           FROM forms f
             LEFT JOIN form_templates ft ON ft.id = f.template_id
          WHERE f.sent_at IS NOT NULL
        UNION ALL
         SELECT cl.client_id,
            cl.date::timestamp with time zone AS date,
            'Counselor'::text AS text,
            cl.method || COALESCE(' — '::text || NULLIF(cl.topic, ''::text), ''::text),
            COALESCE(cl.outcome, ''::text) AS "coalesce",
            s.name,
            'counselors'::text AS text,
            cl.id
           FROM contact_log cl
             LEFT JOIN staff s ON s.id = cl.staff_id
          WHERE cl.client_id IS NOT NULL
        UNION ALL
         SELECT p.client_id,
            p.start_date::timestamp with time zone AS start_date,
            'Placement'::text AS text,
            'Started — '::text || COALESCE(NULLIF(p.employer, ''::text), 'a placement'::text),
            COALESCE(p.title, ''::text) AS "coalesce",
            NULL::text AS text,
            'placements'::text AS text,
            p.id
           FROM placements p
          WHERE p.start_date IS NOT NULL
        UNION ALL
         SELECT p.client_id,
            c.at::timestamp with time zone AS at,
            'Retention'::text AS text,
            (c.label || ' check — '::text) || COALESCE(NULLIF(p.employer, ''::text), 'placement'::text),
            ''::text AS text,
            NULL::text AS text,
            'placements'::text AS text,
            p.id
           FROM placements p
             CROSS JOIN LATERAL ( VALUES (p.check30,'30 day'::text), (p.check60,'60 day'::text), (p.check90,'90 day'::text)) c(at, label)
          WHERE c.at IS NOT NULL
        UNION ALL
         SELECT a.client_id,
            se.date::timestamp with time zone AS date,
            'Hours'::text AS text,
            (fmt_hours(se.hours) || ' logged'::text) ||
                CASE
                    WHEN se.non_billable THEN ' (non-billable)'::text
                    ELSE ''::text
                END,
            COALESCE(se.notes, ''::text) AS "coalesce",
            s.name,
            'authorizations'::text AS text,
            se.id
           FROM service_entries se
             JOIN authorizations a ON a.id = se.auth_id
             LEFT JOIN staff s ON s.id = se.staff_id
        UNION ALL
         SELECT ce.client_id,
            ce.starts_at,
            'Appointment'::text AS text,
            (ce.kind || ' — '::text) || ce.title,
            COALESCE(ce.location, ''::text) AS "coalesce",
            s.name,
            'calendar'::text AS text,
            ce.id
           FROM calendar_events ce
             LEFT JOIN staff s ON s.id = ce.staff_id
          WHERE ce.client_id IS NOT NULL
        UNION ALL
         SELECT ml.client_id,
            ml.sent_at,
            'Mail'::text AS text,
                CASE ml.direction
                    WHEN 'Incoming'::text THEN 'From '::text
                    ELSE 'To '::text
                END || ml.counterpart_email,
            ml.subject,
            NULL::text AS text,
            'calendar'::text AS text,
            ml.id
           FROM mail_log ml
          WHERE ml.client_id IS NOT NULL
        UNION ALL
         SELECT sm.client_id,
            COALESCE(sm.sent_at, sm.created_at) AS "coalesce",
            'Text'::text AS text,
                CASE sm.direction
                    WHEN 'Incoming'::text THEN 'From the client'::text
                    ELSE 'To the client'::text
                END ||
                CASE
                    WHEN sm.status = 'Failed'::text THEN ' — not delivered'::text
                    WHEN sm.kind = 'Reminder'::text THEN ' — appointment reminder'::text
                    ELSE ''::text
                END,
            sm.body,
            s.name,
            'calendar'::text AS text,
            sm.id
           FROM sms_messages sm
             LEFT JOIN staff s ON s.id = sm.created_by
          WHERE sm.client_id IS NOT NULL
        UNION ALL
         SELECT a.client_id,
            COALESCE(pay.warrant_date::timestamp with time zone, pay.created_at) AS "coalesce",
            'Payment'::text AS text,
            (('Paid $'::text || to_char(pay.amount, 'FM999,999,990.00'::text)) || ' — '::text) || COALESCE(NULLIF(a.number, ''::text), a.service_type),
            COALESCE('Warrant '::text || NULLIF(pay.warrant_no, ''::text), 'No warrant number'::text) || COALESCE(' · voucher '::text || NULLIF(pay.voucher, ''::text), ''::text),
            NULLIF(pay.recorded_by_name, ''::text) AS "nullif",
            'payments'::text AS text,
            pay.id
           FROM payments pay
             JOIN authorizations a ON a.id = pay.auth_id
        UNION ALL
         SELECT c.client_id,
            COALESCE(c.last_message_at, c.created_at) AS "coalesce",
            'Chat'::text AS text,
                CASE
                    WHEN c.title <> ''::text THEN 'Staff thread — '::text || c.title
                    ELSE 'Staff thread about this client'::text
                END,
            COALESCE(( SELECT string_agg(s.name, ', '::text ORDER BY s.name) AS string_agg
                   FROM conversation_participants p
                     JOIN staff s ON s.id = p.staff_id
                  WHERE p.conversation_id = c.id AND p.left_at IS NULL), ''::text) AS "coalesce",
            ( SELECT s.name
                   FROM staff s
                  WHERE s.id = c.created_by),
            'chat'::text AS text,
            c.id
           FROM conversations c
          WHERE c.kind = 'internal'::text AND c.client_id IS NOT NULL
        UNION ALL
         SELECT c.client_id,
            COALESCE(c.last_message_at, c.created_at) AS "coalesce",
            'Website'::text AS text,
            'Chat on the website'::text,
            COALESCE(( SELECT m.body
                   FROM messages m
                  WHERE m.conversation_id = c.id AND m.sender_kind = 'visitor'::text
                  ORDER BY m.seq
                 LIMIT 1), ''::text) AS "coalesce",
            ( SELECT s.name
                   FROM staff s
                  WHERE s.id = c.assigned_staff_id),
            'web'::text AS text,
            c.id
           FROM conversations c
          WHERE c.kind = 'web'::text AND c.client_id IS NOT NULL AND NOT c.spam) feed;

alter view public.client_activity set (security_invoker = true);
grant select on public.client_activity to authenticated;
