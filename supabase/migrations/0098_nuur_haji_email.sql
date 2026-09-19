-- Zion Vocational Rehab CRM — Nuur Haji's email
--
-- Held in 0097 because the address begins with an S. The owner confirmed,
-- 18 Sept 2026: shaji@utah.gov is Nuur Haji. Name unchanged; only an empty
-- email is filled.

do $$
declare
  v_n integer;
begin
  update public.counselors
     set email = 'shaji@utah.gov'
   where name = 'Nuur Haji' and office = 'Salt Lake City' and coalesce(email, '') = '';
  get diagnostics v_n = row_count;
  if v_n = 0 and not exists (select 1 from public.counselors where name = 'Nuur Haji' and email = 'shaji@utah.gov') then
    raise exception 'Nuur Haji (Salt Lake City) is not on file with an empty email as expected';
  end if;
end $$;
