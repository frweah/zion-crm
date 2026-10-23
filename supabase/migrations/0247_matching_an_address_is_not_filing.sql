-- Zion Vocational Rehab CRM — 0247 matching an address is not filing
--
-- 0234 gave the writer `p_filed_how` and defaulted it to **auto**, which
-- conflated two things that are not the same and must never be:
--
--   **matched** - the sweep found a known address in a message and wrote a
--   line about it. Nobody decided anything. This is what the sweep has done
--   since it was built, and it is the thing the owner's rule is about:
--   "nothing in a mailbox is read, scored or stored unless filed".
--
--   **auto** - a reply arrived on a thread a person had filed. Somebody did
--   decide; they decided once, when they filed the thread, and the sweep is
--   honouring that decision rather than making one.
--
-- Because the default was "auto", every address match claimed to be the
-- second. The screen said "filed by the sync, on a thread somebody filed"
-- about mail nobody had ever touched, and - far worse - the trigger that
-- tells two people about a reply fired on all of it. One sweep raised 38
-- notifications and 38 My day items for Margaret and Rei about mail that was
-- not a reply to anything. That is the noise the owner's "nobody else" was
-- written to prevent, arriving through the front door.
--
-- Three changes, and none of them loses a row:
--
--   the word `matched` exists, and is the writer's default;
--   every row already here becomes `matched`, because every one of them is
--     an address match - nothing had been filed by a person at all, so there
--     was no filed thread for any of them to be a reply to;
--   and `client_for_thread` answers only for a thread a **person** filed, so
--     a reply files itself onto a decision somebody made and not onto an
--     address match. Without this the back door stays open: an address match
--     puts a client on a thread, and the next reply to it files as "auto" and
--     notifies, with nobody having chosen anything.
--
-- The 38 items are removed in the same transaction. They are a few minutes
-- old, they are system-generated, and not one of them can be real: there is
-- not a single row in `mail_log` filed by hand or by sending, so there is no
-- filed thread for any reply to have arrived on.

alter table public.mail_log drop constraint if exists mail_log_filed_how_check;
alter table public.mail_log add constraint mail_log_filed_how_check
  check (filed_how is null or filed_how in ('sent', 'auto', 'by hand', 'matched'));

comment on column public.mail_log.filed_how is
  'How it came to be here: "sent" from the CRM, "by hand" when somebody filed it, "auto" as a reply on a thread somebody filed, or "matched" when the sweep recognised an address and nobody decided anything (0247).';

update public.mail_log set filed_how = 'matched' where filed_how = 'auto';

-- The noise, and the My day items that came with it.
delete from public.tasks
 where source_kind = 'mail_reply'
   and system_generated
   and source_ref in (select id from public.mail_log where filed_how = 'matched');
delete from public.notifications
 where kind = 'mail_reply'
   and dedupe_key like 'mail_reply:%'
   and split_part(dedupe_key, ':', 2)::uuid in
       (select id from public.mail_log where filed_how = 'matched');

CREATE OR REPLACE FUNCTION public.log_mail_message_internal(p_staff_id uuid, p_mailbox text, p_client_id uuid, p_counselor_id uuid, p_message_id text, p_conversation_id text, p_subject text, p_sent_at timestamp with time zone, p_direction text, p_counterpart text, p_web_link text, p_filed_how text DEFAULT NULL::text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if p_client_id is null and p_counselor_id is null then
    raise exception 'Mail is logged against a client or a counselor, never on its own.'
      using errcode = 'check_violation';
  end if;
  if p_direction not in ('Incoming', 'Outgoing') then
    raise exception 'A message is Incoming or Outgoing.' using errcode = 'check_violation';
  end if;
  if p_staff_id is null and coalesce(p_mailbox, '') = '' then
    raise exception 'A logged message comes from some mailbox.' using errcode = 'check_violation';
  end if;

  if coalesce(p_conversation_id, '') <> ''
     and exists (select 1 from public.mail_exclusions where conversation_id = p_conversation_id) then
    return false;
  end if;

  insert into public.mail_log (
    staff_id, mailbox_address, client_id, counselor_id, graph_message_id, conversation_id,
    subject, sent_at, direction, counterpart_email, web_link, filed_how, filed_at, filed_by
  )
  values (
    p_staff_id, coalesce(p_mailbox, ''), p_client_id, p_counselor_id, p_message_id,
    coalesce(p_conversation_id, ''), left(coalesce(p_subject, ''), 500), p_sent_at,
    p_direction, coalesce(p_counterpart, ''), coalesce(p_web_link, ''),
    coalesce(nullif(btrim(coalesce(p_filed_how, '')), ''), 'matched'),
    now(),
    -- Only a person filing records a person. The sweep files nobody's
    -- decision but its own, and says so by leaving this null (0234, 0247).
    case when p_filed_how = 'by hand' then public.current_staff_id() else null end
  )
  on conflict (mailbox_key, graph_message_id) do nothing;

  return found;
end;
$function$;

/**
 * Which client a thread is already filed on - by a person.
 *
 * "Filed" means somebody chose: by hand, or by sending the message. An
 * address match is not a choice, and a reply to one must not become one
 * (0247). Unfiled rows do not count either, for the same reason in reverse:
 * taking a thread off a client is also a decision.
 */
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
     and m.filed_how in ('by hand', 'sent', 'auto')
   order by m.sent_at desc
   limit 1;

  return v_client;
end;
$$;

comment on function public.client_for_thread is
  'Which client a thread was filed on by a person, for staff and for the sweep. An address match is not a filing (0247).';

revoke all on function public.client_for_thread(text) from anon, authenticated;
grant execute on function public.client_for_thread(text) to authenticated;
