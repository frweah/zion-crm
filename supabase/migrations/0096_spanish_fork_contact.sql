-- Zion Vocational Rehab CRM — Heather Davis is Spanish Fork's counselor, not its billing coordinator
--
-- The owner, 18 Sept 2026: Heather is the counselor; leave the Spanish Fork
-- billing coordinator blank so it can be added or edited later (Admin, on
-- Counselors -> Directory -> Billing offices).
--
-- The billing address stays heatherd1@utah.gov for now. A billing office must
-- have one (0091), and it is the only address known for that office, so
-- billing mail for Spanish Fork clients still reaches the counselor until a
-- coordinator or a group address is added. The note says so, so nobody takes
-- her for the billing contact.
--
-- Her counselor record, which had no email, gets the same address.

do $$
declare
  v_n integer;
begin
  update public.billing_offices
     set contact_name  = '',
         contact_title = '',
         contact_email = '',
         notes = 'No billing coordinator on file yet. Until one - or a group billing address - is added, billing mail goes to the Spanish Fork counselor, Heather Davis.'
   where name = 'Spanish Fork';
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'Expected one Spanish Fork billing office, found %', v_n;
  end if;

  update public.counselors
     set email = 'heatherd1@utah.gov'
   where name = 'Heather Davis' and office = 'Spanish Fork' and coalesce(email, '') = '';
  get diagnostics v_n = row_count;
  if v_n = 0 and not exists (select 1 from public.counselors
                              where name = 'Heather Davis' and email = 'heatherd1@utah.gov') then
    raise exception 'Heather Davis (Spanish Fork) is not on file as expected';
  end if;
end $$;
