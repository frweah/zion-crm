-- Zion Vocational Rehab CRM — 0235 one writer, not two
--
-- 0234 added `p_filed_how text default null` to the four mail writers and
-- believed it was replacing them. It was not. A new parameter is a new
-- signature, so `create or replace` created a second function beside each
-- original and left the originals in place. Two things went wrong at once.
--
-- The first is ambiguity: a call that names the ten original arguments now
-- matches both the ten-argument function and the eleven-argument one whose
-- last argument defaults, and Postgres is entitled to refuse it as not
-- unique. The sweep would have started failing on the next deploy.
--
-- The second is worse and is the reason this is its own migration rather than
-- a tidy-up. `log_mail_message_internal`, `log_mail_message_for_sync` and
-- `log_shared_mail_message` were deliberately never granted to
-- `authenticated`: they are the writers the sweep uses, they take a staff id
-- or a mailbox as an argument, and a signed-in person who could call them
-- directly could file mail as somebody else. A new function starts with
-- EXECUTE to PUBLIC, so all three arrived wide open. This revokes them, which
-- is the same explicit revoke the whole elevated-function sweep put on every
-- other writer, and the lesson is the one that sweep already wrote down: a
-- new signature is a new function, with a new function's default grant.

-- The originals go. Nothing calls them any more - each wrapper was replaced
-- in place and calls the eleven-argument internal - and leaving them is what
-- makes the call ambiguous.
drop function if exists public.log_mail_message(uuid, uuid, text, text, text, timestamptz, text, text, text);
drop function if exists public.log_mail_message_for_sync(uuid, uuid, uuid, text, text, text, timestamptz, text, text, text);
drop function if exists public.log_shared_mail_message(text, uuid, uuid, text, text, text, timestamptz, text, text, text);
drop function if exists public.log_mail_message_internal(uuid, text, uuid, uuid, text, text, text, timestamptz, text, text, text);

-- Three of the four are for the sweep and for the screen's own server code,
-- which runs as `service_role`. Nobody signed in calls them.
revoke all on function public.log_mail_message_internal(uuid, text, uuid, uuid, text, text, text, timestamptz, text, text, text, text)
  from anon, authenticated;
revoke all on function public.log_mail_message_for_sync(uuid, uuid, uuid, text, text, text, timestamptz, text, text, text, text)
  from anon, authenticated;
revoke all on function public.log_shared_mail_message(text, uuid, uuid, text, text, text, timestamptz, text, text, text, text)
  from anon, authenticated;

-- The fourth is the one a person's own sync calls, and it takes no staff id:
-- it asks who is calling. That one stays open to a signed-in member of staff,
-- which is what it was before 0234.
revoke all on function public.log_mail_message(uuid, uuid, text, text, text, timestamptz, text, text, text, text)
  from anon, authenticated;
grant execute on function public.log_mail_message(uuid, uuid, text, text, text, timestamptz, text, text, text, text)
  to authenticated;
