-- Zion Vocational Rehab CRM — 0234 the writer records how it was filed
--
-- 0233 gave mail_log a filed_how, and the three functions that write to it
-- did not know about it. So every message the sweep logged carried a null
-- where the honest answer was "auto", and a message filed by hand had
-- nowhere to say so.
--
-- One parameter, defaulting to null, so the existing calls keep working
-- while they are updated. Null means the sweep, which is "auto"; "by hand"
-- is the only value that records a person, because it is the only one where
-- a person decided anything.
--
-- Each body below is the live definition with the parameter threaded
-- through and nothing else touched.

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
    coalesce(nullif(btrim(coalesce(p_filed_how, '')), ''), 'auto'),
    now(),
    -- Only a person filing records a person. The sweep files nobody's
    -- decision but its own, and says so by leaving this null (0234).
    case when p_filed_how = 'by hand' then public.current_staff_id() else null end
  )
  on conflict (mailbox_key, graph_message_id) do nothing;

  return found;
end;
$function$;

-- log_mail_message
CREATE OR REPLACE FUNCTION public.log_mail_message(p_client_id uuid, p_counselor_id uuid, p_message_id text, p_conversation_id text, p_subject text, p_sent_at timestamp with time zone, p_direction text, p_counterpart text, p_web_link text, p_filed_how text DEFAULT NULL::text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_staff uuid := public.current_staff_id();
begin
  if v_staff is null then
    raise exception 'You are not signed in.' using errcode = 'insufficient_privilege';
  end if;
  return public.log_mail_message_internal(
    v_staff, '', p_client_id, p_counselor_id, p_message_id, p_conversation_id,
    p_subject, p_sent_at, p_direction, p_counterpart, p_web_link, p_filed_how);
end;
$function$;

-- log_mail_message_for_sync
CREATE OR REPLACE FUNCTION public.log_mail_message_for_sync(p_staff_id uuid, p_client_id uuid, p_counselor_id uuid, p_message_id text, p_conversation_id text, p_subject text, p_sent_at timestamp with time zone, p_direction text, p_counterpart text, p_web_link text, p_filed_how text DEFAULT NULL::text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  return public.log_mail_message_internal(
    p_staff_id, '', p_client_id, p_counselor_id, p_message_id, p_conversation_id,
    p_subject, p_sent_at, p_direction, p_counterpart, p_web_link, p_filed_how);
end;
$function$;

-- log_shared_mail_message
CREATE OR REPLACE FUNCTION public.log_shared_mail_message(p_mailbox text, p_client_id uuid, p_counselor_id uuid, p_message_id text, p_conversation_id text, p_subject text, p_sent_at timestamp with time zone, p_direction text, p_counterpart text, p_web_link text, p_filed_how text DEFAULT NULL::text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not exists (select 1 from public.shared_mailboxes where address = p_mailbox and active) then
    raise exception 'That is not a shared mailbox this practice reads.'
      using errcode = 'check_violation';
  end if;
  return public.log_mail_message_internal(
    null, p_mailbox, p_client_id, p_counselor_id, p_message_id, p_conversation_id,
    p_subject, p_sent_at, p_direction, p_counterpart, p_web_link, p_filed_how);
end;
$function$;
