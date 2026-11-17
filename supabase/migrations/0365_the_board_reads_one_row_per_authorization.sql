-- Zion Vocational Rehab CRM — the board reads one row per authorization
--
-- Billing › Authorizations becomes a board grouped by what is owed (owner,
-- 17 November 2026). This is the row it reads, and the client dashboard's
-- authorizations card reads the same one filtered to a client — one source,
-- so the two screens cannot drift.
--
-- ── why a function and not a view ────────────────────────────
--
-- The ruling approved "one new view per authorization". It is a function, for
-- the same reason `billing_worklist` is one: the money and the attention
-- sentence come from `authorization_amount_for` and
-- `authorization_attention_for`, both of which take an array of ids, and a
-- view has nowhere to build that array. This takes the same two arguments as
-- `billing_worklist`, runs as the invoker exactly as it does, and adds no
-- table and no permission.
--
-- ── what it carries that the worklist does not ───────────────
--
-- `billing_worklist` is the working list: it stops at `status not in ('Paid',
-- 'Closed')` and drops clients the practice has closed. A board with Paid and
-- Closed groups cannot be built on it. So this keeps every authorization -
-- still not the coaching parents, which are never a bill, and still not the
-- placeholders, which are history - and adds the office, the counselor, the
-- invoice number, the money and the dates the board puts in its columns.
--
-- ── the groups ───────────────────────────────────────────────
--
-- Five were named. A sixth had to exist: 11 authorizations across 8 clients
-- are authorized with the service not yet delivered and nothing invoiced,
-- which is none of the five, and leaving them out would have taken 8 clients
-- off the board. They are what the attention sentence already calls them -
-- **Waiting for service** - and they sit after Waiting on payment, because
-- nothing is owed yet, and before Paid, because the work is still live.
--
-- Blocked is tested before "delivered and not invoiced" on purpose. A row
-- past the grace cannot be invoiced at all, so putting it in Needs invoice
-- would be telling somebody to do a thing the database will refuse.

begin;

create or replace function public.billing_board(
  p_today date default null,
  p_client uuid default null)
returns table (
  auth_id uuid,
  client_id uuid,
  client_name text,
  client_status text,
  office text,
  counselor_name text,
  number text,
  service_type text,
  period date,
  status text,
  invoice_number text,
  invoice_count integer,
  authorized numeric,
  invoiced numeric,
  paid numeric,
  outstanding numeric,
  amount numeric,
  basis text,
  received_on date,
  submitted_on date,
  paid_on date,
  delivered_on date,
  bill_by date,
  has_invoice boolean,
  blocked boolean,
  attention text,
  urgency integer,
  grp text,
  grp_rank integer)
language sql
stable
set search_path to 'public'
as $fn$
  with live as (
    select a.id, a.client_id, c.name as client_name, c.status as client_status,
           coalesce(nullif(a.number, ''), p.number, '') as number,
           a.service_type, a.period, a.status, a.bill_by,
           -- `received_on` is the day the authorization arrived from USOR and
           -- keeps that meaning. The day the money arrived is `paid_on`, which
           -- is the column the board lets somebody type in (owner, 17 Nov).
           a.received_on, a.submitted_on, a.paid_on, a.delivered_on,
           exists (select 1 from public.invoices i where i.auth_id = a.id) as has_invoice
      from public.authorizations a
      join public.clients c on c.id = a.client_id
      left join public.authorizations p on p.id = a.parent_id
      -- A coaching parent is not a bill; its months are.
     where a.id not in (select parent_id from public.authorizations where parent_id is not null)
       -- A kept placeholder is history, not work.
       and not a.is_placeholder
       and (p_client is null or a.client_id = p_client)
  ),
  ids as (select array(select id from live) as all_ids),
  amt as (select * from public.authorization_amount_for((select all_ids from ids))),
  att as (select * from public.authorization_attention_for((select all_ids from ids), p_today)),
  /*
   * The invoice number on the row, and how many there are.
   *
   * Ten authorizations carry more than one invoice, so a single number is not
   * the whole truth about them. The latest is shown and the count comes with
   * it, rather than picking one and saying nothing.
   */
  inv as (
    select i.auth_id,
           (array_agg(i.number order by i.submitted_on desc nulls last, i.created_at desc))[1] as number,
           count(*)::integer as n
      from public.invoices i
     where i.auth_id is not null
     group by i.auth_id
  )
  select
    live.id,
    live.client_id,
    live.client_name,
    live.client_status,
    bo.billing_office,
    k.name,
    live.number,
    live.service_type,
    live.period,
    live.status,
    inv.number::text,
    coalesce(inv.n, 0),
    coalesce(bp.authorized, 0::numeric),
    coalesce(bp.invoiced, 0::numeric),
    coalesce(bp.paid, 0::numeric),
    coalesce(bp.outstanding, 0::numeric),
    amt.amount,
    amt.basis,
    live.received_on,
    live.submitted_on,
    coalesce(live.paid_on, bp.last_paid_on),
    live.delivered_on,
    live.bill_by,
    live.has_invoice,
    coalesce(att.blocked, false),
    att.attention,
    att.urgency,
    case
      when live.status = 'Closed' or live.client_status = 'Closed' then 'Closed'
      when live.status = 'Paid' then 'Paid'
      when coalesce(att.blocked, false) then 'Too late to bill'
      when live.delivered_on is not null and not live.has_invoice then 'Needs invoice'
      when live.has_invoice then 'Waiting on payment'
      else 'Waiting for service'
    end,
    case
      when live.status = 'Closed' or live.client_status = 'Closed' then 6
      when live.status = 'Paid' then 5
      when coalesce(att.blocked, false) then 2
      when live.delivered_on is not null and not live.has_invoice then 1
      when live.has_invoice then 3
      else 4
    end
  from live
  left join amt on amt.auth_id = live.id
  left join att on att.auth_id = live.id
  left join inv on inv.auth_id = live.id
  left join public.billing_position bp on bp.auth_id = live.id
  left join public.client_billing_office bo on bo.client_id = live.client_id
  left join public.clients cl on cl.id = live.client_id
  left join public.counselors k on k.id = cl.counselor_id
  -- Bill by is the default sort inside every group (owner, 17 Nov), and the
  -- group is what the screen orders by first.
  order by 29, live.bill_by nulls last, live.client_name, live.number;
$fn$;

comment on function public.billing_board is
  'One row per authorization for Billing''s board and the client dashboard''s card: the client, the office, the counselor, the money, the dates, the attention sentence and which of the six groups it belongs to. No warrant and no voucher.';

revoke all on function public.billing_board(date, uuid) from public, anon;
grant execute on function public.billing_board(date, uuid) to authenticated, service_role;

commit;
