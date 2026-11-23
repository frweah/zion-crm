/**
 * "Cannot text" asks about the number (ruling 6b, 23 November 2026).
 *
 * The inbox's rows are threads, and since 0332 a thread is one number: the
 * client's own, or their partner's, or their daughter-in-law's. The chip on
 * the row read `client_sms_consent`, which answers for the *client* - so a
 * thread with a contact who has agreed to be texted could show "Cannot text",
 * and a thread with a contact who has not could show nothing at all. The
 * sending gate has never had this wrong: `sms_outgoing_requires_consent`
 * looks the number up in `sms_consent_numbers`, and the screen now reads the
 * same view the refusal comes from.
 *
 * Nothing else about the function changes. It is re-stated from what the
 * database holds rather than from the migration that created it, because the
 * two have drifted before.
 */

CREATE OR REPLACE FUNCTION public.message_inbox(p_show text DEFAULT 'open'::text)
 RETURNS TABLE(conversation_id uuid, kind text, client_id uuid, client_name text, who text, assigned_staff_id uuid, assigned_name text, last_message_at timestamp with time zone, last_body text, unread integer, unmatched boolean, spam boolean, can_text boolean, last_sender_kind text, last_sender text, last_status text, last_media_url text, last_media_type text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select c.id, c.kind, c.client_id, cl.name,
         case when c.kind = 'portal' then pa.name || case when pa.kind = 'Guardian' then ' · guardian' else '' end
              else coalesce(w.visitor_name || ' · ' || c.external_address, c.external_address) end,
         c.assigned_staff_id, st.name, c.last_message_at,
         lm.body,
         (select count(*)::integer from public.messages m
           left join public.read_receipts r on r.conversation_id = c.id and r.staff_id = public.current_staff_id()
          where m.conversation_id = c.id and m.seq > coalesce(r.last_read_seq, 0)
            and m.sender_kind in ('client', 'visitor')),
         c.client_id is null, c.spam,
         -- The number, not the client (ruling 6b). A thread is one number
         -- since 0332, and this is the view the sending gate itself reads,
         -- so a chip on a row and a refusal on the send cannot disagree.
         -- A website chat has no number and so answers false, which is the
         -- honest answer: there is nothing to text.
         coalesce((select n.can_text from public.sms_consent_numbers n
                    where n.client_id = c.client_id and n.phone = c.external_address), false),
         -- Who said the last thing, and whether it went (1a, 1b, 1c). The
         -- inbox used to show the words alone, so a line could be read as the
         -- client asking or as the practice answering, and a picture message
         -- with no words in it showed as an empty row.
         lm.sender_kind, lm.sender_label, lm.status, lm.media_url, lm.media_type
    from public.conversations c
    left join lateral (
      select m.sender_kind, m.sender_label, m.body, m.status, m.media_url, m.media_type
        from public.messages m
       where m.conversation_id = c.id and m.hidden_at is null
       order by m.seq desc limit 1
    ) lm on true
    left join public.clients cl on cl.id = c.client_id
    left join public.staff st on st.id = c.assigned_staff_id
    left join public.web_chats w on w.conversation_id = c.id
    left join public.portal_accounts pa on pa.id = c.portal_account_id
   where c.kind in ('sms', 'web', 'portal')
     and public.is_active_staff()
     and (c.kind <> 'portal' or public.can_manage_portal(c.client_id))
     and case p_show
           when 'spam' then c.spam
           when 'mine' then not c.spam and c.assigned_staff_id = public.current_staff_id()
           when 'unmatched' then not c.spam and c.client_id is null
           when 'web' then not c.spam and c.kind = 'web'
           when 'texts' then not c.spam and c.kind = 'sms'
           when 'portal' then not c.spam and c.kind = 'portal'
           else not c.spam
         end
   order by c.last_message_at desc nulls last;
$function$;
