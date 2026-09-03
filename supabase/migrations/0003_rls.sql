-- Zion Vocational Rehab CRM — 0003 row-level security
--
-- Model (kickoff, "Decisions already made"):
--   * All four roles see all clients. assigned_staff_id routes tasks and alerts;
--     it does not restrict access.
--   * Restricted tier — DOB, address, intake (accommodations, emergency contact)
--     and USOR 94 / 98 form content — is limited to Admin, Intake & Reports, or
--     the client's assigned staff member.
--   * An inactive staff row sees nothing at all: every policy runs through
--     is_active_staff(), so deactivating an account removes access immediately.
--
-- Editing rights follow the prototype, not spec v2 where the two differ:
--   canEditClients = Admin | Job Search | Reports
--   canEditBilling = Admin | Billing

-- ─────────────────────────────────────────────────────────────
-- Grants. RLS does the gating; without these grants the policies never run.
-- ─────────────────────────────────────────────────────────────
grant usage on schema public to authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;
alter default privileges in schema public
  grant select, insert, update, delete on tables to authenticated;

-- Nothing in this database is readable without a login — now and for any
-- table a later migration adds.
revoke all on all tables in schema public from anon;
alter default privileges in schema public revoke all on tables from anon;

do $$
declare t text;
begin
  foreach t in array array[
    'staff','offices','rate_schedule','counselors','clients','client_private',
    'client_stage_history','intakes','authorizations','service_entries',
    'completions','invoices','placements','tasks','notes','form_templates',
    'forms','contact_log','hours_requests','sops'
  ] loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;

-- ─────────────────────────────────────────────────────────────
-- staff — Admin manages accounts; everyone can see who is who.
-- ─────────────────────────────────────────────────────────────
create policy staff_select_self on public.staff
  for select to authenticated
  using (user_id = auth.uid());

create policy staff_select_all on public.staff
  for select to authenticated
  using (public.is_active_staff());

create policy staff_admin_write on public.staff
  for all to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- ─────────────────────────────────────────────────────────────
-- Reference tables
-- ─────────────────────────────────────────────────────────────
create policy offices_read on public.offices
  for select to authenticated using (public.is_active_staff());
create policy offices_admin_write on public.offices
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

create policy rate_schedule_read on public.rate_schedule
  for select to authenticated using (public.is_active_staff());
create policy rate_schedule_write on public.rate_schedule
  for all to authenticated
  using (public.current_staff_role() in ('Admin','Billing'))
  with check (public.current_staff_role() in ('Admin','Billing'));

create policy counselors_read on public.counselors
  for select to authenticated using (public.is_active_staff());
create policy counselors_write on public.counselors
  for insert to authenticated
  with check (public.current_staff_role() in ('Admin','Job Search','Billing'));
create policy counselors_update on public.counselors
  for update to authenticated
  using (public.current_staff_role() in ('Admin','Job Search','Billing'))
  with check (public.current_staff_role() in ('Admin','Job Search','Billing'));
create policy counselors_delete on public.counselors
  for delete to authenticated using (public.is_admin());

create policy form_templates_read on public.form_templates
  for select to authenticated using (public.is_active_staff());
create policy form_templates_admin_write on public.form_templates
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- ─────────────────────────────────────────────────────────────
-- clients — every role sees every client
-- ─────────────────────────────────────────────────────────────
create policy clients_read on public.clients
  for select to authenticated using (public.is_active_staff());
create policy clients_insert on public.clients
  for insert to authenticated
  with check (public.current_staff_role() in ('Admin','Job Search','Reports'));
create policy clients_update on public.clients
  for update to authenticated
  using (public.current_staff_role() in ('Admin','Job Search','Reports'))
  with check (public.current_staff_role() in ('Admin','Job Search','Reports'));
create policy clients_delete on public.clients
  for delete to authenticated using (public.is_admin());

create policy stage_history_read on public.client_stage_history
  for select to authenticated using (public.is_active_staff());
create policy stage_history_insert on public.client_stage_history
  for insert to authenticated
  with check (public.current_staff_role() in ('Admin','Job Search','Reports'));
create policy stage_history_delete on public.client_stage_history
  for delete to authenticated using (public.is_admin());

-- ─────────────────────────────────────────────────────────────
-- Restricted tier
-- ─────────────────────────────────────────────────────────────
create policy client_private_read on public.client_private
  for select to authenticated
  using (public.can_see_restricted(client_id));
create policy client_private_write on public.client_private
  for all to authenticated
  using (public.can_see_restricted(client_id)
         and public.current_staff_role() in ('Admin','Job Search','Reports'))
  with check (public.can_see_restricted(client_id)
         and public.current_staff_role() in ('Admin','Job Search','Reports'));

create policy intakes_read on public.intakes
  for select to authenticated
  using (public.can_see_restricted(client_id));
create policy intakes_write on public.intakes
  for all to authenticated
  using (public.can_see_restricted(client_id)
         and public.current_staff_role() in ('Admin','Job Search','Reports'))
  with check (public.can_see_restricted(client_id)
         and public.current_staff_role() in ('Admin','Job Search','Reports'));

-- ─────────────────────────────────────────────────────────────
-- Billing
-- ─────────────────────────────────────────────────────────────
create policy authorizations_read on public.authorizations
  for select to authenticated using (public.is_active_staff());
create policy authorizations_write on public.authorizations
  for all to authenticated
  using (public.current_staff_role() in ('Admin','Billing'))
  with check (public.current_staff_role() in ('Admin','Billing'));

-- Job coaches log their own hours, so Job Search writes here too — the SOP
-- "Logging service hours", confirmed by the owner. Authorizations and invoices
-- stay with Admin and Billing.
create policy service_entries_read on public.service_entries
  for select to authenticated using (public.is_active_staff());
create policy service_entries_write on public.service_entries
  for all to authenticated
  using (public.current_staff_role() in ('Admin','Billing','Job Search'))
  with check (public.current_staff_role() in ('Admin','Billing','Job Search'));

create policy completions_read on public.completions
  for select to authenticated using (public.is_active_staff());
create policy completions_write on public.completions
  for all to authenticated
  using (public.current_staff_role() in ('Admin','Billing'))
  with check (public.current_staff_role() in ('Admin','Billing'));

create policy invoices_read on public.invoices
  for select to authenticated using (public.is_active_staff());
create policy invoices_write on public.invoices
  for all to authenticated
  using (public.current_staff_role() in ('Admin','Billing'))
  with check (public.current_staff_role() in ('Admin','Billing'));

-- Placements are recorded by whoever works the case; the JP fee fields on them
-- are submitted from Billing. Both sides need write access to the row.
create policy placements_read on public.placements
  for select to authenticated using (public.is_active_staff());
create policy placements_write on public.placements
  for insert to authenticated with check (public.is_active_staff());
create policy placements_update on public.placements
  for update to authenticated
  using (public.is_active_staff()) with check (public.is_active_staff());
create policy placements_delete on public.placements
  for delete to authenticated using (public.is_admin());

-- ─────────────────────────────────────────────────────────────
-- Tasks — anyone may create one; only the assignee, the author or Admin
-- may change or close it.
-- ─────────────────────────────────────────────────────────────
create policy tasks_read on public.tasks
  for select to authenticated using (public.is_active_staff());
create policy tasks_insert on public.tasks
  for insert to authenticated with check (public.is_active_staff());
create policy tasks_update on public.tasks
  for update to authenticated
  using (public.is_admin()
         or assigned_staff_id = public.current_staff_id()
         or created_by = public.current_staff_id())
  with check (public.is_active_staff());
create policy tasks_delete on public.tasks
  for delete to authenticated
  using (public.is_admin() or created_by = public.current_staff_id());

-- ─────────────────────────────────────────────────────────────
-- Notes — visible_roles is the per-role visibility from the prototype.
-- A note is edited or removed only by its author (or Admin); the record of
-- who wrote what and when is not rewritable by anyone else.
-- ─────────────────────────────────────────────────────────────
create policy notes_read on public.notes
  for select to authenticated
  using (public.is_admin()
         or (public.is_active_staff()
             and public.current_staff_role() = any (visible_roles)));
create policy notes_insert on public.notes
  for insert to authenticated
  with check (public.is_active_staff()
              and staff_id is not distinct from public.current_staff_id());
create policy notes_update on public.notes
  for update to authenticated
  using (public.is_admin() or staff_id = public.current_staff_id())
  with check (public.is_admin() or staff_id = public.current_staff_id());
create policy notes_delete on public.notes
  for delete to authenticated
  using (public.is_admin() or staff_id = public.current_staff_id());

-- ─────────────────────────────────────────────────────────────
-- Forms — USOR 94 and 98 carry restricted content, so those rows follow the
-- restricted tier. The rest are open to all active staff.
-- ─────────────────────────────────────────────────────────────
create policy forms_read on public.forms
  for select to authenticated
  using (public.is_active_staff()
         and (not sensitive or public.can_see_restricted(client_id)));
create policy forms_insert on public.forms
  for insert to authenticated
  with check (public.is_active_staff()
              and (not exists (
                    select 1 from public.form_templates t
                     where t.id = template_id and t.sensitive)
                   or public.can_see_restricted(client_id)));
create policy forms_update on public.forms
  for update to authenticated
  using (public.is_active_staff()
         and (not sensitive or public.can_see_restricted(client_id)))
  with check (public.is_active_staff()
         and (not sensitive or public.can_see_restricted(client_id)));
create policy forms_delete on public.forms
  for delete to authenticated
  using (public.is_admin() and status = 'Draft');

-- ─────────────────────────────────────────────────────────────
-- Counselor contact log and hours requests
-- ─────────────────────────────────────────────────────────────
create policy contact_log_read on public.contact_log
  for select to authenticated using (public.is_active_staff());
create policy contact_log_insert on public.contact_log
  for insert to authenticated
  with check (public.is_active_staff()
              and staff_id is not distinct from public.current_staff_id());
create policy contact_log_update on public.contact_log
  for update to authenticated
  using (public.is_admin() or staff_id = public.current_staff_id())
  with check (public.is_admin() or staff_id = public.current_staff_id());
create policy contact_log_delete on public.contact_log
  for delete to authenticated using (public.is_admin());

create policy hours_requests_read on public.hours_requests
  for select to authenticated using (public.is_active_staff());
create policy hours_requests_insert on public.hours_requests
  for insert to authenticated
  with check (public.is_active_staff()
              and staff_id is not distinct from public.current_staff_id());
create policy hours_requests_update on public.hours_requests
  for update to authenticated
  using (public.current_staff_role() in ('Admin','Billing')
         or staff_id = public.current_staff_id())
  with check (public.current_staff_role() in ('Admin','Billing')
         or staff_id = public.current_staff_id());
create policy hours_requests_delete on public.hours_requests
  for delete to authenticated using (public.is_admin());

-- ─────────────────────────────────────────────────────────────
-- SOPs — everyone reads their role's section; Admin edits.
-- ─────────────────────────────────────────────────────────────
create policy sops_read on public.sops
  for select to authenticated
  using (public.is_admin()
         or (public.is_active_staff()
             and public.current_staff_role() = any (roles)));
create policy sops_admin_write on public.sops
  for all to authenticated using (public.is_admin()) with check (public.is_admin());
