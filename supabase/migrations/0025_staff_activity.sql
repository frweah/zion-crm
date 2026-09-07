-- ─────────────────────────────────────────────────────────────
-- 0025 — what each person did over a period.
--
-- Security invoker on purpose. The same function answers for everyone, and
-- what comes back is whatever the caller was already allowed to see: Admin
-- gets the whole roster, a contractor gets their own hours and their own
-- payments and nobody else's. There is no second, restricted version of this
-- to keep in step with the first.
--
-- Figures are counted where they belong. Hours are counted on the day the work
-- was done; payments on the day they were paid, which is the calendar-year
-- rule a 1099 follows. Voided sessions are left out — a session that was taken
-- back is not work done, and counting it would flatter the total.
--
-- Caseload and open tasks are the position now, not over the period. A count
-- of "clients assigned during March" answers a question nobody asks; "who is
-- carrying what today" is the one that comes up.
-- ─────────────────────────────────────────────────────────────

create or replace function public.staff_activity(p_from date, p_to date)
returns table (
  staff_id            uuid,
  staff_name          text,
  role                text,
  employment_type     text,
  active              boolean,
  hours               numeric,
  sessions            bigint,
  days_worked         bigint,
  statements_submitted bigint,
  statements_approved bigint,
  amount_paid         numeric,
  clients_assigned    bigint,
  tasks_open          bigint,
  tasks_done          bigint,
  notes_written       bigint,
  leads_added         bigint
)
language sql stable security invoker as $$
  select s.id,
         s.name,
         s.role,
         coalesce(e.employment_type, 'Contractor'),
         s.active,
         coalesce((select sum(w.hours) from public.work_sessions w
                    where w.staff_id = s.id and not w.voided
                      and w.worked_on between p_from and p_to), 0),
         (select count(*) from public.work_sessions w
           where w.staff_id = s.id and not w.voided
             and w.worked_on between p_from and p_to),
         (select count(distinct w.worked_on) from public.work_sessions w
           where w.staff_id = s.id and not w.voided
             and w.worked_on between p_from and p_to),
         (select count(*) from public.contractor_statements st
           where st.staff_id = s.id and st.status = 'Submitted'
             and st.period_start between p_from and p_to),
         (select count(*) from public.contractor_statements st
           where st.staff_id = s.id and st.status = 'Approved'
             and st.period_start between p_from and p_to),
         coalesce((select sum(pay.amount) from public.contractor_payments pay
                    where pay.staff_id = s.id
                      and pay.paid_on between p_from and p_to), 0),
         (select count(*) from public.clients c
           where c.assigned_staff_id = s.id and c.status = 'Active'),
         (select count(*) from public.tasks k
           where k.assigned_staff_id = s.id and k.status = 'Open'),
         (select count(*) from public.tasks k
           where k.assigned_staff_id = s.id and k.status = 'Done'
             and k.done_at::date between p_from and p_to),
         (select count(*) from public.notes n
           where n.staff_id = s.id and n.at::date between p_from and p_to),
         (select count(*) from public.job_leads l
           where l.created_by = s.id and l.created_at::date between p_from and p_to)
    from public.staff s
    left join public.staff_employment e on e.staff_id = s.id
   order by s.active desc, s.name;
$$;

grant execute on function public.staff_activity(date, date) to authenticated;
