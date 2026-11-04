-- A text that never went says so
--
-- Fifteen outgoing texts were sitting at 'Queued' on 3 November 2026, the
-- oldest from 29 October, and exactly one text had ever reached 'Sent'. None
-- of the fifteen recorded an error. That last part is what says what happened.
--
-- `sendClientSms` inserts the row as 'Queued', calls GoHighLevel, and then
-- marks the row 'Sent' or 'Failed'. Every GoHighLevel call is wrapped so that
-- an error comes back as a value rather than an exception, so a refusal would
-- have been recorded as 'Failed' with the message. **A hang is not an error.**
-- The fetch had no timeout, so when GoHighLevel stopped answering the call
-- waited, the serverless function was killed at its own time limit, and
-- neither the 'Sent' update nor the 'Failed' update ever ran. The row stayed
-- 'Queued' for ever, and the screen showed it as still going.
--
-- The timeout is in lib/ghl.ts, where the cause is. This file is the other
-- half: what the record says about a text nobody can account for.
--
--   'Not delivered' - the status a text gets when five minutes have passed
--   and nothing has come back. Not 'Failed', which means the provider refused
--   it and said why; this means nobody knows, and the two are different things
--   to a person deciding whether to text again.
--
--   A sweep that sets it, says so to whoever sent it, and leaves the message
--   where it is so it can be retried.
--
--   Retry, which re-sends **the same row** - and is refused once
--   GoHighLevel has given the message an id, because that means it accepted
--   it and a retry would be the client's phone buzzing twice.
--
-- **And the honest limit, which the owner asked about:** nothing in this
-- system receives a delivery status from GoHighLevel. `/api/sms/inbound`
-- handles inbound messages only. An outgoing text's status is set by the code
-- that sent it, at the moment it sent it, and never updated again. So "not
-- delivered" here means "we sent it and heard nothing", not "the carrier
-- rejected it" - and that is exactly what the words say.

-- ─────────────────────────────────────────────────────────────
-- A picture in a text
--
-- Stored as the URL GoHighLevel gives, not copied: the media sits on their
-- side with their retention, and a copy here would be a second place a
-- client's photograph lives (1b).
-- ─────────────────────────────────────────────────────────────
alter table public.sms_messages
  add column if not exists media_url text,
  add column if not exists media_type text;

comment on column public.sms_messages.media_url is
  'The provider URL for a picture sent or received with this text. Referenced, never copied (0280).';

-- ─────────────────────────────────────────────────────────────
-- The status a text gets when nobody knows
-- ─────────────────────────────────────────────────────────────
alter table public.sms_messages drop constraint if exists sms_messages_status_check;
alter table public.sms_messages add constraint sms_messages_status_check
  check (status in (
    'Queued',        -- written, not yet handed to the provider
    'Scheduled',     -- waiting for the window
    'Sending',       -- claimed by the sender
    'Sent',          -- the provider took it
    'Failed',        -- the provider refused it, and `error` says why
    'Not delivered', -- five minutes passed and nothing came back (0280)
    'Received'       -- inbound
  ));

/**
 * How long a text may sit before the practice stops believing in it.
 *
 * Five minutes, which is the owner's figure. One function rather than the
 * number written in three places, because the sweep, the screen and the
 * verification script all have to mean the same five minutes.
 */
create or replace function public.text_lapse_minutes()
returns integer language sql immutable as $$ select 5 $$;

revoke all on function public.text_lapse_minutes() from anon, authenticated;
grant execute on function public.text_lapse_minutes() to authenticated;

-- ─────────────────────────────────────────────────────────────
-- The sweep
--
-- Says so to whoever wrote the text, because they are the person who thinks
-- it went. One notification per message, keyed on the message, so a sweep
-- every quarter hour does not say it four times an hour.
-- ─────────────────────────────────────────────────────────────
create or replace function public.mark_texts_not_delivered()
returns integer
language plpgsql security definer set search_path = public as $$
declare
  r      record;
  v_n    integer := 0;
  v_name text;
begin
  for r in
    select m.id, m.client_id, m.created_by, m.phone, c.name as client_name
      from public.sms_messages m
      left join public.clients c on c.id = m.client_id
     where m.direction = 'Outgoing'
       and m.status in ('Queued', 'Sending')
       -- A scheduled text that has not reached its window is not late.
       and (m.send_after is null or m.send_after <= now())
       and m.created_at < now() - (public.text_lapse_minutes() || ' minutes')::interval
  loop
    update public.sms_messages
       set status = 'Not delivered',
           -- The provider's own words where there are any; otherwise the
           -- plain truth, which is that nothing came back.
           error = case when coalesce(error, '') <> '' then error
                        else 'no status received from GHL' end
     where id = r.id;

    v_n := v_n + 1;

    if r.created_by is not null then
      select name into v_name from public.staff where id = r.created_by;
      perform public.notify_person(
        r.created_by,
        'text_not_delivered',
        format('The text to %s was not delivered. Nothing came back from the provider. Open it to retry.',
               coalesce(nullif(r.client_name, ''), r.phone)),
        r.id::text,
        case when r.client_id is not null
             then '/clients/' || r.client_id || '?tab=messages'
             else '/messages/texts?tab=texts' end,
        r.client_id,
        null, null, 'warn', null
      );
    end if;
  end loop;

  return v_n;
end $$;

comment on function public.mark_texts_not_delivered is
  'Marks an outgoing text Not delivered once text_lapse_minutes has passed with nothing back, and tells whoever sent it. Called by /api/cron/scheduled-texts (0280).';

revoke all on function public.mark_texts_not_delivered() from anon, authenticated;

-- ─────────────────────────────────────────────────────────────
-- Retrying one
--
-- The same row, put back to 'Queued' for the sender to pick up. Never a second
-- row: two rows would be two texts on the client's record for one thing
-- somebody said once, and the contact log would be wrong about what the
-- practice sent.
--
-- Refused once GoHighLevel has given the message an id. That id means it took
-- the message, so whatever happened afterwards, sending it again is the
-- client's phone buzzing twice - and this system is never told about delivery,
-- so an id is the strongest evidence of acceptance it will ever have.
-- ─────────────────────────────────────────────────────────────
create or replace function public.retry_text(p_id uuid)
returns uuid
language plpgsql security definer set search_path = public as $$
declare m public.sms_messages;
begin
  if not public.is_active_staff() then
    raise exception 'Only staff retry a text.' using errcode = 'insufficient_privilege';
  end if;

  select * into m from public.sms_messages where id = p_id;
  if m.id is null then
    raise exception 'That text is not there.' using errcode = 'no_data_found';
  end if;
  if m.direction <> 'Outgoing' then
    raise exception 'That is a text that came in. There is nothing to retry.'
      using errcode = 'check_violation';
  end if;
  if m.status = 'Sent' then
    raise exception 'That text went. Write a new one if it needs saying again.'
      using errcode = 'check_violation';
  end if;
  if coalesce(m.provider_message_id, '') <> '' then
    raise exception 'The provider took that message, so sending it again would text them twice. Write a new one instead.'
      using errcode = 'check_violation';
  end if;
  if m.status not in ('Not delivered', 'Failed') then
    raise exception 'That text has not been given up on yet. Wait for it, or it will say so in a few minutes.'
      using errcode = 'check_violation';
  end if;

  -- Back to the start, and the clock with it: the five minutes are counted
  -- from when it was last tried, not from when it was written.
  update public.sms_messages
     set status = 'Queued', error = '', claimed_at = null, created_at = now()
   where id = p_id;

  return p_id;
end $$;

revoke all on function public.retry_text(uuid) from anon, authenticated;
grant execute on function public.retry_text(uuid) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- A thread is somebody's
--
-- `assign_conversation` has existed since 0104 and twelve of the twenty-four
-- texting threads had an assignee. What was missing is the default: a thread
-- about a client belongs to whoever that client belongs to, unless somebody
-- says otherwise (1e).
--
-- A trigger rather than a line in the screen that opens a thread, so it holds
-- for a text arriving at two in the morning as well.
-- ─────────────────────────────────────────────────────────────
create or replace function public.thread_follows_the_client()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.assigned_staff_id is null and new.client_id is not null then
    select c.assigned_staff_id into new.assigned_staff_id
      from public.clients c where c.id = new.client_id;
  end if;
  return new;
end $$;

drop trigger if exists conversations_follow_the_client on public.conversations;
create trigger conversations_follow_the_client
  before insert on public.conversations
  for each row execute function public.thread_follows_the_client();

-- The threads already on file that never got one. Not a guess: it is the same
-- rule the trigger applies, applied once to the rows that predate it.
update public.conversations c
   set assigned_staff_id = cl.assigned_staff_id
  from public.clients cl
 where c.client_id = cl.id
   and c.assigned_staff_id is null
   and cl.assigned_staff_id is not null;

-- ─────────────────────────────────────────────────────────────
-- What the sweep would do now
-- ─────────────────────────────────────────────────────────────
do $$
declare v_waiting integer; v_assigned integer; v_total integer;
begin
  select count(*) into v_waiting from public.sms_messages
   where direction = 'Outgoing' and status in ('Queued', 'Sending')
     and (send_after is null or send_after <= now())
     and created_at < now() - (public.text_lapse_minutes() || ' minutes')::interval;

  select count(*) filter (where assigned_staff_id is not null), count(*)
    into v_assigned, v_total
    from public.conversations where client_id is not null;

  raise notice 'ok  % outgoing texts are past the five minutes and will be marked Not delivered', v_waiting;
  raise notice 'ok  % of % threads about a client now have an assignee', v_assigned, v_total;
end $$;
