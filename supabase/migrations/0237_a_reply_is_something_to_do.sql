-- Zion Vocational Rehab CRM — 0237 a reply is something to do
--
-- `tasks.source_kind` is a closed list, which is the right shape for it: a My
-- day item that came from nowhere nameable is an item nobody can trace back.
-- But it means every new source of work has to be added to the list, and 0236
-- added one without saying so - the first reply to file itself would have
-- raised the notification and then failed on the task.
--
-- It failed loudly rather than quietly, which is the constraint doing its
-- job. This adds the word.

alter table public.tasks drop constraint if exists tasks_source_kind_check;
alter table public.tasks add constraint tasks_source_kind_check
  check (source_kind = any (array[
    'Interview prep', 'Interview day', 'Follow-up',
    'billing_item', 'text_unanswered', 'intake',
    'authorization_received', 'authorization_missing', 'authorization_ending',
    'placement_authorization', 'portal_upload', 'portal_resume',
    'mail_reply'
  ]));

-- The trigger function is elevated like every other writer, and a function
-- that returns `trigger` cannot be reached over the API - but "cannot be
-- reached" is an argument about today's API and not a grant, so it is
-- revoked explicitly like the rest.
revoke all on function public.mail_reply_notifies() from anon, authenticated;
