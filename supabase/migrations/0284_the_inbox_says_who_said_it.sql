-- The inbox says who said it, whether it went, and shows the picture
--
-- Part 1a, 1b and 1c of the 3 November list, for the half that lives in the
-- inbox rather than on the client's record.
--
-- A text reaches the inbox through `messages`, which `sms_into_conversation`
-- writes as each `sms_messages` row lands. Three things did not make the trip:
--
--   * **Direction and sender.** Both are already on the mirror row -
--     `sender_kind` and `sender_label` - and `message_inbox` simply did not
--     return them, so the inbox showed the words of the last message with
--     nothing to say whether the client had asked something or the practice
--     had answered. The same line read two ways.
--
--   * **The picture.** `sms_messages.media_url` arrived in 0280 and the mirror
--     did not carry it, so a client who sent a photograph and no words showed
--     in the inbox as an empty row. It goes across as the provider's URL and
--     not as a file, which is 0281's decision unchanged: referenced, never
--     copied. `messages.attachments` is a list of documents the practice holds
--     a row for, so a URL does not belong in it - hence two columns of its
--     own, where what they are is visible.
--
--   * **'Not delivered'.** 0280 added the status to `sms_messages` and this
--     case statement did not know the word, so it fell through to the `else`
--     and the mirror said 'queued'. The sweep has not run against production
--     yet, so nothing has been mis-described there - but the moment it does,
--     the client's record would say 'not delivered' and the inbox would say
--     the same text was still going, which is the complaint the brief opens
--     with in a second place. Every status is now named, and the `else` is a
--     fallback rather than a decision.
--
-- Every mirrored row is re-derived from the row it mirrors, which today
-- changes nothing - the two already agree - and from here keeps them that way.
-- Nothing in `sms_messages` is touched: the only correct value for a mirror is
-- what it mirrors.
--
-- The behaviour is asserted in `verify_texts_that_never_went.sql` rather than
-- here. A fixture needs a client and a consent record to make a text at all,
-- and a client with a consent record cannot be deleted - the consent log is
-- append-only and refuses the cascade - so a migration that runs on production
-- cannot make one and tidy up after itself.
--
-- `message_inbox` also stops reading a hidden message. 0275 made a hidden
-- message invisible in the four places that read `messages`, and the inbox
-- preview was a fifth that nobody had: Admin could take a message off the
-- screen and its first 120 characters would still be sitting in the inbox
-- list.

alter table public.messages
  add column if not exists media_url  text,
  add column if not exists media_type text;

comment on column public.messages.media_url is
  'A picture sent with a text, as the provider holds it. Referenced, never copied (0281).';

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
    v_label := '';
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
$function$

;

-- Dropped and recreated: the return type gains five columns, which a replace
-- refuses. One argument either way, so there is no second signature left
-- behind - and the grants go with the drop, so they are set again below.
drop function if exists public.message_inbox(text);

CREATE OR REPLACE FUNCTION public.message_inbox(p_show text DEFAULT 'open'::text)
 RETURNS TABLE(conversation_id uuid, kind text, client_id uuid, client_name text, who text, assigned_staff_id uuid, assigned_name text, last_message_at timestamp with time zone, last_body text, unread integer, unmatched boolean, spam boolean, can_text boolean, last_sender_kind text, last_sender text, last_status text, last_media_url text, last_media_type text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select c.id, c.kind, c.client_id, cl.name,
         case when c.kind = 'portal' then pa.name || case when pa.kind = 'Guardian' then ' · guardian' else '' end
              else coalesce(w.visitor_name || ' · ' || c.external_address, c.external_address) end,
         c.assigned_staff_id, st.name, c.last_message_at,
         lm.body,
         (select count(*)::integer from public.messages m
           left join public.read_receipts r on r.conversation_id = c.id and r.staff_id = public.current_staff_id()
          where m.conversation_id = c.id and m.seq > coalesce(r.last_read_seq, 0)
            and m.sender_kind in ('client', 'visitor')),
         c.client_id is null, c.spam,
         coalesce((select can_text from public.client_sms_consent v where v.client_id = c.client_id), false),
         -- Who said the last thing, and whether it went (1a, 1b, 1c). The
         -- inbox used to show the words alone, so a line could be read as the
         -- client asking or as the practice answering, and a picture message
         -- with no words in it showed as an empty row.
         lm.sender_kind, lm.sender_label, lm.status, lm.media_url, lm.media_type
    from public.conversations c
    left join lateral (
      select m.sender_kind, m.sender_label, m.body, m.status, m.media_url, m.media_type
        from public.messages m
       where m.conversation_id = c.id and m.hidden_at is null
       order by m.seq desc limit 1
    ) lm on true
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
$function$

;

revoke all on function public.message_inbox(text) from anon, authenticated;
grant execute on function public.message_inbox(text) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- The mirror in step with what it mirrors
--
-- Nothing to correct as it turns out: the sweep has not run against production
-- yet, so every mirrored row still agrees with its source and the fifteen
-- texts sitting on 'Queued' are honestly described. The re-derivation stays
-- because the next status word added to `sms_messages` will land here the same
-- way, and because a mirror whose only correct value is what it mirrors should
-- be put back in step rather than asked about.

do $$
declare v_fixed integer; v_media integer;
begin
  update public.messages m
     set status = case s.status
                    when 'Received' then 'received'
                    when 'Sent' then 'sent'
                    when 'Failed' then 'failed'
                    when 'Not delivered' then 'failed'
                    else 'queued' end
    from public.sms_messages s
   where s.id = m.source_sms_id
     and m.status <> case s.status
                       when 'Received' then 'received'
                       when 'Sent' then 'sent'
                       when 'Failed' then 'failed'
                       when 'Not delivered' then 'failed'
                       else 'queued' end;
  get diagnostics v_fixed = row_count;

  update public.messages m
     set media_url = s.media_url, media_type = s.media_type
    from public.sms_messages s
   where s.id = m.source_sms_id and s.media_url is not null and m.media_url is null;
  get diagnostics v_media = row_count;

  raise notice 'ok  % mirrored text(s) brought back into step, % picture(s) carried across', v_fixed, v_media;

  if exists (
    select 1 from public.messages m join public.sms_messages s on s.id = m.source_sms_id
     where m.status = 'queued' and s.status in ('Not delivered', 'Failed')
  ) then
    raise exception 'a text the practice gave up on still reads as going in the inbox';
  end if;
  raise notice 'ok  no text the practice gave up on reads as going';
end $$;

-- The inbox is asked for the five things it was missing. A column that is not
-- there is an error rather than a null, which is the point of asking this way
-- rather than reading the catalogue: the catalogue would say the column exists
-- while the select list had dropped it.

do $$
declare r record;
begin
  for r in select last_sender_kind, last_sender, last_status, last_media_url, last_media_type
             from public.message_inbox('texts') limit 1
  loop
    null;
  end loop;
  raise notice 'ok  the inbox is told the direction, the sender, the status and the picture';
end $$;
