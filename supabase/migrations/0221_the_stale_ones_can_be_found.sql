-- Zion Vocational Rehab CRM — 0221 the stale ones can be found
--
-- Billing → Authorizations gets a Stale filter, and it needed a fact rather
-- than a sentence to filter on (owner, 19 Oct 2026).
--
-- The working list already knows which rows are past saving: the attention
-- line says "Cannot be submitted - ended <date>, more than <n> days ago".
-- The screen could have matched that wording, and that is exactly the kind of
-- thing that breaks silently the next time somebody rewrites the copy - which
-- this practice did to 131 sentences yesterday. §11: a fact lives in one
-- place. So `is_blocked`, which the attention line is already computed from,
-- comes out as a column of its own and the screen filters on that.
--
-- Nothing else changes. The rule itself - stale_date plus the grace, and not
-- already Submitted or Paid - is untouched, and so is every word of the
-- attention line and every urgency number. This migration only stops the
-- answer being thrown away.
--
-- The two that change are dropped rather than replaced, because adding an
-- output column changes the signature and `create or replace` will not do it.
-- The list goes first: it reads the other one.

drop function if exists public.billing_needs_action(date);
drop function if exists public.billing_worklist(date, uuid);
drop function if exists public.authorization_attention_for(uuid[], date);

-- ─────────────────────────────────────────────────────────────
-- What is wrong with each authorization, and whether it is past saving
-- ─────────────────────────────────────────────────────────────
create or replace function public.authorization_attention_for(
  p_auths uuid[],
  p_today date default null
)
returns table (auth_id uuid, attention text, urgency integer, blocked boolean)
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
         end,
         -- The same `is_blocked` the first branch above is chosen by, said
         -- plainly so a screen never has to read the sentence to know.
         coalesce(h.is_blocked, false)
    from h;
$$;

comment on function public.authorization_attention_for is
  'The one thing worth saying about each authorization, how urgent it is, and whether it is past the grace and can no longer be submitted (0221).';

revoke all on function public.authorization_attention_for(uuid[], date) from anon, authenticated;
grant execute on function public.authorization_attention_for(uuid[], date) to authenticated;

-- public.authorization_attention(uuid, date) is deliberately left alone. The
-- authorization_record view is built on it, so changing its shape means
-- dropping and rebuilding that view, and one record has no use for a flag
-- that exists to filter a list. It goes on selecting attention and urgency by
-- name, which the new column does not disturb.

-- ─────────────────────────────────────────────────────────────
-- The working list, carrying it through
-- ─────────────────────────────────────────────────────────────
create or replace function public.billing_worklist(
  p_today  date default null,
  p_client uuid default null
)
returns table (id uuid, client_id uuid, client_name text, number text, service_type text,
               period date, status text, bill_by date, stale_date date, submitted_on date,
               followup_due date, amount numeric, parent_id uuid, attention text,
               urgency integer, blocked boolean)
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
         live.followup_due, amt.amount, live.parent_id, att.attention, att.urgency,
         coalesce(att.blocked, false)
    from live
    left join amt on amt.auth_id = live.id
    left join att on att.auth_id = live.id
   order by att.urgency, live.bill_by nulls last, live.client_name;
$$;

comment on function public.billing_worklist(date, uuid) is
  'Every authorization waiting to be billed, chased or paid - for the practice, or for one client when p_client is given (0206). Each row says whether it is past the grace and can no longer be submitted (0221). The hours behind it are counted once for the whole list rather than once per row.';

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
