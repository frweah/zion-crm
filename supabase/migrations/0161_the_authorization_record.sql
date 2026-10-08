-- Zion Vocational Rehab CRM — what the authorization record reads, and the
-- one alert it shows
-- (Billing Simplification Brief §§9, 11, 12.2, 12.6, 13.11, 13.15)
--
-- §9 moves the forms, the signed authorization, the submission checklist and
-- Report & bill onto the authorization record, and cuts Billing to two tabs.
-- That record needs one place to read itself from, which is what the view
-- below is: the client, the counselor, the office, the money, the dates, the
-- submission and the payment, in one row. §11's rule is why it is a view and
-- not eleven queries in a page component.
--
-- §13.11 wants one alert per record rather than four. That logic already
-- exists, inside billing_worklist, as a first-true-wins case. It is lifted out
-- here into authorization_attention() and the worklist now calls it, because
-- the record and the list saying different things about the same
-- authorization is exactly what §11 is about - and a record that is Paid or
-- Closed falls out of the worklist entirely, so the record screen could not
-- have borrowed it.
--
-- §9 also strips the "(workbook)" prefix. Four placeholders are left: the ones
-- the owner kept, each holding a payment or hours. They were found by their
-- number beginning "(workbook)", in two different screens, by matching text -
-- so stripping the prefix would have made them invisible to the very code
-- that manages them. They get a column saying what they are instead, and
-- nothing parses a number to find out again.

-- ── A placeholder says so, rather than being recognised by its name ──

alter table public.authorizations
  add column if not exists is_placeholder boolean not null default false;

comment on column public.authorizations.is_placeholder is
  'An authorization carried over from the workbook with no USOR number yet (§9). Kept for the payment or hours on it, shown as History, never on the working list. Replaced in place when the real number is confirmed.';

update public.authorizations
   set is_placeholder = true
 where number ilike '(workbook)%';

-- Then the prefix goes from the number and the note (§9).
update public.authorizations
   set number = btrim(regexp_replace(number, '^\(workbook\)\s*', '')),
       note   = nullif(btrim(regexp_replace(coalesce(note, ''), '\(workbook\)\s*', '', 'g')), '')
 where number ilike '(workbook)%' or note ilike '%workbook%';

-- ── One alert, in one place (§13.11) ──

/**
 * The single most pressing thing wrong with an authorization, and how
 * pressing it is. First true wins, so a record that is overdue *and* ending
 * soon says the one that matters.
 *
 * Lifted out of billing_worklist unchanged. The worklist calls it below, and
 * the record screen calls it directly - including for Paid and Closed
 * records, which the worklist does not return at all.
 */
create or replace function public.authorization_attention(p_auth uuid, p_today date default null)
returns table (attention text, urgency integer)
language sql stable security definer set search_path = public as $$
  with me as (select coalesce(p_today, public.practice_today()) as today),
  r as (
    select a.status, a.bill_by, a.stale_date, a.submitted_on, a.followup_due,
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
           a.followup_due is not null and a.followup_due <= (select today from me)
             and a.status = 'Submitted' as needs_chasing,
           a.stale_date is not null and a.status not in ('Submitted', 'Paid')
             and a.stale_date >= (select today from me)
             and a.stale_date <= (select today from me)
               + (select stale_soon_days from public.org_settings where id) as stale_soon
      from public.authorizations a where a.id = p_auth
  )
  select case
           when r.is_blocked then 'Cannot be submitted - ended ' || r.stale_date
                                  || ', more than ' || (select stale_grace_days from public.org_settings where id)
                                  || ' days ago'
           when r.needs_chasing then 'Submitted ' || r.submitted_on || ', no payment after 14 days'
           when r.is_overdue then 'Overdue - meant to be billed by ' || r.bill_by
           when r.is_expired then 'Past its end date (' || r.stale_date || ') - can still be submitted until '
                                  || public.authorization_blocked_from(r.stale_date)
           when r.stale_soon then 'Ends ' || r.stale_date
           when r.no_end_date then 'No end date on the authorization'
           when r.status = 'Due' then 'Due to be billed'
           else ''
         end,
         case
           when r.is_blocked then 0
           when r.needs_chasing then 1
           when r.is_overdue then 2
           when r.is_expired then 3
           when r.stale_soon then 4
           when r.no_end_date then 5
           when r.status = 'Due' then 6
           else 7
         end
    from r;
$$;

comment on function public.authorization_attention is
  'The one thing worth saying about an authorization, and how pressing (§13.11). Read by the working list and by the record, so they cannot disagree.';

revoke all on function public.authorization_attention(uuid, date) from anon, authenticated;
grant execute on function public.authorization_attention(uuid, date) to authenticated;

-- ── The working list, now reading the alert from there (§12.2) ──
-- One list, sorted by bill-by with the most pressing first. No separate Due
-- section: §12.2 says one list, and Due is one of the things a row can say
-- about itself.

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
   order by t.urgency, a.bill_by nulls last, c.name;
$$;

revoke all on function public.billing_worklist(date) from anon, authenticated;
grant execute on function public.billing_worklist(date) to authenticated;

-- ── One number for the dashboard (§13.15) ──

/**
 * How many authorizations need something done about them today.
 *
 * §13.15: the dashboard billing tile is one number, and it opens the working
 * list. Anything the list has nothing to say about does not count - that is
 * §11's "nothing shows that needs no action", as a figure.
 */
create or replace function public.billing_needs_action(p_today date default null)
returns integer language sql stable security definer set search_path = public as $$
  select count(*)::int from public.billing_worklist(p_today) w where coalesce(w.attention, '') <> '';
$$;

revoke all on function public.billing_needs_action(date) from anon, authenticated;
grant execute on function public.billing_needs_action(date) to authenticated;

-- ── The record, read from one place (§§9, 11, 12.6) ──

create or replace view public.authorization_record as
  select a.id,
         a.client_id,
         c.name                           as client_name,
         c.client_no,
         a.parent_id,
         p.number                         as parent_number,
         coalesce(nullif(a.number, ''), p.number, '') as number,
         a.is_placeholder,
         a.service_type,
         a.funding_source,
         a.period,
         a.status,
         a.rate_type,
         a.rate,
         a.total_hours,
         coalesce(pp.total_hours, a.total_hours) as authorized_hours,
         a.carried_used,
         a.start_date,
         a.end_date,
         a.service_start,
         a.service_end,
         a.first_work_day,
         a.received_on,
         a.bill_by,
         a.stale_date,
         a.stale_reason,
         a.submitted_on,
         a.submitted_by,
         sb.name                          as submitted_by_name,
         a.recipient,
         a.paid_on,
         a.paid_amount,
         a.warrant,
         a.correction_note,
         a.followup_due,
         a.closed_reason,
         a.closed_at,
         a.note,
         a.zero_hours_confirmed_at,
         -- Who it is for, read from the client and never editable here (§13.12).
         k.name                           as counselor_name,
         k.email                          as counselor_email,
         bo.billing_office_id,
         bo.billing_office                as billing_office_name,
         b.billing_email                  as billing_office_email,
         -- What it comes to, and the hours behind it.
         public.authorization_amount(a.id) as amount,
         coalesce((select sum(e.hours) from public.service_entries e
                    where e.auth_id = a.id and not e.non_billable), 0) as hours_logged,
         coalesce((select sum(e.hours) from public.service_entries e
                    join public.authorizations ch on ch.id = e.auth_id
                   where not e.non_billable
                     and (ch.id = coalesce(a.parent_id, a.id)
                          or ch.parent_id = coalesce(a.parent_id, a.id))), 0) as hours_on_the_authorization,
         -- Whether it may go, and whether everything is tidy.
         public.authorization_can_submit(a.id) as can_submit,
         public.authorization_gate_met(a.id)   as gate_met,
         public.authorization_missing_forms(a.id) as missing_forms,
         t.attention,
         t.urgency
    from public.authorizations a
    join public.clients c on c.id = a.client_id
    left join public.authorizations p on p.id = a.parent_id
    left join public.authorizations pp on pp.id = a.parent_id
    left join public.counselors k on k.id = c.counselor_id
    left join public.client_billing_office bo on bo.client_id = c.id
    left join public.billing_offices b on b.id = bo.billing_office_id
    left join public.staff sb on sb.id = a.submitted_by
   cross join lateral public.authorization_attention(a.id) t;

alter view public.authorization_record set (security_invoker = true);
grant select on public.authorization_record to authenticated;

comment on view public.authorization_record is
  'One authorization, everything a screen shows about it (§§9, 11). The counselor and the billing office come from the client (§13.12); the amount, the hours and the checklist verdict are computed, never stored twice.';

-- ── §10 begins: nothing raises a draft invoice any more ──
-- Report & bill moves the authorization to Submitted instead. The rest of the
-- invoice goes with the table in its own migration.
drop function if exists public.draft_invoice_for_authorization(uuid);
