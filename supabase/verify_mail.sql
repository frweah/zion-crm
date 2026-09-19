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
  if v_cols <> 'client_id,conversation_id,counselor_id,counterpart_email,created_at,direction,graph_message_id,id,mailbox_address,mailbox_key,sent_at,staff_id,subject,web_link' then
    failures := failures || format('FAILED: mail_log has columns beyond its log line: %s', v_cols)::text;
  else
    raise notice 'ok  mail_log holds the log line only - subject, date, direction, counterpart, link';
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
       ('sms_templates', 'body'));
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
