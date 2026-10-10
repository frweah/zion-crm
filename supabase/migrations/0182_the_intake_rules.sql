-- Zion Vocational Rehab CRM — the intake rules
--
-- Email → client → authorization → notifications, with no person in the loop
-- except to confirm (Intake Automation Brief, 10 Oct 2026).
--
-- Every decision is here rather than in the route, for two reasons. It is the
-- part that can be wrong in a way nobody notices - a second client created for
-- somebody already on file, a notification nobody got - so it is the part that
-- has to be testable without a mailbox, which verify_the_intake.sql does. And
-- it has to be one transaction: a client created without the task raised, or a
-- document attached without the counselor thanked, is worse than nothing
-- happening at all.
--
-- The route reads the PDF with the one reader (lib/read-document.ts) and hands
-- the reading over. It does the talking - Graph, email - and no deciding.

-- ── who intake addresses ─────────────────────────────────────
-- Not by name in a function, and not by role: Margaret is 'Reports' and so is
-- Rispah now, so a role no longer names a person. These are settings with the
-- current defaults in them, which is what the brief calls them.
alter table public.org_settings
  add column if not exists intake_staff_id uuid references public.staff (id),
  add column if not exists placement_staff_id uuid references public.staff (id);

comment on column public.org_settings.intake_staff_id is
  'Who referrals and authorizations are addressed to. Margaret, at the time of writing.';
comment on column public.org_settings.placement_staff_id is
  'Who hears about a placement authorization as well. Rei, at the time of writing.';

-- Read by everybody who can read the rest of the settings, changed by Admin
-- through the same screen. org_settings is granted column by column, so a new
-- column with no grant is a column nobody can read - which verify_columns.sql
-- catches, and did.
grant select (intake_staff_id, placement_staff_id) on public.org_settings to authenticated;
grant update (intake_staff_id, placement_staff_id) on public.org_settings to authenticated;

update public.org_settings set
  intake_staff_id = coalesce(intake_staff_id,
    (select id from public.staff where name = 'Margaret Paasa' and active)),
  placement_staff_id = coalesce(placement_staff_id,
    (select id from public.staff where name = 'Rei Ruzzel' and active));

-- ── every message the job looked at ──────────────────────────
-- The skip log the brief asks for ("Log the skip so it can be found"), and the
-- ledger that keeps Rule 4 to one reply per document. One table, because "what
-- did intake do with that email" is one question.
create table if not exists public.intake_mail (
  id             uuid primary key default gen_random_uuid(),
  seq            bigserial,
  message_id     text not null,
  from_address   text not null default '',
  subject        text not null default '',
  received_at    timestamptz,
  decision       text not null,
  detail         text not null default '',
  sha256         text,
  document_id    uuid references public.inbox_documents (id) on delete set null,
  client_id      uuid references public.clients (id) on delete set null,
  replied_at     timestamptz,
  at             timestamptz not null default now(),
  constraint intake_mail_decision_known check (decision = any (array[
    'not utah.gov', 'no pdf', 'referral', 'referral re-sent', 'authorization',
    'authorization attached', 'no client on file', 'ambiguous name', 'other', 'unreadable'
  ]))
);

create unique index if not exists intake_mail_one_per_document
  on public.intake_mail (message_id, coalesce(sha256, ''));

comment on table public.intake_mail is
  'Every message intake looked at and what it decided, including what it left alone. Also what keeps Rule 4 to one reply per document.';

alter table public.intake_mail enable row level security;
drop policy if exists intake_mail_read on public.intake_mail;
create policy intake_mail_read on public.intake_mail
  for select using ((select public.is_active_staff()));
grant select on public.intake_mail to authenticated;
select public.apply_system_read_only('public.intake_mail'::regclass);

/** The next day somebody is at work. A referral on Friday is called on Monday. */
create or replace function public.next_business_day(p_from date default null)
returns date language sql immutable as $$
  select case extract(isodow from coalesce(p_from, current_date))
    when 5 then coalesce(p_from, current_date) + 3   -- Friday  -> Monday
    when 6 then coalesce(p_from, current_date) + 2   -- Saturday
    else coalesce(p_from, current_date) + 1
  end
$$;

/**
 * Which client a name on a form means.
 *
 * Exact first+last, case-insensitive, trimmed - and the names of records
 * merged away, which are this practice's "known aliases": a merge keeps the
 * old row pointing at the surviving one (0115), so the old name is already
 * recorded as another way of saying the same person. That is why there is no
 * aliases table: there would be two places holding the same fact.
 *
 * Returns a row per candidate. Two rows is the ambiguous case the brief stops
 * on, and it stops on it rather than guessing.
 */
create or replace function public.intake_find_client(p_name text)
returns table (client_id uuid, client_name text, how text)
language sql stable security definer set search_path = public as $$
  with wanted as (select lower(btrim(coalesce(p_name, ''))) as n)
  select c.id, c.name, 'name'::text
    from public.clients c, wanted w
   where w.n <> '' and lower(btrim(c.name)) = w.n and c.merged_into is null
  union
  select public.client_merged_into(c.id), c.name, 'a name this record was merged under'::text
    from public.clients c, wanted w
   where w.n <> '' and lower(btrim(c.name)) = w.n and c.merged_into is not null
     and public.client_merged_into(c.id) is not null
$$;

comment on function public.intake_find_client is
  'Which client a name on a form means: exact name, or the name of a record merged into one. Two rows means ambiguous, and intake stops.';

revoke all on function public.intake_find_client(text) from anon, authenticated;

-- ── the one door admits the intake ───────────────────────────
--
-- add_authorization is the only way a bill comes into being (0168), and its
-- guard is "Admin and Billing". The intake is neither: it runs as the service
-- role behind a cron secret, with nobody signed in.
--
-- So the guard learns about it, under the name this codebase already uses for
-- a caller that is the service role rather than a person (filing_caller_role,
-- 0082). The alternative was an insert of its own inside the intake, and a
-- second way to create a bill is the thing 0168 existed to remove: the PDF
-- import route had one and was broken for two deploys before anybody noticed.
--
-- Written out in full rather than patched, so what the function is can be read
-- here. Everything below the guard is 0168 unchanged.
create or replace function public.add_authorization(
  p_client         uuid,
  p_number         text,
  p_service_type   text,
  p_rate_type      text,
  p_rate           numeric,
  p_total_hours    numeric default null,
  p_start          date default null,
  p_end            date default null,
  p_requires_forms text default '',
  p_funding_source text default 'Utah VR',
  p_note           text default null
)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
begin
  if not (public.current_staff_role() in ('Admin', 'Billing')
          or public.staff_has_area('billing', 'edit')
          -- The intake, which runs as the service role with nobody signed in
          -- (0182). What it creates is unconfirmed; a person still confirms it.
          or coalesce(public.filing_caller_role(), '') = 'service_role') then
    raise exception 'Only Admin and Billing add authorizations.'
      using errcode = 'insufficient_privilege';
  end if;
  if p_client is null then
    raise exception 'Choose a client.' using errcode = 'check_violation';
  end if;

  insert into public.authorizations
    (client_id, number, service_type, funding_source, rate_type, rate, total_hours,
     start_date, end_date, requires_forms, note)
  values
    (p_client, coalesce(p_number, ''), p_service_type,
     coalesce(nullif(p_funding_source, ''), 'Utah VR'),
     p_rate_type, p_rate,
     case when p_rate_type = 'Hourly' then p_total_hours end,
     p_start, p_end, coalesce(p_requires_forms, ''), btrim(coalesce(p_note, '')))
  returning id into v_id;

  return v_id;
end;
$$;

comment on function public.add_authorization is
  'The one way an authorization comes into being. Admin and Billing, or the intake running as the service role (0182).';

-- ── Rule 1: a referral ───────────────────────────────────────
--
-- The one document that may create a client, and the only one. Three outcomes:
-- nobody on file, so create them; somebody on file, so attach and re-send; two
-- people on file, so stop and ask.
--
-- Nothing here guesses. An ambiguous name creates nothing, because a second
-- record for a client already on file is not a tidy-up job - it splits their
-- authorizations, their hours and their forms across two records, and the
-- splitting is only noticed when a bill is short.
create or replace function public.intake_referral(
  p_doc       uuid,
  p_name      text,
  p_counselor text default '',
  p_office    text default '',
  p_date      date default null,
  p_phone     text default ''
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  cfg        public.org_settings;
  v_client   uuid;
  v_found    int;
  v_names    text;
  v_counsel  uuid;
  v_doc      public.inbox_documents;
  v_resend   boolean := false;
  v_due      date := public.next_business_day(public.practice_today());
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
    values (btrim(p_name), 'Referral', 'Active', v_counsel, btrim(coalesce(p_office, '')),
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

  -- ── the contact log ───────────────────────────────────────
  insert into public.contact_log (client_id, counselor_id, date, method, topic, outcome, staff_id)
  values (v_client, v_counsel, coalesce(p_date, public.practice_today()), 'Email',
          'Referral received',
          'Referral received by email from ' || coalesce(nullif(btrim(p_counselor), ''), 'the counselor') || '.',
          cfg.intake_staff_id);

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
$$;

comment on function public.intake_referral is
  'Rule 1: file a referral. Creates the client only when none is on file, attaches to the one that is, and stops on an ambiguous name.';

revoke all on function public.intake_referral(uuid, text, text, text, date, text) from anon, authenticated;

-- ── Rule 2: an authorization ─────────────────────────────────
--
-- Never creates a client. An authorization naming somebody not on file is a
-- question for a person, not a record to invent: the name on it may be a
-- misspelling of a client who exists, and a client created from it would be
-- the duplicate Rule 1 goes to such lengths to avoid.
create or replace function public.intake_authorization(
  p_doc       uuid,
  p_number    text,
  p_name      text,
  p_service   text default '',
  p_start     date default null,
  p_end       date default null,
  p_from_scan boolean default false
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  cfg      public.org_settings;
  v_client uuid;
  v_found  int;
  v_names  text;
  v_doc    public.inbox_documents;
  v_auth   uuid;
  v_new    boolean := false;
  v_rate_type text;
  v_text   text;
  v_scan   text := case when p_from_scan then ' (read from scan — check it)' else '' end;
  v_notify jsonb := '[]'::jsonb;
  r        record;
begin
  select * into cfg from public.org_settings limit 1;
  select * into v_doc from public.inbox_documents where id = p_doc;
  if not found then
    raise exception 'That document is not on file (%).', p_doc using errcode = 'no_data_found';
  end if;

  select count(*), string_agg(client_name, ' and '), (array_agg(client_id))[1]
    into v_found, v_names, v_client
    from public.intake_find_client(p_name);

  -- ── nobody, or too many: ask, and create nothing ───────────
  if v_found <> 1 then
    v_text := case when v_found = 0
      then format('Authorization for %s — no client on file. The document is attached.', btrim(coalesce(p_name, 'an unnamed client')))
      else format('Authorization for %s matches more than one client (%s). It has not been filed.', btrim(p_name), v_names)
    end;
    for r in select * from public.notify_person(
      cfg.intake_staff_id, 'authorization_received', v_text, p_doc::text,
      '/admin/documents', null,
      format('Decide where the authorization for %s belongs', btrim(coalesce(p_name, 'an unnamed client'))),
      public.practice_today(), 'bad', p_doc)
    loop
      v_notify := v_notify || jsonb_build_object('name', r.staff_name, 'email', r.email, 'message', r.message);
    end loop;
    return jsonb_build_object(
      'action', case when v_found = 0 then 'no client on file' else 'ambiguous name' end,
      'client_id', null, 'notify', v_notify, 'reply', v_found = 0);
  end if;

  -- ── the number already on file: attach to it ───────────────
  if coalesce(btrim(p_number), '') <> '' then
    select id into v_auth from public.authorizations
     where client_id = v_client and btrim(number) = btrim(p_number) limit 1;
  end if;

  if v_auth is null then
    -- Through the one door (0168). Hours and rate are not read here: Margaret
    -- or Francis put them in at confirm, which is what the brief asks for.
    -- The rate and the hours are not read - Margaret or Francis put them in at
    -- confirm, which is what the brief asks for - but the table requires both,
    -- so what is written has to be honest about saying nothing.
    --
    --   Whether it is hourly or a flat fee is not a guess: the practice
    --   records it per service in billing_service_rules, which is where the
    --   rest of the billing reads it. A service nobody recognises falls to
    --   Flat Fee, the commoner of the two, and whoever confirms sees it.
    --
    --   The rate is 0, which is the column's own default and means "nobody has
    --   said". An hourly authorization must also carry hours, so they are 0
    --   for the same reason. Neither is a number anybody can act on, and the
    --   submission gate already refuses an authorization with no amount and no
    --   dates - so a figure nobody typed cannot reach an invoice.
    --
    -- What is deliberately not done is invent either of them. A rate on
    -- somebody's file that nobody typed is the mistake this whole pipeline is
    -- built to avoid, and it would be found at the end of a month.
    select billing_type into v_rate_type from public.billing_service_rules
     where service = btrim(coalesce(p_service, ''));
    v_rate_type := coalesce(v_rate_type, 'Flat Fee');

    v_auth := public.add_authorization(
      p_client => v_client,
      p_number => btrim(coalesce(p_number, '')),
      p_service_type => nullif(btrim(coalesce(p_service, '')), ''),
      p_rate_type => v_rate_type,
      p_rate => 0,
      p_total_hours => case when v_rate_type = 'Hourly' then 0 end,
      p_start => p_start,
      p_end => p_end,
      p_note => 'Read from the authorization emailed by the counselor. '
                || 'The rate and the hours were not read - put them in when you confirm it.'
                || v_scan);
    v_new := true;
  end if;

  insert into public.attachments
    (client_id, storage_path, filename, mime_type, size_bytes, category, auth_id, note, uploaded_by_name)
  select v_client, v_doc.storage_path, v_doc.filename, 'application/pdf', v_doc.size_bytes,
         'Authorization', v_auth, 'Received by email.', 'Intake'
   where not exists (
     select 1 from public.attachments a
      where a.client_id = v_client and a.storage_path = v_doc.storage_path
   );

  update public.inbox_documents set client_id = v_client where id = p_doc;

  v_text := format('Authorization %s received for %s: %s, %s–%s. Confirm it.%s',
                   coalesce(nullif(btrim(p_number), ''), '(no number)'),
                   (select name from public.clients where id = v_client),
                   coalesce(nullif(btrim(p_service), ''), 'service not read'),
                   coalesce(to_char(p_start, 'FMDD FMMon'), '?'),
                   coalesce(to_char(p_end, 'FMDD FMMon'), '?'), v_scan);

  for r in select * from public.notify_person(
    cfg.intake_staff_id, 'authorization_received', v_text, p_doc::text,
    '/billing/authorizations/' || v_auth::text, v_client,
    format('Confirm authorization %s for %s',
           coalesce(nullif(btrim(p_number), ''), '(no number)'),
           (select name from public.clients where id = v_client)),
    public.practice_today(), 'warn', p_doc)
  loop
    v_notify := v_notify || jsonb_build_object('name', r.staff_name, 'email', r.email, 'message', r.message);
  end loop;

  -- ── Rule 2.5: placement work reaches Rei as well ───────────
  if cfg.placement_staff_id is not null
     and btrim(coalesce(p_service, '')) in ('Job Placement', 'Job Placement (SE)', 'Job Development',
                                            'Job Development + HQ Indicator', 'Job Search') then
    for r in select * from public.notify_person(
      cfg.placement_staff_id, 'authorization_received',
      format('%s authorized for %s, %s–%s.',
             (select name from public.clients where id = v_client), btrim(p_service),
             coalesce(to_char(p_start, 'FMDD FMMon'), '?'),
             coalesce(to_char(p_end, 'FMDD FMMon'), '?')),
      p_doc::text || ':placement', '/clients/' || v_client::text, v_client,
      format('Start placement work for %s', (select name from public.clients where id = v_client)),
      public.practice_today(), 'warn', p_doc)
    loop
      v_notify := v_notify || jsonb_build_object('name', r.staff_name, 'email', r.email, 'message', r.message);
    end loop;
  end if;

  return jsonb_build_object(
    'action', case when v_new then 'authorization' else 'authorization attached' end,
    'client_id', v_client, 'authorization_id', v_auth, 'notify', v_notify, 'reply', true);
end;
$$;

comment on function public.intake_authorization is
  'Rule 2: file an authorization against a client already on file. Never creates a client; the number already there is attached to rather than doubled.';

revoke all on function public.intake_authorization(uuid, text, text, text, date, date, boolean) from anon, authenticated;

-- ── Rule 3: anything else from utah.gov ──────────────────────
-- Filed if the client is clear, left in the queue if not. Nobody is notified:
-- a monthly report arriving is not news, and a notification for every piece of
-- correspondence is how people stop reading notifications.
create or replace function public.intake_other(p_doc uuid, p_name text default '')
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_doc    public.inbox_documents;
  v_client uuid;
  v_found  int;
begin
  select * into v_doc from public.inbox_documents where id = p_doc;
  if not found then
    raise exception 'That document is not on file (%).', p_doc using errcode = 'no_data_found';
  end if;

  select count(*), (array_agg(client_id))[1] into v_found, v_client from public.intake_find_client(p_name);
  if v_found <> 1 then
    return jsonb_build_object('action', 'other', 'client_id', null,
                              'notify', '[]'::jsonb, 'reply', false);
  end if;

  insert into public.attachments
    (client_id, storage_path, filename, mime_type, size_bytes, category, note, uploaded_by_name)
  select v_client, v_doc.storage_path, v_doc.filename, 'application/pdf', v_doc.size_bytes,
         'Other', 'Received by email.', 'Intake'
   where not exists (
     select 1 from public.attachments a
      where a.client_id = v_client and a.storage_path = v_doc.storage_path
   );
  update public.inbox_documents set client_id = v_client where id = p_doc;

  return jsonb_build_object('action', 'other', 'client_id', v_client,
                            'notify', '[]'::jsonb, 'reply', false);
end;
$$;

comment on function public.intake_other is
  'Rule 3: file a document that is neither a referral nor an authorization against its client, or leave it in the queue. Notifies nobody.';

revoke all on function public.intake_other(uuid, text) from anon, authenticated;

/**
 * Record what intake did with a message, and say whether to reply.
 *
 * Rule 4 is one reply per document, and a re-send gets the same reply - so the
 * ledger is keyed by the message and the document's fingerprint, and the reply
 * is claimed here rather than decided by the route. A poll that overlaps the
 * last one finds the row already claimed and sends nothing.
 */
create or replace function public.intake_record_mail(
  p_message  text,
  p_from     text,
  p_subject  text,
  p_received timestamptz,
  p_decision text,
  p_detail   text default '',
  p_sha256   text default null,
  p_doc      uuid default null,
  p_client   uuid default null,
  p_reply    boolean default false
)
returns boolean
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_replied timestamptz;
begin
  insert into public.intake_mail
    (message_id, from_address, subject, received_at, decision, detail, sha256,
     document_id, client_id, replied_at)
  values (p_message, lower(btrim(coalesce(p_from, ''))), coalesce(p_subject, ''), p_received,
          p_decision, coalesce(p_detail, ''), p_sha256, p_doc, p_client,
          case when p_reply then now() end)
  on conflict (message_id, coalesce(sha256, '')) do nothing
  returning id into v_id;

  if v_id is not null then
    return p_reply;   -- newly recorded: the reply is this call's to send
  end if;

  -- Already seen. The reply is sent only if it never was.
  select replied_at into v_replied from public.intake_mail
   where message_id = p_message and coalesce(sha256, '') = coalesce(p_sha256, '');
  if p_reply and v_replied is null then
    update public.intake_mail set replied_at = now()
     where message_id = p_message and coalesce(sha256, '') = coalesce(p_sha256, '');
    return true;
  end if;
  return false;
end;
$$;

comment on function public.intake_record_mail is
  'Record what intake did with a message and claim the single reply Rule 4 allows. Returns whether this caller should send it.';

revoke all on function public.intake_record_mail(text, text, text, timestamptz, text, text, text, uuid, uuid, boolean)
  from anon, authenticated;
