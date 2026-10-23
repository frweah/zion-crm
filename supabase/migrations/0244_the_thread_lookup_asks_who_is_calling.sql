-- Zion Vocational Rehab CRM — 0244 the thread lookup asks who is calling
--
-- `client_for_thread` (0233) is security definer and granted to anybody
-- signed in, and checked nothing. `verify_portal_rls` named it, which is the
-- whole point of that script: every elevated function enforces the rule its
-- screen does, and a new one that does not is a failure rather than an
-- oversight somebody might notice.
--
-- It is a read rather than a write, and what it reads is small - which client
-- a conversation is filed on - but "small" is not a rule. Handed an Outlook
-- conversation id it answers which client that correspondence belongs to, and
-- that is a fact about a client, answered with the table's own privileges and
-- not the caller's.
--
-- It cannot simply be revoked, because a person's own mail sync calls it with
-- their session: a reply landing in their mailbox on a thread they filed has
-- to find its way home. So it asks the question `reader_may_answer` was
-- written for (0230) - the sweep and the server answer yes because there is
-- nobody signed in to check, a member of staff answers yes because they are
-- one, and anybody else gets nothing.

create or replace function public.client_for_thread(p_conversation text)
returns uuid
language plpgsql stable security definer set search_path = public as $$
declare
  v_client uuid;
begin
  if not public.reader_may_answer() then
    return null;
  end if;

  select m.client_id into v_client
    from public.mail_log m
   where m.conversation_id = p_conversation
     and m.client_id is not null
     and m.unfiled_at is null
   order by m.sent_at desc
   limit 1;

  return v_client;
end;
$$;

comment on function public.client_for_thread is
  'Which client a thread is already filed on, for staff and for the sweep. Nobody else gets an answer (0244).';

revoke all on function public.client_for_thread(text) from anon, authenticated;
grant execute on function public.client_for_thread(text) to authenticated;
