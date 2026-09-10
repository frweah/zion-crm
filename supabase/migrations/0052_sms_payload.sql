-- ─────────────────────────────────────────────────────────────
-- 0052 — keep what the carrier actually sent
--
-- The live test turned up a small hole. Our reminders record GoHighLevel's
-- message id, so a text can be traced back to their record of it. Replies do
-- not: provider_message_id came back null on both real inbound messages,
-- because the id is not under any of the names the webhook looks for.
--
-- The reason that was hard to fix is the point of this migration. The payload
-- was read, acted on and thrown away, so answering "what does their webhook
-- actually send?" meant asking somebody to text us and watching. That is not
-- a debugging method, it is a favour.
--
-- So the body is kept. The first real reply in production settles the mapping
-- from evidence, and any future change to their payload is diagnosable from
-- the row it arrived on rather than from a guess.
-- ─────────────────────────────────────────────────────────────
alter table public.sms_messages
  add column if not exists provider_payload jsonb;

comment on column public.sms_messages.provider_payload is
  'What the provider posted, verbatim, for an incoming message. Kept so a field that moves can be found rather than guessed at.';

-- ─────────────────────────────────────────────────────────────
-- The webhook hands over the whole thing
--
-- The extra argument has a default, so nothing that calls the three-argument
-- version breaks — including verify_sms.sql, which is how this function is
-- exercised.
-- ─────────────────────────────────────────────────────────────
create or replace function public.record_incoming_sms(
  p_phone       text,
  p_body        text,
  p_provider_id text default null,
  p_payload     jsonb default null
)
returns table (client_id uuid, action text)
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
                                   provider_message_id, provider_payload, status, sent_at)
  values (v_client, 'Incoming', v_phone, coalesce(p_body, ''), 'Reply',
          p_provider_id, p_payload, 'Received', now());

  -- The keywords carriers require, plus the ones people actually send.
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
end;
$$;

-- Nobody signed in may call either shape: a person with a browser must not be
-- able to withdraw somebody else's consent, or fake a reply into their
-- timeline. Only the webhook, as the service role, behind a shared secret.
revoke execute on function public.record_incoming_sms(text, text, text, jsonb) from public;
revoke execute on function public.record_incoming_sms(text, text, text, jsonb) from authenticated;
revoke execute on function public.record_incoming_sms(text, text, text, jsonb) from anon;
grant execute on function public.record_incoming_sms(text, text, text, jsonb) to service_role;

-- The three-argument version is gone: two functions of the same name, one of
-- them missing the payload, is a way to keep the hole open by accident.
drop function if exists public.record_incoming_sms(text, text, text);
