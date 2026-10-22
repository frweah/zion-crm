-- 0225 — Client portal, step 2: messages and notices (portal brief, section 2).
--
-- A portal conversation is a conversations row of a new kind, 'portal': one
-- per portal account, so a client and their guardian each have their own
-- thread. It is shown in the inbox beside texts and website chats, and it is
-- read and answered by the people who manage that client's portal
-- (can_manage_portal: Admin, Reports, or the client's assigned staff member).
--
-- The client reaches it only through the functions below, which work from the
-- session (portal_session_account_id) and refuse anybody who has not agreed
-- to the current terms (portal_client_id is null without that consent). The
-- browser never names a conversation.
--
-- A notice tells the client something is waiting. It never carries content:
-- the words are fixed in lib/portal/deliver.ts, and this file decides only
-- whether one may go, where, and records that it did. One per conversation
-- per hour at most.

-- ── the conversation ────────────────────────────────────────
alter table public.conversations drop constraint if exists conversations_kind_check;
alter table public.conversations add constraint conversations_kind_check
  check (kind in ('sms', 'internal', 'web', 'portal'));

alter table public.conversations
  add column if not exists portal_account_id uuid references public.portal_accounts(id) on delete restrict,
  -- How far the client has read. Staff reads are read_receipts, as ever; the
  -- client is not staff and has no row there.
  add column if not exists portal_read_seq bigint not null default 0;

alter table public.conversations drop constraint if exists conversations_portal_shape;
alter table public.conversations add constraint conversations_portal_shape
  check ((kind = 'portal') = (portal_account_id is not null));

create unique index if not exists conversations_one_portal_thread
  on public.conversations (portal_account_id) where kind = 'portal';

-- Staff read a portal thread only if they manage that client's portal.
-- Everything else about this policy is as it was. Applied in five parts
-- (0225a-e) on 21 Oct 2026; this file is their sum.
alter policy conversations_read on public.conversations using (
  (select public.is_active_staff())
  and case kind
        when 'internal' then ((select public.is_admin()) and client_id is not null) or public.is_conversation_participant(id)
        when 'portal' then public.can_manage_portal(client_id)
        else true
      end
);

-- ── how the client wants to be told ─────────────────────────
alter table public.portal_accounts
  add column if not exists notice_channel text check (notice_channel in ('Text', 'Email'));

-- ── notices ─────────────────────────────────────────────────
create table if not exists public.portal_notices (
  id              uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete restrict,
  account_id      uuid not null references public.portal_accounts(id) on delete restrict,
  at              timestamptz not null default now(),
  channel         text not null check (channel in ('Text', 'Email', 'None')),
  status          text not null default 'Claimed' check (status in ('Claimed', 'Sent', 'Failed', 'Skipped')),
  detail          text not null default ''
);
create index if not exists portal_notices_recent on public.portal_notices (conversation_id, at desc);

alter table public.portal_notices enable row level security;
create policy portal_notices_read on public.portal_notices for select to authenticated
  using (exists (select 1 from public.conversations c where c.id = conversation_id));
revoke all on public.portal_notices from anon, authenticated;
grant select on public.portal_notices to authenticated;

-- Can this account be told by text? Only to the client's own number, and only
-- with texting consent on record for it - the same rule every other text from
-- the practice follows. A guardian is told by email.
create or replace function public.portal_can_text(p_account uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((
    select a.kind = 'Client'
       and a.phone is not null
       and public.normalize_phone(a.phone) = public.normalize_phone(nullif(c.phone, ''))
       and coalesce((select e.state = 'Granted' from public.sms_consent_events e
                      where e.client_id = c.id order by e.at desc, e.seq desc limit 1), false)
      from public.portal_accounts a
      join public.clients c on c.id = a.client_id
     where a.id = p_account), false);
$$;

-- The thread for an account, made the first time either side needs it.
create or replace function public.portal_thread_for(p_account uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_id     uuid;
  v_client uuid;
  v_staff  uuid;
  v_name   text;
begin
  select id into v_id from public.conversations where kind = 'portal' and portal_account_id = p_account;
  if v_id is not null then return v_id; end if;

  select a.client_id, c.assigned_staff_id, a.name into v_client, v_staff, v_name
    from public.portal_accounts a join public.clients c on c.id = a.client_id
   where a.id = p_account;
  if v_client is null then
    raise exception 'There is no portal account by that name.' using errcode = 'check_violation';
  end if;

  insert into public.conversations (kind, title, client_id, portal_account_id, assigned_staff_id, external_address)
  values ('portal', 'Portal', v_client, p_account, v_staff, v_name)
  on conflict (portal_account_id) where kind = 'portal' do nothing
  returning id into v_id;
  if v_id is null then
    select id into v_id from public.conversations where kind = 'portal' and portal_account_id = p_account;
  end if;
  return v_id;
end;
$$;

-- ── the client's side ───────────────────────────────────────
create or replace function public.portal_my_messages()
returns table (seq bigint, mine boolean, sender text, body text, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select m.seq, m.sender_kind = 'client',
         case when m.sender_kind = 'client' then 'You'
              when m.sender_kind = 'staff' then coalesce(nullif(split_part(trim(m.sender_label), ' ', 1), ''), 'Zion Voc Rehab')
              else 'Zion Voc Rehab' end,
         m.body, m.created_at
    from public.conversations c
    join public.messages m on m.conversation_id = c.id
   where c.kind = 'portal'
     and c.portal_account_id = public.portal_session_account_id()
     and public.portal_client_id() is not null
     and m.removed_at is null
   order by m.seq
   limit 500;
$$;

create or replace function public.portal_unread()
returns integer language sql stable security definer set search_path = public as $$
  select coalesce((
    select count(*)::integer
      from public.conversations c
      join public.messages m on m.conversation_id = c.id
     where c.kind = 'portal'
       and c.portal_account_id = public.portal_session_account_id()
       and public.portal_client_id() is not null
       and m.sender_kind <> 'client' and m.removed_at is null
       and m.seq > c.portal_read_seq), 0);
$$;

create or replace function public.portal_mark_read(p_seq bigint)
returns void language sql security definer set search_path = public as $$
  update public.conversations
     set portal_read_seq = greatest(portal_read_seq, least(p_seq, last_seq))
   where kind = 'portal'
     and portal_account_id = public.portal_session_account_id()
     and public.portal_client_id() is not null;
$$;

create or replace function public.portal_send_message(p_body text)
returns bigint language plpgsql security definer set search_path = public as $$
declare
  v_account uuid := public.portal_session_account_id();
  v_name    text;
  v_conv    uuid;
  v_seq     bigint;
begin
  if v_account is null or public.portal_client_id() is null then
    raise exception 'Sign in and agree to the portal terms before sending a message.' using errcode = 'insufficient_privilege';
  end if;
  if coalesce(btrim(p_body), '') = '' or length(p_body) > 2000 then
    raise exception 'A message can be up to 2,000 characters. Please shorten it and try again.' using errcode = 'check_violation';
  end if;

  v_conv := public.portal_thread_for(v_account);
  if (select count(*) from public.messages
       where conversation_id = v_conv and sender_kind = 'client' and created_at > now() - interval '1 hour') >= 30 then
    raise exception 'You have sent a lot of messages this hour. Please wait a little, or call 385-406-3432.' using errcode = 'check_violation';
  end if;

  select name into v_name from public.portal_accounts where id = v_account;
  insert into public.messages (conversation_id, sender_kind, sender_label, body, status)
  values (v_conv, 'client', coalesce(v_name, ''), btrim(p_body), 'received')
  returning seq into v_seq;
  update public.conversations
     set last_message_at = now(), last_seq = v_seq, portal_read_seq = v_seq, archived_at = null, archived_by = null
   where id = v_conv;
  return v_seq;
end;
$$;

create or replace function public.portal_set_notice_channel(p_channel text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_account uuid := public.portal_session_account_id();
begin
  if v_account is null or public.portal_client_id() is null then
    raise exception 'Sign in and agree to the portal terms first.' using errcode = 'insufficient_privilege';
  end if;
  if p_channel = 'Text' and not public.portal_can_text(v_account) then
    raise exception 'We can only text a number you have agreed to receive texts on. Call 385-406-3432 to set that up.' using errcode = 'check_violation';
  end if;
  if p_channel = 'Email' and not exists (select 1 from public.portal_accounts where id = v_account and nullif(email, '') is not null) then
    raise exception 'There is no email address on your account. Call 385-406-3432 to add one.' using errcode = 'check_violation';
  end if;
  if p_channel not in ('Text', 'Email') then
    raise exception 'Choose text or email.' using errcode = 'check_violation';
  end if;
  update public.portal_accounts set notice_channel = p_channel where id = v_account;
end;
$$;

-- What the settings screen offers.
create or replace function public.portal_my_notice_options()
returns table (channel text, can_text boolean, has_email boolean)
language sql stable security definer set search_path = public as $$
  select a.notice_channel, public.portal_can_text(a.id), nullif(a.email, '') is not null
    from public.portal_accounts a
   where a.id = public.portal_session_account_id()
     and public.portal_client_id() is not null;
$$;

-- ── the staff side ──────────────────────────────────────────
-- Opens (or finds) the thread for an account, for a staff member who manages
-- that client's portal.
create or replace function public.portal_open_thread(p_account uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_client uuid;
begin
  select client_id into v_client from public.portal_accounts where id = p_account and disabled_at is null;
  if v_client is null then
    raise exception 'That portal account is not open.' using errcode = 'check_violation';
  end if;
  if not public.can_manage_portal(v_client) then
    raise exception 'Only Admin, Reports or the assigned staff member writes to this client''s portal.' using errcode = 'insufficient_privilege';
  end if;
  return public.portal_thread_for(p_account);
end;
$$;

create or replace function public.post_portal_reply(p_conversation uuid, p_body text)
returns bigint language plpgsql security definer set search_path = public as $$
declare
  v_me     uuid := public.current_staff_id();
  v_client uuid;
  v_name   text;
  v_seq    bigint;
begin
  select c.client_id into v_client
    from public.conversations c
    join public.portal_accounts a on a.id = c.portal_account_id and a.disabled_at is null
   where c.id = p_conversation and c.kind = 'portal';
  if v_client is null then
    raise exception 'That is not an open portal conversation.' using errcode = 'check_violation';
  end if;
  if not public.can_manage_portal(v_client) then
    raise exception 'Only Admin, Reports or the assigned staff member writes to this client''s portal.' using errcode = 'insufficient_privilege';
  end if;
  if coalesce(btrim(p_body), '') = '' or length(p_body) > 2000 then
    raise exception 'A message is between one and two thousand characters.' using errcode = 'check_violation';
  end if;

  select name into v_name from public.staff where id = v_me;
  insert into public.messages (conversation_id, sender_kind, sender_staff_id, sender_label, body)
  values (p_conversation, 'staff', v_me, coalesce(v_name, ''), btrim(p_body))
  returning seq into v_seq;
  update public.conversations
     set last_message_at = now(), last_seq = v_seq,
         assigned_staff_id = coalesce(assigned_staff_id, v_me)
   where id = p_conversation;
  insert into public.read_receipts (conversation_id, staff_id, last_read_seq, read_at)
  values (p_conversation, v_me, v_seq, now())
  on conflict (conversation_id, staff_id) do update
    set last_read_seq = greatest(public.read_receipts.last_read_seq, excluded.last_read_seq), read_at = now();
  return v_seq;
end;
$$;

-- May a notice go for this conversation now, and where? Records the decision
-- either way, so the hourly limit counts what was attempted rather than what
-- succeeded, and a failing provider is not retried every reply.
--
-- Text is used only where portal_can_text holds and it is between 8am and
-- 9pm in Utah; otherwise email if there is one; otherwise nothing is sent and
-- the client sees the message the next time they sign in.
create or replace function public.portal_claim_notice(p_conversation uuid)
returns table (notice_id uuid, channel text, destination text, name text)
language plpgsql security definer set search_path = public as $$
declare
  v_acc     public.portal_accounts%rowtype;
  v_local   time := (now() at time zone 'America/Denver')::time;
  v_text    boolean;
  v_channel text;
  v_dest    text;
  v_id      uuid;
  v_why     text := '';
begin
  select a.* into v_acc
    from public.conversations c join public.portal_accounts a on a.id = c.portal_account_id
   where c.id = p_conversation and c.kind = 'portal';
  if v_acc.id is null then
    raise exception 'That is not a portal conversation.' using errcode = 'check_violation';
  end if;
  if not public.can_manage_portal(v_acc.client_id) then
    raise exception 'Only Admin, Reports or the assigned staff member writes to this client''s portal.' using errcode = 'insufficient_privilege';
  end if;

  -- One an hour. A notice that was skipped sent nothing, so it does not count.
  if exists (select 1 from public.portal_notices n
              where n.conversation_id = p_conversation and n.status <> 'Skipped'
                and n.at > now() - interval '1 hour') then
    return;
  end if;

  if v_acc.disabled_at is not null or v_acc.first_signed_in_at is null then
    v_channel := 'None';
    v_why := case when v_acc.disabled_at is not null then 'Account disabled' else 'Not signed in yet' end;
  else
    v_text := public.portal_can_text(v_acc.id) and v_local >= time '08:00' and v_local < time '21:00';
    if coalesce(v_acc.notice_channel, case when nullif(v_acc.email, '') is not null then 'Email' else 'Text' end) = 'Text' and v_text then
      v_channel := 'Text'; v_dest := v_acc.phone;
    elsif nullif(v_acc.email, '') is not null then
      v_channel := 'Email'; v_dest := v_acc.email;
      if v_acc.notice_channel = 'Text' then v_why := 'Text not possible now, sent by email'; end if;
    elsif v_acc.phone is not null and public.portal_can_text(v_acc.id) then
      v_channel := 'None'; v_why := 'Outside texting hours';
    else
      v_channel := 'None'; v_why := 'No way to reach them';
    end if;
  end if;

  insert into public.portal_notices (conversation_id, account_id, channel, status, detail)
  values (p_conversation, v_acc.id, v_channel, case when v_channel = 'None' then 'Skipped' else 'Claimed' end, v_why)
  returning id into v_id;

  if v_channel = 'None' then return; end if;
  return query select v_id, v_channel, v_dest, v_acc.name;
end;
$$;

create or replace function public.portal_note_notice(p_notice uuid, p_sent boolean, p_detail text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.portal_notices n join public.portal_accounts a on a.id = n.account_id
                  where n.id = p_notice and n.status = 'Claimed' and public.can_manage_portal(a.client_id)) then
    raise exception 'That notice is not waiting to be recorded.' using errcode = 'check_violation';
  end if;
  update public.portal_notices
     set status = case when p_sent then 'Sent' else 'Failed' end,
         detail = left(coalesce(nullif(p_detail, ''), detail), 300)
   where id = p_notice;
end;
$$;

-- ── the inbox, with portal threads in it ────────────────────
create or replace function public.message_inbox(p_show text default 'open')
returns table (conversation_id uuid, kind text, client_id uuid, client_name text, who text, assigned_staff_id uuid,
               assigned_name text, last_message_at timestamptz, last_body text, unread integer, unmatched boolean,
               spam boolean, can_text boolean)
language sql stable security definer set search_path = public as $$
  select c.id, c.kind, c.client_id, cl.name,
         case when c.kind = 'portal' then pa.name || case when pa.kind = 'Guardian' then ' · guardian' else '' end
              else coalesce(w.visitor_name || ' · ' || c.external_address, c.external_address) end,
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
    left join public.portal_accounts pa on pa.id = c.portal_account_id
   where c.kind in ('sms', 'web', 'portal')
     and public.is_active_staff()
     and (c.kind <> 'portal' or public.can_manage_portal(c.client_id))
     and case p_show
           when 'spam' then c.spam
           when 'mine' then not c.spam and c.assigned_staff_id = public.current_staff_id()
           when 'unmatched' then not c.spam and c.client_id is null
           when 'web' then not c.spam and c.kind = 'web'
           when 'texts' then not c.spam and c.kind = 'sms'
           when 'portal' then not c.spam and c.kind = 'portal'
           else not c.spam
         end
   order by c.last_message_at desc nulls last;
$$;

-- ── who may call what ───────────────────────────────────────
revoke execute on function public.portal_can_text(uuid), public.portal_thread_for(uuid)
  from public, anon, authenticated;
revoke execute on function public.portal_my_messages(), public.portal_unread(), public.portal_mark_read(bigint),
  public.portal_send_message(text), public.portal_set_notice_channel(text), public.portal_my_notice_options(),
  public.portal_open_thread(uuid), public.post_portal_reply(uuid, text), public.portal_claim_notice(uuid),
  public.portal_note_notice(uuid, boolean, text)
  from public, anon;

grant execute on function public.portal_my_messages(), public.portal_unread(), public.portal_mark_read(bigint),
  public.portal_send_message(text), public.portal_set_notice_channel(text), public.portal_my_notice_options()
  to authenticated, portal_client;
grant execute on function public.portal_open_thread(uuid), public.post_portal_reply(uuid, text),
  public.portal_claim_notice(uuid), public.portal_note_notice(uuid, boolean, text)
  to authenticated;
