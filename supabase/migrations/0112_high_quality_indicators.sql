-- Zion Vocational Rehab CRM — the High Quality Indicators, totalled
--
-- From the fee schedule on page two of the CRP billing pathway (owner,
-- 20 Sept 2026). Six indicators, each worth the same again, claimed against
-- the HQI authorization the counselor raises at stability:
--
--   Hours      SJBT 30 hours a week or more; SE 20 or more
--   Wages      SJBT $14/hr or more; SE $10/hr or more
--   Benefits   the employer pays health benefits
--   Days       60 days or less from the job development authorization to the
--              employment start date
--   STEM       the occupation is listed as STEM on O*NET
--   Rural      the client lives in a rural area
--
-- Three of the six the CRM can already answer from what it holds - the hours
-- and the wage are on the placement, and the days are the distance between
-- the job development authorization and the first day of work. Three it
-- cannot: whether the employer pays health benefits, whether O*NET lists the
-- occupation as STEM, and whether the client lives rurally. Those are added
-- here as answers somebody gives, not as anything inferred.
--
-- The distinction is the point. An indicator nobody has answered is reported
-- as unknown, never as false: the difference between "we checked and it does
-- not qualify" and "nobody has looked" is $560, and a total that quietly
-- treats the second as the first is a total that loses money.
--
-- Hours and wages both depend on which stability rule applies, and the two
-- have different thresholds. Until somebody records SJBT or SE, neither can
-- be answered, and both say so.

alter table public.placements
  add column if not exists employer_benefits boolean,
  add column if not exists stem_occupation boolean,
  -- About where the client lives rather than about the job, but recorded
  -- against the placement: it is the answer as it stood when this claim was
  -- made, and a client who moves does not rewrite a claim already sent.
  add column if not exists rural_client boolean;

comment on column public.placements.employer_benefits is
  'High Quality Indicator: the employer pays health benefits. Null means nobody has answered.';
comment on column public.placements.stem_occupation is
  'High Quality Indicator: O*NET lists the occupation as STEM. Null means nobody has answered.';
comment on column public.placements.rural_client is
  'High Quality Indicator: the client lives in a rural area. Null means nobody has answered.';

/**
 * The six indicators for one placement, and what each is worth.
 *
 * `met` is three-valued on purpose: true, false, or null for "nobody has
 * answered". Only the true ones are counted.
 */
create or replace function public.hqi_for_placement(p_placement uuid)
returns table (key text, label text, met boolean, detail text, amount numeric)
language sql stable security definer set search_path = public as $$
  with p as (
    select pl.*,
           nullif(pl.stability_basis, '') as basis
      from public.placements pl
     where pl.id = p_placement
  ),
  -- The job development authorization this placement followed, for the
  -- sixty-day test. The earliest one: development starts once.
  dev as (
    select min(a.start_date) as started
      from public.authorizations a
      join p on p.client_id = a.client_id
     where a.service_type like 'Job Development%'
  )
  select 'hours', 'Hours',
         case when p.basis is null or p.hours_week is null then null
              when p.basis = 'SJBT' then p.hours_week >= 30
              else p.hours_week >= 20 end,
         case when p.basis is null then 'Which stability rule applies has not been recorded'
              when p.hours_week is null then 'No hours a week on the placement'
              else p.hours_week || ' hrs/wk · ' || p.basis || ' asks for '
                   || (case when p.basis = 'SJBT' then '30' else '20' end) end,
         560
    from p

  union all
  select 'wages', 'Wages',
         case when p.basis is null or p.wage is null then null
              when p.basis = 'SJBT' then p.wage >= 14
              else p.wage >= 10 end,
         case when p.basis is null then 'Which stability rule applies has not been recorded'
              when p.wage is null then 'No wage on the placement'
              else '$' || trim(to_char(p.wage, 'FM999990.00')) || '/hr · ' || p.basis || ' asks for $'
                   || (case when p.basis = 'SJBT' then '14' else '10' end) end,
         560
    from p

  union all
  select 'benefits', 'Benefits', p.employer_benefits,
         case when p.employer_benefits is null then 'Nobody has answered whether the employer pays health benefits'
              when p.employer_benefits then 'The employer pays health benefits'
              else 'The employer does not pay health benefits' end,
         560
    from p

  union all
  select 'days', 'Days to placement',
         case when d.started is null or p.start_date is null then null
              else p.start_date - d.started <= 60 end,
         case when d.started is null then 'No job development authorization to measure from'
              when p.start_date is null then 'No start date on the placement'
              else (p.start_date - d.started) || ' days from the development authorization · 60 or fewer qualifies' end,
         560
    from p cross join dev d

  union all
  select 'stem', 'STEM', p.stem_occupation,
         case when p.stem_occupation is null then 'Nobody has answered whether O*NET lists this as STEM'
              when p.stem_occupation then 'O*NET lists the occupation as STEM'
              else 'O*NET does not list the occupation as STEM' end,
         560
    from p

  union all
  select 'rural', 'Rural', p.rural_client,
         case when p.rural_client is null then 'Nobody has answered whether the client lives rurally'
              when p.rural_client then 'The client lives in a rural area'
              else 'The client does not live in a rural area' end,
         560
    from p;
$$;

/**
 * What the indicators come to for a placement.
 *
 * `unanswered` is returned alongside the total because it is the number that
 * matters before a claim goes: a total of $1,120 with three unanswered is not
 * a claim for $1,120, it is a claim nobody has finished working out.
 */
create or replace function public.hqi_total(p_placement uuid)
returns table (met integer, unanswered integer, total numeric)
language sql stable security definer set search_path = public as $$
  select count(*) filter (where i.met)::integer,
         count(*) filter (where i.met is null)::integer,
         coalesce(sum(i.amount) filter (where i.met), 0)
    from public.hqi_for_placement(p_placement) i;
$$;

revoke execute on function public.hqi_for_placement(uuid) from public, anon;
revoke execute on function public.hqi_total(uuid) from public, anon;
grant execute on function public.hqi_for_placement(uuid) to authenticated;
grant execute on function public.hqi_total(uuid) to authenticated;
