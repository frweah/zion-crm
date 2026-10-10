-- Zion Vocational Rehab CRM — the working list drops what is finished
-- (Billing Simplification Brief §§9, 11)
--
-- "If a row needs no action from the person looking at it, it doesn't show."
--
-- Paid and Closed already left the list the moment their status changed. What
-- did not leave was everything belonging to a client who has been closed: their
-- authorizations stay Authorized or Due for ever, so they sit at the top of the
-- list being overdue, on a person nobody is working with any more. Margaret
-- cannot clear them and cannot bill them, which is the definition of a row that
-- needs no action.
--
-- Closing the client is the decision; the list follows it, and the
-- authorizations keep their own status so the history still reads true. They are
-- on the client's record under History, where a closed client's work belongs.

create or replace function public.billing_worklist(p_today date default null)
returns table (id uuid, client_id uuid, client_name text, number text, service_type text,
               period date, status text, bill_by date, stale_date date, submitted_on date,
               followup_due date, amount numeric, parent_id uuid, attention text, urgency integer)
language sql stable set search_path = public as $$
  select a.id, a.client_id, c.name,
         coalesce(nullif(a.number, ''), p.number, ''),
         a.service_type, a.period, a.status, a.bill_by, a.stale_date,
         a.submitted_on, a.followup_due,
         public.authorization_amount(a.id),
         a.parent_id,
         t.attention, t.urgency
    from public.authorizations a
    join public.clients c on c.id = a.client_id
    left join public.authorizations p on p.id = a.parent_id
   cross join lateral public.authorization_attention(a.id, p_today) t
   where a.status not in ('Paid', 'Closed')
     -- A coaching parent is not a bill; its months are.
     and a.id not in (select parent_id from public.authorizations where parent_id is not null)
     -- A kept placeholder is history, not work (§9).
     and not a.is_placeholder
     -- And nothing belonging to a client the practice has closed.
     and c.status <> 'Closed'
   order by t.urgency, a.bill_by nulls last, c.name;
$$;

revoke all on function public.billing_worklist(date) from anon, authenticated;
grant execute on function public.billing_worklist(date) to authenticated;

-- The alerts follow the same rule: an authorization that is not on the list has
-- nothing to tell anybody, and an alert about a closed client's billing is one
-- more thing to dismiss every morning.
create or replace function public.billing_needs_action(p_today date default null)
returns integer language sql stable security definer set search_path = public as $$
  select count(*)::int from public.billing_worklist(p_today) w where coalesce(w.attention, '') <> '';
$$;

revoke all on function public.billing_needs_action(date) from anon, authenticated;
grant execute on function public.billing_needs_action(date) to authenticated;
