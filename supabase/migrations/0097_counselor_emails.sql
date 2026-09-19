-- Zion Vocational Rehab CRM — counselor emails from the owner's list
--
-- The owner's list of USOR addresses, 18 Sept 2026: nineteen emails and no
-- names. Thirteen already matched the record. These five fill the gaps where
-- the address plainly belongs to the counselor. Names stay as they are on
-- record, and only an empty email is filled - an address already on file is
-- never overwritten.
--
-- Not here: shaji@utah.gov. The only counselor still without an email is Nuur
-- Haji, and that address begins with an S. Held for the owner to confirm.

do $$
declare
  r   record;
  v_n integer;
begin
  for r in
    select * from (values
      ('Carmen Bento',   'Tooele',         'cbento@utah.gov'),
      ('Rebekah Berg',   'Taylorsville',   'rberg@utah.gov'),
      ('Sabin Muratori', 'Taylorsville',   'sabinm@utah.gov'),
      ('Sherida Burge',  'Centerville',    'sburge@utah.gov'),
      ('Danielle Hood',  'Salt Lake City', 'dchood@utah.gov')
    ) as x(name, office, email)
  loop
    update public.counselors
       set email = r.email
     where name = r.name and office = r.office and coalesce(email, '') = '';
    get diagnostics v_n = row_count;
    if v_n = 0 and not exists (select 1 from public.counselors where name = r.name and email = r.email) then
      raise exception '% (%) is not on file with an empty email as expected', r.name, r.office;
    end if;
  end loop;
end $$;
