-- ─────────────────────────────────────────────────────────────
-- 0024 — onboarding and offboarding checklists.
--
-- Most of what has to happen when somebody joins or leaves is already
-- recorded somewhere in this system: whether they accepted their invitation,
-- whether their tax form is signed, whether a rate is set, whether their
-- clients have been handed on. A checklist that asks a human to tick those by
-- hand is a checklist that will say "done" about things that are not.
--
-- So an item is one of two kinds. An automatic item is derived from the data
-- and cannot be ticked at all — it is true when the underlying fact is true
-- and not before. A manual item is for things this system genuinely cannot
-- see: a laptop handed back, a mailbox closed, a policy signed on paper.
--
-- Offboarding matters more than onboarding here, because the risk runs the
-- other way. Onboarding half-done is an inconvenience; offboarding half-done
-- is somebody who still has access, or a caseload nobody is watching.
-- ─────────────────────────────────────────────────────────────

create table if not exists public.checklist_tasks (
  id          uuid primary key default gen_random_uuid(),
  phase       text not null check (phase in ('Onboarding', 'Offboarding')),
  label       text not null,
  detail      text not null default '',
  -- Null means every kind of engagement. An owner is not onboarded by anyone,
  -- so most items name the two kinds that are.
  applies_to  text[] check (
    applies_to is null
    or applies_to <@ array['Owner', 'Employee', 'Contractor']
  ),
  -- Set for a derived item. Null means somebody has to tick it.
  auto_key    text,
  required    boolean not null default true,
  sort_order  integer not null default 0,
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

create table if not exists public.staff_checklist_items (
  staff_id   uuid not null references public.staff(id) on delete cascade,
  task_id    uuid not null references public.checklist_tasks(id) on delete cascade,
  done_on    date,
  done_by    uuid references public.staff(id) on delete set null,
  note       text not null default '',
  updated_at timestamptz not null default now(),
  primary key (staff_id, task_id)
);
drop trigger if exists staff_checklist_items_updated_at on public.staff_checklist_items;
create trigger staff_checklist_items_updated_at before update on public.staff_checklist_items
  for each row execute function public.set_updated_at();

alter table public.checklist_tasks enable row level security;
alter table public.staff_checklist_items enable row level security;

-- Everyone can read the list of what onboarding involves; only Admin edits it.
drop policy if exists checklist_tasks_read on public.checklist_tasks;
create policy checklist_tasks_read on public.checklist_tasks
  for select to authenticated using (public.is_active_staff());
drop policy if exists checklist_tasks_write on public.checklist_tasks;
create policy checklist_tasks_write on public.checklist_tasks
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- A person may see their own progress. Ticking is Admin's, because a checklist
-- somebody signs off for themselves is not a check.
drop policy if exists staff_checklist_read on public.staff_checklist_items;
create policy staff_checklist_read on public.staff_checklist_items
  for select to authenticated
  using (public.is_admin() or staff_id = public.current_staff_id());
drop policy if exists staff_checklist_write on public.staff_checklist_items;
create policy staff_checklist_write on public.staff_checklist_items
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- ─────────────────────────────────────────────────────────────
-- An automatic item cannot be ticked.
--
-- Without this, "signed their tax form" could be marked done for somebody who
-- has not signed one, and the checklist would be worth less than no checklist
-- because it would be believed.
-- ─────────────────────────────────────────────────────────────
create or replace function public.reject_manual_tick()
returns trigger language plpgsql as $$
declare
  v_auto text;
begin
  select auto_key into v_auto from public.checklist_tasks where id = new.task_id;
  if v_auto is not null and new.done_on is not null then
    raise exception
      'That item is answered by the system, not by ticking it. It becomes done when the thing itself is done.'
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

drop trigger if exists staff_checklist_no_manual_tick on public.staff_checklist_items;
create trigger staff_checklist_no_manual_tick before insert or update
  on public.staff_checklist_items
  for each row execute function public.reject_manual_tick();

-- ─────────────────────────────────────────────────────────────
-- Everybody's checklist, with the automatic items worked out.
-- ─────────────────────────────────────────────────────────────
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
   -- Own row, or Admin. Everyone can read the staff list, so without this a
   -- contractor would see every colleague's checklist — and see it wrongly,
   -- because the derived items read tables they have no access to and would
   -- come back false rather than refuse. A confident wrong answer is worse
   -- than none.
   and (public.is_admin() or s.id = public.current_staff_id());

alter view public.staff_checklist set (security_invoker = true);
grant select on public.staff_checklist to authenticated;

-- ─────────────────────────────────────────────────────────────
-- The starting list. Admin can add to it, and turn items off.
-- ─────────────────────────────────────────────────────────────
insert into public.checklist_tasks (phase, label, detail, applies_to, auto_key, required, sort_order)
select * from (values
  ('Onboarding', 'Accepted their invitation',
   'They have set a password and signed in at least once.',
   array['Employee','Contractor'], 'account_accepted', true, 10),
  ('Onboarding', 'Tax form signed',
   'A W-9, W-8BEN or W-4, whichever their engagement calls for. Completed on the Paperwork screen.',
   array['Employee','Contractor'], 'tax_form_signed', true, 20),
  ('Onboarding', 'Address on file',
   'Needed before a 1099 can be filed for them.',
   array['Contractor'], 'address_on_file', true, 30),
  ('Onboarding', 'Rate agreed and recorded',
   'A rate exists on their pay record.',
   array['Employee','Contractor'], 'pay_rate_set', true, 40),
  ('Onboarding', 'Signed the data handling policy',
   'The policy covering client information. Kept with their file.',
   array['Employee','Contractor'], null, true, 50),
  ('Onboarding', 'Read the SOPs for their role',
   'Confirmed with them, not assumed.',
   array['Employee','Contractor'], null, true, 60),
  ('Onboarding', 'Practice email account set up',
   'And added to the shared mailboxes they need.',
   array['Employee','Contractor'], null, false, 70),
  ('Onboarding', 'Introduced to the USOR counselors they will work with',
   '',
   array['Employee','Contractor'], null, false, 80),

  ('Offboarding', 'Account deactivated',
   'Deactivating removes access the same moment. Do this first.',
   array['Employee','Contractor'], 'account_closed', true, 10),
  ('Offboarding', 'Clients reassigned',
   'Nobody active is still assigned to them.',
   array['Employee','Contractor'], 'clients_reassigned', true, 20),
  ('Offboarding', 'Open tasks reassigned',
   'No open task still points at them.',
   array['Employee','Contractor'], 'tasks_reassigned', true, 30),
  ('Offboarding', 'Statements settled',
   'No draft or submitted statement is left hanging.',
   array['Contractor'], 'statements_settled', true, 40),
  ('Offboarding', 'Final payment made',
   'And recorded on the Contractors screen, so the year total is right.',
   array['Contractor'], null, true, 50),
  ('Offboarding', 'Practice email closed or forwarded',
   '',
   array['Employee','Contractor'], null, true, 60),
  ('Offboarding', 'Equipment returned',
   'Laptop, phone, keys, anything else issued.',
   array['Employee','Contractor'], null, false, 70),
  ('Offboarding', 'Forwarding address confirmed',
   'Their 1099 or W-2 has to reach them in January.',
   array['Employee','Contractor'], null, true, 80)
) as v(phase, label, detail, applies_to, auto_key, required, sort_order)
where not exists (select 1 from public.checklist_tasks);

/** Ticks or unticks a manual item. Admin only, and never an automatic one. */
create or replace function public.set_checklist_item(
  p_staff_id uuid,
  p_task_id  uuid,
  p_done     boolean,
  p_note     text default ''
)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then
    raise exception 'Only Admin can tick these off.' using errcode = 'insufficient_privilege';
  end if;

  insert into public.staff_checklist_items (staff_id, task_id, done_on, done_by, note)
  values (p_staff_id, p_task_id,
          case when p_done then current_date end,
          case when p_done then public.current_staff_id() end,
          coalesce(p_note, ''))
  on conflict (staff_id, task_id) do update set
    done_on = excluded.done_on,
    done_by = excluded.done_by,
    note    = excluded.note;
end;
$$;

revoke execute on function public.set_checklist_item(uuid, uuid, boolean, text) from public;
grant execute on function public.set_checklist_item(uuid, uuid, boolean, text) to authenticated;
