-- Zion Vocational Rehab CRM — the waiting list does not carry what was said
--
-- texts_unanswered (0130) included the last message's text, for no better
-- reason than that it might be useful on a screen one day. The practice's own
-- rule is that a message body is kept in exactly one place and copied into
-- none, and the test that enforces it said so the first time it ran.
--
-- Nothing read the column. What the escalation needs is who is waiting and
-- for how long, and a task that says "X texted four business days ago and has
-- had no answer" is a better task than one quoting half a sentence out of
-- context anyway.

-- Dropped rather than replaced: a view cannot lose a column in place, and
-- this one is losing the column on purpose.
drop view if exists public.texts_unanswered;

create view public.texts_unanswered
with (security_invoker = true) as
  with last_message as (
    select distinct on (m.conversation_id)
           m.conversation_id, m.sender_kind, m.created_at
      from public.messages m
     where m.removed_at is null
     order by m.conversation_id, m.seq desc
  )
  select c.id as conversation_id,
         c.client_id,
         cl.name as client_name,
         coalesce(c.assigned_staff_id, cl.assigned_staff_id) as owed_by,
         lm.created_at as waiting_since,
         public.business_days_between(lm.created_at, now()) as business_days
    from public.conversations c
    join last_message lm on lm.conversation_id = c.id
    join public.clients cl on cl.id = c.client_id
   where c.kind = 'sms'
     and c.archived_at is null
     and not coalesce(c.spam, false)
     and cl.merged_into is null
     and lm.sender_kind = 'client';

grant select on public.texts_unanswered to authenticated;

comment on view public.texts_unanswered is
  'Client texts whose last word was the client''s (0130, 0133): who is waiting, since when, and whose answer it is. Never what was said.';
