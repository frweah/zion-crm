-- ─────────────────────────────────────────────────────────────
-- 0046 — where each client is, and how long they have been there
--
-- The clients list says what stage somebody is in. It cannot say how long
-- they have been in it, which is the only part that tells you anything: 24
-- people sitting at Referral is either a good week or a year of neglect, and
-- the difference is a date nobody was storing anywhere readable.
--
-- Days in stage counts from the last time the client entered the stage they
-- are in now — not from when the record was created, and not from the first
-- time they touched that stage. Somebody who went Referral → Intake and back
-- to Referral has been at Referral since they came back.
-- ─────────────────────────────────────────────────────────────
create or replace view public.client_pipeline as
select c.id                          as client_id,
       c.name,
       c.status,
       c.stage,
       c.counselor_id,
       c.referring_office,
       c.assigned_staff_id,
       c.created_at                  as referred_at,
       h.stage_since,
       greatest(
         public.practice_today()
           - coalesce(h.stage_since::date, c.created_at::date), 0)            as days_in_stage,

       a.auth_count,
       a.first_auth_on,
       p.first_placement_on,

       -- A referral with no authorization is not yet work: USOR has sent
       -- somebody, and nothing has been agreed to be paid for.
       (a.auth_count = 0)                                                     as no_authorization
  from public.clients c

  left join lateral (
    select max(sh.at) as stage_since
      from public.client_stage_history sh
     where sh.client_id = c.id
       and sh.stage = c.stage
  ) h on true

  left join lateral (
    select count(*)          as auth_count,
           min(au.start_date) as first_auth_on
      from public.authorizations au
     where au.client_id = c.id
  ) a on true

  left join lateral (
    select min(pl.start_date) as first_placement_on
      from public.placements pl
     where pl.client_id = c.id
  ) p on true;

alter view public.client_pipeline set (security_invoker = true);
grant select on public.client_pipeline to authenticated;

comment on view public.client_pipeline is
  'Each client with the stage they are in, how many days they have been in it, when their first authorization and first placement were, and whether anything has been authorized at all.';

-- ─────────────────────────────────────────────────────────────
-- Which stages a client has ever reached
--
-- Conversion is a question about history, and the workbook migration gave
-- every client exactly one stage row — where they stood on the day of the
-- import. Reading only that history would say nobody has ever converted.
--
-- So a stage counts as reached if it is in the history OR if the client is
-- standing further along than it: somebody at Job Coaching has been through
-- Job Development, whatever the record remembers. Closed carries no position,
-- so a closed client is credited only with what the history actually holds.
-- ─────────────────────────────────────────────────────────────
create or replace function public.stage_rank(p_stage text)
returns int language sql immutable as $$
  select case p_stage
    when 'Referral'        then 1
    when 'Intake'          then 2
    when 'Assessment'      then 3
    when 'Job Development' then 4
    when 'Placement'       then 5
    when 'Job Coaching'    then 6
    when 'Follow-Along'    then 7
    else null
  end;
$$;

create or replace view public.client_stages_reached as
select c.id as client_id, s.stage
  from public.clients c
  cross join lateral (
    select unnest(array['Referral', 'Intake', 'Assessment', 'Job Development',
                        'Placement', 'Job Coaching', 'Follow-Along']) as stage
  ) s
 where exists (
         select 1 from public.client_stage_history sh
          where sh.client_id = c.id and sh.stage = s.stage
       )
    or (public.stage_rank(c.stage) is not null
        and public.stage_rank(c.stage) >= public.stage_rank(s.stage));

alter view public.client_stages_reached set (security_invoker = true);
grant select on public.client_stages_reached to authenticated;

comment on view public.client_stages_reached is
  'One row per client per stage they have reached — from the stage history, plus every stage behind the one they are standing in.';
