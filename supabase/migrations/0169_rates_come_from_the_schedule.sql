-- Zion Vocational Rehab CRM — the rate comes from the rate schedule
-- (Billing Simplification Brief §§11, 13.13)
--
-- §13.13: "Rates come from the rate schedule by service; the authorization
-- shows the rate but asks for it only when the PDF says something different."
--
-- There were two rate schedules. One is this table, eighteen rows from the Voc
-- Rehab Workbook, which Admin can see and edit. The other was SERVICE_DEFAULTS
-- in lib/constants.ts - a hard-coded copy, in the names the CRM uses rather
-- than the workbook's, and it is the one the Add authorization form actually
-- filled in. The duplication audit could not see it, because one of the two
-- copies was TypeScript.
--
-- They disagreed, and it mattered. The code said Job Development + HQ Indicator
-- was 560. The practice has billed it twelve times at 1,120 - which is what the
-- schedule says it is: Job Development at 560 plus one High Quality Indicator at
-- 560. So the form has been offering half the rate for the second busiest
-- service in the practice, and the only reason it has not gone out short
-- twelve times is that whoever entered it knew better and typed over it. That
-- is the "4.50 instead of 45.00" the form warns about, in the form's own
-- default.
--
-- The schedule wins, because it is the document USOR and the practice agree on
-- and Admin can change it without a deploy. What this migration does is give
-- each schedule row the CRM service it prices, add the one row the workbook
-- expresses as a sum, and provide the function the form reads. The TypeScript
-- copy goes in the same commit.
--
-- Every rate below is the schedule's own figure, and every one is confirmed by
-- what the practice has actually authorized. Nothing is invented here.

alter table public.rate_schedule
  add column if not exists crm_service text;

comment on column public.rate_schedule.crm_service is
  'The service a CRM authorization carries, for the rows that price one (§13.13). The workbook''s own service names stay in `service`; this is the name the practice picks on screen.';

-- The workbook's names, mapped to the CRM's. Each of these is one-to-one and
-- the fee is the schedule's.
update public.rate_schedule set crm_service = 'Job Coaching'
 where service = 'Job Coaching' and sub = 'All';
update public.rate_schedule set crm_service = 'Job Development'
 where service = 'Job Development' and sub = 'SJBT / SE';
update public.rate_schedule set crm_service = 'Job Placement'
 where service = 'Placement' and sub = 'SBT';
update public.rate_schedule set crm_service = 'Job Placement (SE)'
 where service = 'Placement' and sub = 'SE';
update public.rate_schedule set crm_service = 'WSA Tier 1'
 where service = 'Work Strategy Assessment' and sub = 'Tier 1';
update public.rate_schedule set crm_service = 'WSA Tier 2'
 where service = 'Work Strategy Assessment' and sub like 'Tier 2%';
update public.rate_schedule set crm_service = 'Life Skills'
 where service like 'Life Skills%' and sub = 'Individual';
update public.rate_schedule set crm_service = 'CRP Group Training'
 where service like 'CRP Group Training%';
update public.rate_schedule set crm_service = 'Temporary Work Experience'
 where service = 'Temporary Work Experience' and sub = 'Placement';

-- Every High Quality Indicator is the same fee; which indicator was met is a
-- fact about the placement, not about the price. All seven price the one
-- service, so a rate read from them cannot depend on which row is picked.
update public.rate_schedule set crm_service = 'HQ Indicator'
 where service = 'High Quality Indicator';

-- The one the workbook expresses as a sum rather than a row. 1,120 is what the
-- practice has billed it at twelve times, and 560 + 560 is why.
insert into public.rate_schedule (funding_source, service, sub, fee, unit, crm_service)
select 'Utah VR', 'Job Development + High Quality Indicator',
       'Development fee and one indicator', 1120.00, 'flat',
       'Job Development + HQ Indicator'
 where not exists (
   select 1 from public.rate_schedule where crm_service = 'Job Development + HQ Indicator');

grant select (crm_service) on public.rate_schedule to authenticated;

/**
 * What a service costs, and the unit it is charged in.
 *
 * One place, read by the form that enters an authorization and by anything else
 * that needs it. A service the schedule does not price returns nothing, and the
 * form asks - which is right: "Other" has no rate, and inventing one would be
 * worse than asking.
 *
 * Every row that prices a service carries the same fee and unit, so max() is a
 * figure and not a guess.
 */
create or replace function public.service_rate(p_service text)
returns table (fee numeric, rate_type text, basis text)
language sql stable security definer set search_path = public as $$
  select max(r.fee),
         case when max(r.unit) = 'per hour' then 'Hourly' else 'Flat Fee' end,
         'The rate schedule: ' || max(r.service)
           || case when count(*) > 1 then format(' (%s rows, all %s)', count(*), max(r.fee))
                   else coalesce(', ' || max(r.sub), '') end
    from public.rate_schedule r
   where r.crm_service = p_service
     and (r.effective_from is null or r.effective_from <= public.practice_today())
     and (r.effective_to is null or r.effective_to >= public.practice_today())
  having count(*) > 0;
$$;

comment on function public.service_rate is
  'What the rate schedule says a service costs (§13.13). The one place a rate comes from; a service it does not price returns nothing so the form asks rather than guessing.';

revoke all on function public.service_rate(text) from anon, authenticated;
grant execute on function public.service_rate(text) to authenticated;
