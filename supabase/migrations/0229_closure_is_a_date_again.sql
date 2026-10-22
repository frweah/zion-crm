-- Zion Vocational Rehab CRM — 0229 closure is a date again
--
-- 0223 took 'Closed' out of the stages, and broke the retention schedule
-- doing it. `client_retention` worked out when a client's file was closed by
-- looking for the most recent stage-history row saying 'Closed'. No such row
-- can be written any more, so `closed_on` is null for everybody, `due` is
-- false for everybody, and nothing can ever come up for disposal.
--
-- That is mine, and it is the kind of break that would not have announced
-- itself: nothing errors, a list is simply empty for ever. The verification
-- suite caught it, which is the whole argument for having one.
--
-- Closure is a status now, so the date belongs on the client. `closed_at` is
-- stamped by a trigger the moment the status becomes Closed, and cleared if
-- they are reopened - which is the same event the retention clock has always
-- started from, recorded where it can still be found.
--
-- **What could not be recovered, and what that means.** The stage-history
-- rows saying 'Closed' were overwritten by 0223's remap. Of the 25 closed
-- clients, 22 never had such a row at all - their file holds one stage entry,
-- the day they arrived - so nothing was lost for them and their closure date
-- was already unknown. For the other three the row existed and now reads
-- 'Intake'; their closure dates are gone and are not guessed at here.
--
-- A client whose closure date is unknown is never due for disposal. That is
-- the safe direction: a record kept too long is a filing problem, and a
-- record destroyed too early is not recoverable. Setting the date for those
-- three is a decision for the owner, from the paper file.

alter table public.clients add column if not exists closed_at date;

comment on column public.clients.closed_at is
  'The day the file was closed, which starts the retention clock (0229). Null when it is not known - and an unknown date is never due for disposal.';

/**
 * The status is the event; the date is the record of it.
 *
 * Only Closed starts the clock. Inactive (0222) is a file nobody is working,
 * not a file that has ended, and the retention policy is about the latter.
 */
create or replace function public.stamp_closed_at()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'Closed' and coalesce(old.status, '') <> 'Closed' then
    new.closed_at := coalesce(new.closed_at, public.practice_today());
  elsif new.status <> 'Closed' and coalesce(old.status, '') = 'Closed' then
    new.closed_at := null;
  end if;
  return new;
end;
$$;

drop trigger if exists clients_closed_at on public.clients;
create trigger clients_closed_at
  before insert or update of status on public.clients
  for each row execute function public.stamp_closed_at();

-- What survives of the old evidence: a stage-history row still saying
-- 'Closed' is one the remap did not reach. There are none, but the backfill
-- is written anyway so that running this on a database restored from before
-- 0223 does the right thing.
update public.clients c
   set closed_at = h.at
  from (
    select sh.client_id, max(sh.at) as at
      from public.client_stage_history sh
     where sh.stage = 'Closed'
     group by sh.client_id
  ) h
 where c.id = h.client_id and c.status = 'Closed' and c.closed_at is null;

/**
 * The retention view, reading the date from where it now lives.
 *
 * The old rule is kept as a fallback rather than deleted: on a database that
 * still holds 'Closed' stage rows - a restore from before 0223 - it is the
 * better answer, and on this one it finds nothing and costs nothing.
 */
create or replace view public.client_retention as
  with closed as (
    select c.id, c.name, c.client_no, c.status, c.stage,
           coalesce(
             c.closed_at,
             (select max(h.at) from public.client_stage_history h
               where h.client_id = c.id and h.stage = 'Closed')
           ) as closed_on
      from public.clients c
     where c.status = 'Closed'
  ),
  policy as (
    select keep_years, confirmed from public.retention_policies
     where key = 'client-record' and active
  )
  select cl.id as client_id, cl.name, cl.client_no, cl.status, cl.stage, cl.closed_on,
         (select keep_years from policy) as keep_years,
         (select confirmed from policy) as policy_confirmed,
         case when cl.closed_on is not null
              then (cl.closed_on + ((select keep_years from policy) * 12)::int * interval '1 month')::date
         end as keep_until,
         h.id as hold_id,
         h.reason as hold_reason,
         h.id is not null as on_hold,
         cl.closed_on is not null
           and (select confirmed from policy)
           and h.id is null
           and (cl.closed_on + ((select keep_years from policy) * 12)::int * interval '1 month')::date
               <= public.practice_today() as due,
         d.disposed_at,
         d.action as disposed_action
    from closed cl
    left join lateral (
      select id, reason from public.legal_holds
       where client_id = cl.id and lifted_at is null
       order by placed_at desc limit 1
    ) h on true
    left join lateral (
      select disposed_at, action from public.retention_dispositions
       where client_id = cl.id order by disposed_at desc limit 1
    ) d on true;

alter view public.client_retention set (security_invoker = true);
grant select on public.client_retention to authenticated;

comment on view public.client_retention is
  'Every closed client, when their file closed, when it may be destroyed, and whether a legal hold stops that (0229). A file whose closure date is unknown is never due.';

-- Only a transition stamps the date.
--
-- The first version fired on INSERT as well, which meant a client imported
-- with status Closed was recorded as having closed the day they were
-- imported. That is a worse answer than no answer: an invented closure date
-- starts a real retention clock. A row that arrives already closed brings its
-- own date or has none, and the verification suite says so in as many words.
drop trigger if exists clients_closed_at on public.clients;
create trigger clients_closed_at
  before update of status on public.clients
  for each row execute function public.stamp_closed_at();
