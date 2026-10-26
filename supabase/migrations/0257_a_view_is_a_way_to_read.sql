-- Zion Vocational Rehab CRM — 0257 a view is a way to read
--
-- Creating anything in schema `public` on this project hands `authenticated`
-- INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES and TRIGGER on it, whether or
-- not the migration grants a thing, because Supabase sets
--
--   alter default privileges in schema public grant all on tables to authenticated
--
-- as part of setting the project up. Every one of these views was created to
-- be read. None of them has ever been written to - no screen, no action and
-- no function writes through a view, which was checked rather than assumed
-- before this ran - and the grants were nobody's decision.
--
-- That matters most for `billed_work`, which is simple enough that Postgres
-- can write through it: with INSERT granted it was a second door into
-- `authorizations`, shaped differently from the first, and `verify_one_door`
-- exists to say there is only one. The others are not auto-updatable and so
-- refuse a write on their own account today, which is a property of how they
-- happen to be written rather than of what anybody decided. The grant is the
-- thing to remove.
--
-- Read access is untouched. Each view keeps SELECT for `authenticated`, and
-- `service_role` - which the server uses and which bypasses row security
-- anyway - is left as it is. Checked as every role on the practice before and
-- after: Admin, Billing, Case Manager, Job Search and Reports each see the
-- same rows in all nine (owner, 26 Oct 2026).
--
-- `client_documents` is the one view in `public` with no `security_invoker`,
-- and it stays that way on purpose rather than by oversight. The reason, and
-- the condition that keeps it safe without one, are in
-- `supabase/verify_view_grants.sql`, which asserts both.

-- The nine views that read `authorizations`, directly or through another view.
revoke all on public.authorization_economics from anon, authenticated;
grant select on public.authorization_economics to authenticated;

revoke all on public.authorization_record from anon, authenticated;
grant select on public.authorization_record to authenticated;

revoke all on public.billed_work from anon, authenticated;
grant select on public.billed_work to authenticated;

revoke all on public.billing_position from anon, authenticated;
grant select on public.billing_position to authenticated;

revoke all on public.client_activity from anon, authenticated;
grant select on public.client_activity to authenticated;

revoke all on public.client_last_activity from anon, authenticated;
grant select on public.client_last_activity to authenticated;

revoke all on public.client_paperwork from anon, authenticated;
grant select on public.client_paperwork to authenticated;

revoke all on public.client_pipeline from anon, authenticated;
grant select on public.client_pipeline to authenticated;

revoke all on public.staff_capacity from anon, authenticated;
grant select on public.staff_capacity to authenticated;

-- The default itself is left alone on purpose. Turning it off with
--
--   alter default privileges in schema public
--     revoke insert, update, delete, truncate on tables from authenticated
--
-- would close this for every view made from here on - and would also, in the
-- same breath, take the writes off every new *table*, which is not the same
-- question. Some tables grant explicitly and some lean on the default:
-- `mail_templates` (0238) has no grant of its own, and the Mail screen writes
-- to it. So the default stays, `verify_view_grants` watches the views
-- instead, and whether to change the default is the owner's to decide with
-- the whole picture rather than as a side-effect of tidying nine views.
