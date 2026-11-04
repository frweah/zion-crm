-- The fifteen, as they actually went
--
-- Fifteen outgoing texts sat on 'Queued' with no error. The cause was 0285 -
-- no permissive UPDATE policy, so the update that records a send matched no
-- rows and reported success - which means the record says nothing at all about
-- what happened to them. It was not a GoHighLevel outage.
--
-- GoHighLevel was asked, read-only, contact by contact, matching each row
-- against the outbound messages it holds within two minutes of the row being
-- written and on the same number. Its answer:
--
--   * **eleven delivered**, each with the provider's own message id;
--   * **three failed**, all three with the same reason in its words,
--     "Unable to send message, please contact support!";
--   * **one it has no record of at all** - nothing outbound anywhere on the
--     location within two minutes of it. The send never reached the provider,
--     and the reason it gave at the time was lost with the update that would
--     have saved it.
--
-- Each row keeps whoever wrote it. Eleven of these reached the client, so
-- anything sent by hand afterwards reached them twice; that is a fact about
-- the past and it is recorded as what it is rather than tidied into
-- "Sent by hand".
--
-- **'Delivered' is a new status.** The practice has only ever been able to say
-- 'Sent', which means the provider accepted it - a different claim from the
-- client's phone having it. GoHighLevel distinguishes the two and these eleven
-- are the stronger word, so the word exists now. The mirror in `messages`
-- already had 'delivered' and was never given anything to map onto it; it is
-- mapped here. Nothing else is re-labelled: every text already recorded as
-- 'Sent' stays 'Sent', because 'Sent' is all that was known about it.

alter table public.sms_messages drop constraint if exists sms_messages_status_check;
alter table public.sms_messages add constraint sms_messages_status_check
  check (status in ('Queued', 'Scheduled', 'Sending', 'Sent', 'Delivered',
                    'Failed', 'Not delivered', 'Received'));

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

-- ─────────────────────────────────────────────────────────────
-- The fifteen
--
-- Written as a table of what the provider said rather than fifteen update
-- statements, so the evidence and the write are the same thing and anybody
-- reading this file can check one against the other.

do $$
declare
  r record;
  v_done integer := 0;
  v_delivered integer := 0;
  v_failed integer := 0;
begin
  for r in
    select * from (values
    ('192e4072-cc08-4566-b835-5c28f144c700'::uuid, 'Delivered'::text, 'zwsTrZXJffeFupswUKIS'::text, '2026-10-29T21:35:15.478Z'::timestamptz, ''::text),
    ('437ab194-136f-474a-9e7b-321308023569', 'Delivered', '4OlqFELgGS2Fwu8hiCdV', '2026-10-29T21:55:23.966Z', ''),
    ('9837b6bb-b559-473a-a6a4-28132d321b6a', 'Delivered', 'Lao4qyWwMY39xhj9ZE0w', '2026-10-30T01:23:48.687Z', ''),
    ('7f15941e-1304-4b85-8c71-39ad4ce11139', 'Delivered', '4ZEniaV2LHODanZEEWbG', '2026-11-02T21:29:59.396Z', ''),
    ('fa9faec0-1058-44fd-84b8-fc2f54baafc5', 'Failed', 'poiSzRHPUiO7rA08YQKR', '2026-11-03T18:37:11.400Z', 'Unable to send message, please contact support! (GoHighLevel)'),
    ('4c13d035-790f-4b09-85c8-ef3044eca32b', 'Failed', 'xOwcagn83b3vgQFJjOuc', '2026-11-03T18:51:19.513Z', 'Unable to send message, please contact support! (GoHighLevel)'),
    ('39b6b2f6-1712-4279-9f59-bdf193d87a2c', 'Failed', '9D3k04xEGniHDP8ehd5T', '2026-11-03T19:40:23.592Z', 'Unable to send message, please contact support! (GoHighLevel)'),
    ('d1c33e9c-f62f-4fc4-982f-32d939dc66ef', 'Failed', null, null, 'GoHighLevel has no record of this message, and the reason it gave at the time was not saved.'),
    ('b4461d38-35a2-436a-a9bc-62679ff43232', 'Delivered', '3c81uC2wa15c6eJHj1SN', '2026-11-03T20:46:30.102Z', ''),
    ('c3634f06-604f-4172-9fa0-df240d0ec4a0', 'Delivered', 'fO1vL9atYVjw8feDWfuv', '2026-11-03T20:46:58.564Z', ''),
    ('c92b99f7-567f-495d-b35e-db6967dafce5', 'Delivered', 'RIg5oSbLuDy6Jhk6xqhA', '2026-11-03T20:47:09.124Z', ''),
    ('802e4b9a-c02c-4345-847f-0ddba43b3aa7', 'Delivered', '4S6fe5eeK7ya4HaXqaju', '2026-11-03T20:47:27.173Z', ''),
    ('c3baf7cc-bdbd-4104-a215-edff7349b6c9', 'Delivered', 'ClOQSu1BSmhKOwM0vNfP', '2026-11-03T21:44:37.064Z', ''),
    ('4c4876ff-14f7-4676-a1fb-315e9896f40f', 'Delivered', 'GhX7cS0idKzV9vPpzAHy', '2026-11-03T23:08:17.913Z', ''),
    ('99ca0ddf-1db3-48bd-99d6-65957a452ed0', 'Delivered', 'phq0OQIm9MJPYW7ngLP1', '2026-11-03T23:26:11.471Z', '')
    ) as t(id, status, provider, at, why)
  loop
    -- Only a row still sitting on 'Queued'. If anything has happened to one
    -- since this was worked out - a retry, a hand correction - that is newer
    -- than this file and it is left alone.
    update public.sms_messages m
       set status = r.status,
           provider_message_id = coalesce(r.provider, m.provider_message_id),
           sent_at = coalesce(r.at, m.sent_at),
           error = r.why
     where m.id = r.id and m.status = 'Queued';

    if found then
      v_done := v_done + 1;
      if r.status = 'Delivered' then v_delivered := v_delivered + 1; else v_failed := v_failed + 1; end if;
    end if;
  end loop;

  raise notice 'ok  % text(s) recorded as they actually went: % delivered, % failed',
    v_done, v_delivered, v_failed;

  if exists (select 1 from public.sms_messages
              where direction = 'Outgoing' and status = 'Queued'
                and created_at < now() - interval '1 hour') then
    raise notice 'note  an outgoing text over an hour old is still on Queued, so something arrived after this file was written';
  end if;

  -- Nothing the provider delivered may be left looking retryable: Retry is
  -- offered on 'Not delivered' and 'Failed' only, and every delivered one now
  -- carries the provider's receipt as well, which refuses a retry on its own.
  if exists (select 1 from public.sms_messages
              where status = 'Delivered' and coalesce(provider_message_id, '') = '') then
    raise exception 'a text recorded as delivered has no receipt from the provider';
  end if;
  raise notice 'ok  every delivered text carries the provider''s receipt, so none can be sent twice';
end $$;
