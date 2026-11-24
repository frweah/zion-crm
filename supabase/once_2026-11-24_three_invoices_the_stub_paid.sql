-- Approved by the owner, 24 November 2026. Run once.
--
-- Three payments were recorded from warrant stubs on 23 November by another
-- Claude session working for the owner, against authorizations this practice
-- had never raised an invoice for: V1044403 ($560, Job Development), V1044400
-- ($900, Life Skills) and V1046527 ($585, WSA Tier 2). USOR paid them - the
-- stub says so, and the stub's reference for each is the authorization number
-- itself - so the money is right and the ledger was missing a step.
-- `verify_invoices` has been failing on exactly that since: a payment that
-- names a warrant and no invoice.
--
-- So the invoice each payment pays is raised now, through `raise_invoice` and
-- in the owner's name, and each existing payment is linked to it. Nothing
-- else: no amount changes, no authorization changes, no payment is created or
-- removed.
--
-- Rehearsed inside a transaction that was thrown away first. Invoice numbers
-- come from max+1 under an advisory lock rather than a sequence (0323), so
-- the rehearsal spent no claim numbers. The numbers jump from 955636 to
-- 957908 because the floor reads the warrant stubs as well as the ledger: a
-- claim number USOR has already paid against cannot be handed out twice, even
-- when this practice never recorded it.
--
-- Run:
--   node --env-file=.env.local scripts/run-sql.mjs supabase/once_2026-11-24_three_invoices_the_stub_paid.sql

begin;

do $$
declare
  v_me   uuid := '04b7945f-f14b-42a9-a6c4-6dda453bd17b';  -- Francis Weah, Admin
  v_rows jsonb := '[
    {"auth": "V1044403", "payment": "c11b43d1-cbcb-47d2-9f92-64a6574c9601", "amount": 560.00},
    {"auth": "V1044400", "payment": "05ee16a4-f03e-4218-a68c-72f00e903ae6", "amount": 900.00},
    {"auth": "V1046527", "payment": "f1c92793-c4ec-4d39-ab70-fbffa801a218", "amount": 585.00}
  ]'::jsonb;
  r      jsonb;
  v_auth uuid;
  v_inv  uuid;
  v_num  bigint;
  v_n    integer;
begin
  if not exists (select 1 from public.staff where id = v_me and role = 'Admin' and active) then
    raise exception 'The staff id this invoice would be raised under is not an active Admin.';
  end if;

  for r in select * from jsonb_array_elements(v_rows) loop
    select id into v_auth from public.authorizations where number = r->>'auth';
    if v_auth is null then
      raise exception '% is not on file.', r->>'auth';
    end if;

    -- Each of the three is here because it had no invoice. If one has
    -- acquired one since, this script is out of date and stops rather than
    -- raising a second claim for the same service.
    if exists (select 1 from public.invoices i where i.auth_id = v_auth) then
      raise exception '% already has an invoice; nothing has been changed.', r->>'auth';
    end if;
    if (select invoice_id from public.payments where id = (r->>'payment')::uuid) is not null then
      raise exception 'The payment on % is already linked to an invoice.', r->>'auth';
    end if;
    if (select amount from public.payments where id = (r->>'payment')::uuid) is distinct from (r->>'amount')::numeric then
      raise exception 'The payment on % is not the amount this script was approved for.', r->>'auth';
    end if;

    v_inv := public.raise_invoice(v_auth, null, null, (r->>'amount')::numeric, v_me);
    if v_inv is null then
      raise exception 'No invoice came back for %.', r->>'auth';
    end if;

    update public.payments set invoice_id = v_inv where id = (r->>'payment')::uuid;
    get diagnostics v_n = row_count;
    if v_n <> 1 then
      raise exception 'The payment for % did not link (% row(s)).', r->>'auth', v_n;
    end if;

    select number into v_num from public.invoices where id = v_inv;
    raise notice '% -> claim %, $% , payment linked', r->>'auth', v_num, (r->>'amount')::numeric;
  end loop;

  -- The assertion that has been failing.
  select count(*) into v_n
    from public.payments p
    join public.authorizations a on a.id = p.auth_id
    join public.clients c on c.id = a.client_id
   where p.invoice_id is null and coalesce(btrim(p.warrant_no), '') <> ''
     and not public.is_fixture_name(c.name);
  if v_n <> 0 then
    raise exception '% payment(s) still name a warrant and no invoice.', v_n;
  end if;
  raise notice 'No payment names a warrant and no invoice.';
end $$;

commit;
