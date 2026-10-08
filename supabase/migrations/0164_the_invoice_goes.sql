-- Zion Vocational Rehab CRM — the invoice goes
-- (Billing Simplification Brief §§10, 11, 13.17), part two of two
--
-- 0163 put the replacements in: billed_work for what the invoice was read for,
-- service_date_for() for the dating rule. The screens that read the invoice
-- have shipped and read those instead. This is the removal.
--
-- Every link the invoice carried is carried by the authorization already:
-- payments.auth_id is NOT NULL on all 139 rows, and warrant_lines.auth_id is
-- how a matched line is recorded. The columns pointing at the invoice go
-- first, so the drop needs no cascade and complains if anything still depends
-- on it rather than quietly taking it with them.
--
-- billing_gate_met() asked exactly the question authorization_missing_forms()
-- answers. Two functions that answer the same question are two functions that
-- will one day answer it differently (§11).

drop function if exists public.invoice_date_for(uuid);
drop function if exists public.billing_gate_met(uuid);

-- ── The billing item, and the gate that read it ──
drop function if exists public.billing_item_ready(uuid);
drop view if exists public.billing_item_rows;
drop view if exists public.billing_items_undated;
drop table if exists public.billing_item_events;
drop table if exists public.billing_items;

-- ── The invoice ──
alter table public.payments      drop column if exists invoice_id;
alter table public.warrant_lines drop column if exists invoice_id;

drop table if exists public.invoices;

-- Its guards go with it; they were triggers on a table that no longer exists.
drop function if exists public.check_invoice_forms();
drop function if exists public.check_invoice_amount();
drop function if exists public.check_invoice_completion();
drop function if exists public.invoice_paid_payment();

-- ── and the word goes with the record ──
--
-- The reconciliation still called its two kinds of row "Unpaid invoice" and
-- "Ending soon, not fully invoiced", and still returned an invoice_number
-- column that has been null since §1. The screen matched on that prose to
-- decide which rows were which, which is a screen depending on wording.
--
-- The kinds are machine values now - 'unpaid' and 'ending' - and the words
-- belong to the screen that shows them. The empty column goes.

drop function if exists public.billing_office_reconciliation(uuid, integer);

create or replace function public.billing_office_reconciliation(
  p_billing_office uuid, p_within_days integer default 30)
returns table (kind text, client_id uuid, client_name text, counselor_id uuid,
               counselor_name text, counselor_email text, auth_id uuid, auth_number text,
               service text, amount numeric, sent_on date, days_outstanding integer,
               end_date date, unbilled numeric)
language sql stable security definer set search_path = public as $$
  select 'unpaid'::text, c.id, c.name, k.id, k.name, nullif(trim(k.email), ''),
         a.id, coalesce(nullif(a.number, ''), p.number, ''), a.service_type,
         public.authorization_amount(a.id), a.submitted_on,
         (public.practice_today() - a.submitted_on)::integer,
         a.end_date, null::numeric
    from public.authorizations a
    left join public.authorizations p on p.id = a.parent_id
    join public.clients c on c.id = a.client_id
    join public.client_billing_office cbo on cbo.client_id = c.id
    left join public.counselors k on k.id = c.counselor_id
   where a.status = 'Submitted'
     and a.submitted_on is not null
     and cbo.billing_office_id = p_billing_office
  union all
  select 'ending'::text, c.id, c.name, k.id, k.name, nullif(trim(k.email), ''),
         a.id, a.number, a.service_type,
         null::numeric, null::date, null::integer,
         a.end_date, bp.not_yet_invoiced
    from public.billing_position bp
    join public.authorizations a on a.id = bp.auth_id
    join public.clients c on c.id = a.client_id
    join public.client_billing_office cbo on cbo.client_id = c.id
    left join public.counselors k on k.id = c.counselor_id
   where a.status in ('Authorized', 'Due', 'Submitted')
     and a.end_date between public.practice_today()
       and public.practice_today() + greatest(coalesce(p_within_days, 30), 0)
     and bp.not_yet_invoiced > 0
     and cbo.billing_office_id = p_billing_office
$$;

comment on function public.billing_office_reconciliation is
  'What is outstanding with one billing office, and what is about to lapse with value left on it. `kind` is a machine value - unpaid, ending - because a screen should not have to match on prose (§10).';

revoke all on function public.billing_office_reconciliation(uuid, integer) from anon, authenticated;
grant execute on function public.billing_office_reconciliation(uuid, integer) to authenticated;
