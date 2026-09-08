-- ─────────────────────────────────────────────────────────────
-- 0028 — a pay rate is not an amount of money.
--
-- pay_rate was numeric(10,2), so a rate of 5.625 an hour was silently stored
-- as 5.63. Nothing warned anybody: the figure was accepted, written down
-- wrong, and read back wrong. Eight hours at the true rate is $45.00 and at
-- the stored one $45.04, and the error grows with every hour worked.
--
-- Two decimals is right for an amount — you cannot pay a fraction of a cent —
-- and wrong for a rate, which is a multiplier. Four decimals now, which covers
-- the eighths and sixteenths of a dollar that hourly rates are actually
-- negotiated in.
--
-- The amount is still rounded to cents where it is computed, which is the
-- correct place to round: once, at the end, on the money.
--
-- Caught by the owner reading a rate back off the screen and not recognising
-- it. Nothing had used the rate yet, so no statement or payment needed
-- restating.
-- ─────────────────────────────────────────────────────────────

alter table public.staff_pay
  alter column pay_rate type numeric(12,4);

comment on column public.staff_pay.pay_rate is
  'A rate, not an amount. Four decimals, because 5.625 an hour is a real rate and 5.63 is not it.';

/**
 * Recording a rate, refusing to round it.
 *
 * Restated from 0026 with one addition: a figure carrying more precision than
 * the column keeps is rejected rather than quietly rounded. Silent rounding is
 * what put 5.63 on somebody's record when 5.625 was agreed, and a rule that
 * only makes it less likely is not the same as one that makes it impossible.
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
  if p_rate <> round(p_rate, 4) then
    raise exception 'A rate is kept to four decimal places. % would be rounded to %, which is a different rate.',
      p_rate, round(p_rate, 4) using errcode = 'check_violation';
  end if;
  if p_unit not in ('Hourly', 'Flat') then
    raise exception 'A rate is Hourly or Flat.' using errcode = 'check_violation';
  end if;
  if p_effective_from is null then
    raise exception 'A rate needs a date it takes effect from.' using errcode = 'check_violation';
  end if;

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

revoke execute on function public.set_staff_pay(uuid, numeric, text, date, text) from public;
grant execute on function public.set_staff_pay(uuid, numeric, text, date, text) to authenticated;
