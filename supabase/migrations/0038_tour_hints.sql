-- ─────────────────────────────────────────────────────────────
-- 0038 — saying what is already here.
--
-- Roughly half the improvements Margaret asked for after her first week
-- describe things the CRM already did. That is not a documentation problem to
-- be solved by writing more documentation nobody opens; it is the screens not
-- saying what they are for.
--
-- So: one short hint per screen, shown once, dismissed for good. In a table
-- rather than in the code because the wording is the sort of thing that gets
-- improved by whoever is using it, and because the onboarding checklist needs
-- to count them — a checklist item that asked the code how many hints exist
-- would be two lists again.
-- ─────────────────────────────────────────────────────────────

create table if not exists public.tour_hints (
  key        text primary key,
  screen     text not null,
  title      text not null,
  body       text not null,
  -- Null means everybody. A hint about billing is noise to Job Search.
  roles      text[],
  sort_order integer not null default 0,
  active     boolean not null default true,
  created_at timestamptz not null default now()
);

alter table public.tour_hints enable row level security;

drop policy if exists tour_hints_read on public.tour_hints;
create policy tour_hints_read on public.tour_hints
  for select to authenticated using (public.is_active_staff());
drop policy if exists tour_hints_write on public.tour_hints;
create policy tour_hints_write on public.tour_hints
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- Dismissals live in staff_prefs, which already exists for exactly this: a
-- per-person key and value, readable and writable by that person alone.
-- The key is 'hint:<key>'.

/** How many hints this person should be shown, and how many they have seen. */
create or replace view public.my_tour_progress as
select s.id as staff_id,
       (select count(*) from public.tour_hints h
         where h.active and (h.roles is null or s.role = any(h.roles)))          as hints_total,
       (select count(*) from public.staff_prefs p
         where p.staff_id = s.id and p.key like 'hint:%'
           and exists (select 1 from public.tour_hints h
                        where h.active and ('hint:' || h.key) = p.key
                          and (h.roles is null or s.role = any(h.roles))))       as hints_seen
  from public.staff s;

alter view public.my_tour_progress set (security_invoker = true);
grant select on public.my_tour_progress to authenticated;

-- ─────────────────────────────────────────────────────────────
-- The hints
-- ─────────────────────────────────────────────────────────────
insert into public.tour_hints (key, screen, title, body, roles, sort_order) values
  ('dashboard', '/dashboard', 'This is what needs you today',
   'Your open tasks, anything overdue, and alerts the system raised overnight. Connect Outlook here, and start a work session if you log hours.',
   null, 10),

  ('clients', '/clients', 'Every client, filtered how you like',
   'Sort and filter, then save the filter as a view you can come back to. Restricted details are only shown to Admin, Intake & Reports, or whoever the client is assigned to.',
   null, 20),

  ('client-record', '/clients/', 'Activity first, then the detail',
   'Activity is everything that has happened, in one order. Jobs we have tried sits under stage history on Overview. Forms, files, notes, placements and the progress report each have their own tab.',
   null, 30),

  ('leads', '/leads', 'The job board, shared by everyone',
   'Employers, the jobs going at each, and which clients are being put forward. Moving somebody to Hired writes a note and offers to create the placement — the placement is always a separate decision.',
   null, 40),

  ('counselors', '/counselors', 'Counselors and every contact with them',
   'Each counselor, their clients, and the log of calls, emails and reports sent. Recording a contact here is what the monthly reporting counts.',
   null, 50),

  ('tasks', '/tasks', 'Tasks, including the ones raised for you',
   'Anything with a due date. Interview prep and follow-up reminders appear here on their own when a date is set on a job — closing one asks how it went and moves the job along.',
   null, 60),

  ('forms', '/forms', 'The USOR forms, blank',
   'The eight DWS-USOR templates. Fill one in from a client''s Forms tab rather than here, so it is attached to them and can be emailed to the counselor.',
   null, 70),

  ('hours', '/hours', 'Your time, and your statement',
   'Log what you worked, or run the timer. Hours are append-only: a mistake is corrected by a replacement that records the reason, never by an edit. Submit the statement when the period ends.',
   null, 80),

  ('billing', '/billing', 'Authorizations, hours and invoices',
   'Hours cannot exceed what USOR authorized and an invoice cannot be sent until the forms USOR requires are complete. Both rules are enforced in the database, not by remembering.',
   array['Admin', 'Billing'], 90),

  ('reports', '/reports', 'The numbers, by month',
   'Placement and retention rates, hours delivered, and what is outstanding. Figures that cannot be measured show a dash rather than a zero.',
   array['Admin', 'Reports', 'Billing'], 100),

  ('paperwork', '/paperwork', 'Your tax form, signed here',
   'Whichever form your engagement calls for — W-9, W-8BEN or W-4 — completed and signed in the app. Only the administrator can open the finished PDF.',
   null, 110),

  ('contractors', '/contractors', 'What contractors are owed and reported',
   'Profiles as they appear on a 1099, payments as they were actually made, and the tax-year settings a 1099 run depends on. No run can be built on an unconfirmed threshold.',
   array['Admin'], 120),

  ('staff', '/staff', 'Accounts, rates and onboarding',
   'Invite and deactivate — deactivating removes access the same moment. Pay rates are dated records, so work keeps the rate it was done under. Onboarding items the system can answer for itself are answered for itself.',
   array['Admin'], 130),

  ('sops', '/sops', 'How we do things, and where to find them',
   'The written procedures, plus "Where do I…?" — a short list of the twenty things people ask for most, with a link straight to each one.',
   null, 140)
on conflict (key) do update set
  screen = excluded.screen, title = excluded.title, body = excluded.body,
  roles = excluded.roles, sort_order = excluded.sort_order;

-- ─────────────────────────────────────────────────────────────
-- "Guided tour completed", on the onboarding checklist
--
-- Automatic, like the rest of the derived items: it becomes true when somebody
-- has seen every hint that applies to them, and cannot be ticked to say
-- otherwise. The count comes from the table, so adding a hint later reopens
-- the item for people who have not seen the new one — which is the honest
-- behaviour, and the reason the hints are data rather than code.
-- ─────────────────────────────────────────────────────────────
insert into public.checklist_tasks (phase, label, detail, applies_to, auto_key, required, sort_order)
select 'Onboarding', 'Guided tour completed',
       'The short "what''s here" note on each screen has been read and dismissed.',
       array['Employee', 'Contractor'], 'tour_completed', false, 65
where not exists (select 1 from public.checklist_tasks where auto_key = 'tour_completed');

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
         when 'tax_form_signed' then exists (
           select 1 from public.tax_form_submissions f
            where f.staff_id = s.id and f.status = 'Signed'
              and f.form_type = case
                    when coalesce(e.employment_type, 'Contractor') = 'Employee' then 'W-4'
                    when p.tax_status = 'Foreign person' then 'W-8BEN'
                    else 'W-9' end)
         when 'address_on_file' then coalesce(nullif(p.address_line1, ''), '') <> ''
         when 'pay_rate_set' then exists (
           select 1 from public.staff_pay r where r.staff_id = s.id)
         when 'tour_completed' then (
           select tp.hints_seen >= tp.hints_total and tp.hints_total > 0
             from public.my_tour_progress tp where tp.staff_id = s.id)
         when 'account_closed' then not s.active
         when 'clients_reassigned' then not exists (
           select 1 from public.clients c
            where c.assigned_staff_id = s.id and c.status = 'Active')
         when 'tasks_reassigned' then not exists (
           select 1 from public.tasks k
            where k.assigned_staff_id = s.id and k.status = 'Open')
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
   and (t.applies_to is null
        or coalesce(e.employment_type, 'Contractor') = any(t.applies_to))
   and (public.is_admin() or s.id = public.current_staff_id());

alter view public.staff_checklist set (security_invoker = true);
grant select on public.staff_checklist to authenticated;
