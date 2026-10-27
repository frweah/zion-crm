-- Zion Vocational Rehab CRM — 0259 the rest of the default grants
--
-- 0257 took Supabase's default write grants off the nine views that read
-- `authorizations`, and left twenty-four others carrying them with a note
-- saying so. This is the owner's answer to that note (26 Oct 2026): take them
-- off the rest, keep SELECT, and leave the schema-wide default privilege on,
-- because turning that off would also strip the writes from every new *table*
-- and some tables lean on it.
--
-- None of these twenty-four was a door. Three of them - `my_tour_progress`,
-- `offboarding_readiness` and `updates_for_me` - are simple enough that
-- Postgres can write through them, and all three have `security_invoker`, so
-- a write would be checked against the base table as the person and refused
-- there. The other twenty-one are not auto-updatable and so refuse a write on
-- their own account. Both of those are properties of how the views happen to
-- be written, though, not of what anybody decided; the grant is still the
-- thing to remove, and after this the rule is the same for every view in
-- `public` rather than for the nine somebody looked at.
--
-- Nothing writes through a view, checked again rather than assumed: no screen
-- or action in the app, no function body, and no view in `public` carries an
-- INSTEAD OF trigger or a rule of its own.
--
-- Read access is untouched. Each view keeps SELECT for `authenticated`, and
-- `service_role` is left as it is. Counted as each of the five people on the
-- practice - Admin, Billing, Case Manager, Job Search, Reports - across all
-- twenty-four views, before and after, inside a rolled-back transaction: 120
-- pairs, every one identical.

-- What a client's record and the screens around it read.
revoke all on public.client_billing_office from anon, authenticated;
grant select on public.client_billing_office to authenticated;

revoke all on public.client_job_history from anon, authenticated;
grant select on public.client_job_history to authenticated;

revoke all on public.client_mail from anon, authenticated;
grant select on public.client_mail to authenticated;

revoke all on public.client_next_up from anon, authenticated;
grant select on public.client_next_up to authenticated;

revoke all on public.client_retention from anon, authenticated;
grant select on public.client_retention to authenticated;

revoke all on public.client_sms_consent from anon, authenticated;
grant select on public.client_sms_consent to authenticated;

revoke all on public.client_stages_reached from anon, authenticated;
grant select on public.client_stages_reached to authenticated;

-- Hours, expenses and what they come to.
revoke all on public.contractor_statement_totals from anon, authenticated;
grant select on public.contractor_statement_totals to authenticated;

revoke all on public.contractor_year_totals from anon, authenticated;
grant select on public.contractor_year_totals to authenticated;

revoke all on public.expense_values from anon, authenticated;
grant select on public.expense_values to authenticated;

revoke all on public.my_hours_summary from anon, authenticated;
grant select on public.my_hours_summary to authenticated;

revoke all on public.work_hours_by_category from anon, authenticated;
grant select on public.work_hours_by_category to authenticated;

revoke all on public.work_session_totals from anon, authenticated;
grant select on public.work_session_totals to authenticated;

revoke all on public.work_session_values from anon, authenticated;
grant select on public.work_session_values to authenticated;

-- Paperwork, credentials and the way in and out of the practice.
revoke all on public.credential_attention from anon, authenticated;
grant select on public.credential_attention to authenticated;

revoke all on public.my_tour_progress from anon, authenticated;
grant select on public.my_tour_progress to authenticated;

revoke all on public.offboarding_readiness from anon, authenticated;
grant select on public.offboarding_readiness to authenticated;

revoke all on public.staff_checklist from anon, authenticated;
grant select on public.staff_checklist to authenticated;

revoke all on public.staff_credential_status from anon, authenticated;
grant select on public.staff_credential_status to authenticated;

revoke all on public.staff_documents from anon, authenticated;
grant select on public.staff_documents to authenticated;

-- What is waiting to be answered.
revoke all on public.inbox_pending from anon, authenticated;
grant select on public.inbox_pending to authenticated;

revoke all on public.sms_due_reminders from anon, authenticated;
grant select on public.sms_due_reminders to authenticated;

revoke all on public.texts_unanswered from anon, authenticated;
grant select on public.texts_unanswered to authenticated;

revoke all on public.updates_for_me from anon, authenticated;
grant select on public.updates_for_me to authenticated;

-- With these, every view in `public` gives `authenticated` SELECT and nothing
-- else, which is what `supabase/verify_view_grants.sql` now asks - of the
-- catalogue rather than of a list of names, so the next view created in this
-- schema is judged by the same rule without anybody remembering to add it.
