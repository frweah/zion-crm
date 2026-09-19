-- Zion Vocational Rehab CRM — the staff onboarding walkthrough
--
-- The owner, 18 Sept 2026: when Admin adds somebody from Admin -> People, the
-- invite says to complete onboarding, and on first sign-in they are taken
-- through six steps in order -
--
--   1. personal details     legal name, address, phone, date of birth, emergency contact
--   2. identity documents   I-9 documents for an employee, marked "in-person
--                           inspection still required" until Admin has seen the originals
--   3. certifications       what they hold, with expiry dates, for Admin to check
--   4. tax form             whichever their record calls for (Paperwork's own forms)
--   5. data-handling policy signed in the app, the signed copy kept on their file
--   6. payment              how they are paid and who pays them - never a bank
--                           account number; the payroll service holds those
--
-- Each step is an item on the existing onboarding checklist, and like every
-- automatic item there it is worked out from the thing itself, never ticked.
-- The walkthrough can be left and resumed, open steps are reminded nightly,
-- and Admin is told when the six are done.
--
-- Nothing new sits outside the staff restricted tier: every table here is
-- readable by the person and by Admin, nobody else, the same rule as their
-- tax forms and documents. Admin opening somebody's personal details is
-- written to the access log, as opening their documents is.

-- ── 1. personal details ─────────────────────────────────────
-- The legal name is its own field: staff.name is what the screens call them.
create table if not exists public.staff_personal (
  staff_id               uuid primary key references public.staff(id) on delete cascade,
  legal_name             text not null default '',
  address_line1          text not null default '',
  address_line2          text not null default '',
  city                   text not null default '',
  state                  text not null default '',
  postal_code            text not null default '',
  phone                  text not null default '',
  date_of_birth          date,
  emergency_name         text not null default '',
  emergency_relationship text not null default '',
  emergency_phone        text not null default '',
  updated_at             timestamptz not null default now(),
  updated_by             uuid references public.staff(id) on delete set null,
  constraint staff_personal_dob check (date_of_birth is null or date_of_birth between date '1900-01-01' and current_date)
);
drop trigger if exists staff_personal_updated_at on public.staff_personal;
create trigger staff_personal_updated_at before update on public.staff_personal
  for each row execute function public.set_updated_at();

-- ── 6. payment ──────────────────────────────────────────────
-- How they are paid, by whom, and that they gave their bank details to the
-- payroll service themselves. No account or routing number is ever stored:
-- the check refuses anything that looks like one, wherever it is typed.
alter table public.org_settings add column if not exists payroll_service text not null default '';

create table if not exists public.staff_payment_setup (
  staff_id          uuid primary key references public.staff(id) on delete cascade,
  method            text not null check (method in ('Direct deposit through the payroll service', 'Paper check')),
  payer_of_record   text not null,
  payroll_service   text not null default '',
  bank_details_with_payroll boolean not null default false,
  confirmed_at      timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint staff_payment_no_account_numbers check (
    payer_of_record !~ '\d{5,}' and payroll_service !~ '\d{5,}'),
  constraint staff_payment_deposit_needs_payroll check (
    method <> 'Direct deposit through the payroll service' or bank_details_with_payroll)
);
drop trigger if exists staff_payment_setup_updated_at on public.staff_payment_setup;
create trigger staff_payment_setup_updated_at before update on public.staff_payment_setup
  for each row execute function public.set_updated_at();

-- ── 5. staff policies, signed in the app ────────────────────
-- Same shape as the portal terms: a version's text is frozen once stored, a
-- change is a new version, and a signature records the hash of exactly the
-- text that was signed.
create table if not exists public.staff_policies (
  key          text not null,
  version      integer not null,
  title        text not null,
  body         jsonb not null,
  text_sha256  text not null,
  is_current   boolean not null default false,
  published_at timestamptz not null default now(),
  primary key (key, version)
);
create unique index if not exists staff_policies_one_current on public.staff_policies (key) where is_current;

create or replace function public.staff_policies_frozen()
returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' or new.body is distinct from old.body or new.title is distinct from old.title
     or new.text_sha256 is distinct from old.text_sha256 or new.key is distinct from old.key
     or new.version is distinct from old.version then
    raise exception 'A policy version is a record of what people signed; publish a new version instead.'
      using errcode = 'insufficient_privilege';
  end if;
  return new;
end;
$$;
drop trigger if exists staff_policies_frozen on public.staff_policies;
create trigger staff_policies_frozen before update or delete on public.staff_policies
  for each row execute function public.staff_policies_frozen();

create table if not exists public.staff_policy_signatures (
  id              uuid primary key default gen_random_uuid(),
  staff_id        uuid not null references public.staff(id) on delete cascade,
  policy_key      text not null,
  policy_version  integer not null,
  text_sha256     text not null,
  signer_name     text not null check (trim(signer_name) <> ''),
  signer_ip       text not null default '',
  signed_at       timestamptz not null default now(),
  staff_file_id   uuid references public.staff_files(id) on delete set null,
  pdf_sha256      text not null default '',
  foreign key (policy_key, policy_version) references public.staff_policies(key, version),
  unique (staff_id, policy_key, policy_version)
);

create or replace function public.staff_policy_signatures_append_only()
returns trigger language plpgsql as $$
begin
  raise exception 'A signature is a record; it is never changed or removed.' using errcode = 'insufficient_privilege';
end;
$$;
drop trigger if exists staff_policy_signatures_append_only on public.staff_policy_signatures;
create trigger staff_policy_signatures_append_only before update or delete on public.staff_policy_signatures
  for each row execute function public.staff_policy_signatures_append_only();

-- The data-handling policy, from docs/data-handling-policy.md, with the paper
-- acknowledgement block replaced by the signature the app records.
insert into public.staff_policies (key, version, title, body, text_sha256, is_current)
select 'data-handling', 1, v.title, v.body, encode(extensions.digest(v.body::text, 'sha256'), 'hex'), true
  from (select $p$Data-handling policy$p$::text as title,
               $p$[
{"type":"p","text":"Zion Vocational Rehabilitation Center, 2880 S Main Street Ste 105, Salt Lake City, Utah 84115"},
{"type":"p","text":"Every person with a login to the Zion CRM signs this before their first use of the system. It is what a counselor, USOR, or an auditor will ask to see."},
{"type":"h2","text":"What this covers"},
{"type":"p","text":"The CRM holds information about people receiving vocational rehabilitation services: names, contact details, dates of birth, addresses, disabilities and accommodations, employment history, and the authorizations and invoices tied to their cases. Some of it we are trusted with because a person had no choice but to disclose it in order to get help finding work. It is handled accordingly."},
{"type":"h2","text":"The rules"},
{"type":"li","text":"Client data lives in the CRM only. Not on personal phones, not in personal text messages, not in personal email, not in spreadsheets on a laptop, not in a notes app. If you need it somewhere, that is a reason to fix the CRM, not to copy the data out of it."},
{"type":"li","text":"Your login is yours alone. Sharing a login is prohibited, including with another member of staff. Every note, form and invoice records who did it; a shared login makes that record a lie. Do not save your password in a shared browser profile."},
{"type":"li","text":"Access is need-to-know. Your role determines what you can see. Dates of birth, addresses, intake records and DWS-USOR 94 and 98 content are restricted to the administrator, Intake & Reports, and the staff member assigned to that client. Do not ask a colleague to look something up for you that your own role does not give you."},
{"type":"li","text":"Client documents go into the client record. Signed USOR forms, work schedules and authorizations are uploaded to the client in the CRM - not left in a Downloads folder, an email attachment, or a desk drawer. Delete local copies once uploaded."},
{"type":"li","text":"Texting and calling. Until the CRM handles messaging directly, use the business lines - 801-657-6671 for counselors, 385-406-3432 for clients - and log the outcome in the CRM. Do not use a personal number."},
{"type":"li","text":"Departing staff lose access the same day. The administrator deactivates the account, which cuts off access immediately. Anyone leaving returns any printed client material before their last day."},
{"type":"li","text":"Report any suspected exposure to the owner immediately. A phone left in a taxi, an email sent to the wrong counselor, a document left on a printer, a login you think someone else has used. Same day, no exceptions, no blame for reporting. The damage from a late report is always worse than the damage from the mistake."},
{"type":"li","text":"Do not discuss client information where it can be overheard, and do not share it with family, friends, or on social media - including details you think are anonymous. In a caseload this size, they are not."},
{"type":"h2","text":"What happens if this is broken"},
{"type":"p","text":"Depending on what happened: retraining, removal of access, or dismissal, and where the law requires it, notification of the affected person and of the Utah State Office of Rehabilitation."},
{"type":"h2","text":"Acknowledgement"},
{"type":"p","text":"I have read this policy. I understand what I may access and what I may not, and I understand that I am responsible for what happens under my login."}
]$p$::jsonb as body) v
 where not exists (select 1 from public.staff_policies where key = 'data-handling');

-- ── the walkthrough itself ──────────────────────────────────
-- A row means the person was brought on through the walkthrough. People who
-- joined before it have none and are never sent through it.
create table if not exists public.staff_onboarding (
  staff_id                   uuid primary key references public.staff(id) on delete cascade,
  started_at                 timestamptz not null default now(),
  certifications_confirmed_at timestamptz,
  completed_at               timestamptz,
  last_reminded_on           date
);

-- ── 2. identity documents ───────────────────────────────────
-- An I-9's documents must be examined in person, original in hand; a scan
-- uploaded here is not that. The file carries when Admin did it, and until
-- then every screen says it is still required.
insert into public.staff_file_categories (key, label, detail, system_only, sort_order) values
  ('Identity document', 'Identity document', 'A photo ID, for somebody who does not complete an I-9.', false, 21)
on conflict (key) do nothing;

alter table public.staff_files add column if not exists inspected_at timestamptz;
alter table public.staff_files add column if not exists inspected_by uuid references public.staff(id) on delete set null;

create or replace function public.record_identity_inspection(p_file_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_cat text;
begin
  if not public.is_admin() then
    raise exception 'Only Admin records an in-person inspection.' using errcode = 'insufficient_privilege';
  end if;
  select category into v_cat from public.staff_files where id = p_file_id;
  if v_cat is null then
    raise exception 'That document is not on file.' using errcode = 'check_violation';
  end if;
  if v_cat not in ('I-9', 'Identity document') then
    raise exception 'Only identity documents are inspected in person.' using errcode = 'check_violation';
  end if;
  update public.staff_files
     set inspected_at = now(), inspected_by = public.current_staff_id()
   where id = p_file_id and inspected_at is null;
end;
$$;

create or replace view public.staff_documents as
select f.id,
       f.staff_id,
       f.filename,
       f.category,
       coalesce(c.label, f.category)          as category_label,
       coalesce(c.system_only, false)         as system_generated,
       f.note,
       f.size_bytes,
       f.mime_type,
       f.storage_path,
       f.created_at,
       f.uploaded_by,
       u.name                                 as uploaded_by_name,
       exists (select 1 from public.staff_credentials sc where sc.file_id = f.id)
                                              as backs_a_credential,
       f.category = 'I-9' and f.inspected_at is null
                                              as inspection_required,
       f.inspected_at,
       i.name                                 as inspected_by_name
  from public.staff_files f
  left join public.staff_file_categories c on c.key = f.category
  left join public.staff s on s.id = f.staff_id
  left join public.staff u on u.id = f.uploaded_by
  left join public.staff i on i.id = f.inspected_by;

alter view public.staff_documents set (security_invoker = true);

-- ── 3. certifications ───────────────────────────────────────
-- A person may put forward their own card: it lands unverified, with the scan
-- behind it, and reads "Awaiting check" until Admin has looked. Verifying stays
-- Admin's - a person confirming their own credential is still not a check.
create or replace function public.submit_own_credential(
  p_type_key  text,
  p_reference text,
  p_issued_on date,
  p_expires_on date,
  p_file_id   uuid,
  p_note      text
)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_me    uuid := public.current_staff_id();
  v_type  public.credential_types%rowtype;
  v_owner uuid;
  v_id    uuid;
begin
  if v_me is null or not public.is_active_staff() then
    raise exception 'Only staff put forward credentials.' using errcode = 'insufficient_privilege';
  end if;
  select * into v_type from public.credential_types where key = p_type_key and active;
  if not found then
    raise exception 'Unknown credential.' using errcode = 'check_violation';
  end if;
  if v_type.kind <> 'certificate' then
    raise exception 'Continuing education is logged as hours, not as a certificate.' using errcode = 'check_violation';
  end if;
  if v_type.expires and p_expires_on is null then
    raise exception 'A % expires - put the date on it.', v_type.label using errcode = 'check_violation';
  end if;
  if p_file_id is null then
    raise exception 'Add a scan or photo of the card, so it can be checked.' using errcode = 'check_violation';
  end if;
  select staff_id into v_owner from public.staff_files where id = p_file_id;
  if v_owner is distinct from v_me then
    raise exception 'That document is not on your file.' using errcode = 'insufficient_privilege';
  end if;

  insert into public.staff_credentials (staff_id, type_key, reference, issued_on, expires_on, file_id, note, created_by)
  values (v_me, p_type_key, coalesce(trim(p_reference), ''), p_issued_on, p_expires_on, p_file_id,
          coalesce(trim(p_note), ''), v_me)
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.verify_credential(p_credential_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then
    raise exception 'Only Admin checks a credential.' using errcode = 'insufficient_privilege';
  end if;
  update public.staff_credentials
     set verified_by = public.current_staff_id(), verified_at = now()
   where id = p_credential_id and verified_at is null;
end;
$$;

create or replace view public.staff_credential_status as
with required as (
  select s.id as staff_id, t.key as type_key, t.label, t.kind, t.expires,
         t.warn_days, t.hours_target, t.applies_to, t.sort_order,
         (t.applies_to = 'everyone' or coalesce(e.transports_clients, false)) as required
    from public.staff s
    cross join public.credential_types t
    left join public.staff_employment e on e.staff_id = s.id
   where s.active and t.active
),
latest as (
  select distinct on (c.staff_id, c.type_key)
         c.staff_id, c.type_key, c.id as credential_id,
         c.issued_on, c.expires_on, c.reference, c.file_id,
         c.verified_at, c.verified_by
    from public.staff_credentials c
   order by c.staff_id, c.type_key, c.expires_on desc nulls first, c.created_at desc
),
ce as (
  select staff_id,
         sum(hours) filter (
           where on_date >= date_trunc('year', public.practice_today())::date
         ) as hours_this_year,
         max(on_date) as last_entry_on
    from public.ce_entries
   group by staff_id
)
select r.staff_id,
       r.type_key,
       r.label,
       r.kind,
       r.required,
       r.sort_order,
       l.credential_id,
       l.reference,
       l.issued_on,
       l.expires_on,
       l.file_id,
       l.verified_at,
       coalesce(c.hours_this_year, 0)                            as hours_this_year,
       r.hours_target,
       c.last_entry_on,
       case
         when r.kind = 'hours' then
           case
             when not r.required then 'Not required'
             when coalesce(c.hours_this_year, 0) >= coalesce(r.hours_target, 0) then 'Met'
             else 'Outstanding'
           end
         when l.credential_id is null then
           case when r.required then 'Missing' else 'Not held' end
         -- Put forward by the person and not yet looked at. An expired card is
         -- still expired, checked or not.
         when r.expires and l.expires_on is not null and l.expires_on < public.practice_today() then 'Expired'
         when l.verified_at is null then 'Awaiting check'
         when not r.expires or l.expires_on is null then 'Valid'
         when l.expires_on <= public.practice_today() + r.warn_days then 'Expiring'
         else 'Valid'
       end                                                       as state,
       case when l.expires_on is null then null
            else l.expires_on - public.practice_today() end       as days_left
  from required r
  left join latest l on l.staff_id = r.staff_id and l.type_key = r.type_key
  left join ce c on c.staff_id = r.staff_id and r.kind = 'hours'
 where r.required or l.credential_id is not null;

alter view public.staff_credential_status set (security_invoker = true);

create or replace view public.credential_attention as
select s.staff_id,
       st.name        as staff_name,
       st.role        as staff_role,
       s.type_key,
       s.label,
       s.state,
       s.expires_on,
       s.days_left,
       s.hours_this_year,
       s.hours_target,
       case s.state
         when 'Expired'        then 1
         when 'Missing'        then 2
         when 'Awaiting check' then 3
         when 'Expiring'       then 4
         when 'Outstanding'    then 5
         else 9
       end            as urgency
  from public.staff_credential_status s
  join public.staff st on st.id = s.staff_id
 where s.state in ('Expired', 'Missing', 'Awaiting check', 'Expiring', 'Outstanding');

alter view public.credential_attention set (security_invoker = true);

-- ── each step, worked out ───────────────────────────────────
-- One definition, used by the checklist, the walkthrough, the reminders and
-- the completion notice, so none of them can disagree about a step.
-- Security definer so the nightly run can ask about anybody; a signed-in
-- person asking about somebody else who is not theirs to see gets null.
create or replace function public.onboarding_step_done(p_staff uuid, p_key text)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare
  v_type text;
begin
  if auth.uid() is not null and coalesce(auth.role(), '') <> 'service_role'
     and not (public.is_admin() or p_staff = public.current_staff_id()) then
    return null;
  end if;
  select coalesce(employment_type, 'Contractor') into v_type from public.staff_employment where staff_id = p_staff;
  v_type := coalesce(v_type, 'Contractor');

  return case p_key
    when 'personal_details' then exists (
      select 1 from public.staff_personal p
       where p.staff_id = p_staff
         and trim(p.legal_name) <> '' and trim(p.address_line1) <> '' and trim(p.city) <> ''
         and trim(p.state) <> '' and trim(p.postal_code) <> '' and trim(p.phone) <> ''
         and p.date_of_birth is not null
         and trim(p.emergency_name) <> '' and trim(p.emergency_phone) <> '')
    when 'identity_documents' then exists (
      select 1 from public.staff_files f
       where f.staff_id = p_staff
         and f.category = case when v_type = 'Employee' then 'I-9' else 'Identity document' end)
    when 'identity_inspected' then
      exists (select 1 from public.staff_files f where f.staff_id = p_staff and f.category = 'I-9')
      and not exists (select 1 from public.staff_files f
                       where f.staff_id = p_staff and f.category = 'I-9' and f.inspected_at is null)
    when 'certifications_submitted' then
      exists (select 1 from public.staff_onboarding o
               where o.staff_id = p_staff and o.certifications_confirmed_at is not null)
      or not exists (select 1 from public.staff_credential_status cs
                      where cs.staff_id = p_staff and cs.kind = 'certificate' and cs.state = 'Missing')
    when 'tax_form_signed' then exists (
      select 1 from public.tax_form_submissions f
        left join public.contractor_profiles cp on cp.staff_id = f.staff_id
       where f.staff_id = p_staff and f.status = 'Signed'
         and f.form_type = case
               when v_type = 'Employee' then 'W-4'
               when cp.tax_status = 'Foreign person' then 'W-8BEN'
               else 'W-9' end)
    when 'policy_signed' then
      exists (select 1 from public.staff_policy_signatures g
                join public.staff_policies sp on sp.key = g.policy_key and sp.version = g.policy_version
               where g.staff_id = p_staff and sp.key = 'data-handling' and sp.is_current)
      -- Signed on paper before the app could take a signature, and ticked then.
      or exists (select 1 from public.staff_checklist_items i
                   join public.checklist_tasks t on t.id = i.task_id
                  where i.staff_id = p_staff and t.auto_key = 'policy_signed' and i.done_on is not null)
    when 'payment_setup' then exists (
      select 1 from public.staff_payment_setup ps where ps.staff_id = p_staff)
    else null
  end;
end;
$$;

-- The six the person does, in the order they do them. Inspection is Admin's.
create or replace function public.onboarding_open_steps(p_staff uuid)
returns text[] language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(k order by n), '{}')
    from unnest(array['personal_details', 'identity_documents', 'certifications_submitted',
                      'tax_form_signed', 'policy_signed', 'payment_setup']) with ordinality as x(k, n)
   where public.onboarding_step_done(p_staff, k) is not true;
$$;

-- ── the checklist gains the steps ───────────────────────────
-- The paper item "Signed the data handling policy" becomes automatic; a tick
-- given before today still counts (see policy_signed above).
update public.checklist_tasks
   set auto_key = 'policy_signed', sort_order = 22,
       detail = 'Signed in the app during onboarding, or on paper and ticked before that. The signed copy is on their file.'
 where phase = 'Onboarding' and label = 'Signed the data handling policy' and auto_key is null;

insert into public.checklist_tasks (phase, label, detail, applies_to, auto_key, required, sort_order)
select v.* from (values
  ('Onboarding', 'Personal details on file',
   'Legal name, address, phone, date of birth and an emergency contact.',
   array['Employee','Contractor'], 'personal_details', true, 12),
  ('Onboarding', 'Identity documents uploaded',
   'I-9 documents for an employee; a photo ID for a contractor.',
   array['Employee','Contractor'], 'identity_documents', true, 14),
  ('Onboarding', 'I-9 documents inspected in person',
   'The originals, in hand, within three business days of starting. Recorded on the document by Admin.',
   array['Employee'], 'identity_inspected', true, 15),
  ('Onboarding', 'Certifications put forward',
   'What they hold, with expiry dates and a scan of each. Each is checked by Admin on their record.',
   array['Employee','Contractor'], 'certifications_submitted', true, 16),
  ('Onboarding', 'Payment method and payer confirmed',
   'How they are paid and who pays them. Bank details go to the payroll service, never here.',
   array['Employee','Contractor'], 'payment_setup', true, 24)
) as v(phase, label, detail, applies_to, auto_key, required, sort_order)
where not exists (select 1 from public.checklist_tasks t where t.auto_key = v.auto_key);

create or replace view public.staff_checklist as
select s.id                                        as staff_id,
       s.name                                      as staff_name,
       s.active                                    as staff_active,
       coalesce(e.employment_type, 'Contractor')   as employment_type,
       t.id                                        as task_id,
       t.phase,
       t.label,
       t.detail,
       t.auto_key,
       t.required,
       t.sort_order,
       case t.auto_key
         when 'account_accepted' then s.accepted_at is not null
         when 'tax_form_signed' then public.onboarding_step_done(s.id, 'tax_form_signed')
         when 'address_on_file' then coalesce(nullif(p.address_line1, ''), '') <> ''
         when 'pay_rate_set' then exists (select 1 from public.staff_pay r where r.staff_id = s.id)
         when 'tour_completed' then (select tp.hints_seen >= tp.hints_total and tp.hints_total > 0
                                       from public.my_tour_progress tp where tp.staff_id = s.id)
         when 'personal_details' then public.onboarding_step_done(s.id, 'personal_details')
         when 'identity_documents' then public.onboarding_step_done(s.id, 'identity_documents')
         when 'identity_inspected' then public.onboarding_step_done(s.id, 'identity_inspected')
         when 'certifications_submitted' then public.onboarding_step_done(s.id, 'certifications_submitted')
         when 'policy_signed' then public.onboarding_step_done(s.id, 'policy_signed')
         when 'payment_setup' then public.onboarding_step_done(s.id, 'payment_setup')
         when 'account_closed' then not s.active
         when 'clients_reassigned' then not exists (
           select 1 from public.clients c where c.assigned_staff_id = s.id and c.status = 'Active')
         when 'tasks_reassigned' then not exists (
           select 1 from public.tasks k where k.assigned_staff_id = s.id and k.status = 'Open')
         when 'statements_settled' then not exists (
           select 1 from public.contractor_statements st
            where st.staff_id = s.id and st.status in ('Draft', 'Submitted'))
         else null
       end                                          as auto_done,
       i.done_on,
       i.done_by,
       coalesce(i.note, '')                         as note
  from public.staff s
  cross join public.checklist_tasks t
  left join public.staff_employment e on e.staff_id = s.id
  left join public.contractor_profiles p on p.staff_id = s.id
  left join public.staff_checklist_items i on i.staff_id = s.id and i.task_id = t.id
 where t.active
   and (t.applies_to is null or coalesce(e.employment_type, 'Contractor') = any(t.applies_to))
   and ((select public.is_admin()) or s.id = (select public.current_staff_id()));

alter view public.staff_checklist set (security_invoker = true);

-- ── the person's own actions ────────────────────────────────
create or replace function public.confirm_onboarding_certifications()
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.staff_onboarding
     set certifications_confirmed_at = coalesce(certifications_confirmed_at, now())
   where staff_id = public.current_staff_id();
end;
$$;

create or replace function public.sign_staff_policy(
  p_key text, p_version integer, p_signer text, p_ip text, p_file_id uuid, p_pdf_sha256 text
)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_me     uuid := public.current_staff_id();
  v_policy public.staff_policies%rowtype;
  v_owner  uuid;
  v_legal  text;
begin
  if v_me is null or not public.is_active_staff() then
    raise exception 'Only staff sign staff policies.' using errcode = 'insufficient_privilege';
  end if;
  select * into v_policy from public.staff_policies where key = p_key and version = p_version;
  if not found or not v_policy.is_current then
    raise exception 'That is not the current version of the policy. Reload and read it again.' using errcode = 'check_violation';
  end if;
  if coalesce(trim(p_signer), '') = '' then
    raise exception 'Type your name to sign.' using errcode = 'check_violation';
  end if;
  select nullif(trim(legal_name), '') into v_legal from public.staff_personal where staff_id = v_me;
  if v_legal is not null and lower(trim(p_signer)) <> lower(v_legal) then
    raise exception 'Sign with your legal name as it is on file: %.', v_legal using errcode = 'check_violation';
  end if;
  select staff_id into v_owner from public.staff_files where id = p_file_id;
  if v_owner is distinct from v_me then
    raise exception 'The signed copy must be on your own file.' using errcode = 'insufficient_privilege';
  end if;

  insert into public.staff_policy_signatures
    (staff_id, policy_key, policy_version, text_sha256, signer_name, signer_ip, staff_file_id, pdf_sha256)
  values (v_me, p_key, p_version, v_policy.text_sha256, trim(p_signer), coalesce(p_ip, ''), p_file_id, coalesce(p_pdf_sha256, ''))
  on conflict (staff_id, policy_key, policy_version) do nothing;
end;
$$;

-- Marks the walkthrough done once the six are, and tells Admin - on the
-- dashboard at once, and in that night's email. Returns true only the first
-- time, so the caller knows to send the email now.
create or replace function public.refresh_onboarding(p_staff uuid)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  v_row   public.staff_onboarding%rowtype;
  v_name  text;
  v_inspect boolean;
begin
  if auth.uid() is not null and coalesce(auth.role(), '') <> 'service_role'
     and not (public.is_admin() or p_staff = public.current_staff_id()) then
    raise exception 'That is not your onboarding.' using errcode = 'insufficient_privilege';
  end if;
  select * into v_row from public.staff_onboarding where staff_id = p_staff for update;
  if not found or v_row.completed_at is not null then
    return false;
  end if;
  if cardinality(public.onboarding_open_steps(p_staff)) > 0 then
    return false;
  end if;

  update public.staff_onboarding set completed_at = now() where staff_id = p_staff;
  select name into v_name from public.staff where id = p_staff;
  v_inspect := exists (select 1 from public.staff_files f
                        where f.staff_id = p_staff and f.category = 'I-9' and f.inspected_at is null);

  insert into public.notifications (dedupe_key, kind, level, text, roles, href, staff_id)
  values ('onboarding_done:' || p_staff, 'onboarding_done', 'warn',
          v_name || ' finished onboarding.' ||
            case when v_inspect then ' Their I-9 documents still need inspecting in person.' else '' end,
          array['Admin'], '/admin/people/' || p_staff, null)
  on conflict (dedupe_key) do update set text = excluded.text, resolved_at = null;
  return true;
end;
$$;

-- ── Admin opening somebody's personal details ───────────────
alter table public.access_log drop constraint if exists access_log_subject_check;
alter table public.access_log add constraint access_log_subject_check
  check (subject in (
    'Client restricted details', 'Client intake', 'Contractor tax number', 'Signed tax form',
    'Staff document', 'Records request', 'Staff personal details'));

create or replace function public.note_staff_personal_access(p_staff uuid)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if p_staff = public.current_staff_id() then
    return true;
  end if;
  if not public.is_admin() then
    perform public.log_access('Staff personal details', null, p_staff, 'refused');
    return false;
  end if;
  perform public.log_access('Staff personal details', null, p_staff, 'opened personal details');
  return true;
end;
$$;

-- ── rules ───────────────────────────────────────────────────
alter table public.staff_personal enable row level security;
alter table public.staff_payment_setup enable row level security;
alter table public.staff_policies enable row level security;
alter table public.staff_policy_signatures enable row level security;
alter table public.staff_onboarding enable row level security;

drop policy if exists staff_personal_read on public.staff_personal;
drop policy if exists staff_personal_insert on public.staff_personal;
drop policy if exists staff_personal_update on public.staff_personal;
drop policy if exists staff_personal_delete on public.staff_personal;
create policy staff_personal_read on public.staff_personal for select to authenticated
  using ((select public.is_admin()) or staff_id = (select public.current_staff_id()));
create policy staff_personal_insert on public.staff_personal for insert to authenticated
  with check ((select public.is_admin()) or staff_id = (select public.current_staff_id()));
create policy staff_personal_update on public.staff_personal for update to authenticated
  using ((select public.is_admin()) or staff_id = (select public.current_staff_id()))
  with check ((select public.is_admin()) or staff_id = (select public.current_staff_id()));
create policy staff_personal_delete on public.staff_personal for delete to authenticated
  using ((select public.is_admin()));

drop policy if exists staff_payment_read on public.staff_payment_setup;
drop policy if exists staff_payment_insert on public.staff_payment_setup;
drop policy if exists staff_payment_update on public.staff_payment_setup;
drop policy if exists staff_payment_delete on public.staff_payment_setup;
create policy staff_payment_read on public.staff_payment_setup for select to authenticated
  using ((select public.is_admin()) or staff_id = (select public.current_staff_id()));
create policy staff_payment_insert on public.staff_payment_setup for insert to authenticated
  with check ((select public.is_admin()) or staff_id = (select public.current_staff_id()));
create policy staff_payment_update on public.staff_payment_setup for update to authenticated
  using ((select public.is_admin()) or staff_id = (select public.current_staff_id()))
  with check ((select public.is_admin()) or staff_id = (select public.current_staff_id()));
create policy staff_payment_delete on public.staff_payment_setup for delete to authenticated
  using ((select public.is_admin()));

drop policy if exists staff_policies_read on public.staff_policies;
drop policy if exists staff_policies_write on public.staff_policies;
create policy staff_policies_read on public.staff_policies for select to authenticated
  using ((select public.is_active_staff()));
create policy staff_policies_write on public.staff_policies for all to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));

drop policy if exists staff_policy_signatures_read on public.staff_policy_signatures;
create policy staff_policy_signatures_read on public.staff_policy_signatures for select to authenticated
  using ((select public.is_admin()) or staff_id = (select public.current_staff_id()));

drop policy if exists staff_onboarding_read on public.staff_onboarding;
drop policy if exists staff_onboarding_admin_write on public.staff_onboarding;
create policy staff_onboarding_read on public.staff_onboarding for select to authenticated
  using ((select public.is_admin()) or staff_id = (select public.current_staff_id()));
create policy staff_onboarding_admin_write on public.staff_onboarding for all to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));

-- An inactive person's record is kept as it was (0085).
drop trigger if exists staff_personal_frozen_when_inactive on public.staff_personal;
create trigger staff_personal_frozen_when_inactive before insert or update or delete on public.staff_personal
  for each row execute function public.staff_record_frozen();
drop trigger if exists staff_payment_setup_frozen_when_inactive on public.staff_payment_setup;
create trigger staff_payment_setup_frozen_when_inactive before insert or update or delete on public.staff_payment_setup
  for each row execute function public.staff_record_frozen();
drop trigger if exists staff_policy_signatures_frozen_when_inactive on public.staff_policy_signatures;
create trigger staff_policy_signatures_frozen_when_inactive before insert on public.staff_policy_signatures
  for each row execute function public.staff_record_frozen();

revoke all on public.staff_personal, public.staff_payment_setup, public.staff_policies,
              public.staff_policy_signatures, public.staff_onboarding from anon;
revoke insert, update, delete, truncate on public.staff_policy_signatures from authenticated;
revoke truncate on public.staff_personal, public.staff_payment_setup, public.staff_policies, public.staff_onboarding from authenticated;
grant select, insert, update, delete on public.staff_personal, public.staff_payment_setup to authenticated;
grant select, insert, update, delete on public.staff_policies, public.staff_onboarding to authenticated;
grant select on public.staff_policy_signatures to authenticated;
grant all on public.staff_personal, public.staff_payment_setup, public.staff_policies,
             public.staff_policy_signatures, public.staff_onboarding to service_role;

revoke execute on function public.staff_policies_frozen() from public, anon, authenticated;
revoke execute on function public.staff_policy_signatures_append_only() from public, anon, authenticated;
revoke execute on function public.onboarding_step_done(uuid, text) from public, anon;
revoke execute on function public.onboarding_open_steps(uuid) from public, anon, authenticated;
revoke execute on function public.record_identity_inspection(uuid) from public, anon;
revoke execute on function public.submit_own_credential(text, text, date, date, uuid, text) from public, anon;
revoke execute on function public.verify_credential(uuid) from public, anon;
revoke execute on function public.confirm_onboarding_certifications() from public, anon;
revoke execute on function public.sign_staff_policy(text, integer, text, text, uuid, text) from public, anon;
revoke execute on function public.refresh_onboarding(uuid) from public, anon;
revoke execute on function public.note_staff_personal_access(uuid) from public, anon;
grant execute on function public.onboarding_step_done(uuid, text) to authenticated, service_role;
grant execute on function public.onboarding_open_steps(uuid) to service_role;
grant execute on function public.record_identity_inspection(uuid) to authenticated, service_role;
grant execute on function public.submit_own_credential(text, text, date, date, uuid, text) to authenticated;
grant execute on function public.verify_credential(uuid) to authenticated;
grant execute on function public.confirm_onboarding_certifications() to authenticated;
grant execute on function public.sign_staff_policy(text, integer, text, text, uuid, text) to authenticated;
grant execute on function public.refresh_onboarding(uuid) to authenticated, service_role;
grant execute on function public.note_staff_personal_access(uuid) to authenticated;

-- ── nightly: open steps, finished onboarding, cards awaiting a check ──
-- generate_notifications_on as it stood (0093), with 11b, 13 and 14 added.
CREATE OR REPLACE FUNCTION public.generate_notifications_on(p_today date)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  n_open      integer;
  v_today     date := coalesce(p_today, public.practice_today());
  last_month  text := to_char((date_trunc('month', v_today) - interval '1 day'), 'YYYY-MM');
  tax_year    integer := extract(year from v_today)::int - 1;
  in_season   boolean := (extract(month from v_today) = 1 and extract(day from v_today) >= 2)
                         or extract(month from v_today) = 2;
  past_target boolean := (extract(month from v_today) = 1 and extract(day from v_today) >= 15)
                         or extract(month from v_today) = 2;
  v_threshold numeric;
  n_due       integer;
begin
  drop table if exists _current;
  drop table if exists _used;

  create temporary table _current (
    dedupe_key text primary key,
    kind text, level text, text text, roles text[], href text,
    client_id uuid, staff_id uuid
  ) on commit drop;

  create temporary table _used on commit drop as
  select a.id, a.client_id, a.number, a.service_type, a.total_hours, a.end_date,
         a.carried_used + coalesce(
           (select sum(e.hours) from public.service_entries e
             where e.auth_id = a.id and not e.non_billable), 0) as used
    from public.authorizations a
   where a.status = 'Open';

  -- 1. Authorizations out of hours, or nearly.
  insert into _current
  select 'auth_hours:' || u.id,
         case when u.total_hours - u.used <= 0 then 'auth_exhausted' else 'auth_low' end,
         case when u.total_hours - u.used <= 0 then 'bad' else 'warn' end,
         case
           when u.total_hours - u.used <= 0 then
             coalesce(nullif(u.number, ''), u.service_type) || ' (' || u.service_type ||
             ') has no hours left — request additional hours before more service.'
           else
             coalesce(nullif(u.number, ''), u.service_type) || ' (' || u.service_type ||
             ') is under 10% remaining (' || public.fmt_hours(u.total_hours - u.used) || ' hrs).'
         end,
         case when u.total_hours - u.used <= 0
              then array['Admin','Billing','Job Search'] else array['Admin','Billing'] end,
         '/clients/' || u.client_id || '?tab=authorizations',
         u.client_id, null
    from _used u
   where u.total_hours is not null and u.total_hours - u.used <= u.total_hours * 0.1;

  -- 2. Authorizations ending within a fortnight.
  insert into _current
  select 'auth_ending:' || u.id, 'auth_ending', 'warn',
         coalesce(nullif(u.number, ''), u.service_type) || ' ends ' || u.end_date ||
         ' — unbilled work after that date will not be paid.',
         array['Admin','Billing'],
         '/clients/' || u.client_id || '?tab=authorizations', u.client_id, null
    from _used u
   where u.end_date is not null and u.end_date >= v_today and u.end_date <= v_today + 14;

  -- 3. Invoices sent and unpaid, escalating at 30 / 60 / 90.
  insert into _current
  select 'invoice_unpaid:' || i.id || ':' ||
         case when v_today - i.date >= 90 then '90'
              when v_today - i.date >= 60 then '60' else '30' end,
         'invoice_unpaid',
         case when v_today - i.date >= 90 then 'bad' else 'warn' end,
         'Invoice ' || i.number || ' unpaid ' || (v_today - i.date) || ' days.',
         array['Admin','Billing'], '/billing?tab=invoices', a.client_id, null
    from public.invoices i
    join public.authorizations a on a.id = i.auth_id
   where i.status = 'Sent' and v_today - i.date >= 30;

  -- 4. Overdue tasks.
  insert into _current
  select 'task_overdue:' || t.id, 'task_overdue', 'warn',
         'Overdue task: ' || t.title,
         array_remove(array['Admin', s.role], null), '/tasks', t.client_id, t.assigned_staff_id
    from public.tasks t
    left join public.staff s on s.id = t.assigned_staff_id
   where t.status = 'Open' and t.due is not null and t.due < v_today;

  -- 5. Monthly USOR reports, due by the 15th.
  if extract(day from v_today) <= 15 then
    insert into _current
    select 'monthly_forms:' || u.id || ':' || last_month, 'monthly_forms', 'warn',
           missing.usors || ' for ' || last_month || ' due by the 15th — ' ||
           c.name || ' (' || coalesce(nullif(u.number, ''), u.service_type) || ')',
           array['Admin','Billing','Job Search'],
           '/clients/' || u.client_id || '?tab=forms', u.client_id, null
      from _used u
      join public.clients c on c.id = u.client_id
      cross join lateral (
        select string_agg(t.usor, ' + ' order by t.sort_order) as usors
          from public.form_templates t
         where t.monthly and t.required_for_billing
           and u.service_type = any (t.services)
           and not exists (
             select 1 from public.forms f
              where f.auth_id = u.id and f.template_id = t.id
                and f.month = last_month and f.status <> 'Draft')
      ) missing
     where u.service_type in ('Job Coaching', 'Job Development', 'Job Development + HQ Indicator')
       and missing.usors is not null
       and (
         exists (select 1 from public.service_entries e
                  where e.auth_id = u.id and to_char(e.date, 'YYYY-MM') = last_month)
         or exists (select 1 from public.notes n
                     where n.client_id = u.client_id
                       and to_char(n.at, 'YYYY-MM') = last_month
                       and n.type in ('Job search','Application submitted','Interview','Employer contact'))
       );
  end if;

  -- 6. Counselor follow-ups now due.
  insert into _current
  select 'followup:' || cl.id, 'followup_due', 'warn',
         'Counselor follow-up due: ' || cl.topic,
         array_remove(array['Admin', s.role], null), '/counselors', cl.client_id, cl.staff_id
    from public.contact_log cl
    left join public.staff s on s.id = cl.staff_id
   where cl.follow_up is not null and not cl.follow_up_done and cl.follow_up <= v_today;

  -- ── 7. A foreign contractor with no W-8BEN on file ──────────
  insert into _current
  select 'w8ben_missing:' || s.id, 'w8ben_missing', 'warn',
         s.name || ' is a foreign person with no W-8BEN on file. One is needed before payment.',
         array['Admin'], '/staff', null, s.id
    from public.staff s
    join public.contractor_profiles p on p.staff_id = s.id
   where s.active and p.tax_status = 'Foreign person' and p.w8ben_received_on is null;

  -- ── 8. A W-8BEN expiring, or already expired ────────────────
  --      Valid through the last day of the third succeeding calendar year;
  --      60 days' notice is enough to get a fresh one signed and returned.
  insert into _current
  select 'w8ben_expiry:' || s.id || ':' || to_char(p.w8ben_expires_on, 'YYYY'),
         case when p.w8ben_expires_on < v_today then 'w8ben_expired' else 'w8ben_expiring' end,
         case when p.w8ben_expires_on < v_today then 'bad' else 'warn' end,
         case when p.w8ben_expires_on < v_today
              then s.name || '''s W-8BEN expired on ' || p.w8ben_expires_on || '. A new one is needed.'
              else s.name || '''s W-8BEN expires ' || p.w8ben_expires_on || ' — ask for a new one.'
         end,
         array['Admin'], '/staff', null, s.id
    from public.staff s
    join public.contractor_profiles p on p.staff_id = s.id
   where s.active
     and p.tax_status = 'Foreign person'
     and p.w8ben_expires_on is not null
     and p.w8ben_expires_on <= v_today + 60;

  -- ── 9. January: the threshold the CPA confirms ──────────────
  if in_season then
    select federal_threshold into v_threshold from public.tax_years where year = tax_year;

    if v_threshold is null then
      insert into _current values (
        'tax_threshold:' || tax_year, 'tax_threshold_unconfirmed', 'warn',
        'Confirm the ' || tax_year || ' federal 1099-NEC threshold with your CPA, and whether Utah requires a state copy. Nothing can be generated until it is entered.',
        array['Admin'], '/staff?tab=tax', null, null);
    else
      -- ── 10. January: the run itself ─────────────────────────
      select count(*) into n_due from public.form_1099_candidates(tax_year);

      if n_due > 0 and not exists (
        select 1 from public.form_1099_runs where year = tax_year
      ) then
        insert into _current values (
          'form_1099_run:' || tax_year, 'form_1099_due',
          case when past_target then 'bad' else 'warn' end,
          n_due || ' contractor' || case when n_due = 1 then '' else 's' end ||
          ' need a ' || tax_year || ' 1099-NEC. ' ||
          case when past_target
               then 'Past the 15 January target — recipient copies and filing are due by 31 January.'
               else 'Aim to generate by 15 January; delivery and filing are due by 31 January.'
          end,
          array['Admin'], '/staff?tab=tax', null, null);
      end if;
    end if;
  end if;

  -- 11. Certifications and clearances.
  --
  -- Missing and expired are the same colour on purpose: somebody without a
  -- current background check is in the same position whether the card ran out
  -- or was never recorded, and the difference is a matter for the
  -- conversation rather than for the flag.
  --
  -- The state is in the dedupe key, so a card moving from Expiring to Expired
  -- raises a new flag and resolves the old one, rather than quietly rewriting
  -- the first and losing the date it started.
  insert into _current
  select 'credential:' || a.staff_id || ':' || a.type_key || ':' || a.state,
         'credential_' || lower(a.state),
         case when a.state in ('Expired', 'Missing') then 'bad' else 'warn' end,
         case a.state
           when 'Missing' then
             a.staff_name || ' has no ' || a.label || ' on file.'
           when 'Expired' then
             a.staff_name || '''s ' || a.label || ' expired ' || a.expires_on || '.'
           else
             a.staff_name || '''s ' || a.label || ' expires ' || a.expires_on ||
             ' - ' || a.days_left || ' days.'
         end,
         array['Admin'],
         '/admin/staff',
         null,
         -- Named so the person themselves sees it, and nobody else in their
         -- role does. A colleague has no business knowing whose CPR card has
         -- run out.
         a.staff_id
    from public.credential_attention a
   where a.state in ('Expired', 'Missing', 'Expiring');

  -- 11b. A card somebody put forward themselves, waiting for Admin to look.
  --      Admin only: it is a request to check, not news for the person.
  insert into _current
  select 'credential:' || a.staff_id || ':' || a.type_key || ':' || a.state,
         'credential_awaiting_check',
         'warn',
         a.staff_name || ' put forward their ' || a.label || ' - check it against the scan and verify.',
         array['Admin'],
         '/admin/people/' || a.staff_id,
         null,
         null
    from public.credential_attention a
   where a.state = 'Awaiting check';

  -- 12. Continuing education, but only once it matters.
  --
  -- Somebody being short of hours in February is not news; being short in
  -- October is. Raising it in January would train everybody to ignore it for
  -- nine months and then miss it in the tenth.
  if extract(month from v_today) >= 10 then
    insert into _current
    select 'ce_short:' || a.staff_id || ':' || extract(year from v_today),
           'credential_ce',
           case when extract(month from v_today) = 12 then 'bad' else 'warn' end,
           a.staff_name || ' has ' || a.hours_this_year || ' of ' ||
           a.hours_target || ' training hours for the year.',
           array['Admin'],
           '/paperwork',
           null,
           a.staff_id
      from public.credential_attention a
     where a.state = 'Outstanding';
  end if;

  -- 13. Onboarding steps still open (0100). Named to the person, so it is on
  --     their own dashboard, and addressed to Admin, who is waiting on it.
  --     Only for somebody who has signed in: before that the invite is what
  --     is outstanding, and Admin resends it.
  insert into _current
  select 'onboarding_open:' || o.staff_id,
         'onboarding_open',
         'warn',
         s.name || ' has ' || cardinality(public.onboarding_open_steps(o.staff_id)) ||
           ' onboarding step' || case when cardinality(public.onboarding_open_steps(o.staff_id)) = 1 then '' else 's' end ||
           ' still to do.',
         array['Admin'],
         '/onboarding',
         null,
         o.staff_id
    from public.staff_onboarding o
    join public.staff s on s.id = o.staff_id
   where o.completed_at is null and s.active and s.accepted_at is not null
     and cardinality(public.onboarding_open_steps(o.staff_id)) > 0;

  -- 14. Onboarding finished, for a fortnight after, so Admin sees it however
  --     long they were away. Raised the moment it happens by refresh_onboarding;
  --     kept here so the nightly reconcile does not resolve it.
  insert into _current
  select 'onboarding_done:' || o.staff_id,
         'onboarding_done',
         'warn',
         s.name || ' finished onboarding.' ||
           case when exists (select 1 from public.staff_files f
                              where f.staff_id = o.staff_id and f.category = 'I-9' and f.inspected_at is null)
                then ' Their I-9 documents still need inspecting in person.' else '' end,
         array['Admin'],
         '/admin/people/' || o.staff_id,
         null,
         null
    from public.staff_onboarding o
    join public.staff s on s.id = o.staff_id
   where o.completed_at >= v_today - 14;

  -- ── reconcile ───────────────────────────────────────────────
  insert into public.notifications
    (dedupe_key, kind, level, text, roles, href, client_id, staff_id)
  select c.dedupe_key, c.kind, c.level, c.text, c.roles, c.href, c.client_id, c.staff_id
    from _current c
  on conflict (dedupe_key) do update set
    kind = excluded.kind, level = excluded.level, text = excluded.text,
    roles = excluded.roles, href = excluded.href, resolved_at = null;

  update public.notifications n
     set resolved_at = now()
   where n.resolved_at is null
     and not exists (select 1 from _current c where c.dedupe_key = n.dedupe_key);

  select count(*) into n_open from public.notifications where resolved_at is null;
  return n_open;
end;
$function$;

-- org_settings is read column by column (0039); the payroll service is for everyone to see.
grant select (payroll_service) on public.org_settings to authenticated;
