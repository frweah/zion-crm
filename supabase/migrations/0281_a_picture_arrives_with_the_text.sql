-- A picture arrives with the text
--
-- An inbound picture message already reached the record: the provider's whole
-- payload is kept verbatim on the row, so the URL was in
-- `sms_messages.provider_payload` all along. It was in no column anything
-- read, so no screen could show it, and a client who sent a photograph of a
-- pay stub appeared to have sent an empty text.
--
-- So the URL comes out into `media_url` (0280 added the column) and the route
-- that takes the webhook picks it out of the payload with the same reader it
-- uses for the phone number and the body.
--
-- **Referenced, never copied.** The media stays on the provider's side with
-- the provider's retention. A copy here would be a second place a client's
-- photograph lives, and the practice would then owe it the same retention and
-- the same records-request answer as everything else on the record. If the
-- practice ever wants the picture kept, that is a decision to take out loud
-- and it goes through "File to client" like any other document.
--
-- Dropped and recreated rather than given two defaulted parameters, for the
-- usual reason: a defaulted parameter makes a second function and leaves the
-- four-argument calls ambiguous between them.

drop function if exists public.record_incoming_sms(text, text, text, jsonb);

create or replace function public.record_incoming_sms(
  p_phone       text,
  p_body        text,
  p_provider_id text default null,
  p_payload     jsonb default null,
  p_media       text default null,
  p_media_type  text default null
)
returns table(client_id uuid, action text)
language plpgsql security definer set search_path = public as $$
declare
  v_phone  text := public.normalize_phone(p_phone);
  v_client uuid;
  v_word   text := upper(regexp_replace(coalesce(p_body, ''), '[^A-Za-z]', '', 'g'));
  v_action text := 'logged';
begin
  if v_phone is null then
    raise exception 'That is not a phone number we can match: %', p_phone
      using errcode = 'check_violation';
  end if;

  select c.id into v_client
    from public.clients c
   where public.normalize_phone(c.phone) = v_phone
   order by case when c.status = 'Active' then 0 else 1 end, c.created_at
   limit 1;

  -- The message is written down whether or not we know whose it is. A STOP
  -- from a number we cannot place still has to be honoured, and an unmatched
  -- reply is a thing somebody should see rather than lose.
  insert into public.sms_messages (client_id, direction, phone, body, kind,
                                   provider_message_id, provider_payload, status, sent_at,
                                   media_url, media_type)
  values (v_client, 'Incoming', v_phone, coalesce(p_body, ''), 'Reply',
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
  if v_word in ('STOP', 'STOPALL', 'UNSUBSCRIBE', 'CANCEL', 'END', 'QUIT', 'REVOKE', 'OPTOUT') then
    if v_client is not null then
      insert into public.sms_consent_events (client_id, state, phone, method, note)
      values (v_client, 'Withdrawn', v_phone, 'Text reply',
              'Replied ' || v_word || ' — consent withdrawn automatically');
    end if;
    v_action := 'withdrawn';

  elsif v_word in ('START', 'UNSTOP', 'YES', 'OPTIN') then
    -- A person can put themselves back on, and only for the number they sent
    -- from. Anything less would mean a withdrawal that cannot be undone
    -- without ringing the office.
    if v_client is not null then
      insert into public.sms_consent_events (client_id, state, phone, method, note)
      values (v_client, 'Granted', v_phone, 'Text reply',
              'Replied ' || v_word || ' — consent given by text');
    end if;
    v_action := 'granted';
  end if;

  return query select v_client, v_action;
end $$;

revoke all on function public.record_incoming_sms(text, text, text, jsonb, text, text) from anon, authenticated;

-- ─────────────────────────────────────────────────────────────
-- No backfill, and why
--
-- All 238 inbound texts kept their payload, and **not one of them has a
-- media key of any kind** - nothing matching attach, media, image or url
-- anywhere in any of them. No picture message has ever arrived.
--
-- So there is nothing to backfill, and more to the point there is nothing to
-- learn the key name from. A first draft of this file guessed five key names
-- off the shape of other providers (attachments[0], mediaUrl, media_url, …)
-- and backfilled from them, which would have been five guesses dressed as a
-- migration and would have found nothing either way.
--
-- The route finds the URL by **shape** instead - a URL-looking string under a
-- key that reads like media, at any depth - which is the same way that file
-- already finds the phone number and the provider id when the provider moves
-- them. The first real picture message will either be read correctly or will
-- land with its payload kept, which is the position every other field in this
-- webhook is in.

do $$
declare v_media integer; v_in integer; v_sig integer;
begin
  select count(*) filter (where media_url is not null), count(*)
    into v_media, v_in
    from public.sms_messages where direction = 'Incoming';

  select count(*) into v_sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'record_incoming_sms';
  if v_sig <> 1 then
    raise exception 'record_incoming_sms exists at % signatures, not one', v_sig;
  end if;

  raise notice 'ok  % of % inbound texts carry a picture; no picture message has arrived yet', v_media, v_in;
  raise notice 'ok  record_incoming_sms exists once, taking the media as well';
end $$;
