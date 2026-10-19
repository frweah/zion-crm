-- Zion Vocational Rehab CRM — the baseline measures the work, not only the money
-- (owner, 18 Oct 2026)
--
-- 0219 froze what the practice had authorized, billed and been paid. The
-- money is half the picture: how long things take, how many people got jobs
-- and whether they kept them is what the practice is actually for, and it is
-- the half a funder asks about.
--
-- Two of these read empty today, and that is the finding rather than a fault
-- in the measure:
--
--   **No authorization on file has a submitted date.** 162 of them, none
--   with submitted_on, so neither median can be computed. The dates are set
--   when the status moves through the app; the records that are on file were
--   imported with their status already set. Both medians store null and the
--   screen says "not known yet" rather than showing a zero that would read
--   as "same day".
--
--   **No placement has a 30, 60 or 90-day check recorded.** 30 placements,
--   none checked. So retention is unknown rather than nil, and the two
--   figures are kept as a pair - how many were retained, out of how many we
--   could possibly know about - because a retention rate with no denominator
--   is a number that can be read any way somebody likes.
--
-- What "retained" means here, exactly, because it is a proxy and should not
-- be quoted as more than it is: a placement that has a check recorded at
-- that point. The table holds the date each check happened and no outcome
-- beside it, so the presence of the check is the best the record supports.
-- If an outcome is ever recorded, this is the line to change.

alter table public.money_baselines
  -- Median days from receiving an authorization to submitting it, and from
  -- submitting it to being paid. Null when there is nothing to measure.
  add column if not exists days_to_submit numeric(8,1),
  add column if not exists days_to_pay    numeric(8,1),
  -- Placements that started in the year the baseline covers.
  add column if not exists placements     integer not null default 0,
  -- Retention, as a pair: retained of those we could know about.
  add column if not exists retained_4w    integer not null default 0,
  add column if not exists known_4w       integer not null default 0,
  add column if not exists retained_90d   integer not null default 0,
  add column if not exists known_90d      integer not null default 0,
  -- Clients by stage, as {"Referral": 24, "Closed": 26, ...}. A map rather
  -- than columns because the stages are the practice's to change.
  add column if not exists by_stage       jsonb not null default '{}'::jsonb;

comment on column public.money_baselines.retained_4w is
  'Placements with a 30-day check recorded, out of known_4w that were old enough to have one (0220). The check''s presence is a proxy: the table records when it happened and no outcome beside it.';

create or replace function public.take_money_baseline(p_as_of date, p_label text default '')
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_id    uuid;
  v_start date;
begin
  if not public.is_admin() then
    raise exception 'The practice''s baseline is Admin''s to take.'
      using errcode = 'insufficient_privilege';
  end if;
  if p_as_of is null then
    raise exception 'As at which day?' using errcode = 'check_violation';
  end if;
  if p_as_of > public.practice_today() then
    raise exception 'That day has not happened yet.' using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.money_baselines where as_of = p_as_of) then
    raise exception 'There is already a baseline for %. A baseline is taken once.', p_as_of
      using errcode = 'unique_violation';
  end if;

  v_start := date_trunc('year', p_as_of)::date;

  insert into public.money_baselines (
    as_of, label, authorized, earned, invoiced, received, outstanding, unbilled,
    clients, authorizations, documents, hours, taken_by,
    days_to_submit, days_to_pay, placements,
    retained_4w, known_4w, retained_90d, known_90d, by_stage
  )
  select
    p_as_of,
    coalesce(nullif(btrim(p_label), ''), to_char(p_as_of, 'YYYY') || ' baseline'),
    coalesce(sum(e.authorized), 0),
    coalesce(sum(e.earned), 0),
    coalesce(sum(e.invoiced), 0),
    coalesce(sum(e.received), 0),
    coalesce(sum(e.outstanding), 0),
    coalesce(sum(e.unbilled), 0),
    (select count(*) from public.clients),
    (select count(*) from public.authorizations),
    (select count(*) from public.attachments),
    (select coalesce(sum(se.hours), 0) from public.service_entries se where se.date <= p_as_of),
    public.current_staff_id(),

    -- How long the practice takes, in days.
    (select percentile_cont(0.5) within group (order by (a2.submitted_on - a2.received_on))
       from public.authorizations a2
      where a2.received_on is not null and a2.submitted_on is not null
        and a2.submitted_on <= p_as_of and a2.submitted_on >= a2.received_on),
    (select percentile_cont(0.5) within group (order by (a3.paid_on - a3.submitted_on))
       from public.authorizations a3
      where a3.submitted_on is not null and a3.paid_on is not null
        and a3.paid_on <= p_as_of and a3.paid_on >= a3.submitted_on),

    -- Jobs started in the year this baseline covers.
    (select count(*) from public.placements p
      where p.start_date between v_start and p_as_of),

    -- Retention, as a pair. The denominator is placements old enough by the
    -- baseline's date to have been checked at all.
    (select count(*) from public.placements p
      where p.start_date between v_start and p_as_of
        and p.start_date <= p_as_of - 28 and p.check30 is not null),
    (select count(*) from public.placements p
      where p.start_date between v_start and p_as_of
        and p.start_date <= p_as_of - 28),
    (select count(*) from public.placements p
      where p.start_date between v_start and p_as_of
        and p.start_date <= p_as_of - 90 and p.check90 is not null),
    (select count(*) from public.placements p
      where p.start_date between v_start and p_as_of
        and p.start_date <= p_as_of - 90),

    -- Where everybody stood, by stage.
    coalesce((select jsonb_object_agg(s.stage, s.n)
                from (select coalesce(nullif(c.stage, ''), 'Not set') as stage, count(*) as n
                        from public.clients c group by 1) s), '{}'::jsonb)

  from public.authorization_economics e
  join public.authorizations a on a.id = e.auth_id
  where a.received_on is null or a.received_on <= p_as_of
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.take_money_baseline(date, text) from anon, authenticated;
grant execute on function public.take_money_baseline(date, text) to authenticated;

do $$
declare
  v_subs integer;
  v_checked integer;
begin
  select count(*) into v_subs from public.authorizations where submitted_on is not null;
  select count(*) into v_checked from public.placements where check30 is not null or check90 is not null;
  raise notice 'ok  the baseline measures the work too';
  if v_subs = 0 then
    raise notice '--  no authorization has a submitted date, so both medians will be empty';
  end if;
  if v_checked = 0 then
    raise notice '--  no placement has a 30 or 90-day check, so retention will be unknown';
  end if;
end $$;
