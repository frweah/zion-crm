-- ─────────────────────────────────────────────────────────────
-- 0026 — recording a pay rate.
--
-- staff_pay has existed since 0014 and has never had a way to put anything in
-- it. The onboarding checklist asks whether a rate is recorded, and the answer
-- was always no, because there was no screen. This adds the two functions the
-- screen needs and the rule that makes the history trustworthy.
--
-- A rate is a dated record, not a field. Setting a new one adds a row from a
-- date; it does not overwrite what somebody was paid under before. That is why
-- the table has effective_from and why nothing here updates in place.
-- ─────────────────────────────────────────────────────────────

/**
 * Records a rate from a date.
 *
 * A future date is allowed — a raise agreed now and starting next month is a
 * normal thing to want to record before it happens.
 */
create or replace function public.set_staff_pay(
  p_staff_id       uuid,
  p_rate           numeric,
  p_unit           text,
  p_effective_from date,
  p_note           text default ''
)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
begin
  if not public.is_admin() then
    raise exception 'Only Admin can set a pay rate.' using errcode = 'insufficient_privilege';
  end if;
  if p_rate is null or p_rate <= 0 then
    raise exception 'A rate is more than zero.' using errcode = 'check_violation';
  end if;
  if p_unit not in ('Hourly', 'Flat') then
    raise exception 'A rate is Hourly or Flat.' using errcode = 'check_violation';
  end if;
  if p_effective_from is null then
    raise exception 'A rate needs a date it takes effect from.' using errcode = 'check_violation';
  end if;

  -- Two rates from the same day is not a history, it is an argument about
  -- which one applied.
  if exists (
    select 1 from public.staff_pay
     where staff_id = p_staff_id and effective_from = p_effective_from
  ) then
    raise exception 'There is already a rate from %. Remove it, or use a different date.',
      p_effective_from using errcode = 'unique_violation';
  end if;

  insert into public.staff_pay (staff_id, pay_rate, rate_unit, effective_from, note, created_by)
  values (p_staff_id, p_rate, p_unit, p_effective_from, coalesce(p_note, ''),
          public.current_staff_id())
  returning id into v_id;

  return v_id;
end;
$$;

/**
 * Removes a rate — but only the most recent one for that person.
 *
 * Correcting a figure you have just mistyped is ordinary. Deleting a rate from
 * two years ago rewrites what somebody was paid under, and if the answer to
 * "what was the rate then" can be changed later, it was never an answer. So
 * the newest row can go and the ones behind it cannot.
 */
create or replace function public.delete_staff_pay(p_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  r       record;
  v_newest uuid;
begin
  if not public.is_admin() then
    raise exception 'Only Admin can remove a pay rate.' using errcode = 'insufficient_privilege';
  end if;

  select * into r from public.staff_pay where id = p_id;
  if r is null then
    raise exception 'That rate is no longer there.' using errcode = 'check_violation';
  end if;

  select id into v_newest from public.staff_pay
   where staff_id = r.staff_id
   order by effective_from desc, created_at desc
   limit 1;

  if v_newest <> p_id then
    raise exception
      'Only the most recent rate can be removed. An earlier one is what somebody was paid under.'
      using errcode = 'check_violation';
  end if;

  delete from public.staff_pay where id = p_id;
end;
$$;

revoke execute on function public.set_staff_pay(uuid, numeric, text, date, text) from public;
revoke execute on function public.delete_staff_pay(uuid) from public;
grant execute on function public.set_staff_pay(uuid, numeric, text, date, text) to authenticated;
grant execute on function public.delete_staff_pay(uuid) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- The rate in effect on a given day.
--
-- Written now because it is the honest way to price past work: what somebody
-- earned on a Tuesday is what the rate was on that Tuesday, not what it is
-- today. Nothing computes money from it yet — statements still show hours
-- only — but when they do, this is what they should ask.
-- ─────────────────────────────────────────────────────────────
create or replace function public.pay_rate_on(p_staff_id uuid, p_date date)
returns table (pay_rate numeric, rate_unit text, effective_from date)
language sql stable security invoker as $$
  select pay_rate, rate_unit, effective_from
    from public.staff_pay
   where staff_id = p_staff_id and effective_from <= p_date
   order by effective_from desc, created_at desc
   limit 1;
$$;

grant execute on function public.pay_rate_on(uuid, date) to authenticated;
