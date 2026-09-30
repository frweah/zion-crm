-- Zion Vocational Rehab CRM — a client's text that nobody answered
--
-- The dashboard shows each person what is waiting for them, which works right
-- up until somebody is away, or busy, or simply does not open the CRM that
-- day. Then a client's message sits there and the only thing standing between
-- it and next week is that somebody happens to look.
--
-- So it escalates, on the owner's rule (30 Sept 2026):
--
--   Two business days with no answer: a task for whoever works that client's
--   job search, on their own list, like any other task.
--
--   Five: it goes to the Admin's dashboard as well, because at that point it
--   is no longer one person's oversight.
--
-- Business days, not days: a text arriving on Friday afternoon is not late on
-- Sunday, and treating it as late is how an alert becomes something people
-- learn to ignore.
--
-- Only texts from clients, and only where the last word was theirs. A
-- conversation where we answered and they have not replied is not waiting on
-- us, and a website chat from a stranger has nobody to assign it to.

/** Whole business days between two moments, counting neither weekend day. */
create or replace function public.business_days_between(p_from timestamptz, p_to timestamptz)
returns integer language sql immutable as $$
  select greatest(0, count(*)::integer - 1)
    from generate_series(date_trunc('day', p_from), date_trunc('day', p_to), interval '1 day') d
   where extract(isodow from d) < 6;
$$;
revoke execute on function public.business_days_between(timestamptz, timestamptz) from public, anon;
grant execute on function public.business_days_between(timestamptz, timestamptz) to authenticated, service_role;

/**
 * Every client text still waiting on us, with how many business days it has
 * been waiting and whose it is.
 *
 * A conversation counts as waiting when its most recent message came from the
 * client. Nothing here asks whether anybody read it: reading a message is not
 * answering it, and the client cannot tell the difference.
 */
create or replace view public.texts_unanswered
with (security_invoker = true) as
  with last_message as (
    select distinct on (m.conversation_id)
           m.conversation_id, m.sender_kind, m.created_at, m.body
      from public.messages m
     where m.removed_at is null
     order by m.conversation_id, m.seq desc
  )
  select c.id as conversation_id,
         c.client_id,
         cl.name as client_name,
         coalesce(c.assigned_staff_id, cl.assigned_staff_id) as owed_by,
         lm.created_at as waiting_since,
         public.business_days_between(lm.created_at, now()) as business_days,
         left(lm.body, 120) as last_body
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
  'Client texts whose last word was the client''s (0130), with how many business days they have been waiting and who owes the answer.';

/**
 * Raises the task at two business days, and the Admin's alert at five.
 *
 * Both are idempotent: the task carries the conversation as its source, so a
 * second night does not raise a second task, and the alert is resolved by the
 * existing sweep once the conversation is answered.
 */
create or replace function public.escalate_unanswered_texts(p_today date)
returns integer language plpgsql security definer set search_path = public as $$
declare r record; v_made integer := 0; v_admin uuid;
begin
  for r in select * from public.texts_unanswered where business_days >= 2 loop
    if r.owed_by is not null and not exists (
      select 1 from public.tasks t
       where t.source_kind = 'text_unanswered' and t.source_match_id = r.conversation_id and t.status = 'Open'
    ) then
      insert into public.tasks (client_id, assigned_staff_id, title, due, status, system_generated, source_kind, source_match_id)
      values (r.client_id, r.owed_by,
              r.client_name || ' texted ' || r.business_days || ' business days ago and has had no answer',
              p_today, 'Open', true, 'text_unanswered', r.conversation_id);
      v_made := v_made + 1;
    end if;

    -- Five days is no longer one person's oversight.
    if r.business_days >= 5 and not exists (
      select 1 from public.notifications n
       where n.kind = 'text_unanswered' and n.client_id = r.client_id and n.resolved_at is null
    ) then
      insert into public.notifications (kind, level, text, roles, href, client_id)
      values ('text_unanswered', 'bad',
              r.client_name || ' has been waiting ' || r.business_days || ' business days for an answer to a text',
              array['Admin'],
              '/clients/' || r.client_id || '?tab=messages',
              r.client_id);
      v_made := v_made + 1;
    end if;
  end loop;

  -- Answered since: the alert goes when the waiting does.
  update public.notifications n
     set resolved_at = now()
   where n.kind = 'text_unanswered' and n.resolved_at is null
     and not exists (select 1 from public.texts_unanswered u where u.client_id = n.client_id and u.business_days >= 5);

  update public.tasks t
     set status = 'Done', done_at = now()
   where t.source_kind = 'text_unanswered' and t.status = 'Open'
     and not exists (select 1 from public.texts_unanswered u where u.conversation_id = t.source_match_id);

  return v_made;
end;
$$;
revoke execute on function public.escalate_unanswered_texts(date) from public, anon, authenticated;
grant execute on function public.escalate_unanswered_texts(date) to service_role;
