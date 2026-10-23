-- Zion Vocational Rehab CRM — 0246 the two new tables refuse the system account
--
-- Every table carries three restrictive policies that refuse a write from a
-- system account - the throwaway logins smoke signs in as, which open every
-- screen on every deploy and must never change anything. `verify_system_account`
-- names any table that does not have them, and it named
-- `microsoft_subscriptions` (0241).
--
-- `mail_templates` (0238) is here too, though nothing complained about it: it
-- got the three policies hand-written, which is the same three policies
-- spelled a second time. `apply_system_read_only` is the one spelling, and a
-- table whose version was typed out is a table whose version will drift when
-- that helper changes.

select public.apply_system_read_only('public.microsoft_subscriptions');
select public.apply_system_read_only('public.mail_templates');
