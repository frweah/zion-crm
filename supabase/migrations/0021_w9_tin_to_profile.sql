-- ─────────────────────────────────────────────────────────────
-- 0021 — a signed W-9 puts the TIN on the contractor's profile.
--
-- 0019 already had a signed form update the profile, but only with the date
-- and the last four digits. The number itself stayed inside the form's
-- encrypted payload, where the 1099 run cannot reach it — so a contractor who
-- had signed a W-9 in the app would still show as having no TIN, and Admin
-- would have to key it in a second time from a document only they can open.
-- Two places holding the same number is how the two come to disagree.
--
-- set_contractor_tin() cannot do this: it is Admin-only by design, and the
-- person signing their own W-9 is not Admin. This trigger already runs as
-- definer, so it decrypts the payload it was just handed and re-encrypts the
-- nine digits into the profile under the same Vault key.
--
-- search_path carries vault and extensions for the reason 0016 records:
-- pgcrypto lives in extensions, not public.
-- ─────────────────────────────────────────────────────────────

create or replace function public.tax_form_updates_profile()
returns trigger language plpgsql security definer
set search_path = public, vault, extensions as $$
declare
  k         text;
  payload   jsonb;
  digits    text;
  tin_kind  text;
begin
  if new.status <> 'Signed' or old.status = 'Signed' then
    return new;
  end if;

  insert into public.contractor_profiles (staff_id) values (new.staff_id)
  on conflict (staff_id) do nothing;

  if new.form_type = 'W-8BEN' then
    update public.contractor_profiles
       set tax_status = 'Foreign person',
           w9_received_on = null,
           w8ben_received_on = new.signed_at::date
     where staff_id = new.staff_id;

  elsif new.form_type = 'W-9' then
    update public.contractor_profiles
       set tax_status = 'US person',
           w8ben_received_on = null,
           w9_received_on = new.signed_at::date,
           tin_last4 = coalesce(new.tin_last4, tin_last4)
     where staff_id = new.staff_id;

    if new.sensitive_encrypted is not null then
      select decrypted_secret into k from vault.decrypted_secrets where name = 'zion_tin_key';
      if k is null then
        raise exception 'The TIN encryption key is missing from Vault.';
      end if;

      payload := pgp_sym_decrypt(new.sensitive_encrypted, k)::jsonb;
      digits := regexp_replace(coalesce(payload ->> 'ssn', payload ->> 'ein', ''), '\D', '', 'g');
      tin_kind := case when payload ? 'ssn' then 'SSN' when payload ? 'ein' then 'EIN' end;

      if length(digits) = 9 and tin_kind is not null then
        update public.contractor_profiles
           set tin_type = tin_kind,
               tin_encrypted = pgp_sym_encrypt(digits, k),
               tin_last4 = right(digits, 4)
         where staff_id = new.staff_id;
      end if;
    end if;
  end if;

  return new;
end;
$$;
