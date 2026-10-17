-- Zion Vocational Rehab CRM — the working list stops re-reading every hour
-- (stress test, finding 3, owner 16 Oct 2026)
--
-- billing_worklist called two functions once per authorization, and both of
-- them read service_entries:
--
--   authorization_amount(a.id)   - a correlated sum of that row's hours.
--   authorization_attention(a.id) - another sum, this one joined across the
--   coaching family through an OR, which is the shape that stops an index
--   being used; plus two scalar reads of org_settings, per row.
--
-- At the practice's current size that is 162 authorizations and nobody
-- notices. At ten times the size it is roughly 1,500 live rows each touching
-- a 20,000-row table twice, and the list runs in three places: Billing, the
-- Home tile for Admin and Billing, and - worst - every client record's
-- billing tab, which asked for the whole list and then threw away every row
-- belonging to somebody else.
--
-- The fix is the shape client_next_actions_for already established: compute
-- it for a set in one pass, and leave the single-row function in place as a
-- wrapper over the set-wise one, so there is still one definition of each
-- rule and the authorization record and the list cannot disagree.
--
-- And billing_worklist takes a client, so the client record asks for its own
-- rows instead of filtering the practice's.
--
-- One deliberate correction carried in here: the old attention query read
-- carried hours as coalesce(parent.carried_used, own.carried_used, 0), while
-- check_entry_hours (0171) and authorization_hours_used (0205) read them
-- from the root alone. A coaching month carries no hours of its own (§5), so
-- the root is the right answer and this now matches what the database
-- actually enforces.

-- ─────────────────────────────────────────────────────────────
-- What an authorization comes to, for a set of them
--
-- Per authorization and its own entries, which is not how the cap is counted:
-- a coaching month bills the hours logged on that month, while the cap is the
-- whole family's. The two are different questions and stay different.
-- ─────────────────────────────────────────────────────────────
create or replace function public.authorization_amount_for(p_auths uuid[])
returns table (auth_id uuid, amount numeric)
language sql stable set search_path = public as $$
  with hours as (
    select e.auth_id, sum(e.hours) as hours
      from public.service_entries e
     where e.auth_id = any(p_auths)
       and e.non_billable = false
     group by e.auth_id
  )
  select a.id,
         case when a.rate_type = 'Flat Fee' then round(coalesce(a.rate, 0), 2)
              else round(coalesce(h.hours, 0) * coalesce(a.rate, 0), 2)
         end
    from public.authorizations a
    left join hours h on h.auth_id = a.id
   where a.id = any(p_auths);
$$;

comment on function public.authorization_amount_for(uuid[]) is
  'What each authorization comes to, for a whole set in one pass (0206). authorization_amount is the one-row wrapper over it.';

revoke all on function public.authorization_amount_for(uuid[]) from anon, authenticated;
grant execute on function public.authorization_amount_for(uuid[]) to authenticated;

create or replace function public.authorization_amount(p_auth uuid)
returns numeric language sql stable set search_path = public as $$
  select amount from public.authorization_amount_for(array[p_auth]);
$$;

revoke all on function public.authorization_amount(uuid) from anon, authenticated;
grant execute on function public.authorization_amount(uuid) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- What each authorization needs, for a set of them
--
-- The rules, the wording and the order of precedence are 0170's, unchanged.
-- What changed is that they are worked out once for the whole set: the hours
-- come from authorization_hours_used (0205), and the two org_settings values
-- are read once rather than once per row.
-- ─────────────────────────────────────────────────────────────
create or replace function public.authorization_attention_for(
  p_auths uuid[],
  p_today date default null
)
returns table (auth_id uuid, attention text, urgency integer)
language sql stable security definer set search_path = public as $$
  with me as (select coalesce(p_today, public.practice_today()) as today),
  settings as (
    select stale_grace_days, stale_soon_days from public.org_settings where id
  ),
  r as (
    select a.id,
           a.status, a.bill_by, a.stale_date, a.submitted_on, a.followup_due,
           coalesce(p.total_hours, a.total_hours) as authorized,
           u.used,
           public.authorization_blocked_from(a.stale_date) is not null
             and public.authorization_blocked_from(a.stale_date) < (select today from me)
             and a.status not in ('Submitted', 'Paid') as is_blocked,
           a.stale_date is not null and a.stale_date < (select today from me)
             and (public.authorization_blocked_from(a.stale_date) is null
                  or public.authorization_blocked_from(a.stale_date) >= (select today from me))
             and a.status not in ('Submitted', 'Paid') as is_expired,
           a.stale_date is null and a.status not in ('Submitted', 'Paid') as no_end_date,
           a.bill_by is not null and a.bill_by < (select today from me)
             and a.status in ('Authorized', 'Due') as is_overdue,
           a.status = 'Submitted'
             and ((a.followup_due is not null and a.followup_due <= (select today from me))
                  or (a.submitted_on is not null
                      and (select today from me) - a.submitted_on >= 14)) as needs_chasing,
           a.stale_date is not null and a.status not in ('Submitted', 'Paid')
             and a.stale_date >= (select today from me)
             and a.stale_date <= (select today from me) + (select stale_soon_days from settings)
             as stale_soon
      from public.authorizations a
      left join public.authorizations p on p.id = a.parent_id
      left join public.authorization_hours_used(p_auths) u on u.auth_id = a.id
     where a.id = any(p_auths)
  ),
  h as (
    select r.*,
           r.authorized is not null and r.authorized - r.used <= 0
             and r.status not in ('Paid', 'Closed') as out_of_hours,
           r.authorized is not null and r.authorized - r.used > 0
             and r.authorized - r.used <= r.authorized * 0.1
             and r.status not in ('Paid', 'Closed') as hours_low
      from r
  )
  select h.id,
         case
           when h.is_blocked then 'Cannot be submitted - ended ' || h.stale_date
                                  || ', more than ' || (select stale_grace_days from settings)
                                  || ' days ago'
           when h.out_of_hours then 'No hours left - request more before any further service'
           when h.needs_chasing then 'Submitted ' || h.submitted_on || ', no payment after 14 days'
           when h.is_overdue then 'Overdue - meant to be billed by ' || h.bill_by
           when h.hours_low then 'Under a tenth of the hours left ('
                                  || public.fmt_hours(h.authorized - h.used) || ' of '
                                  || public.fmt_hours(h.authorized) || ')'
           when h.is_expired then 'Past its end date (' || h.stale_date || ') - can still be submitted until '
                                  || public.authorization_blocked_from(h.stale_date)
           when h.stale_soon then 'Ends ' || h.stale_date
           when h.no_end_date then 'No end date on the authorization'
           when h.status = 'Due' then 'Due to be billed'
           else ''
         end,
         case
           when h.is_blocked then 0
           when h.out_of_hours then 1
           when h.needs_chasing then 2
           when h.is_overdue then 3
           when h.hours_low then 4
           when h.is_expired then 5
           when h.stale_soon then 6
           when h.no_end_date then 7
           when h.status = 'Due' then 8
           else 9
         end
    from h;
$$;

comment on function public.authorization_attention_for(uuid[], date) is
  'What each authorization needs, for a whole set in one pass (0206). The rules are 0170''s; authorization_attention is the one-row wrapper over it.';

revoke all on function public.authorization_attention_for(uuid[], date) from anon, authenticated;
grant execute on function public.authorization_attention_for(uuid[], date) to authenticated;

create or replace function public.authorization_attention(p_auth uuid, p_today date default null)
returns table (attention text, urgency integer)
language sql stable security definer set search_path = public as $$
  select f.attention, f.urgency
    from public.authorization_attention_for(array[p_auth], p_today) f;
$$;

revoke all on function public.authorization_attention(uuid, date) from anon, authenticated;
grant execute on function public.authorization_attention(uuid, date) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- The working list, for the practice or for one client
-- ─────────────────────────────────────────────────────────────
drop function if exists public.billing_worklist(date);

create or replace function public.billing_worklist(
  p_today  date default null,
  p_client uuid default null
)
returns table (id uuid, client_id uuid, client_name text, number text, service_type text,
               period date, status text, bill_by date, stale_date date, submitted_on date,
               followup_due date, amount numeric, parent_id uuid, attention text, urgency integer)
language sql stable set search_path = public as $$
  with live as (
    select a.id, a.client_id, c.name as client_name,
           coalesce(nullif(a.number, ''), p.number, '') as number,
           a.service_type, a.period, a.status, a.bill_by, a.stale_date,
           a.submitted_on, a.followup_due, a.parent_id
      from public.authorizations a
      join public.clients c on c.id = a.client_id
      left join public.authorizations p on p.id = a.parent_id
     where a.status not in ('Paid', 'Closed')
       -- A coaching parent is not a bill; its months are.
       and a.id not in (select parent_id from public.authorizations where parent_id is not null)
       -- A kept placeholder is history, not work (§9).
       and not a.is_placeholder
       -- And nothing belonging to a client the practice has closed.
       and c.status <> 'Closed'
       -- One client's rows, when one client is asked for.
       and (p_client is null or a.client_id = p_client)
  ),
  ids as (select array(select id from live) as all_ids),
  amt as (
    select * from public.authorization_amount_for((select all_ids from ids))
  ),
  att as (
    select * from public.authorization_attention_for((select all_ids from ids), p_today)
  )
  select live.id, live.client_id, live.client_name, live.number, live.service_type,
         live.period, live.status, live.bill_by, live.stale_date, live.submitted_on,
         live.followup_due, amt.amount, live.parent_id, att.attention, att.urgency
    from live
    left join amt on amt.auth_id = live.id
    left join att on att.auth_id = live.id
   order by att.urgency, live.bill_by nulls last, live.client_name;
$$;

comment on function public.billing_worklist(date, uuid) is
  'Every authorization waiting to be billed, chased or paid - for the practice, or for one client when p_client is given (0206). The hours behind it are counted once for the whole list rather than once per row.';

revoke all on function public.billing_worklist(date, uuid) from anon, authenticated;
grant execute on function public.billing_worklist(date, uuid) to authenticated;

-- The count behind Home's tile. Same function, so the tile and the list
-- cannot disagree - that was 0177's point and it still holds.
create or replace function public.billing_needs_action(p_today date default null)
returns integer language sql stable security definer set search_path = public as $$
  select count(*)::int from public.billing_worklist(p_today) w where coalesce(w.attention, '') <> '';
$$;

revoke all on function public.billing_needs_action(date) from anon, authenticated;
grant execute on function public.billing_needs_action(date) to authenticated;

do $$
declare
  v_all integer;
  v_one integer;
  v_client uuid;
begin
  select count(*) into v_all from public.billing_worklist();
  select client_id into v_client from public.billing_worklist() limit 1;
  if v_client is null then
    raise notice 'ok  the working list is empty; both shapes are in place';
  else
    select count(*) into v_one from public.billing_worklist(null, v_client);
    raise notice 'ok  the working list reads % rows, and % for one client', v_all, v_one;
  end if;
end $$;
