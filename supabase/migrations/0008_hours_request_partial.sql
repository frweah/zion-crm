-- Zion Vocational Rehab CRM — 0008 partially approved hours requests
--
-- The prototype offers Pending / Approved / Partially approved / Denied. 0001
-- allowed only three, which would have forced a counselor granting 10 of the
-- 20 hours asked for to be recorded as a plain "Approved" — losing exactly the
-- fact Billing needs when the hours run out early.

alter table public.hours_requests drop constraint if exists hours_requests_response_check;
alter table public.hours_requests add constraint hours_requests_response_check
  check (response in ('Pending', 'Approved', 'Partially approved', 'Denied'));
