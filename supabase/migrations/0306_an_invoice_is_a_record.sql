-- Zion Vocational Rehab CRM — the invoice ledger (Phase 3, part one)
--
-- One record per invoice submitted to USOR. Until now the authorization was
-- the invoice: its status said Submitted, its rate implied an amount, and
-- what was actually billed existed only in an email and a PDF.
--
-- ── what that cost, measured ──────────────────────────────────
--
-- Phase 2 found all three of these in one afternoon:
--
--   Money showed $3,370 outstanding where the invoices said $4,180. The $810
--   gap was two hourly authorizations invoiced for hours that were never
--   logged as service entries - the hours are on the USOR 95 forms - so the
--   view valued them at nothing. An amount that is derived cannot be wrong
--   about what was sent; it can only be wrong about everything else.
--
--   An authorization invoiced on 6 October did not exist in the CRM at all,
--   and one invoiced on 27 October sat as Authorized. Neither appeared on any
--   list of money owed, because that list is "Submitted and unpaid" and
--   nothing had told the CRM they were sent.
--
--   V1028166 was reported as "up to $900" from twenty hours at $45. The
--   signed authorization says $450. The rate said one thing and the invoice
--   said another, and only one of them went to the state.
--
-- So: the invoice is its own record, the amount on it is what was sent, and
-- the authorization goes back to being the authorization.
--
-- ── one invoice, one claim ────────────────────────────────────
--
-- The warrant index settles the shape: 156 warrant lines, 156 distinct Zion
-- invoice numbers, none repeated. One invoice is one claim against one
-- authorization, which is exactly what the Billing letter counts - so an
-- invoice carries the claim letter too, and the pair is unique.
--
-- The numbers run 901444 to 955636 in the index, so the sequence starts at
-- 955637 and the ledger continues rather than starting again.

begin;

create sequence if not exists public.zion_invoice_number start with 955637;

create table if not exists public.invoices (
  id            uuid primary key default gen_random_uuid(),
  number        bigint not null default nextval('public.zion_invoice_number'),

  client_id     uuid not null references public.clients(id) on delete cascade,
  auth_id       uuid references public.authorizations(id) on delete set null,
  -- The letter the state adds on a repeat claim. Null where it gave none.
  claim         text,

  submitted_on  date,
  submitted_by  uuid references public.staff(id) on delete set null,
  -- Where it went. The office, and the address it was actually sent to, which
  -- is the billing email: an invoice goes by email and the office's postal
  -- address is not what anybody needs to know about where it went.
  office_id     uuid references public.billing_offices(id) on delete set null,
  sent_to       text not null default '',

  amount        numeric(12,2),
  -- The progress report that had to go with it, where one did.
  report_id     uuid references public.attachments(id) on delete set null,

  status        text not null default 'Submitted',
  paid_on       date,
  warrant       text not null default '',
  voucher       text not null default '',
  amount_paid   numeric(12,2),

  -- Where the record came from: Submit, or the warrant index and the mailbox.
  source        text not null default 'Submit',
  note          text not null default '',
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),

  constraint invoices_status_check
    check (status in ('Submitted', 'Paid', 'Short-paid', 'Rejected')),
  constraint invoices_source_check
    check (source in ('Submit', 'Backfill')),
  constraint invoices_claim_is_a_letter
    check (claim is null or claim ~ '^[A-Z]$'),
  -- A paid invoice says when and how much. The status is not a feeling.
  constraint invoices_paid_says_so
    check (status not in ('Paid', 'Short-paid') or (paid_on is not null and amount_paid is not null)),
  constraint invoices_amounts_are_real
    check ((amount is null or amount >= 0) and (amount_paid is null or amount_paid >= 0))
);

create unique index if not exists invoices_number_unique on public.invoices (number);

-- Not unique on (authorization, claim), and the reason is worth writing down.
-- The letter is the state's, added on a repeat claim, and at the moment an
-- invoice is sent nobody knows whether there will be a second - so the first
-- claim has no letter until the remittance gives it one. A unique index on
-- (authorization, no letter) would refuse the second claim at the moment of
-- sending it, which is the opposite of the rule intended. What stops the same
-- work being billed twice is further down: a service entry can be on one
-- invoice line, and submit refuses an authorization that already has an
-- invoice outstanding.

create index if not exists invoices_client_idx on public.invoices (client_id);
create index if not exists invoices_status_idx on public.invoices (status, submitted_on);
create index if not exists invoices_office_idx on public.invoices (office_id);

comment on table public.invoices is
  'One record per invoice sent to USOR: what was billed, when, to which '
  'office, and what came back. The amount is what was sent, not what a rate '
  'implies.';

-- ── the services it was for ──────────────────────────────────
create table if not exists public.invoice_lines (
  id          uuid primary key default gen_random_uuid(),
  invoice_id  uuid not null references public.invoices(id) on delete cascade,
  -- The service entry this line bills, where it came from one. A service
  -- entry can be billed once: that is what stops Submit running twice over
  -- the same work, and it is a unique index rather than a rule somebody
  -- remembers.
  entry_id    uuid references public.service_entries(id) on delete set null,
  on_date     date,
  description text not null default '',
  hours       numeric(10,2),
  rate        numeric(12,2),
  amount      numeric(12,2),
  created_at  timestamptz not null default now()
);

create unique index if not exists invoice_lines_one_per_entry
  on public.invoice_lines (entry_id) where entry_id is not null;

create index if not exists invoice_lines_invoice_idx on public.invoice_lines (invoice_id);

comment on column public.invoice_lines.entry_id is
  'The service entry this line bills. Unique, so the same hours cannot be '
  'invoiced twice however many times Submit is pressed.';

-- ── the payment knows which invoice it answers ───────────────
alter table public.payments
  add column if not exists invoice_id uuid references public.invoices(id) on delete set null;

create index if not exists payments_invoice_idx on public.payments (invoice_id);

comment on column public.payments.invoice_id is
  'The invoice this payment answers. Every payment has one once the ledger is '
  'backfilled; verify_invoices holds it to that.';

-- ── short-paid is arithmetic, not an opinion ─────────────────
create or replace function public.invoice_status_follows_the_money()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  new.updated_at := now();

  -- Rejected is somebody's decision and is left alone. The other three follow
  -- from what came in against what went out, so nobody has to remember to
  -- change the status when a short payment lands.
  if new.status <> 'Rejected' then
    if coalesce(new.amount_paid, 0) = 0 then
      new.status := 'Submitted';
      new.paid_on := null;
      new.amount_paid := null;
    elsif new.amount is not null and new.amount_paid < new.amount then
      new.status := 'Short-paid';
    else
      new.status := 'Paid';
    end if;
  end if;

  return new;
end $$;

drop trigger if exists invoices_status on public.invoices;
create trigger invoices_status
  before insert or update on public.invoices
  for each row execute function public.invoice_status_follows_the_money();

-- ── what it came to, and what is left ────────────────────────
--
-- Read from the rows rather than stored, so it cannot drift from them. Both
-- figures the brief asks for: what was authorized and not yet invoiced, and
-- what was invoiced and not yet paid.
create or replace view public.authorization_invoicing as
  select a.id as auth_id,
         a.client_id,
         a.number,
         a.status,
         -- Flat fee is the fee; hourly is the ceiling the authorization set,
         -- which is the figure to measure invoicing against. The money view's
         -- own "amount" is hours worked, which is a different question.
         case when a.rate_type = 'Flat Fee' then coalesce(a.rate, 0)
              else coalesce(a.total_hours, 0) * coalesce(a.rate, 0) end as authorized,
         coalesce((select sum(i.amount) from public.invoices i where i.auth_id = a.id), 0) as invoiced,
         coalesce((select sum(p.amount) from public.payments p where p.auth_id = a.id), 0) as paid,
         (select count(*) from public.invoices i where i.auth_id = a.id) as invoices,
         (select count(*) from public.invoices i
           where i.auth_id = a.id and i.status in ('Submitted', 'Short-paid')) as invoices_open
    from public.authorizations a;

comment on view public.authorization_invoicing is
  'Per authorization: what it authorized, what has been invoiced against it, '
  'and what has been paid. authorized - invoiced is what is left to bill; '
  'invoiced - paid is what is owed.';

alter view public.authorization_invoicing set (security_invoker = on);

-- ── who may read it, and who may write it ────────────────────
alter table public.invoices enable row level security;
alter table public.invoice_lines enable row level security;

drop policy if exists invoices_read on public.invoices;
create policy invoices_read on public.invoices
  for select using ((select public.is_active_staff()));

drop policy if exists invoice_lines_read on public.invoice_lines;
create policy invoice_lines_read on public.invoice_lines
  for select using ((select public.is_active_staff()));

-- No write policy, deliberately, and the same way payments has none: every
-- change to the ledger goes through a function that says who did it and why.
-- A table anybody with a session can update is a table the ledger cannot be
-- trusted from.

revoke all on public.invoices from anon, authenticated;
revoke all on public.invoice_lines from anon, authenticated;
grant select on public.invoices to authenticated;
grant select on public.invoice_lines to authenticated;
revoke all on sequence public.zion_invoice_number from anon, authenticated;
revoke execute on function public.invoice_status_follows_the_money() from anon, authenticated;

revoke all on public.authorization_invoicing from anon, authenticated;
grant select on public.authorization_invoicing to authenticated;

select public.apply_system_read_only('invoices');
select public.apply_system_read_only('invoice_lines');

commit;
