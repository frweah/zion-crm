-- Zion Vocational Rehab CRM — the rules run again once a scan is read
--
-- The brief's Timing section, second half: "Scanned PDFs: queue for OCR, run
-- the rules when text is available."
--
-- The first half already worked and needed nothing: a scan arrives with no
-- text, so it is stored with kind 'Unreadable', which is exactly what
-- /api/agent/ocr-wanted looks for - the agent reads it on the machine and
-- sends the text back. What was missing is the second half. The text arrived
-- and nothing looked at the document again, so a referral that came in as a
-- scan would have been OCR'd and then left sitting in the queue, creating no
-- client and telling nobody.
--
-- Found on the first live run of the intake: rlhill@utah.gov sent "Fwd:
-- Scanned image from State of Utah" and it is in the queue unread. It is not a
-- referral as it happens, but the next one might be.
--
-- This is the list of documents that are owed a second look, and only that
-- list - the deciding is the same rules as before (intake_referral,
-- intake_authorization, intake_other). Nothing is duplicated; what the intake
-- route does with a scan once it can read it is what it would have done the
-- first time.

/**
 * Documents the intake could not read, which can now be read.
 *
 * Narrow on purpose. A document the intake read and decided was 'other' was
 * genuinely read - OCR will not change its mind, and asking again every
 * quarter of an hour forever would be work that never ends. Only a document
 * the intake could not read at all, which now has text, is owed another look.
 *
 * The message it arrived in comes back with it, because Rule 4's reply is per
 * document and that is still owed: the counselor who sent a scan has not been
 * thanked, since nothing was filed.
 */
create or replace function public.intake_scans_now_readable()
returns table (
  document_id  uuid,
  message_id   text,
  from_address text,
  subject      text,
  received_at  timestamptz,
  sha256       text,
  ocr_text     text
)
language sql stable security definer set search_path = public as $$
  select d.id, m.message_id, m.from_address, m.subject, m.received_at, d.sha256, d.ocr_text
    from public.intake_mail m
    join public.inbox_documents d on d.id = m.document_id
   where m.decision = 'unreadable'
     and m.client_id is null
     and coalesce(d.ocr_text, '') <> ''
   order by m.received_at
   limit 20
$$;

comment on function public.intake_scans_now_readable is
  'Documents the intake could not read and the agent has since read with OCR. The rules have not run on these; the brief''s Timing section says they should.';

revoke all on function public.intake_scans_now_readable() from anon, authenticated;
grant execute on function public.intake_scans_now_readable() to authenticated;

/**
 * And the record of the second look.
 *
 * intake_record_mail keys a message and a document together and refuses a
 * second row, which is what keeps Rule 4 to one reply. That is right for a
 * document seen twice by the poll and wrong here: this *is* the first time the
 * rules have run on it, so the decision has to be allowed to change from
 * 'unreadable' to what it actually is - and the reply becomes owed.
 */
create or replace function public.intake_rules_ran_late(
  p_message  text,
  p_sha256   text,
  p_decision text,
  p_detail   text default '',
  p_client   uuid default null,
  p_reply    boolean default false
)
returns boolean
language plpgsql security definer set search_path = public as $$
declare v_replied timestamptz; v_was text;
begin
  select decision, replied_at into v_was, v_replied
    from public.intake_mail
   where message_id = p_message and coalesce(sha256, '') = coalesce(p_sha256, '');
  if v_was is null then
    raise exception 'That message and document were never recorded (%).', p_message
      using errcode = 'no_data_found';
  end if;
  if v_was <> 'unreadable' then
    -- Somebody or something has already decided this. Leave it.
    return false;
  end if;

  update public.intake_mail set
    decision = p_decision,
    detail = coalesce(nullif(btrim(p_detail), ''), 'read from the scan'),
    client_id = coalesce(p_client, client_id),
    replied_at = case when p_reply and replied_at is null then now() else replied_at end
   where message_id = p_message and coalesce(sha256, '') = coalesce(p_sha256, '');

  return p_reply and v_replied is null;
end;
$$;

comment on function public.intake_rules_ran_late is
  'Record what the rules decided about a scan once it could be read, and claim the reply that was never owed while it was unreadable.';

revoke all on function public.intake_rules_ran_late(text, text, text, text, uuid, boolean)
  from anon, authenticated;
