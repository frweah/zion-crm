-- Zion Vocational Rehab CRM — a text from a contact files on the client
--
-- The third part of A. Who a text may go to, who it came from, and where it
-- is filed.
--
-- ── going out ────────────────────────────────────────────────
--
-- The gate asked one question: has this client agreed to be texted at the
-- number on their record. With three numbers and a daughter-in-law that is
-- the wrong question. It now asks about the number the text is addressed to:
-- the number must be one the practice holds for this client - their own or a
-- contact's - and that number must have consent.
--
-- ── coming in ────────────────────────────────────────────────
--
-- An unknown number is matched against the client's own numbers first and
-- their contacts' second. That is the order the owner asked for and it is
-- also the only order that cannot mislabel a client as their own
-- daughter-in-law: a number on both would otherwise be a coin toss.
--
-- A STOP applies to the number it came from, which is what a carrier keyword
-- means and what the practice can honour. A daughter-in-law who stops hearing
-- about appointments has not withdrawn the client's consent.
--
-- ── and where it is filed ────────────────────────────────────
--
-- On the client, always. One thread per number so the two sides of a
-- conversation stay together, each thread on the client's record, and the
-- contact's thread titled with who it is. Every message from a contact
-- carries "Eunice (daughter-in-law)" as the sender, because six weeks later
-- the question is who said this and the number will not answer it.

begin;

alter table public.sms_messages
  add column if not exists contact_id uuid references public.client_contacts(id) on delete set null;

comment on column public.sms_messages.contact_id is
  'The contact this text was with, where the number is a contact''s. The '
  'client is on the row either way: the text is part of that client''s record.';

create index if not exists sms_messages_by_contact on public.sms_messages (contact_id)
  where contact_id is not null;

-- ── going out ────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.sms_outgoing_requires_consent()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_phone text := public.normalize_phone(new.phone);
  v_who   text;
  v_name  text;
  v_contact uuid;
  v_ok    boolean;
begin
  if new.direction <> 'Outgoing' then
    return new;
  end if;

  if new.client_id is null then
    raise exception 'A text has to be to somebody: no client on this message.'
      using errcode = 'check_violation';
  end if;
  if v_phone is null then
    raise exception 'That is not a number we can text: %', coalesce(new.phone, 'nothing')
      using errcode = 'check_violation';
  end if;

  select n.whose, n.whose_name, n.contact_id, n.can_text
    into v_who, v_name, v_contact, v_ok
    from public.sms_consent_numbers n
   where n.client_id = new.client_id and n.phone = v_phone
   limit 1;

  if v_who is null then
    raise exception 'That number is not on this client''s record, so nothing can be sent to it.'
      using errcode = 'check_violation',
            hint = 'Add the number, or the contact it belongs to, first.';
  end if;

  if not coalesce(v_ok, false) then
    raise exception
      '% has not agreed to be texted at that number, so nothing can be sent to it. Record their consent first.',
      coalesce(nullif(v_name, ''), 'That person')
      using errcode = 'check_violation';
  end if;

  new.phone := v_phone;
  -- Whose number it is, written on the message rather than worked out again
  -- by every screen that shows it.
  new.contact_id := v_contact;

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
$function$;

-- ── coming in ────────────────────────────────────────────────

drop function if exists public.record_incoming_sms(text, text, text, jsonb, text, text);

create function public.record_incoming_sms(
  p_phone text,
  p_body text,
  p_provider_id text DEFAULT NULL::text,
  p_payload jsonb DEFAULT NULL::jsonb,
  p_media text DEFAULT NULL::text,
  p_media_type text DEFAULT NULL::text
) returns table(client_id uuid, contact_id uuid, action text)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_phone   text := public.normalize_phone(p_phone);
  v_client  uuid;
  v_contact uuid;
  v_word    text := upper(regexp_replace(coalesce(p_body, ''), '[^A-Za-z]', '', 'g'));
  v_action  text := 'logged';
begin
  if v_phone is null then
    raise exception 'That is not a phone number we can match: %', p_phone
      using errcode = 'check_violation';
  end if;

  /*
   * The client's own numbers first, their contacts' second.
   *
   * The owner's order, and the only one that cannot mislabel a client as
   * their own daughter-in-law. Within each, an active client before a closed
   * one, and the oldest record before a newer duplicate - which is what the
   * version before this did when `clients.phone` was the only number there
   * was.
   */
  select n.client_id, n.contact_id into v_client, v_contact
    from public.client_numbers n
    join public.clients c on c.id = n.client_id
   where n.phone = v_phone
   order by case when n.whose = 'Client' then 0 else 1 end,
            case when c.status = 'Active' then 0 else 1 end,
            c.created_at
   limit 1;

  -- The message is written down whether or not we know whose it is. A STOP
  -- from a number we cannot place still has to be honoured, and an unmatched
  -- reply is a thing somebody should see rather than lose.
  insert into public.sms_messages (client_id, contact_id, direction, phone, body, kind,
                                   provider_message_id, provider_payload, status, sent_at,
                                   media_url, media_type)
  values (v_client, v_contact, 'Incoming', v_phone, coalesce(p_body, ''), 'Reply',
          p_provider_id, p_payload, 'Received', now(),
          nullif(btrim(coalesce(p_media, '')), ''),
          nullif(btrim(coalesce(p_media_type, '')), ''));

  -- The keywords carriers require, plus the ones people actually send.
  --
  -- A picture with no words in it must not read as a keyword. `v_word` strips
  -- everything that is not a letter, so a text whose body is empty gives an
  -- empty string, which matches none of the lists below - but it is worth
  -- saying out loud, because a picture message is the commonest way a body
  -- arrives empty and "withdrew consent by sending a photograph" would be a
  -- bad afternoon.
  --
  -- And it applies to the number it came from. A daughter-in-law who stops
  -- hearing about appointments has not withdrawn the client's consent, and
  -- the row says whose number it was.
  if v_word in ('STOP', 'STOPALL', 'UNSUBSCRIBE', 'CANCEL', 'END', 'QUIT', 'REVOKE', 'OPTOUT') then
    if v_client is not null then
      insert into public.sms_consent_events (client_id, contact_id, state, phone, method, note)
      values (v_client, v_contact, 'Withdrawn', v_phone, 'Text reply',
              'Replied ' || v_word || ' — consent withdrawn automatically');
    end if;
    v_action := 'withdrawn';

  elsif v_word in ('START', 'UNSTOP', 'YES', 'OPTIN') then
    -- A person can put themselves back on, and only for the number they sent
    -- from. Anything less would mean a withdrawal that cannot be undone
    -- without ringing the office.
    if v_client is not null then
      insert into public.sms_consent_events (client_id, contact_id, state, phone, method, note)
      values (v_client, v_contact, 'Granted', v_phone, 'Text reply',
              'Replied ' || v_word || ' — consent given by text');
    end if;
    v_action := 'granted';
  end if;

  return query select v_client, v_contact, v_action;
end $function$;

comment on function public.record_incoming_sms is
  'A text that arrived: written down, matched against the client''s own '
  'numbers and then their contacts'', and acted on if it is a keyword.';

revoke all on function public.record_incoming_sms(text, text, text, jsonb, text, text)
  from public, anon, authenticated;
grant execute on function public.record_incoming_sms(text, text, text, jsonb, text, text) to service_role;

-- ── and where it is filed ────────────────────────────────────

CREATE OR REPLACE FUNCTION public.text_conversation_for(p_client uuid, p_phone text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_conv  uuid;
  v_phone text := coalesce(public.normalize_phone(p_phone), p_phone);
  v_title text := '';
begin
  /*
   * One thread per number, all of them on the client (0332).
   *
   * This was one thread per client, whatever number a text came from, which
   * was right while a client had one number. With a client's partner texting
   * from theirs, a single thread would put two people's words in one column
   * with nothing to tell them apart.
   *
   * The 31 threads that existed when this changed all carry the number they
   * are with, so they are found by the same query.
   */
  if p_client is not null and v_phone is not null then
    select id into v_conv from public.conversations
     where kind = 'sms' and client_id = p_client and external_address = v_phone
     order by created_at limit 1;
  end if;
  if v_conv is null and v_phone is not null then
    select id into v_conv from public.conversations
     where kind = 'sms' and client_id is null and external_address = v_phone order by created_at limit 1;
    -- Once the number is known to be somebody's, the thread is theirs.
    if v_conv is not null and p_client is not null then
      update public.conversations set client_id = p_client where id = v_conv;
    end if;
  end if;

  -- Whose number this is, so the inbox says "Eunice (daughter-in-law)"
  -- rather than a number nobody recognises.
  if p_client is not null and v_phone is not null then
    select t.name || ' (' || t.relationship || ')' into v_title
      from public.client_contacts t
     where t.client_id = p_client and t.phone = v_phone and t.active
     limit 1;
  end if;

  if v_conv is null then
    insert into public.conversations (kind, client_id, external_address, title)
    values ('sms', p_client, v_phone, coalesce(v_title, ''))
    returning id into v_conv;
  elsif coalesce(v_title, '') <> '' then
    update public.conversations set title = v_title
     where id = v_conv and coalesce(title, '') is distinct from v_title;
  end if;

  return v_conv;
end;
$function$;

-- ── and who said it ─────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.sms_into_conversation()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_conv   uuid;
  v_kind   text;
  v_label  text;
  v_status text;
  v_seq    bigint;
begin
  -- The mirror's words, which are not the same words. 'Not delivered' was
  -- added to sms_messages in 0280 and this case did not know it, so it fell
  -- through to 'queued': the sweep gave up on fifteen texts and the inbox went
  -- on saying they were still going. Named here rather than left to the else,
  -- which is what hid it.
  v_status := case new.status
    when 'Received' then 'received'
    when 'Sent' then 'sent'
    -- The stronger word, added in 0286. The mirror has had 'delivered' all
    -- along with nothing mapped onto it.
    when 'Delivered' then 'delivered'
    when 'Failed' then 'failed'
    when 'Not delivered' then 'failed'
    when 'Queued' then 'queued'
    when 'Scheduled' then 'queued'
    else 'queued' end;

  if tg_op = 'UPDATE' then
    update public.messages set status = v_status where source_sms_id = new.id;
    return null;
  end if;

  v_conv := public.text_conversation_for(new.client_id, new.phone);
  if new.direction = 'Incoming' then
    v_kind := 'client';
    /*
     * Who sent it, where it was not the client (0332).
     *
     * A text from a client's partner is on the client's record, which is
     * where it belongs - and six weeks later the question is who said this.
     * The number does not answer it, so the name and the relationship are
     * written onto the message as it arrives. They are copied rather than
     * joined: a contact who comes off the record later must not take the
     * authorship of what they said with them.
     */
    v_label := '';
    if new.contact_id is not null then
      select t.name || ' (' || t.relationship || ')' into v_label
        from public.client_contacts t where t.id = new.contact_id;
    end if;
  elsif new.created_by is not null then
    v_kind := 'staff';
    select name into v_label from public.staff where id = new.created_by;
  else
    -- The nightly reminder, sent by the system rather than by a person.
    v_kind := 'system';
    v_label := new.kind;
  end if;

  -- The picture comes across as the provider's URL, not as a file (0281):
  -- referenced, never copied, so the practice does not become a second place a
  -- client's photograph lives. `attachments` is for documents the practice
  -- holds a row for, which this is not, so it has two columns of its own.
  insert into public.messages (conversation_id, sender_kind, sender_staff_id, sender_label, body, status,
                               provider_message_id, source_sms_id, created_at,
                               media_url, media_type)
  values (v_conv, v_kind, case when v_kind = 'staff' then new.created_by end, coalesce(v_label, ''),
          new.body, v_status, new.provider_message_id, new.id, new.created_at,
          new.media_url, new.media_type)
  returning seq into v_seq;

  update public.conversations
     set last_message_at = new.created_at, last_seq = v_seq,
         external_address = coalesce(nullif(external_address, ''), public.normalize_phone(new.phone))
   where id = v_conv;
  return null;
end;
$function$;

commit;
