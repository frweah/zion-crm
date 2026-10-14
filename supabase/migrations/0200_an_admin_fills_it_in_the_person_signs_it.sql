-- Zion Vocational Rehab CRM - an Admin fills a form in; the person signs it
-- (owner, 14 Oct 2026: "The only things Admin can't do for someone else: sign
-- their tax form or policy, or give texting/e-delivery consent - those stay
-- the person's own.")
--
-- Item 4 opens a staff record right up: an Admin may change every field and
-- upload or replace any document on somebody's behalf. This migration is the
-- fence around that, and two of the three sides of it were missing.
--
-- ── signing a tax form ──
--
-- sign_tax_form allowed it. The guard read
--
--   if not (public.is_admin() or v_owner = public.current_staff_id())
--
-- while the error it raised said "You can only sign your own form." So the
-- message described the rule the owner has now asked for, and the code did
-- something else - an Admin could put somebody's name and the date on their
-- W-9. Corrected to what the message always claimed.
--
-- ── signing a policy ──
--
-- Already safe, and worth saying so rather than changing something to look
-- busy: sign_staff_policy takes no staff id at all and writes the signature
-- for current_staff_id(). There is no argument an Admin could pass to sign as
-- somebody else, so nothing here touches it.
--
-- ── e-delivery consent ──
--
-- contractor_profiles.e_delivery_consent_on is agreeing to be sent a 1099 by
-- email instead of on paper, which is the contractor's choice to make under
-- the IRS rule that offers it. RLS gives an Admin the whole table, so an
-- Admin could tick it. A trigger refuses that one column, and a trigger
-- rather than a policy on purpose: the paperwork screens write through the
-- service-role client in places, which bypasses RLS and does not bypass
-- triggers.
--
-- There is no staff texting-consent column to guard. Client texting consent
-- is client_sms_consent, which an Admin records *for a client* by design -
-- a different thing from giving it on a colleague's behalf, and left alone.

CREATE OR REPLACE FUNCTION public.sign_tax_form(p_form_id uuid, p_sensitive jsonb, p_tin_last4 text, p_signer text, p_ip text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'vault', 'extensions'
AS $function$
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
  /**
   * Only the person whose form it is.
   *
   * This read `is_admin() or v_owner = current_staff_id()` while raising "You
   * can only sign your own form" - so an Admin could sign somebody's W-9 and
   * the error message said they could not. The owner settled it on 14 Oct
   * 2026: an Admin may fill in anybody's details and upload anybody's
   * documents, and may not sign for them.
   *
   * An Admin keeps everything around the signature. They can create the
   * draft, correct it, attach the PDF and supersede it - RLS still lets them
   * - because preparing a form for somebody is help, and signing it is a
   * statement only that person can make.
   */
  if v_owner is distinct from public.current_staff_id() then
    raise exception 'Only % signs that form. An Admin can prepare it, not sign it.',
      coalesce((select name from public.staff where id = v_owner), 'the person it belongs to')
      using errcode = 'insufficient_privilege',
            hint = 'Ask them to sign it from Paperwork.';
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
$function$;

comment on function public.sign_tax_form is
  'Signs the caller''s own tax form. An Admin may prepare, correct, attach to and supersede anybody''s form, and may not sign one: a signature is a statement only the person it names can make.';

-- ─────────────────────────────────────────────────────────────
-- A migration is not somebody acting for somebody
--
-- Found by verify_1099.sql: its fixture records a consent while connected as
-- the database owner, and the guard above refused it, because
-- current_staff_id() is null there and null is not the contractor.
--
-- So the guard has to tell three callers apart, and only two of them are
-- people:
--
--   postgres          a migration, a backfill, or somebody at the console.
--                     Allowed - not as a favour but because anybody holding
--                     those credentials can drop the trigger in the next
--                     statement. Pretending otherwise would be a wall with a
--                     door beside it.
--
--   service_role      the key the application itself holds. This is the one
--                     that matters: it bypasses RLS, so a screen that set a
--                     consent through the admin client would sail past every
--                     policy. It is refused.
--
--   authenticated     a person. Refused unless it is their own row.
-- ─────────────────────────────────────────────────────────────
create or replace function public.writing_as_the_database()
returns boolean language sql stable set search_path = public as $$
  select current_user = 'postgres' and public.current_staff_id() is null
$$;

comment on function public.writing_as_the_database is
  'True for a migration or the console - the database owner, with no signed-in person. Deliberately false for service_role, which is the key the application holds and the one a consent guard exists to stop.';

revoke all on function public.writing_as_the_database() from anon, authenticated, service_role;

-- ─────────────────────────────────────────────────────────────
-- E-delivery consent is the contractor's to give
-- ─────────────────────────────────────────────────────────────
create or replace function public.e_delivery_consent_is_theirs()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  /**
   * Granting it, not clearing it.
   *
   * Recording a consent somebody did not give misrepresents them, and that is
   * what this refuses. Recording that we do not have one cannot: it means
   * their 1099 goes on paper, which is the fallback the IRS rule assumes
   * anyway. So an Admin may always take it off - resetting a stale record, or
   * clearing it because the person said so on the phone - and may never put
   * it on.
   *
   * verify_1099.sql found this: its fixture clears the field while setting up,
   * and an earlier version of this guard refused that, which would have made
   * a contractor's consent impossible to correct.
   */
  if new.e_delivery_consent_on is not null
     and new.e_delivery_consent_on is distinct from old.e_delivery_consent_on
     and new.staff_id is distinct from public.current_staff_id()
     and not public.writing_as_the_database() then
    raise exception 'Only % agrees to be sent their 1099 by email.',
      coalesce((select name from public.staff where id = new.staff_id), 'the contractor')
      using errcode = 'insufficient_privilege',
            hint = 'They give it from Paperwork. An Admin can change everything else here.';
  end if;
  return new;
end;
$$;

comment on function public.e_delivery_consent_is_theirs is
  'Refuses a change to e_delivery_consent_on by anybody but the contractor it belongs to. A trigger rather than a policy, because the paperwork screens write through the service-role client in places - which bypasses RLS and not this.';

drop trigger if exists contractor_e_delivery_is_theirs on public.contractor_profiles;
create trigger contractor_e_delivery_is_theirs
  before update on public.contractor_profiles
  for each row execute function public.e_delivery_consent_is_theirs();

-- An insert that arrives already consented is the same act by another route.
create or replace function public.e_delivery_consent_on_insert()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.e_delivery_consent_on is not null
     and new.staff_id is distinct from public.current_staff_id()
     and not public.writing_as_the_database() then
    raise exception 'Only % agrees to be sent their 1099 by email.',
      coalesce((select name from public.staff where id = new.staff_id), 'the contractor')
      using errcode = 'insufficient_privilege',
            hint = 'Add the record without it; they give consent from Paperwork.';
  end if;
  return new;
end;
$$;

drop trigger if exists contractor_e_delivery_on_insert on public.contractor_profiles;
create trigger contractor_e_delivery_on_insert
  before insert on public.contractor_profiles
  for each row execute function public.e_delivery_consent_on_insert();

-- ─────────────────────────────────────────────────────────────
-- The door for the person already existed
--
-- An earlier draft of this migration added give_e_delivery_consent(), having
-- found that contractor_profiles is Admin-write and concluded the contractor
-- had no way in. verify_1099.sql knew better: set_e_delivery_consent() has
-- been there since the 1099 work, takes no staff id, and acts for the caller.
--
-- So the duplicate is dropped rather than shipped. Two functions doing this
-- would have drifted, and the one that already has a verify script behind it
-- is the one to keep.
-- ─────────────────────────────────────────────────────────────
drop function if exists public.give_e_delivery_consent(boolean);
