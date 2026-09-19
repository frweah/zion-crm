-- Zion Vocational Rehab CRM — client texting, two ways (Messaging brief, A)
--
-- Texts already go out (0050): reminders, the consent gate, quiet hours, STOP
-- and START honoured on the way in. What was missing is the other half - the
-- conversation. This puts every text, in both directions, into the messaging
-- model (0104) so a client's thread, the team's inbox, unread counts and live
-- delivery are the same machinery as staff chat.
--
--   sms_messages stays the record of every text: the provider's id, its
--   status, and the gate that decides whether it may go at all. Nothing here
--   goes round that gate.
--
--   Each text is mirrored into a conversation as it is written down, by the
--   database itself, so a reminder sent by the nightly job and a reply typed
--   on a screen land in the same thread in the same way.
--
--   STOP and START appear in the thread too, as the system's own lines: a
--   thread that does not show why texting stopped invites somebody to try
--   again.
--
--   A text from a number nobody knows is written down as it always was, and
--   now shows in the inbox as unmatched - to be matched to a client, turned
--   into a referral, or marked as spam. It is never quietly dropped.
--
--   Sending outside 8am-9pm is still refused. A message written at night can
--   be scheduled instead, for the next window, which the cron sends.

-- ── scheduling, inside the same gate ────────────────────────
alter table public.sms_messages add column if not exists send_after timestamptz;
alter table public.sms_messages drop constraint if exists sms_messages_status_check;
alter table public.sms_messages add constraint sms_messages_status_check
  check (status in ('Queued', 'Scheduled', 'Sent', 'Failed', 'Received'));

/** The next moment a text may go: now, if now is inside the window. */
create or replace function public.next_text_window(p_at timestamptz default now())
returns timestamptz language sql stable as $$
  select case
    when public.sms_within_sending_hours(p_at) then p_at
    -- Before 8am: today at 8. After 9pm: tomorrow at 8.
    when extract(hour from (p_at at time zone 'America/Denver')) < 8
      then (date_trunc('day', p_at at time zone 'America/Denver') + interval '8 hours') at time zone 'America/Denver'
    else (date_trunc('day', (p_at at time zone 'America/Denver') + interval '1 day') + interval '8 hours') at time zone 'America/Denver'
  end;
$$;

-- The gate as it stood, with one addition: a message may be written now to go
-- out in the next window. Consent is still required, and still for the number
-- on the record.
create or replace function public.sms_outgoing_requires_consent()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_ok    boolean;
  v_phone text;
begin
  if new.direction <> 'Outgoing' then
    return new;
  end if;

  if new.client_id is null then
    raise exception 'A text has to be to somebody: no client on this message.'
      using errcode = 'check_violation';
  end if;

  select can_text, consented_phone into v_ok, v_phone
    from public.client_sms_consent where client_id = new.client_id;

  if not coalesce(v_ok, false) then
    raise exception
      'This client has not agreed to be texted at the number on their record, so nothing can be sent to them. Record their consent first.'
      using errcode = 'check_violation';
  end if;

  if public.normalize_phone(new.phone) is distinct from v_phone then
    raise exception
      'That is not the number this client agreed to be texted at.'
      using errcode = 'check_violation';
  end if;
  new.phone := v_phone;

  -- Scheduled for the next window: written now, sent then, by the cron.
  if new.status = 'Scheduled' then
    if new.send_after is null or not public.sms_within_sending_hours(new.send_after) then
      raise exception 'A scheduled text goes out between 8am and 9pm - % is outside that.',
        coalesce(to_char(new.send_after at time zone 'America/Denver', 'HH12:MIam'), 'no time')
        using errcode = 'check_violation';
    end if;
    if new.send_after < now() - interval '1 minute' then
      raise exception 'That time has passed.' using errcode = 'check_violation';
    end if;
    return new;
  end if;

  -- A reminder is not urgent enough to be worth waking somebody up for.
  if not public.sms_within_sending_hours(now()) then
    raise exception
      'It is % in Utah. Texts go out between 8am and 9pm.',
      to_char(now() at time zone 'America/Denver', 'HH12:MIam')
      using errcode = 'check_violation';
  end if;

  return new;
end;
$$;

-- ── what people send often ──────────────────────────────────
create table if not exists public.sms_templates (
  id         uuid primary key default gen_random_uuid(),
  label      text not null,
  body       text not null,
  sort_order integer not null default 100,
  active     boolean not null default true,
  created_by uuid references public.staff(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (length(body) between 1 and 600)
);
drop trigger if exists sms_templates_updated_at on public.sms_templates;
create trigger sms_templates_updated_at before update on public.sms_templates
  for each row execute function public.set_updated_at();

alter table public.sms_templates enable row level security;
drop policy if exists sms_templates_read on public.sms_templates;
create policy sms_templates_read on public.sms_templates for select to authenticated
  using ((select public.is_active_staff()));
drop policy if exists sms_templates_write on public.sms_templates;
create policy sms_templates_write on public.sms_templates for all to authenticated
  using ((select public.current_staff_role()) in ('Admin', 'Job Search', 'Reports'))
  with check ((select public.current_staff_role()) in ('Admin', 'Job Search', 'Reports'));
revoke all on public.sms_templates from anon;

-- Five to start with, in the practice's own words. Staff add and edit their
-- own from the client's Messages tab; the owner will want to change the
-- wording, which is why they are rows and not code.
insert into public.sms_templates (label, body, sort_order)
select * from (values
  ('Appointment change', 'Hi {first}, this is Zion Vocational Rehab. We need to move your appointment. Call us at 385-406-3432 and we will find a new time.', 10),
  ('Appointment reminder', 'Hi {first}, a reminder of your appointment with Zion Vocational Rehab. Call 385-406-3432 if you need to change it.', 20),
  ('Document needed', 'Hi {first}, Zion Vocational Rehab here. We still need a document from you before we can carry on. Call 385-406-3432 and we will tell you which.', 30),
  ('Please call us', 'Hi {first}, please give Zion Vocational Rehab a call at 385-406-3432 when you have a moment.', 40),
  ('Checking in', 'Hi {first}, checking in from Zion Vocational Rehab. How is the job search going? Reply here or call 385-406-3432.', 50)
) as v(label, body, sort_order)
where not exists (select 1 from public.sms_templates);

-- ── a text is part of a conversation ────────────────────────
alter table public.messages add column if not exists source_sms_id uuid references public.sms_messages(id) on delete cascade;
create unique index if not exists messages_source_sms_idx on public.messages (source_sms_id) where source_sms_id is not null;
alter table public.conversations add column if not exists spam boolean not null default false;

/** The thread a text belongs in: the client's, or the number's until somebody says whose it is. */
create or replace function public.text_conversation_for(p_client uuid, p_phone text)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_conv uuid;
  v_phone text := coalesce(public.normalize_phone(p_phone), p_phone);
begin
  if p_client is not null then
    select id into v_conv from public.conversations where kind = 'sms' and client_id = p_client order by created_at limit 1;
  end if;
  if v_conv is null and v_phone is not null then
    select id into v_conv from public.conversations
     where kind = 'sms' and client_id is null and external_address = v_phone order by created_at limit 1;
    -- Once the number is known to be somebody's, the thread is theirs.
    if v_conv is not null and p_client is not null then
      update public.conversations set client_id = p_client where id = v_conv;
    end if;
  end if;
  if v_conv is null then
    insert into public.conversations (kind, client_id, external_address) values ('sms', p_client, v_phone)
    returning id into v_conv;
  end if;
  return v_conv;
end;
$$;

create or replace function public.sms_into_conversation()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_conv   uuid;
  v_kind   text;
  v_label  text;
  v_status text;
  v_seq    bigint;
begin
  v_status := case new.status
    when 'Received' then 'received'
    when 'Sent' then 'sent'
    when 'Failed' then 'failed'
    else 'queued' end;

  if tg_op = 'UPDATE' then
    update public.messages set status = v_status where source_sms_id = new.id;
    return null;
  end if;

  v_conv := public.text_conversation_for(new.client_id, new.phone);
  if new.direction = 'Incoming' then
    v_kind := 'client';
    v_label := '';
  elsif new.created_by is not null then
    v_kind := 'staff';
    select name into v_label from public.staff where id = new.created_by;
  else
    -- The nightly reminder, sent by the system rather than by a person.
    v_kind := 'system';
    v_label := new.kind;
  end if;

  insert into public.messages (conversation_id, sender_kind, sender_staff_id, sender_label, body, status,
                               provider_message_id, source_sms_id, created_at)
  values (v_conv, v_kind, case when v_kind = 'staff' then new.created_by end, coalesce(v_label, ''),
          new.body, v_status, new.provider_message_id, new.id, new.created_at)
  returning seq into v_seq;

  update public.conversations
     set last_message_at = new.created_at, last_seq = v_seq,
         external_address = coalesce(nullif(external_address, ''), public.normalize_phone(new.phone))
   where id = v_conv;
  return null;
end;
$$;

drop trigger if exists sms_into_conversation on public.sms_messages;
create trigger sms_into_conversation after insert or update of status on public.sms_messages
  for each row execute function public.sms_into_conversation();

-- STOP and START in the thread, so it is plain why texting stopped.
create or replace function public.consent_event_into_conversation()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_conv uuid;
  v_seq  bigint;
  v_text text;
begin
  v_conv := public.text_conversation_for(new.client_id, new.phone);
  v_text := case new.state
    when 'Withdrawn' then 'Texting stopped. ' || coalesce(nullif(new.note, ''), 'Consent withdrawn (' || new.method || ').')
    when 'Granted' then 'Texting agreed. ' || coalesce(nullif(new.note, ''), 'Consent given (' || new.method || ').')
    else new.state || ': ' || coalesce(new.note, '') end;

  insert into public.messages (conversation_id, sender_kind, sender_label, body, status, created_at)
  values (v_conv, 'system', 'Consent', v_text, 'sent', new.at)
  returning seq into v_seq;
  update public.conversations set last_message_at = greatest(coalesce(last_message_at, new.at), new.at), last_seq = greatest(last_seq, v_seq)
   where id = v_conv;
  return null;
end;
$$;

drop trigger if exists consent_event_into_conversation on public.sms_consent_events;
create trigger consent_event_into_conversation after insert on public.sms_consent_events
  for each row execute function public.consent_event_into_conversation();

-- Everything already texted, into its thread, oldest first so the threads read
-- in order.
do $$
declare r record; v_conv uuid; v_seq bigint; v_kind text; v_label text; v_status text;
begin
  for r in select * from public.sms_messages m
            where not exists (select 1 from public.messages x where x.source_sms_id = m.id)
            order by m.created_at loop
    v_conv := public.text_conversation_for(r.client_id, r.phone);
    v_status := case r.status when 'Received' then 'received' when 'Sent' then 'sent' when 'Failed' then 'failed' else 'queued' end;
    if r.direction = 'Incoming' then v_kind := 'client'; v_label := '';
    elsif r.created_by is not null then v_kind := 'staff'; select name into v_label from public.staff where id = r.created_by;
    else v_kind := 'system'; v_label := r.kind;
    end if;
    insert into public.messages (conversation_id, sender_kind, sender_staff_id, sender_label, body, status,
                                 provider_message_id, source_sms_id, created_at)
    values (v_conv, v_kind, case when v_kind = 'staff' then r.created_by end, coalesce(v_label, ''),
            r.body, v_status, r.provider_message_id, r.id, r.created_at)
    returning seq into v_seq;
    update public.conversations set last_message_at = r.created_at, last_seq = v_seq where id = v_conv;
  end loop;
end $$;

-- ── the team's inbox ────────────────────────────────────────
-- Every text conversation with what it needs to be worked: who it is with,
-- what was last said, who has it, and how much of it this person has not read.
create or replace function public.texts_inbox(p_show text default 'open')
returns table (
  conversation_id uuid, client_id uuid, client_name text, phone text,
  assigned_staff_id uuid, assigned_name text, last_message_at timestamptz,
  last_body text, unread integer, unmatched boolean, spam boolean, can_text boolean
)
language sql stable security definer set search_path = public as $$
  select c.id, c.client_id, cl.name, c.external_address, c.assigned_staff_id, st.name, c.last_message_at,
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
   where c.kind = 'sms'
     and public.is_active_staff()
     and case p_show
           when 'spam' then c.spam
           when 'mine' then not c.spam and c.assigned_staff_id = public.current_staff_id()
           when 'unmatched' then not c.spam and c.client_id is null
           else not c.spam
         end
   order by c.last_message_at desc nulls last;
$$;

/** Who is looking after a text conversation. */
create or replace function public.assign_text_conversation(p_conversation uuid, p_staff uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if (select public.current_staff_role()) not in ('Admin', 'Job Search', 'Reports') then
    raise exception 'Your role does not work the texts inbox.' using errcode = 'insufficient_privilege';
  end if;
  if p_staff is not null and not exists (select 1 from public.staff where id = p_staff and active) then
    raise exception 'That person is not active staff.' using errcode = 'check_violation';
  end if;
  update public.conversations set assigned_staff_id = p_staff where id = p_conversation and kind = 'sms';
end;
$$;

/** Whose number it is, after all: the thread and its texts join their record. */
create or replace function public.match_text_conversation(p_conversation uuid, p_client uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_phone text;
begin
  if (select public.current_staff_role()) not in ('Admin', 'Job Search', 'Reports') then
    raise exception 'Your role does not work the texts inbox.' using errcode = 'insufficient_privilege';
  end if;
  select external_address into v_phone from public.conversations where id = p_conversation and kind = 'sms' and client_id is null;
  if v_phone is null then
    raise exception 'That conversation is not an unmatched one.' using errcode = 'check_violation';
  end if;
  if not exists (select 1 from public.clients where id = p_client) then
    raise exception 'That client is not on file.' using errcode = 'check_violation';
  end if;
  update public.conversations set client_id = p_client, spam = false where id = p_conversation;
  update public.sms_messages set client_id = p_client
   where client_id is null and public.normalize_phone(phone) = v_phone;
end;
$$;

/** A new person, texting in: a referral, with the texts already on it. */
create or replace function public.referral_from_text(p_conversation uuid, p_name text)
returns uuid language plpgsql security definer set search_path = public as $$
declare
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
  select external_address into v_phone from public.conversations where id = p_conversation and kind = 'sms' and client_id is null;
  if v_phone is null then
    raise exception 'That conversation is already somebody''s.' using errcode = 'check_violation';
  end if;

  insert into public.clients (name, phone, stage, status, assigned_staff_id)
  values (btrim(p_name), v_phone, 'Referral', 'Active', v_me)
  returning id into v_client;

  -- Texting them back still needs their consent: arriving by text is not it.
  perform public.match_text_conversation(p_conversation, v_client);
  insert into public.tasks (client_id, title, assigned_staff_id, status, due)
  values (v_client, 'Intake call - texted in', v_me, 'Open', public.practice_today() + 1);
  return v_client;
end;
$$;

/** Not a person we deal with. Kept, not deleted; a mistake here is undoable. */
create or replace function public.mark_text_spam(p_conversation uuid, p_spam boolean default true)
returns void language plpgsql security definer set search_path = public as $$
begin
  if (select public.current_staff_role()) not in ('Admin', 'Job Search', 'Reports') then
    raise exception 'Your role does not work the texts inbox.' using errcode = 'insufficient_privilege';
  end if;
  update public.conversations set spam = coalesce(p_spam, true)
   where id = p_conversation and kind = 'sms' and client_id is null;
  if not found then
    raise exception 'Only an unmatched conversation is marked spam.' using errcode = 'check_violation';
  end if;
end;
$$;

revoke execute on function public.text_conversation_for(uuid, text) from public, anon, authenticated;
revoke execute on function public.sms_into_conversation() from public, anon, authenticated;
revoke execute on function public.consent_event_into_conversation() from public, anon, authenticated;
revoke execute on function public.next_text_window(timestamptz) from public, anon;
revoke execute on function public.texts_inbox(text) from public, anon;
revoke execute on function public.assign_text_conversation(uuid, uuid) from public, anon;
revoke execute on function public.match_text_conversation(uuid, uuid) from public, anon;
revoke execute on function public.referral_from_text(uuid, text) from public, anon;
revoke execute on function public.mark_text_spam(uuid, boolean) from public, anon;
grant execute on function public.next_text_window(timestamptz) to authenticated, service_role;
grant execute on function public.texts_inbox(text) to authenticated;
grant execute on function public.assign_text_conversation(uuid, uuid) to authenticated;
grant execute on function public.match_text_conversation(uuid, uuid) to authenticated;
grant execute on function public.referral_from_text(uuid, text) to authenticated;
grant execute on function public.mark_text_spam(uuid, boolean) to authenticated;
grant execute on function public.text_conversation_for(uuid, text) to service_role;
