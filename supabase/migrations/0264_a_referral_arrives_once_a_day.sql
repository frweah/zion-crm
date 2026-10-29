-- Zion Vocational Rehab CRM — 0264 a referral arrives once a day
--
-- `zion-intake` runs every quarter of an hour and reads the newest forty
-- messages in service@. Nothing is marked read and nothing is moved, so a
-- message in that window is handed to the rules again on every run. That is
-- the design: a document that arrives twice is one document, a re-sent
-- referral is a re-send, and every write in the intake rules is idempotent so
-- that re-reading costs nothing.
--
-- Every write but one. `intake_referral` guards the client (created only when
-- the name matches nobody), the attachment (`where not exists` on the storage
-- path), the task and the notification (keyed on the document) — and then
-- inserts the contact-log row unconditionally. So a referral sitting in the
-- newest forty collected a "Referral received" row every fifteen minutes for
-- as long as it stayed there: four an hour, ninety-six a day.
--
-- Found on 29 Oct 2026 with 547 of the practice's 623 contact-log rows on one
-- client, still arriving. It had gone unnoticed for six days because every
-- visible consequence of a referral — the task, the bell, the email, the
-- document — was already idempotent, so the screens looked right. Only the
-- contact log grew, and nobody reads six days of one client's contact log
-- until a report is drafted off it.
--
-- The fix is the guard the rest of the function already has. The fact the row
-- records is that the referral arrived on that day, so one row per client per
-- day is the fact: a referral genuinely re-sent on a later date still gets its
-- own row, and the second reading of the same arrival does not. The counselor
-- name is deliberately not part of the key — it is read off the form and can
-- differ between two readings of the same page, and "the referral arrived
-- twice today under two spellings" is not a thing that happened.
--
-- Nothing already written is touched here. Rows the loop left behind are the
-- owner's to decide about.

CREATE OR REPLACE FUNCTION public.intake_referral(p_doc uuid, p_name text, p_counselor text DEFAULT ''::text, p_office text DEFAULT ''::text, p_date date DEFAULT NULL::date, p_phone text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  cfg        public.org_settings;
  v_client   uuid;
  v_found    int;
  v_names    text;
  v_counsel  uuid;
  v_doc      public.inbox_documents;
  v_resend   boolean := false;
  v_due      date := public.next_business_day(public.practice_today());
  v_when     date;
  v_text     text;
  v_notify   jsonb := '[]'::jsonb;
  r          record;
begin
  select * into cfg from public.org_settings limit 1;
  if cfg.intake_staff_id is null then
    raise exception 'Nobody is set to receive intake (org_settings.intake_staff_id).'
      using errcode = 'no_data_found';
  end if;
  select * into v_doc from public.inbox_documents where id = p_doc;
  if not found then
    raise exception 'That document is not on file (%).', p_doc using errcode = 'no_data_found';
  end if;
  if coalesce(btrim(p_name), '') = '' then
    raise exception 'A referral with no client name on it cannot be filed.'
      using errcode = 'check_violation';
  end if;

  select count(*), string_agg(client_name, ' and '), (array_agg(client_id))[1]
    into v_found, v_names, v_client
    from public.intake_find_client(p_name);

  -- ── two candidates: create nothing, ask ────────────────────
  if v_found > 1 then
    v_text := format('Referral for %s matches more than one client on file (%s). The form is attached; it has not been filed.',
                     btrim(p_name), v_names);
    for r in select * from public.notify_person(
      cfg.intake_staff_id, 'intake', v_text, p_doc::text,
      '/admin/documents', null,
      format('Decide which client the referral for %s belongs to', btrim(p_name)), v_due, 'bad', p_doc)
    loop
      v_notify := v_notify || jsonb_build_object('name', r.staff_name, 'email', r.email, 'message', r.message);
    end loop;
    return jsonb_build_object('action', 'ambiguous name', 'client_id', null,
                              'candidates', v_names, 'notify', v_notify, 'reply', false);
  end if;

  select id into v_counsel from public.counselors
   where lower(btrim(name)) = lower(btrim(coalesce(p_counselor, ''))) limit 1;

  -- ── nobody on file: create them ────────────────────────────
  if v_found = 0 then
    insert into public.clients
      (name, stage, status, counselor_id, referring_office, phone,
       assigned_staff_id, billing_staff_id)
    values (btrim(p_name), 'Intake', 'Active', v_counsel, btrim(coalesce(p_office, '')),
            btrim(coalesce(p_phone, '')),
            (select id from public.staff where id = cfg.placement_staff_id and active),
            cfg.intake_staff_id)
    returning id into v_client;
  else
    v_resend := true;
    -- The counselor and the office as the form has them, where the record has
    -- nothing. Never overwritten: what is on the record was put there by
    -- somebody, and a form is not a correction.
    update public.clients set
      counselor_id = coalesce(counselor_id, v_counsel),
      referring_office = case when btrim(coalesce(referring_office, '')) = ''
                              then btrim(coalesce(p_office, '')) else referring_office end,
      phone = case when btrim(coalesce(phone, '')) = ''
                   then btrim(coalesce(p_phone, '')) else phone end
     where id = v_client;
  end if;

  -- ── the PDF, on the client, once ───────────────────────────
  -- One object: the attachment points at what the inbox already stored. The
  -- fingerprint made it one document however many times it arrived.
  insert into public.attachments
    (client_id, storage_path, filename, mime_type, size_bytes, category, note, uploaded_by_name)
  select v_client, v_doc.storage_path, v_doc.filename, 'application/pdf', v_doc.size_bytes,
         'Signed USOR form',
         'Received by email from ' || coalesce(nullif(btrim(p_counselor), ''), 'the counselor') || '.',
         'Intake'
   where not exists (
     select 1 from public.attachments a
      where a.client_id = v_client and a.storage_path = v_doc.storage_path
   );

  update public.inbox_documents set client_id = v_client where id = p_doc;

  -- ── the contact log, once for the day it arrived ───────────
  -- Guarded the way the attachment above is guarded, and for the same reason:
  -- the intake rules are run again every time the message is still in the
  -- newest forty, so an unguarded insert here is one row every quarter of an
  -- hour for as long as the counselor's email sits in the inbox (0264).
  v_when := coalesce(p_date, public.practice_today());

  insert into public.contact_log (client_id, counselor_id, date, method, topic, outcome, staff_id)
  select v_client, v_counsel, v_when, 'Email',
         'Referral received',
         'Referral received by email from ' || coalesce(nullif(btrim(p_counselor), ''), 'the counselor') || '.',
         cfg.intake_staff_id
   where not exists (
     select 1 from public.contact_log l
      where l.client_id = v_client
        and l.topic = 'Referral received'
        and l.date = v_when
   );

  -- ── one notification, three places (Rules 1.4, 5) ──────────
  -- Rule 5: the intake task and the My day item are the same item, so there is
  -- one call and one task, titled as Rule 5 words it.
  if v_resend then
    v_text := format('Referral re-sent for %s — form attached.', btrim(p_name));
  else
    v_text := format('New referral: %s, from %s, %s. Intake call due %s.',
                     btrim(p_name),
                     coalesce(nullif(btrim(p_counselor), ''), 'an unnamed counselor'),
                     coalesce(nullif(btrim(p_office), ''), 'no office given'),
                     to_char(v_due, 'FMDay FMDD FMMonth'));
  end if;

  for r in select * from public.notify_person(
    cfg.intake_staff_id, 'intake', v_text, p_doc::text,
    '/clients/' || v_client::text, v_client,
    format('Initiate contact with %s%s — referred by %s',
           btrim(p_name),
           case when btrim(coalesce(p_phone, '')) <> '' then ' — ' || btrim(p_phone) else '' end,
           coalesce(nullif(btrim(p_counselor), ''), 'an unnamed counselor')),
    v_due, 'warn', p_doc)
  loop
    v_notify := v_notify || jsonb_build_object('name', r.staff_name, 'email', r.email, 'message', r.message);
  end loop;

  return jsonb_build_object(
    'action', case when v_resend then 'referral re-sent' else 'referral' end,
    'client_id', v_client, 'notify', v_notify, 'reply', true);
end;
$function$;

comment on function public.intake_referral(uuid, text, text, text, date, text) is
  'Files a referral read off a scanned form: the client if the name matches nobody, the document, the contact-log row for the day it arrived, and one task. Every write is idempotent, because the intake rules are run again on every poll while the message is still in the inbox (0264).';
