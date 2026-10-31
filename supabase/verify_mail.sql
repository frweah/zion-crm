-- Zion Vocational Rehab CRM — mail bodies are never stored (Messaging brief, M)
--
-- What has to hold: the Mail screen reads messages live from Microsoft and
-- shows them; the database keeps only the log line it always kept - subject,
-- date, direction, counterpart, link - and nowhere else could a body go.
--
--   mail_log has exactly its log columns, and nothing that could hold text.
--   No table anywhere has a body or content column except the ones known to
--   hold the CRM's own writing (policies, SOPs, hints, templates, texts,
--   records requests, chat and texts). A new one fails this until it is looked at.
--   Nobody signed in can write a mail_log row by hand.
--
-- Read-only. Runs inside a transaction that is rolled back.

begin;

do $$
declare
  v_cols    text;
  v_extra   text;
  failures  text[] := '{}';
begin
  select string_agg(column_name, ',' order by column_name) into v_cols
    from information_schema.columns
   where table_schema = 'public' and table_name = 'mail_log';
  -- The log line, and - since filing became a decision somebody makes
  -- (0233) - the record of that decision: who filed it, when, how, whether
  -- the thread is restricted, and who took it off again and why. Still not a
  -- word of the message.
  if v_cols <> 'client_id,conversation_id,counselor_id,counterpart_email,created_at,direction,filed_at,filed_by,filed_how,graph_message_id,id,mailbox_address,mailbox_key,restricted,sent_at,staff_id,subject,unfiled_at,unfiled_by,unfiled_reason,web_link' then
    failures := failures || format('FAILED: mail_log has columns beyond its log line and its filing: %s', v_cols)::text;
  else
    raise notice 'ok  mail_log holds the log line and who filed it - never the message';
  end if;

  select string_agg(table_name || '.' || column_name, ', ' order by table_name, column_name) into v_extra
    from information_schema.columns
   where table_schema = 'public'
     and column_name ~ '(body|html|content|message_text|preview)'
     and (table_name, column_name) not in (
       ('note_templates', 'body'), ('portal_terms', 'body'), ('records_requests', 'contents'),
       ('sms_messages', 'body'), ('sops', 'body'), ('staff_policies', 'body'), ('tour_hints', 'body'),
       -- Chat and texts, written in the CRM (0104) - never an email's body.
       ('messages', 'body'),
       -- Text templates: the practice's own words, ready to send (0105).
       ('sms_templates', 'body'),
       -- The three letters the practice keeps writing (0238). The practice's
       -- own words again, which is the whole distinction this list draws:
       -- what the practice wrote is kept, what arrived in a mailbox is not.
       ('mail_templates', 'body'),
       -- The weekly and monthly reports (0260). The practice's own writing
       -- about its own work: dated lines built from hours, appointments,
       -- notes, applications, placements and the *subjects* of filed mail.
       -- A body could not get in even by mistake, because there is nowhere
       -- for one to be copied from - `mail_log` has no body column, which is
       -- what the clause above this list asserts.
       ('client_weekly_reports', 'content'),
       ('client_reports', 'content'));
  if v_extra is not null then
    failures := failures || format('FAILED: somewhere a message body could be kept: %s', v_extra)::text;
  else
    raise notice 'ok  no table has a column that could hold a mail body';
  end if;

  if has_table_privilege('authenticated', 'public.mail_log', 'insert')
     or has_table_privilege('authenticated', 'public.mail_log', 'update') then
    failures := failures || 'FAILED: somebody signed in can write the mail log by hand'::text;
  else
    raise notice 'ok  the mail log is written by the sync alone';
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- MAIL VERIFIED ---';
end $$;

rollback;
