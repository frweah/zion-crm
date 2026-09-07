-- ─────────────────────────────────────────────────────────────
-- 0022 — the employer half of Form W-4.
--
-- A W-4 is not finished when the employee signs it. The bottom block is the
-- employer's: legal name and address, the employee's first date of employment,
-- and the employer's EIN. None of that was anywhere in this system, and a
-- stored PDF with an empty employer block is not the record it is meant to be.
--
-- The first date of employment already exists — staff_employment.started_on —
-- so only the three org-level values are added here.
--
-- The EIN is the business's own number, printed on every return and every
-- 1099 the practice issues, so it is not a personal secret in the way a staff
-- member's SSN is. It is still no one else's business, so the column is
-- readable by Admin alone, the same way pay rates are.
-- ─────────────────────────────────────────────────────────────

alter table public.org_settings
  add column if not exists employer_legal_name text not null default '',
  add column if not exists employer_address    text not null default '',
  add column if not exists employer_ein        text not null default '';

-- Everyone active reads this row for the pay period, so the restriction is on
-- the column rather than the row.
revoke select (employer_ein) on public.org_settings from authenticated;

/**
 * The employer block, for filling a W-4.
 *
 * Admin only, and returned in one call so the caller cannot assemble a
 * half-filled block from whatever it happened to be allowed to read.
 */
create or replace function public.get_employer_details()
returns table (legal_name text, address text, ein text)
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then
    raise exception 'Only Admin can read the employer details.'
      using errcode = 'insufficient_privilege';
  end if;
  return query
    select employer_legal_name, employer_address, employer_ein
      from public.org_settings where id;
end;
$$;

create or replace function public.set_employer_details(
  p_legal_name text,
  p_address    text,
  p_ein        text
)
returns void
language plpgsql security definer set search_path = public as $$
declare
  digits text := regexp_replace(coalesce(p_ein, ''), '\D', '', 'g');
begin
  if not public.is_admin() then
    raise exception 'Only Admin can set the employer details.'
      using errcode = 'insufficient_privilege';
  end if;
  -- A number that is present but the wrong length would go onto a filed form.
  if digits <> '' and length(digits) <> 9 then
    raise exception 'An EIN is nine digits.' using errcode = 'check_violation';
  end if;

  -- A blank EIN leaves the stored one alone. The screen never shows the number
  -- back, so an empty box means "unchanged", not "delete it" — otherwise
  -- editing the address would silently wipe the EIN.
  update public.org_settings
     set employer_legal_name = coalesce(p_legal_name, ''),
         employer_address    = coalesce(p_address, ''),
         employer_ein        = case when digits = '' then employer_ein else digits end
   where id;
end;
$$;

revoke execute on function public.get_employer_details() from public;
revoke execute on function public.set_employer_details(text, text, text) from public;
grant execute on function public.get_employer_details() to authenticated;
grant execute on function public.set_employer_details(text, text, text) to authenticated;
