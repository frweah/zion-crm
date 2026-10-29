-- A name nobody read is not a name
--
-- The referral rule may create a client, which makes the name the one field on
-- the form that cannot be guessed at. Until now a referral whose name could
-- not be read threw in the route: the poll failed, the document stayed in the
-- queue, and nobody was told - so the only way anybody found out was the next
-- time somebody looked at the inbox.
--
-- Worse, the name was read too easily rather than not at all. A DWS-USOR 94
-- read on 23 October gave a client called "The assessment is due", referred by
-- "Referral Page", from an office called "Observations:" - three values read
-- off the form's own instructions and headings while the correctly labelled
-- "Client Name:" sat three lines below. lib/referral-parse.ts now asks the
-- stricter question, and check-referral-parse holds it there against the whole
-- form rather than its first five lines.
--
-- This is the other half: when the stricter question comes back with nothing,
-- the document stays where it is and the person whose job it is hears about it
-- in the same three places everything else in intake arrives.
--
-- The document is deliberately left unfiled rather than attached to a holding
-- client record. A client record created from a guess is what the last week
-- was spent undoing, and a record named "Unnamed referral - needs review"
-- would collect every unreadable referral, sit in the client list, and need
-- merging out again. The queue already holds documents whose client is not
-- clear, which is exactly what this is.

create or replace function public.intake_referral_unreadable(p_doc uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_doc    public.inbox_documents;
  cfg      public.org_settings;
  v_notify jsonb := '[]'::jsonb;
  v_text   text;
  r        record;
begin
  select * into v_doc from public.inbox_documents where id = p_doc;
  if not found then
    raise exception 'That document is not on file (%).', p_doc using errcode = 'no_data_found';
  end if;

  select * into cfg from public.org_settings limit 1;
  if cfg.intake_staff_id is null then
    raise exception 'There is nobody set to receive referrals. Set it on Admin → Settings.'
      using errcode = 'check_violation';
  end if;

  v_text := format(
    'A referral arrived that no name could be read off: %s. It is in the document inbox.',
    coalesce(nullif(btrim(v_doc.filename), ''), 'a file with no name'));

  -- Keyed on the document, so a mailbox polled every fifteen minutes tells
  -- Margaret once rather than ninety-six times a day. The same guard 0264 put
  -- on the contact log, for the same reason.
  for r in select * from public.notify_person(
    cfg.intake_staff_id, 'intake', v_text, p_doc::text,
    '/admin/documents', null,
    format('Read the client name off %s and file it',
           coalesce(nullif(btrim(v_doc.filename), ''), 'the referral in the inbox')),
    public.practice_today(), 'bad', p_doc)
  loop
    v_notify := v_notify || jsonb_build_object('name', r.staff_name, 'email', r.email, 'message', r.message);
  end loop;

  -- No reply to the counselor. The practice has not read the referral yet, and
  -- thanking somebody for a document nobody can file says something untrue.
  return jsonb_build_object('action', 'referral needs a name', 'client_id', null,
                            'notify', v_notify, 'reply', false);
end;
$$;

comment on function public.intake_referral_unreadable(uuid) is
  'A referral whose client name could not be read: left in the queue, and the intake owner told once.';

-- A new signature is a new function, and a new function is executable by
-- everybody until it is not. Intake runs as the service role; nobody signed in
-- has any business calling this.
revoke execute on function public.intake_referral_unreadable(uuid) from anon;
revoke execute on function public.intake_referral_unreadable(uuid) from authenticated;
