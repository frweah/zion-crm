-- Zion Vocational Rehab CRM — 0019 in-app tax forms
--
-- Staff complete their own tax paperwork in the CRM, which fills the official
-- IRS PDF and stores it in the Admin-only bucket.
--
-- The lifecycle is what keeps the sensitive numbers contained:
--   Draft   the person is typing; their own entries are readable to them and
--           to Admin, because they are looking at them anyway.
--   Signed  the tax identification numbers are moved into an encrypted column
--           and removed from the readable data. From then on the full number
--           exists in exactly two places — that encrypted column, and the
--           generated PDF, which only Admin can open.
--
-- A signed form is never edited. A change means a new form that supersedes it,
-- the same rule as time records, and for the same reason.

create table public.tax_form_submissions (
  id                  uuid primary key default gen_random_uuid(),
  staff_id            uuid not null references public.staff(id) on delete cascade,
  form_type           text not null check (form_type in ('W-8BEN', 'W-9', 'W-4')),
  status              text not null default 'Draft' check (status in ('Draft', 'Signed', 'Superseded')),
  data                jsonb not null default '{}'::jsonb,
  sensitive_encrypted bytea,
  tin_last4           text,
  signed_at           timestamptz,
  signer_name         text,
  signer_ip           text,
  pdf_path            text,
  pdf_sha256          text,
  staff_file_id       uuid references public.staff_files(id) on delete set null,
  supersedes_id       uuid references public.tax_form_submissions(id) on delete set null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create index tax_forms_staff_idx on public.tax_form_submissions (staff_id, created_at desc);
create index tax_forms_open_idx on public.tax_form_submissions (staff_id, form_type)
  where status = 'Draft';

create trigger tax_forms_updated_at before update on public.tax_form_submissions
  for each row execute function public.set_updated_at();

alter table public.tax_form_submissions enable row level security;

create policy tax_forms_read on public.tax_form_submissions
  for select to authenticated
  using (public.is_admin() or staff_id = public.current_staff_id());

create policy tax_forms_insert on public.tax_form_submissions
  for insert to authenticated
  with check (public.is_admin() or staff_id = public.current_staff_id());

create policy tax_forms_update on public.tax_form_submissions
  for update to authenticated
  using (public.is_admin() or staff_id = public.current_staff_id())
  with check (public.is_admin() or staff_id = public.current_staff_id());

-- Nobody deletes a signed tax form, including Admin.
create policy tax_forms_delete on public.tax_form_submissions
  for delete to authenticated
  using (status = 'Draft' and (public.is_admin() or staff_id = public.current_staff_id()));

-- The ciphertext column is not readable through the API by anyone.
revoke select (sensitive_encrypted) on public.tax_form_submissions from authenticated;

/**
 * A signed form is frozen. Superseding it is the only permitted change, and
 * that only flips the status — everything the person attested to stays as it
 * was on the day they signed.
 */
create or replace function public.tax_forms_freeze_when_signed()
returns trigger language plpgsql as $$
begin
  if old.status = 'Signed' then
    if new.status = 'Superseded'
       and new.data is not distinct from old.data
       and new.signed_at is not distinct from old.signed_at
       and new.pdf_sha256 is not distinct from old.pdf_sha256 then
      return new;
    end if;
    raise exception
      'A signed % cannot be changed. Complete a new one, which will supersede it.', old.form_type
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

create trigger tax_forms_freeze before update on public.tax_form_submissions
  for each row execute function public.tax_forms_freeze_when_signed();

/**
 * Sign a form.
 *
 * Takes the sensitive values separately from the rest so they never land in
 * the readable column: they are encrypted with the same Vault key used for
 * contractor TINs, and only the last four digits are kept in the clear. The
 * caller must be the person the form belongs to, or Admin acting for them.
 */
create or replace function public.sign_tax_form(
  p_form_id   uuid,
  p_sensitive jsonb,
  p_tin_last4 text,
  p_signer    text,
  p_ip        text
)
returns void
language plpgsql security definer set search_path = public, vault, extensions
as $$
declare
  k       text;
  v_owner uuid;
  v_type  text;
  v_state text;
begin
  select staff_id, form_type, status into v_owner, v_type, v_state
    from public.tax_form_submissions where id = p_form_id;

  if v_owner is null then
    raise exception 'That form does not exist.';
  end if;
  if not (public.is_admin() or v_owner = public.current_staff_id()) then
    raise exception 'You can only sign your own form.' using errcode = 'insufficient_privilege';
  end if;
  if v_state <> 'Draft' then
    raise exception 'That form is already signed.' using errcode = 'check_violation';
  end if;
  if coalesce(trim(p_signer), '') = '' then
    raise exception 'A signature needs the signer''s name.' using errcode = 'check_violation';
  end if;

  select decrypted_secret into k from vault.decrypted_secrets where name = 'zion_tin_key';
  if k is null then
    raise exception 'The encryption key is missing from Vault.';
  end if;

  update public.tax_form_submissions
     set status = 'Signed',
         sensitive_encrypted = case
           when p_sensitive is null or p_sensitive = '{}'::jsonb then null
           else extensions.pgp_sym_encrypt(p_sensitive::text, k)
         end,
         tin_last4 = nullif(p_tin_last4, ''),
         signed_at = now(),
         signer_name = trim(p_signer),
         signer_ip = p_ip
   where id = p_form_id;

  -- Any earlier signed form of the same type steps aside.
  update public.tax_form_submissions
     set status = 'Superseded'
   where staff_id = v_owner
     and form_type = v_type
     and status = 'Signed'
     and id <> p_form_id;
end;
$$;

create or replace function public.get_tax_form_sensitive(p_form_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, vault, extensions
as $$
declare
  k text;
  e bytea;
begin
  if not public.is_admin() then
    raise exception 'Only Admin can read the numbers on a filed form.'
      using errcode = 'insufficient_privilege';
  end if;

  select sensitive_encrypted into e from public.tax_form_submissions where id = p_form_id;
  if e is null then return null; end if;

  select decrypted_secret into k from vault.decrypted_secrets where name = 'zion_tin_key';
  return extensions.pgp_sym_decrypt(e, k)::jsonb;
end;
$$;

revoke execute on function public.sign_tax_form(uuid, jsonb, text, text, text) from public;
revoke execute on function public.get_tax_form_sensitive(uuid) from public;
grant execute on function public.sign_tax_form(uuid, jsonb, text, text, text) to authenticated;
grant execute on function public.get_tax_form_sensitive(uuid) to authenticated;

/**
 * Signing a W-8BEN or W-9 is how the profile learns the paperwork is on file.
 * Recording it in two places by hand is how the two end up disagreeing.
 */
create or replace function public.tax_form_updates_profile()
returns trigger language plpgsql security definer set search_path = public as $$
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
  end if;

  return new;
end;
$$;

create trigger tax_forms_update_profile after update of status on public.tax_form_submissions
  for each row execute function public.tax_form_updates_profile();
