-- ─────────────────────────────────────────────────────────────
-- 0023 — building a 1099 run, and consent to receive one electronically.
--
-- A run is a snapshot. Once it exists, the names, addresses and amounts on it
-- are what was filed, and later edits to a profile must not silently rewrite
-- history — otherwise the copy the contractor holds and the record here drift
-- apart with nothing to show which is right.
--
-- The run refuses to build at all if any candidate is incomplete. That is
-- deliberate and it is the whole point: form_1099_candidates already knows who
-- is missing a TIN, a W-9 or an address, and a filing that quietly leaves a
-- person out, or files them with a blank address, is worse than one that will
-- not start until the gap is closed.
--
-- Electronic delivery of a payee statement needs the recipient's affirmative
-- consent, and the consent has to be on record before the statement is sent.
-- So it lives on the profile as a date, and is copied onto the recipient row
-- when the run is built — what mattered is whether consent was in place then.
-- ─────────────────────────────────────────────────────────────

alter table public.contractor_profiles
  add column if not exists e_delivery_consent_on date;

comment on column public.contractor_profiles.e_delivery_consent_on is
  'When this person agreed to receive their 1099 electronically. Null means it must be posted.';

/**
 * Records a contractor's own consent to electronic delivery.
 *
 * The person consents for themselves — this is the one thing on their profile
 * that is not Admin's to set, because consent given on somebody else's behalf
 * is not consent. Withdrawing it is equally theirs.
 */
create or replace function public.set_e_delivery_consent(p_consent boolean)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_staff uuid := public.current_staff_id();
begin
  if v_staff is null then
    raise exception 'You are not signed in.' using errcode = 'insufficient_privilege';
  end if;

  insert into public.contractor_profiles (staff_id, e_delivery_consent_on)
  values (v_staff, case when p_consent then current_date end)
  on conflict (staff_id) do update
    set e_delivery_consent_on = case when p_consent then current_date end;
end;
$$;

revoke execute on function public.set_e_delivery_consent(boolean) from public;
grant execute on function public.set_e_delivery_consent(boolean) to authenticated;

/**
 * Builds a 1099 run for a year, snapshotting every recipient.
 *
 * Refuses on an unconfirmed threshold, on nobody over it, and on any candidate
 * whose details are incomplete — naming who and what is missing, because "it
 * did not work" is not something anybody can act on in January.
 */
create or replace function public.generate_1099_run(p_year integer)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_run       uuid;
  v_year      record;
  v_problems  text;
  v_count     int;
begin
  if not public.is_admin() then
    raise exception 'Only Admin can generate a 1099 run.' using errcode = 'insufficient_privilege';
  end if;

  select * into v_year from public.tax_years where year = p_year;
  if v_year is null or v_year.federal_threshold is null then
    raise exception 'The % federal threshold has not been set.', p_year
      using errcode = 'check_violation';
  end if;
  if v_year.confirmed_on is null then
    raise exception 'The % threshold has not been confirmed. Nothing is filed on an unconfirmed figure.', p_year
      using errcode = 'check_violation';
  end if;

  select count(*) into v_count from public.form_1099_candidates(p_year);
  if v_count = 0 then
    raise exception 'Nobody was paid % or more in %.', v_year.federal_threshold, p_year
      using errcode = 'check_violation';
  end if;

  select string_agg(format('%s (%s)', staff_name, problem), '; ' order by staff_name)
    into v_problems
    from public.form_1099_candidates(p_year)
   where not ready;

  if v_problems is not null then
    raise exception 'These are not ready to file: %', v_problems
      using errcode = 'check_violation';
  end if;

  insert into public.form_1099_runs (year, threshold, state_copy, generated_by)
  values (p_year, v_year.federal_threshold, v_year.utah_state_copy, public.current_staff_id())
  returning id into v_run;

  insert into public.form_1099_recipients (
    run_id, staff_id, legal_name, business_name, address_snapshot,
    tin_type, tin_last4, nonemployee_comp, consent_recorded
  )
  select v_run, c.staff_id, c.legal_name, c.business_name, c.address_snapshot,
         c.tin_type, c.tin_last4, c.total_paid,
         p.e_delivery_consent_on is not null
    from public.form_1099_candidates(p_year) c
    left join public.contractor_profiles p on p.staff_id = c.staff_id;

  return v_run;
end;
$$;

revoke execute on function public.generate_1099_run(integer) from public;
grant execute on function public.generate_1099_run(integer) to authenticated;

/**
 * Marks one recipient's copy as delivered.
 *
 * Electronic delivery without consent on record is refused here rather than
 * left to the screen, because "we emailed it" is exactly the claim that has to
 * be defensible a year later.
 */
create or replace function public.record_1099_delivery(
  p_recipient_id uuid,
  p_method       text,
  p_delivered_on date
)
returns void
language plpgsql security definer set search_path = public as $$
declare
  r record;
begin
  if not public.is_admin() then
    raise exception 'Only Admin can record delivery.' using errcode = 'insufficient_privilege';
  end if;

  select * into r from public.form_1099_recipients where id = p_recipient_id;
  if r is null then
    raise exception 'No such recipient.' using errcode = 'check_violation';
  end if;

  if p_method not in ('Secure download', 'Email', 'Post', 'In person') then
    raise exception 'Unknown delivery method.' using errcode = 'check_violation';
  end if;

  if p_method in ('Secure download', 'Email') and not r.consent_recorded then
    raise exception
      '% has not agreed to receive their 1099 electronically. Post it, or ask them to agree first.',
      r.legal_name using errcode = 'check_violation';
  end if;

  if p_delivered_on > current_date then
    raise exception 'A copy cannot be delivered in the future.' using errcode = 'check_violation';
  end if;

  update public.form_1099_recipients
     set delivered_on = p_delivered_on, delivery_method = p_method
   where id = p_recipient_id;
end;
$$;

revoke execute on function public.record_1099_delivery(uuid, text, date) from public;
grant execute on function public.record_1099_delivery(uuid, text, date) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- A snapshot stays a snapshot.
--
-- The amount, the name and the number on a filed run are what was filed. If
-- something was wrong, the answer is a corrected return — which the table
-- already carries the columns for — not an edit that leaves no trace.
-- ─────────────────────────────────────────────────────────────
create or replace function public.freeze_1099_recipient()
returns trigger language plpgsql as $$
begin
  if new.legal_name is distinct from old.legal_name
     or new.business_name is distinct from old.business_name
     or new.address_snapshot is distinct from old.address_snapshot
     or new.tin_type is distinct from old.tin_type
     or new.tin_last4 is distinct from old.tin_last4
     or new.nonemployee_comp is distinct from old.nonemployee_comp
     or new.staff_id is distinct from old.staff_id
     or new.run_id is distinct from old.run_id then
    raise exception
      'What is on a 1099 run is what was filed. Issue a corrected return instead of editing it.'
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

drop trigger if exists form_1099_recipients_freeze on public.form_1099_recipients;
create trigger form_1099_recipients_freeze before update on public.form_1099_recipients
  for each row execute function public.freeze_1099_recipient();
