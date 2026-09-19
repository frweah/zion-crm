-- Zion Vocational Rehab CRM — onboarding, as the owner revised it
--
-- The owner, 19 Sept 2026:
--
--   Identity documents: the walkthrough uploads them and nothing more - no
--   List A/B/C names, numbers or expiry dates. The owner completes the I-9 in
--   person from the originals. (A screen change; nothing stored changes.)
--
--   Where they are paid: structured, not free text. A method from a fixed
--   list, and optionally the last four digits of the account - never more.
--   Eight or more digits in a row are refused anywhere on the step, so an
--   account number cannot be typed in by mistake. The "I gave my bank details
--   to the payroll service" confirmation goes; the method says it.
--
--   Somebody invited before the walkthrough existed and not yet signed in is
--   brought on through it too, on their first sign-in.

-- ── where they are paid ─────────────────────────────────────
-- Nobody has confirmed payment yet (the walkthrough is not live), so the
-- table is reshaped in place.
alter table public.staff_payment_setup drop constraint if exists staff_payment_no_account_numbers;
alter table public.staff_payment_setup drop constraint if exists staff_payment_deposit_needs_payroll;
alter table public.staff_payment_setup drop constraint if exists staff_payment_setup_method_check;
alter table public.staff_payment_setup drop column if exists bank_details_with_payroll;
alter table public.staff_payment_setup add column if not exists method_other text not null default '';
alter table public.staff_payment_setup add column if not exists last_four text not null default '';

alter table public.staff_payment_setup add constraint staff_payment_setup_method_check
  check (method in ('Payroll service', 'Direct deposit via payroll', 'Wise', 'PayPal', 'Other'));
alter table public.staff_payment_setup add constraint staff_payment_last_four
  check (last_four ~ '^([0-9]{4})?$');
-- "Other" says what; nothing else carries words of their own.
alter table public.staff_payment_setup add constraint staff_payment_other_only_for_other
  check (method = 'Other' or method_other = '');
alter table public.staff_payment_setup add constraint staff_payment_no_account_numbers
  check (method_other !~ '[0-9]{8,}' and payer_of_record !~ '[0-9]{8,}' and payroll_service !~ '[0-9]{8,}');

-- ── invited before the walkthrough ──────────────────────────
-- Active, invited, never signed in, and not already in it.
insert into public.staff_onboarding (staff_id)
select s.id
  from public.staff s
 where s.active and s.invited_at is not null and s.accepted_at is null
   and not exists (select 1 from public.staff_onboarding o where o.staff_id = s.id);
