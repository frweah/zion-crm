-- ─────────────────────────────────────────────────────────────
-- Warrants: what USOR actually paid, reconciled against what was billed
--
-- USOR pays by warrant. Each warrant stub is a page listing, line by line, the
-- invoice it pays - "{V-number}{suffix} / {6 digits}-{initial} {Surname}-
-- {V-number}[-DOS {date}]-{amount}" - its voucher and amount, with the warrant
-- number, date and total at the foot. The desktop agent reads the pages in the
-- _Warrants folder with OCR and sends each page's text and image; the route
-- parses the lines; this reconciles them.
--
-- A line is trusted only when the page proves it:
--
--   both copies of the V-number on the line agree,
--   the lines add up to the page's own total, to the cent,
--   the page gave its warrant number and date,
--   and the V-number is an authorization on file - suffix and all. "V0000101"
--   is the base authorization; it is never quietly matched to V0000101A.
--
-- Then the line is a payment on that authorization, its invoice is marked
-- Paid - or, when no unpaid invoice for that amount is on file, one is created
-- and marked as reconciled from the warrant. A line naming a payment already
-- imported from the workbook (same warrant, authorization and amount) is
-- linked to it, not paid twice. Anything that fails waits on a review list
-- with the page image, for a person to record or dismiss.
--
-- Payments are their own record now. Until this, "paid" was an invoice status;
-- the 139 payments imported from the workbook become payment rows here, and an
-- invoice marked Paid by hand still records one.
-- ─────────────────────────────────────────────────────────────

-- ── page images ──────────────────────────────────────────────
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('warrants', 'warrants', false, 10485760, array['image/jpeg', 'image/png'])
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "zion read warrant pages" on storage.objects;
create policy "zion read warrant pages" on storage.objects
  for select to authenticated
  using (bucket_id = 'warrants' and public.current_staff_role() in ('Admin', 'Billing'));
-- No insert, update or delete policy: only the agent route, as the service role, writes them.

-- ── what arrived ─────────────────────────────────────────────
create table if not exists public.warrant_documents (
  id            uuid primary key default gen_random_uuid(),
  sha256        text not null unique check (sha256 ~ '^[0-9a-f]{64}$'),
  filename      text not null,
  relative_path text not null default '',
  page_count    integer not null check (page_count > 0),
  first_seen    timestamptz not null default now()
);

create table if not exists public.warrant_pages (
  id             uuid primary key default gen_random_uuid(),
  document_id    uuid not null references public.warrant_documents(id) on delete cascade,
  page_no        integer not null check (page_no > 0),
  image_path     text not null default '',
  ocr_text       text not null default '',
  ocr_confidence numeric(5,2),
  rotation       integer not null default 0,
  warrant_no     text not null default '',
  warrant_date   date,
  total          numeric(12,2),
  lines_total    numeric(12,2),
  status         text not null default 'Needs review'
                   check (status in ('Reconciled', 'Needs review', 'Not a warrant')),
  problems       text[] not null default '{}',
  received_at    timestamptz not null default now(),
  unique (document_id, page_no)
);

create index if not exists warrant_pages_status_idx on public.warrant_pages (status, received_at desc);
create index if not exists warrant_pages_warrant_idx on public.warrant_pages (warrant_no);

-- ── payments ─────────────────────────────────────────────────
create table if not exists public.payments (
  id               uuid primary key default gen_random_uuid(),
  auth_id          uuid not null references public.authorizations(id) on delete cascade,
  invoice_id       uuid references public.invoices(id) on delete set null,
  amount           numeric(10,2) not null check (amount > 0),
  warrant_no       text not null default '',
  warrant_date     date,
  voucher          text not null default '',
  source           text not null check (source in ('Workbook', 'Warrant', 'By hand')),
  warrant_line_id  uuid,
  recorded_by      uuid references public.staff(id) on delete set null,
  recorded_by_name text not null default '',
  created_at       timestamptz not null default now()
);

create index if not exists payments_auth_idx on public.payments (auth_id);
create index if not exists payments_warrant_idx on public.payments (warrant_no);
create index if not exists payments_invoice_idx on public.payments (invoice_id);

create table if not exists public.warrant_lines (
  id               uuid primary key default gen_random_uuid(),
  page_id          uuid not null references public.warrant_pages(id) on delete cascade,
  line_no          integer not null check (line_no > 0),
  raw              text not null default '',
  dept             text not null default '',
  voucher          text not null default '',
  invoice_ref      text not null default '',
  described_ref    text not null default '',
  client_code      text not null default '',
  client_name      text not null default '',
  service_date     date,
  described_amount numeric(10,2),
  amount           numeric(10,2),
  auth_id          uuid references public.authorizations(id) on delete set null,
  status           text not null default 'Needs review'
                     check (status in ('Reconciled', 'Already recorded', 'Needs review', 'Resolved by hand', 'Dismissed')),
  problem          text not null default '',
  payment_id       uuid references public.payments(id) on delete set null,
  invoice_id       uuid references public.invoices(id) on delete set null,
  decided_by       uuid references public.staff(id) on delete set null,
  decided_by_name  text not null default '',
  decided_at       timestamptz,
  unique (page_id, line_no)
);

create index if not exists warrant_lines_status_idx on public.warrant_lines (status);

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'payments_warrant_line_fk') then
    alter table public.payments add constraint payments_warrant_line_fk
      foreign key (warrant_line_id) references public.warrant_lines(id) on delete set null;
  end if;
end $$;

create unique index if not exists payments_one_per_line
  on public.payments (warrant_line_id) where warrant_line_id is not null;

alter table public.invoices
  add column if not exists reconciled_from_warrant boolean not null default false;

comment on column public.invoices.reconciled_from_warrant is
  'Created by warrant reconciliation: USOR paid a line for which no invoice was on file.';

-- ── who sees it ──────────────────────────────────────────────
alter table public.warrant_documents enable row level security;
alter table public.warrant_pages     enable row level security;
alter table public.warrant_lines     enable row level security;
alter table public.payments          enable row level security;

drop policy if exists warrant_documents_read on public.warrant_documents;
create policy warrant_documents_read on public.warrant_documents
  for select to authenticated using (public.current_staff_role() in ('Admin', 'Billing'));
drop policy if exists warrant_pages_read on public.warrant_pages;
create policy warrant_pages_read on public.warrant_pages
  for select to authenticated using (public.current_staff_role() in ('Admin', 'Billing'));
drop policy if exists warrant_lines_read on public.warrant_lines;
create policy warrant_lines_read on public.warrant_lines
  for select to authenticated using (public.current_staff_role() in ('Admin', 'Billing'));
-- Payments are read like invoices: by active staff.
drop policy if exists payments_read on public.payments;
create policy payments_read on public.payments
  for select to authenticated using (public.is_active_staff());

-- Written only through the functions below and the agent route.
revoke insert, update, delete, truncate on public.warrant_documents, public.warrant_pages,
  public.warrant_lines, public.payments from authenticated, anon;

-- ── the workbook's payments become payment rows ──────────────
insert into public.payments (auth_id, invoice_id, amount, warrant_no, warrant_date, voucher, source, recorded_by_name)
select i.auth_id, i.id, i.amount, i.warrant, i.paid_date, i.voucher, 'Workbook', 'Workbook import'
  from public.invoices i
 where i.status = 'Paid'
   and i.amount > 0
   and not exists (select 1 from public.payments p where p.invoice_id = i.id);

-- ── an invoice marked Paid by hand records its payment ───────
create or replace function public.invoice_paid_payment()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  -- Reconciliation writes its own payment, with the warrant line.
  if coalesce(current_setting('zion.reconciling', true), '') <> '' then
    return null;
  end if;

  if new.status = 'Paid' and (tg_op = 'INSERT' or old.status <> 'Paid') and new.amount > 0
     and not exists (select 1 from public.payments p where p.invoice_id = new.id) then
    insert into public.payments
      (auth_id, invoice_id, amount, warrant_no, warrant_date, voucher, source, recorded_by, recorded_by_name)
    values
      (new.auth_id, new.id, new.amount, new.warrant, coalesce(new.paid_date, public.practice_today()),
       new.voucher, 'By hand', public.current_staff_id(),
       coalesce((select s.name from public.staff s where s.id = public.current_staff_id()), ''));
  elsif tg_op = 'UPDATE' and old.status = 'Paid' and new.status <> 'Paid' then
    -- Un-paying an invoice by hand takes back only what was recorded by hand.
    delete from public.payments p
     where p.invoice_id = new.id and p.source = 'By hand' and p.warrant_line_id is null;
  end if;
  return null;
end;
$$;

drop trigger if exists invoices_paid_payment on public.invoices;
create trigger invoices_paid_payment
  after insert or update of status on public.invoices
  for each row execute function public.invoice_paid_payment();

-- ─────────────────────────────────────────────────────────────
-- One line: validate, then pay
-- ─────────────────────────────────────────────────────────────
create or replace function public.reconcile_warrant_line(
  p_line    uuid,
  p_by_hand boolean default false,
  p_auth    uuid    default null,
  p_amount  numeric default null
) returns text
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare
  v_role    text := public.filing_caller_role();
  v_staff   uuid := public.current_staff_id();
  v_name    text;
  v_line    public.warrant_lines%rowtype;
  v_page    public.warrant_pages%rowtype;
  v_auth    public.authorizations%rowtype;
  v_inv     public.invoices%rowtype;
  v_amount  numeric;
  v_sum     numeric;
  v_pay     uuid;
  v_problem text;
  v_status  text;
begin
  if coalesce(p_by_hand, false) then
    if v_role is null or v_role not in ('Admin', 'Billing') then
      raise exception 'Only Admin and Billing record a warrant line by hand.' using errcode = 'insufficient_privilege';
    end if;
  elsif v_role is null or v_role not in ('service_role', 'Admin', 'Billing') then
    raise exception 'Only Admin, Billing and the agent reconcile warrants.' using errcode = 'insufficient_privilege';
  end if;

  select * into v_line from public.warrant_lines where id = p_line for update;
  if not found then
    raise exception 'That warrant line does not exist.' using errcode = 'no_data_found';
  end if;
  if v_line.status <> 'Needs review' then
    return v_line.status;
  end if;

  select * into v_page from public.warrant_pages where id = v_line.page_id;
  select name into v_name from public.staff where id = v_staff;
  v_amount := coalesce(p_amount, v_line.amount);

  -- ── what the page must prove ─────────────────────────────
  if coalesce(p_by_hand, false) then
    if p_auth is null then
      raise exception 'Choose the authorization this line pays.' using errcode = 'check_violation';
    end if;
    if v_amount is null or v_amount <= 0 then
      raise exception 'Give the amount paid.' using errcode = 'check_violation';
    end if;
    if v_page.warrant_no = '' or v_page.warrant_date is null then
      raise exception 'The page has no warrant number or date read off it.' using errcode = 'check_violation';
    end if;
    select * into v_auth from public.authorizations where id = p_auth;
    if not found then
      raise exception 'That authorization does not exist.' using errcode = 'no_data_found';
    end if;
  else
    select sum(l.amount) into v_sum from public.warrant_lines l where l.page_id = v_page.id;

    if v_page.warrant_no = '' then
      v_problem := 'No warrant number was read on the page.';
    elsif v_page.warrant_date is null then
      v_problem := 'No warrant date was read on the page.';
    elsif v_page.total is null then
      v_problem := 'No page total was read, so the lines cannot be checked against it.';
    elsif v_sum is distinct from v_page.total then
      v_problem := format('The lines add up to %s and the page total is %s.', coalesce(v_sum::text, 'nothing'), v_page.total);
    elsif public.normalize_auth_number(v_line.invoice_ref) = '' then
      v_problem := 'No V-number was read before the slash.';
    elsif public.normalize_auth_number(v_line.described_ref) = '' then
      v_problem := 'The description on this line could not be read; check it against the page image.';
    -- The stub prints the suffix only before the slash: "V0000101A /
    -- 123456-D Name-V0000101-V0000101-450.00". The description's copy must be
    -- the same V-number - with the suffix, or without it - and never another.
    -- The suffix itself is then matched exactly against the authorizations.
    elsif public.normalize_auth_number(v_line.described_ref) not in (
            public.normalize_auth_number(v_line.invoice_ref),
            regexp_replace(public.normalize_auth_number(v_line.invoice_ref), '([0-9])[A-Z]$', '\1')) then
      v_problem := format('The two copies of the V-number disagree: %s and %s.', v_line.invoice_ref, v_line.described_ref);
    elsif v_amount is null or v_amount <= 0 then
      v_problem := 'No amount was read on the line.';
    end if;

    if v_problem is null then
      -- Suffix and all: V0000101 is the base authorization, V0000101A another.
      select * into v_auth from public.authorizations
       where public.normalize_auth_number(number) = public.normalize_auth_number(v_line.invoice_ref);
      if not found then
        v_problem := format('%s is not an authorization on file.', v_line.invoice_ref);
      end if;
    end if;

    if v_problem is not null then
      update public.warrant_lines set problem = v_problem where id = v_line.id;
      update public.warrant_pages set status = 'Needs review' where id = v_page.id;
      return 'Needs review';
    end if;
  end if;

  -- ── pay it ───────────────────────────────────────────────
  begin
    perform set_config('zion.reconciling', 'on', true);

    -- Already recorded from the workbook: same warrant, the same authorization
    -- (or an invoice numbered with the same V-number), the same amount.
    select p.id into v_pay
      from public.payments p
      left join public.invoices i on i.id = p.invoice_id
     where p.warrant_no = v_page.warrant_no
       and p.amount = v_amount
       and p.warrant_line_id is null
       and (p.auth_id = v_auth.id
            or public.normalize_auth_number(i.number) = public.normalize_auth_number(v_auth.number))
     order by p.created_at
     limit 1;

    -- Or recorded from another copy of the same warrant: the backfill PDF and
    -- a later scan of the same stub. A payment already tied to a line on a
    -- different page with this warrant number is this line, seen twice. (Two
    -- identical lines on one page are two payments, and stay so.)
    if v_pay is null then
      select p.id into v_pay
        from public.payments p
        join public.warrant_lines ol on ol.id = p.warrant_line_id
        join public.warrant_pages op on op.id = ol.page_id
       where p.warrant_no = v_page.warrant_no
         and p.amount = v_amount
         and p.auth_id = v_auth.id
         and op.id <> v_page.id
         and op.warrant_no = v_page.warrant_no
         and not exists (select 1 from public.warrant_lines same
                          where same.page_id = v_page.id and same.payment_id = p.id)
       order by p.created_at
       limit 1;

      if v_pay is not null then
        v_status := case when p_by_hand then 'Resolved by hand' else 'Already recorded' end;
        update public.warrant_lines
           set status = v_status, auth_id = v_auth.id, payment_id = v_pay, amount = v_amount,
               invoice_id = (select p.invoice_id from public.payments p where p.id = v_pay),
               problem = format('Already recorded from another copy of warrant %s.', v_page.warrant_no),
               decided_by = case when p_by_hand then v_staff end,
               decided_by_name = case when p_by_hand then coalesce(v_name, '') else '' end,
               decided_at = case when p_by_hand then now() end
         where id = v_line.id;
        perform set_config('zion.reconciling', '', true);
        update public.warrant_pages pg
           set status = case when exists (select 1 from public.warrant_lines l
                                           where l.page_id = pg.id and l.status = 'Needs review')
                             then 'Needs review' else 'Reconciled' end
         where pg.id = v_page.id and pg.status <> 'Not a warrant';
        return v_status;
      end if;
    end if;

    if v_pay is not null then
      update public.payments
         set warrant_line_id = v_line.id,
             voucher = case when voucher = '' then v_line.voucher else voucher end,
             warrant_date = coalesce(warrant_date, v_page.warrant_date)
       where id = v_pay;
      v_status := case when p_by_hand then 'Resolved by hand' else 'Already recorded' end;
      update public.warrant_lines
         set status = v_status, auth_id = v_auth.id, payment_id = v_pay, amount = v_amount,
             invoice_id = (select p.invoice_id from public.payments p where p.id = v_pay),
             problem = '',
             decided_by = case when p_by_hand then v_staff end,
             decided_by_name = case when p_by_hand then coalesce(v_name, '') else '' end,
             decided_at = case when p_by_hand then now() end
       where id = v_line.id;
    else
      -- The invoice it pays: an unpaid one on that authorization for that amount.
      select * into v_inv from public.invoices i
       where i.auth_id = v_auth.id and i.status in ('Sent', 'Draft') and i.amount = v_amount
       order by (i.status = 'Sent') desc, i.date
       limit 1;

      if found then
        update public.invoices
           set status = 'Paid', paid_date = v_page.warrant_date, warrant = v_page.warrant_no,
               voucher = coalesce(nullif(v_line.voucher, ''), voucher)
         where id = v_inv.id;
      else
        insert into public.invoices
          (auth_id, number, date, amount, status, paid_date, warrant, voucher, service_type, reconciled_from_warrant)
        values
          (v_auth.id, v_auth.number, coalesce(v_line.service_date, v_page.warrant_date), v_amount, 'Paid',
           v_page.warrant_date, v_page.warrant_no, v_line.voucher, v_auth.service_type, true)
        returning * into v_inv;
      end if;

      insert into public.payments
        (auth_id, invoice_id, amount, warrant_no, warrant_date, voucher, source, warrant_line_id,
         recorded_by, recorded_by_name)
      values
        (v_auth.id, v_inv.id, v_amount, v_page.warrant_no, v_page.warrant_date, v_line.voucher,
         case when p_by_hand then 'By hand' else 'Warrant' end, v_line.id,
         v_staff, coalesce(v_name, case when p_by_hand then '' else 'Warrant reconciliation' end))
      returning id into v_pay;

      v_status := case when p_by_hand then 'Resolved by hand' else 'Reconciled' end;
      update public.warrant_lines
         set status = v_status, auth_id = v_auth.id, payment_id = v_pay, invoice_id = v_inv.id,
             amount = v_amount, problem = '',
             decided_by = case when p_by_hand then v_staff end,
             decided_by_name = case when p_by_hand then coalesce(v_name, '') else '' end,
             decided_at = case when p_by_hand then now() end
       where id = v_line.id;
    end if;

    perform set_config('zion.reconciling', '', true);
  exception when others then
    -- For example an invoice that would exceed what the authorization authorizes.
    -- Nothing above is kept; the line waits with the reason.
    if coalesce(p_by_hand, false) then
      raise;
    end if;
    update public.warrant_lines set problem = sqlerrm, auth_id = v_auth.id where id = v_line.id;
    v_status := 'Needs review';
  end;

  update public.warrant_pages pg
     set status = case when exists (select 1 from public.warrant_lines l
                                     where l.page_id = pg.id and l.status = 'Needs review')
                       then 'Needs review' else 'Reconciled' end
   where pg.id = v_page.id and pg.status <> 'Not a warrant';

  return v_status;
end;
$$;

revoke execute on function public.reconcile_warrant_line(uuid, boolean, uuid, numeric) from public;
revoke execute on function public.reconcile_warrant_line(uuid, boolean, uuid, numeric) from anon;
grant execute on function public.reconcile_warrant_line(uuid, boolean, uuid, numeric) to authenticated, service_role;

comment on function public.reconcile_warrant_line(uuid, boolean, uuid, numeric) is
  'Validates one warrant line (both V-number copies agree, page lines sum to the total, warrant number and date read, authorization on file with its exact suffix) and records it: links a workbook payment for the same warrant, authorization and amount, or pays the matching invoice or creates one reconciled from the warrant. Failures wait for review. By hand, Admin or Billing choose the authorization and amount.';

-- ── a whole page ─────────────────────────────────────────────
create or replace function public.reconcile_warrant_page(p_page uuid)
returns table (reconciled integer, already_recorded integer, needs_review integer)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare
  v_role text := public.filing_caller_role();
  v_line record;
begin
  if v_role is null or v_role not in ('service_role', 'Admin', 'Billing') then
    raise exception 'Only Admin, Billing and the agent reconcile warrants.' using errcode = 'insufficient_privilege';
  end if;

  update public.warrant_pages pg
     set lines_total = (select sum(l.amount) from public.warrant_lines l where l.page_id = pg.id)
   where pg.id = p_page;

  for v_line in select l.id from public.warrant_lines l
                 where l.page_id = p_page and l.status = 'Needs review' order by l.line_no loop
    perform public.reconcile_warrant_line(v_line.id);
  end loop;

  update public.warrant_pages pg
     set status = case
                    when pg.status = 'Not a warrant' then pg.status
                    when not exists (select 1 from public.warrant_lines l where l.page_id = pg.id) then 'Needs review'
                    when exists (select 1 from public.warrant_lines l where l.page_id = pg.id and l.status = 'Needs review')
                      then 'Needs review'
                    else 'Reconciled' end
   where pg.id = p_page;

  return query
    select count(*) filter (where l.status = 'Reconciled')::int,
           count(*) filter (where l.status = 'Already recorded')::int,
           count(*) filter (where l.status = 'Needs review')::int
      from public.warrant_lines l where l.page_id = p_page;
end;
$$;

revoke execute on function public.reconcile_warrant_page(uuid) from public;
revoke execute on function public.reconcile_warrant_page(uuid) from anon;
grant execute on function public.reconcile_warrant_page(uuid) to authenticated, service_role;

-- ── setting a line aside ─────────────────────────────────────
create or replace function public.dismiss_warrant_line(p_line uuid, p_reason text)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_line public.warrant_lines%rowtype;
begin
  if public.current_staff_role() is null or public.current_staff_role() not in ('Admin', 'Billing') then
    raise exception 'Only Admin and Billing set a warrant line aside.' using errcode = 'insufficient_privilege';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'Say why it is being set aside.' using errcode = 'check_violation';
  end if;
  select * into v_line from public.warrant_lines where id = p_line for update;
  if not found then
    raise exception 'That warrant line does not exist.' using errcode = 'no_data_found';
  end if;
  if v_line.status <> 'Needs review' then
    raise exception 'Only a line waiting for review can be set aside.' using errcode = 'check_violation';
  end if;

  update public.warrant_lines
     set status = 'Dismissed', problem = btrim(p_reason), decided_by = public.current_staff_id(),
         decided_by_name = coalesce((select name from public.staff where id = public.current_staff_id()), ''),
         decided_at = now()
   where id = p_line;

  update public.warrant_pages pg
     set status = case when exists (select 1 from public.warrant_lines l
                                     where l.page_id = pg.id and l.status = 'Needs review')
                       then 'Needs review' else 'Reconciled' end
   where pg.id = v_line.page_id and pg.status <> 'Not a warrant';
end;
$$;

revoke execute on function public.dismiss_warrant_line(uuid, text) from public;
revoke execute on function public.dismiss_warrant_line(uuid, text) from anon;
grant execute on function public.dismiss_warrant_line(uuid, text) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- Authorized, invoiced, paid, outstanding
-- ─────────────────────────────────────────────────────────────
create or replace view public.billing_position as
select e.auth_id,
       e.client_id,
       c.name                                              as client_name,
       e.auth_number,
       e.service_type,
       e.status,
       e.authorized,
       e.invoiced,
       coalesce(p.paid, 0)                                 as paid,
       -- What USOR has been asked for and has not paid.
       greatest(e.invoiced - coalesce(p.paid, 0), 0)       as outstanding,
       -- What USOR has agreed to and has not been asked for yet.
       greatest(e.authorized - e.invoiced, 0)              as not_yet_invoiced,
       p.last_paid_on,
       coalesce(p.payments, 0)                             as payments
  from public.authorization_economics e
  join public.clients c on c.id = e.client_id
  left join (select auth_id, sum(amount) as paid, max(warrant_date) as last_paid_on, count(*) as payments
               from public.payments group by auth_id) p on p.auth_id = e.auth_id;

alter view public.billing_position set (security_invoker = true);
grant select on public.billing_position to authenticated;

comment on view public.billing_position is
  'Per authorization: authorized, invoiced (not Void), paid (payments recorded), outstanding (invoiced and not paid) and not yet invoiced.';
