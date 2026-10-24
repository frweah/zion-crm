-- Zion Vocational Rehab CRM — 0250 a job search update is everybody's to add
--
-- Margaret could open a client, see the Add a job panel, fill it in, and get
-- "new row violates row-level security policy for table job_leads". The screen
-- and the database disagreed about who may do this, and the database was the
-- one that mattered.
--
-- The screen asks `CAN_EDIT_CLIENTS` - Admin, Job Search, Reports, Job Coach,
-- Case Manager. The policies asked for Admin or Job Search. So the panel was
-- offered to five roles and accepted from two, and the three in between got a
-- sentence about a policy, which is the one thing a person reading a screen
-- can do nothing with.
--
-- The owner's rule (23 Oct 2026): everybody who can see the client can add a
-- job search update. That is one question, so it is one function rather than
-- the same five-role array written into six policies - the array is what
-- drifted, and three tables are involved in adding a single job:
--
--   `employers`    - the employer, if it is not in the directory yet. Making
--                    somebody leave the client, add an employer and come back
--                    is how a job gets recorded as "Some Diner (?)" in a note.
--   `job_leads`    - the job itself.
--   `lead_matches` - this client against that job.
--
-- A job added from a client's record and a job added on the leads board are
-- the same rows, which is why this widens the board's tables and not a copy of
-- them. The board stays Job Search's screen; what changes is who the database
-- will accept the rows from.
--
-- **And the writer is recorded by the rule rather than by the caller.** Every
-- insert in the app already sets `created_by`, and "already does" is not a
-- guarantee - so the policy requires it to be the person inserting. A row that
-- does not say who added it cannot be added.

create or replace function public.can_record_job_search()
returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_active_staff()
     and public.current_staff_role() = any (array[
       'Admin', 'Job Search', 'Reports', 'Job Coach', 'Case Manager'
     ]);
$$;

comment on function public.can_record_job_search is
  'Whether this person may record a job search update - the employer, the job, and a client against it. Everybody who can see the client (0250).';

revoke all on function public.can_record_job_search() from anon, authenticated;
grant execute on function public.can_record_job_search() to authenticated;

-- ── the employer ─────────────────────────────────────────────
drop policy if exists employers_insert on public.employers;
create policy employers_insert on public.employers
  for insert to authenticated
  with check (
    (select public.can_record_job_search())
    and created_by = (select public.current_staff_id())
  );

drop policy if exists employers_update on public.employers;
create policy employers_update on public.employers
  for update to authenticated
  using ((select public.can_record_job_search()))
  with check ((select public.can_record_job_search()));

-- ── the job ──────────────────────────────────────────────────
drop policy if exists job_leads_insert on public.job_leads;
create policy job_leads_insert on public.job_leads
  for insert to authenticated
  with check (
    (select public.can_record_job_search())
    and created_by = (select public.current_staff_id())
  );

drop policy if exists job_leads_update on public.job_leads;
create policy job_leads_update on public.job_leads
  for update to authenticated
  using ((select public.can_record_job_search()))
  with check ((select public.can_record_job_search()));

-- ── this client against it ───────────────────────────────────
drop policy if exists lead_matches_insert on public.lead_matches;
create policy lead_matches_insert on public.lead_matches
  for insert to authenticated
  with check (
    (select public.can_record_job_search())
    and created_by = (select public.current_staff_id())
  );

drop policy if exists lead_matches_update on public.lead_matches;
create policy lead_matches_update on public.lead_matches
  for update to authenticated
  using ((select public.can_record_job_search()))
  with check ((select public.can_record_job_search()));
