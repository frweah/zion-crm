-- Zion Vocational Rehab CRM — 0004 invite flow + reference data
--
-- Nothing in this file is client data. It is safe in git: staff accounts,
-- offices, the CRP rate schedule, USOR form metadata and the starter SOPs.

-- ─────────────────────────────────────────────────────────────
-- Invite flow
--
-- Admin creates the staff row first (name, email, role) and sends an invite.
-- When the invited person accepts and Supabase creates their auth user, this
-- trigger links the two by email address.
--
-- A person who signs up with an email that has no staff row gets no access at
-- all: every RLS policy runs through is_active_staff(). Email signups should
-- still be turned off in Supabase → Authentication → Providers, so that invite
-- is the only way in.
-- ─────────────────────────────────────────────────────────────
create or replace function public.link_staff_account()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  update public.staff
     set user_id     = new.id,
         accepted_at = coalesce(accepted_at, now())
   where lower(email) = lower(new.email)
     and user_id is null;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.link_staff_account();

-- ─────────────────────────────────────────────────────────────
-- Staff — the first accounts (kickoff, "Staff to create as the first accounts")
-- The Billing staff member is not named yet; Admin adds them from the Staff
-- screen, which sends the invite.
-- ─────────────────────────────────────────────────────────────
insert into public.staff (legacy_id, name, email, phone, role, active) values
  -- Owner's personal login. service@zionvocrehab.com is the sending address
  -- for outgoing mail, not a sign-in account.
  ('s1', 'Francis Weah',   'frweah@gmail.com',           '801-657-6671', 'Admin',      true),
  ('s2', 'Rei Ruzzel',     'Rei@zionvocrehab.com',       null,           'Job Search', true),
  ('s3', 'Margaret Paasa', 'Margaret@zionvocrehab.com',  '385-406-3432', 'Reports',    true)
on conflict (legacy_id) do nothing;

-- ─────────────────────────────────────────────────────────────
-- USOR referring offices
-- ─────────────────────────────────────────────────────────────
insert into public.offices (name) values
  ('Centerville'), ('Salt Lake City'), ('South Jordan'), ('Spanish Fork'), ('Taylorsville')
on conflict (name) do nothing;

-- ─────────────────────────────────────────────────────────────
-- CRP rate schedule (Utah VR). Keyed by funding source so a second funder can
-- be added without code changes (spec 3d).
-- ─────────────────────────────────────────────────────────────
insert into public.rate_schedule (funding_source, service, sub, fee, unit) values
  ('Utah VR', 'Work Strategy Assessment',            'Tier 1',                                    270.00, 'flat'),
  ('Utah VR', 'Work Strategy Assessment',            'Tier 2 (incl. situational assessment)',     585.00, 'flat'),
  ('Utah VR', 'Job Development',                     'SJBT / SE',                                 560.00, 'flat'),
  ('Utah VR', 'Placement',                           'SBT',                                      2250.00, 'flat'),
  ('Utah VR', 'Placement',                           'SE',                                       3375.00, 'flat'),
  ('Utah VR', 'Job Coaching',                        'All',                                        45.00, 'per hour'),
  ('Utah VR', 'High Quality Indicator',              'Hourly Wage',                               560.00, 'flat'),
  ('Utah VR', 'High Quality Indicator',              'Work Hours',                                560.00, 'flat'),
  ('Utah VR', 'High Quality Indicator',              'Placement within 60 days',                  560.00, 'flat'),
  ('Utah VR', 'High Quality Indicator',              'Health Benefits',                           560.00, 'flat'),
  ('Utah VR', 'High Quality Indicator',              'STEM',                                      560.00, 'flat'),
  ('Utah VR', 'High Quality Indicator',              'Rural Job Development',                     560.00, 'flat'),
  ('Utah VR', 'High Quality Indicator',              'Rural Job Stability',                       560.00, 'flat'),
  ('Utah VR', 'Temporary Work Experience',           'Development (if no dev fee paid yet)',      500.00, 'flat'),
  ('Utah VR', 'Temporary Work Experience',           'Placement',                                 500.00, 'flat'),
  ('Utah VR', 'Temporary Work Experience',           'Job Coaching',                               45.00, 'per hour'),
  ('Utah VR', 'Life Skills (Financial Literacy, etc.)', 'Individual',                              45.00, 'per hour'),
  ('Utah VR', 'CRP Group Training – ACRE certified', 'Group session (up to 8 people)',             17.00, 'per hour')
on conflict do nothing;

-- ─────────────────────────────────────────────────────────────
-- DWS-USOR form templates — metadata only. The field definitions stay in
-- application code (FORM_TEMPLATES); what the database needs is which service
-- types require which form, and which forms carry restricted content.
-- ─────────────────────────────────────────────────────────────
insert into public.form_templates
  (id, usor, name, services, required_for_billing, monthly, incoming, sensitive, sort_order) values
  ('usor60',  'DWS-USOR 60',
   'CRP Evaluation of Competitive Integrated Employment (CIE) — Job Placement Report',
   array['Job Placement','Job Placement (SE)'], true, false, false, false, 1),

  ('usor92',  'DWS-USOR 92', 'Initial Job Placement Assessment',
   array['Job Placement','Job Placement (SE)'], true, false, false, false, 2),

  ('usor93',  'DWS-USOR 93', 'Ongoing Supports — Monthly Job Coaching Report',
   array['Job Coaching'], true, true, false, false, 3),

  ('wsa',     'DWS-USOR 94', 'Work Strategy Assessment',
   array['WSA Tier 1','WSA Tier 2'], true, false, false, true, 4),

  ('usor95',  'DWS-USOR 95', 'Job Coaching Tracker',
   array['Job Coaching'], true, true, false, false, 5),

  ('usor96',  'DWS-USOR 96', 'Job Development Monthly Report',
   array['Job Development','Job Development + HQ Indicator'], true, true, false, false, 6),

  ('usor98',  'DWS-USOR 98', 'Referral for CRP Assessment (received from VR Counselor)',
   array[]::text[], false, false, true, true, 7),

  ('usor148', 'DWS-USOR 148',
   'CRP Billable Hours Form (Job Readiness, Financial Literacy, Supported Education, etc.)',
   array['Life Skills','CRP Group Training','Job Readiness','Supported Employment'],
   true, false, false, false, 8)
on conflict (id) do update set
  usor = excluded.usor,
  name = excluded.name,
  services = excluded.services,
  required_for_billing = excluded.required_for_billing,
  monthly = excluded.monthly,
  incoming = excluded.incoming,
  sensitive = excluded.sensitive,
  sort_order = excluded.sort_order;

-- ─────────────────────────────────────────────────────────────
-- Starter SOPs (prototype seed)
-- ─────────────────────────────────────────────────────────────
insert into public.sops (legacy_id, title, roles, body, screen, sort_order) values
  ('sop0', 'Client intake',
   array['Admin','Reports','Job Search'],
   'When a referral arrives: add the client under Clients (name, agency client ID, funding source, counselor). Open the record → Intake tab and complete it with the client; the consent box must be checked before it will submit. Submitting moves the client to Intake and creates the assessment task for the assigned Job Search staff member.',
   'Clients', 0),

  ('sop1', 'Logging service hours',
   array['Admin','Billing','Job Search'],
   'Log hours in Billing → Service log on the day the service happens, against the correct authorization. Never log ahead. If the authorization is out of hours, submit an additional-hours request under Counselors before providing more service.',
   'Billing', 1),

  ('sop2', 'Monthly billing close',
   array['Admin','Billing','Job Search'],
   'USOR monthly reports are due by the 15th of the following month. For each client with activity last month: Job Coaching → complete USOR 93 (two worksite observations) and USOR 95 (tracker — use "Fill from the log", attach the work schedule); Job Development → USOR 96 (use "Fill from the log"). Placement bills need USOR 60 (CIE evaluation) and USOR 92 (after the 5th work day, with employer verification). Hourly services like job readiness need USOR 148 on completion. Then create the invoice; it cannot be marked Sent until the required forms are completed. Email the forms to the counselor from the Forms tab — the send is logged automatically.',
   'Billing', 2),

  ('sop3', 'Counselor communication',
   array['Admin','Billing','Job Search'],
   'Every call, email, fax, or report sent to a counselor is logged under Counselors with the outcome and a follow-up date if one is needed. Follow-ups appear on your dashboard.',
   'Counselors', 3),

  ('sop4', 'Placement follow-up',
   array['Admin','Job Search','Reports'],
   'When a client starts a job, record it on the client''s Placements tab the same week. Complete the 30-, 60-, and 90-day retention checks and note the dates — 90-day retention is what USOR measures, and the placement fee (JP) is submitted from here.',
   'Clients', 4),

  ('sop5', 'Data handling',
   array['Admin','Billing','Job Search','Reports'],
   'Client information stays in this system — not personal phones, texts, or email. Do not share logins. Upload client documents to the client record. Report any suspected data exposure to the owner the same day.',
   null, 5)
on conflict (legacy_id) do nothing;
