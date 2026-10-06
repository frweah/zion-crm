-- Zion Vocational Rehab CRM — the offboarding checklist reads the register (E4)
--
-- "Offboarding checklist pulls 'return assigned assets' from here."
--
-- The readiness view already answers "what is still attached to this person":
-- their caseload, their unsubmitted hours, their open statements. A laptop is
-- the same kind of fact and belongs in the same place, so it is a column on
-- the same view rather than a second thing to look at - which is the whole
-- reason that view exists.
--
-- Recreated in full rather than altered: 0061 wrote the list out, and a view
-- rebuilt from memory is how a column goes quietly missing. Every count below
-- is 0061's, with one added.

create or replace view public.offboarding_readiness as
  select s.id                                                        as staff_id,
         s.name,
         s.role,
         s.active,

         (select count(*) from public.clients c
           where c.assigned_staff_id = s.id and c.status = 'Active')    as active_clients,

         (select count(*) from public.tasks t
           where t.assigned_staff_id = s.id and t.status = 'Open')      as open_tasks,

         -- Hours worked and not yet on a statement: the money they are owed.
         (select coalesce(sum(w.hours), 0) from public.work_sessions w
           where w.staff_id = s.id and not w.voided and w.statement_id is null)
                                                                       as unsubmitted_hours,

         (select count(*) from public.contractor_statements st
           where st.staff_id = s.id and st.status in ('Submitted', 'Returned'))
                                                                       as open_statements,

         (select count(*) from public.work_session_timers tm
           where tm.staff_id = s.id)                                   as running_timers,

         (select count(*) from public.staff_files f where f.staff_id = s.id)
                                                                       as documents_held,

         (select count(*) from public.microsoft_connections m where m.staff_id = s.id)
                                                                       as mailbox_connected,

         -- The laptop, the phone, whatever has their name on it (E4).
         (select count(*) from public.assets a
           where a.assigned_staff_id = s.id and a.status <> 'Disposed') as assets_held

    from public.staff s;

alter view public.offboarding_readiness set (security_invoker = true);
grant select on public.offboarding_readiness to authenticated;

comment on view public.offboarding_readiness is
  'What is still attached to a member of staff: caseload, open tasks, unsubmitted hours, open statements, a running timer, documents held, a connected mailbox, and equipment they still have (0151).';
