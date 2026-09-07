-- Zion Vocational Rehab CRM — 0016 fix the TIN functions' search path
--
-- pgcrypto lives in the `extensions` schema on Supabase, not `public`, so
-- pgp_sym_encrypt was not visible to functions pinned to `public, vault` and
-- recording a TIN failed outright.
--
-- The search_path stays pinned rather than being dropped: these functions are
-- SECURITY DEFINER and hold the decryption key, so leaving the path open to
-- the caller would be the one place in this schema where that actually matters.

create or replace function public.set_contractor_tin(p_staff_id uuid, p_tin text, p_tin_type text)
returns void
language plpgsql security definer set search_path = public, vault, extensions
as $$
declare
  k      text;
  digits text := regexp_replace(coalesce(p_tin, ''), '\D', '', 'g');
begin
  if not public.is_admin() then
    raise exception 'Only Admin can record a TIN.' using errcode = 'insufficient_privilege';
  end if;
  if length(digits) <> 9 then
    raise exception 'A TIN is nine digits.' using errcode = 'check_violation';
  end if;
  if p_tin_type not in ('SSN', 'EIN') then
    raise exception 'TIN type must be SSN or EIN.' using errcode = 'check_violation';
  end if;

  select decrypted_secret into k from vault.decrypted_secrets where name = 'zion_tin_key';
  if k is null then
    raise exception 'The TIN encryption key is missing from Vault.';
  end if;

  insert into public.contractor_profiles (staff_id, tin_type, tin_encrypted, tin_last4)
  values (p_staff_id, p_tin_type, extensions.pgp_sym_encrypt(digits, k), right(digits, 4))
  on conflict (staff_id) do update set
    tin_type = excluded.tin_type,
    tin_encrypted = excluded.tin_encrypted,
    tin_last4 = excluded.tin_last4;
end;
$$;

create or replace function public.get_contractor_tin(p_staff_id uuid)
returns text
language plpgsql security definer set search_path = public, vault, extensions
as $$
declare
  k text;
  e bytea;
begin
  if not public.is_admin() then
    raise exception 'Only Admin can read a TIN.' using errcode = 'insufficient_privilege';
  end if;

  select tin_encrypted into e from public.contractor_profiles where staff_id = p_staff_id;
  if e is null then return null; end if;

  select decrypted_secret into k from vault.decrypted_secrets where name = 'zion_tin_key';
  return extensions.pgp_sym_decrypt(e, k);
end;
$$;
