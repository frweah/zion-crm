-- GoHighLevel says what happened to the text
--
-- Until now the practice learned one thing about an outgoing text: whether
-- GoHighLevel accepted it. Accepting it is not delivering it, and nothing ever
-- came back afterwards - so 'Delivered' was unknowable and a text that the
-- carrier dropped an hour later went on reading as sent. The only thing that
-- told the difference was the five-minute sweep (0280), and a sweep measures
-- silence rather than hearing an answer.
--
-- This is the other half: the provider's own status, taken on a webhook and
-- written against the receipt it gave when it took the message. `0286` added
-- the word 'Delivered' for exactly this.
--
-- Nothing is trusted from the body except the receipt and the status word.
-- There is no client in it and no phone number in it: a webhook that could
-- name a client would be a way to write on somebody's record by HTTP, and the
-- receipt already says which row this is about.
--
-- **A status never goes backwards.** 'Delivered' is the end of the story -
-- the phone has it, and nothing a provider says later makes that untrue. Below
-- it, a later word wins, because a carrier reporting a drop twenty minutes on
-- is telling the practice something it needs. Without that rule a retried
-- message's own callbacks would arrive out of order and the last one to land
-- would decide, which is how a delivered text ends up offering Retry.

create or replace function public.record_text_status(
  p_provider_id text,
  p_status      text,
  p_error       text default null,
  p_payload     jsonb default null
)
returns table(matched boolean, status text)
language plpgsql security definer set search_path = public as $$
declare
  m        public.sms_messages;
  v_word   text := lower(btrim(coalesce(p_status, '')));
  v_status text;
begin
  if coalesce(btrim(coalesce(p_provider_id, '')), '') = '' then
    raise exception 'That status has no message id on it, so there is nothing to put it against.'
      using errcode = 'check_violation';
  end if;

  -- The provider's words, in ours. Anything unrecognised is not guessed at:
  -- a word nobody has seen before must not quietly read as a failure and
  -- tell somebody a text did not go.
  v_status := case
    when v_word in ('delivered', 'read') then 'Delivered'
    when v_word in ('sent', 'accepted', 'queued', 'pending', 'scheduled') then 'Sent'
    when v_word in ('failed', 'undelivered', 'error', 'rejected', 'bounced') then 'Failed'
    else null
  end;

  if v_status is null then
    return query select false, format('GoHighLevel said %L, which this does not know', v_word)::text;
    return;
  end if;

  select * into m from public.sms_messages
   where provider_message_id = p_provider_id and direction = 'Outgoing'
   order by created_at desc limit 1;

  -- A status for a message the practice has no row for is not an error. It is
  -- a text sent from GoHighLevel's own screens, and a 400 here would have the
  -- provider retrying it for ever.
  if m.id is null then
    return query select false, 'no text on file carries that receipt'::text;
    return;
  end if;

  if m.status = 'Delivered' then
    return query select true, m.status;
    return;
  end if;

  update public.sms_messages
     set status = v_status,
         sent_at = coalesce(sent_at, now()),
         error = case when v_status = 'Failed'
                      then left(coalesce(nullif(btrim(coalesce(p_error, '')), ''),
                                         'GoHighLevel reported the message failed.'), 300)
                      else '' end,
         provider_payload = coalesce(p_payload, provider_payload)
   where id = m.id;

  return query select true, v_status;
end $$;

revoke all on function public.record_text_status(text, text, text, jsonb) from anon, authenticated;

-- Only the webhook, which runs as the service role. Nothing on a screen has
-- any business saying what a carrier reported.

do $$
declare v_n integer;
begin
  select count(*) into v_n from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'record_text_status';
  if v_n <> 1 then
    raise exception 'record_text_status exists at % signatures, not one', v_n;
  end if;

  select count(*) into v_n from information_schema.routine_privileges
   where routine_schema = 'public' and routine_name = 'record_text_status'
     and grantee in ('anon', 'authenticated');
  if v_n <> 0 then
    raise exception 'record_text_status can be called from a browser';
  end if;

  raise notice 'ok  one signature, and the browser cannot call it';
end $$;
