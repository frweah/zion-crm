-- Zion Vocational Rehab CRM — 0243 the two new settings can be read
--
-- `org_settings` is granted column by column rather than as a table: it holds
-- the practice's EIN and its payroll arrangements, and a blanket grant on the
-- table would be a grant on those. So every new column needs a grant of its
-- own, and 0236 and 0238 added two without one. The screen that edits them
-- would have read null and written nothing, silently.
--
-- This is the third time it has happened - 0218 was the same fault on
-- `require_two_factor`, and it says so in its own first paragraph - which is
-- why `verify_columns.sql` asks the question and why it caught this one
-- before a deploy did.

grant select (mail_notice_staff_id) on public.org_settings to authenticated;
grant update (mail_notice_staff_id) on public.org_settings to authenticated;
grant select (mail_signature) on public.org_settings to authenticated;
grant update (mail_signature) on public.org_settings to authenticated;
