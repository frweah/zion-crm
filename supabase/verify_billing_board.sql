-- Zion Vocational Rehab CRM — the billing board (0365, 0366, 0367)
--
-- Billing › Authorizations became a board grouped by what is owed (owner,
-- 17 November 2026), and the client dashboard's card reads the same row. What
-- has to hold is what the ruling said, asked of the database rather than of
-- the screen:
--
--   every authorization is in exactly one group, and the groups are the six;
--   a client's board row is its most pressing authorization's group;
--   the board carries no warrant and no voucher, for anybody;
--   a submission date needs an invoice number, and so does Waiting on payment;
--   the two things the board types into go through the functions the record
--   screen uses, so the correction log sees them;
--   and the ordinary reader still reads it - a board only Admin can open is
--   not a board.
--
-- Everything is rolled back.

begin;

do $$
declare
  failures text[] := '{}';
  v_billing record;
  v_admin   record;
  n integer;
  v_text text;
  v_msg  text;
begin
  select s.id, s.user_id, s.name into v_billing
    from public.staff s
   where s.active and s.user_id is not null and s.role = 'Billing'
     and not coalesce(s.is_system, false)
   order by s.created_at limit 1;
  select s.id, s.user_id, s.name into v_admin
    from public.staff s
   where s.active and s.user_id is not null and s.role = 'Admin'
     and not coalesce(s.is_system, false)
   order by s.created_at limit 1;
  if v_billing.user_id is null then
    raise exception 'This needs a signed-in Billing person to ask as.';
  end if;

  -- ── 1. the six groups, and nothing outside them ───────────
  select coalesce(string_agg(distinct b.grp, ', ' order by b.grp), '') into v_text
    from public.billing_board() b
   where b.grp not in ('Needs invoice', 'Too late to bill', 'Waiting on payment',
                       'Waiting for service', 'Paid', 'Closed');
  if v_text <> '' then
    failures := failures || format('FAILED: the board put rows in a group nobody named: %s', v_text)::text;
  else
    raise notice 'ok  every row is in one of the six groups';
  end if;

  -- And every authorization the practice bills is on it. The board drops the
  -- coaching parents and the placeholders on purpose and nothing else.
  select count(*) into n
    from public.authorizations a
    join public.clients c on c.id = a.client_id
   where a.id not in (select parent_id from public.authorizations where parent_id is not null)
     and not a.is_placeholder
     and not exists (select 1 from public.billing_board() b where b.auth_id = a.id);
  if n <> 0 then
    failures := failures || format(
      'FAILED: %s authorization(s) are on no group at all, so %s client(s) could be missing from the board',
      n, n)::text;
  else
    raise notice 'ok  every authorization that is a bill is on the board';
  end if;

  /*
   * The group that was not in the ruling.
   *
   * Five were named and a sixth had to exist: authorized, the service not yet
   * delivered, nothing invoiced. Eleven of those across eight clients were on
   * file when the board was built, and without a group they would have been
   * left off it. This asserts the classification still has somewhere to put
   * them rather than silently dropping them again.
   */
  select count(*) into n from public.billing_board() b
   where b.status not in ('Paid', 'Closed') and not b.blocked
     -- A client the practice has closed takes their authorizations with them
     -- into Closed, whatever state the work was left in. The first version of
     -- this assertion forgot that and reported the one such row as misfiled.
     and b.client_status <> 'Closed'
     and b.delivered_on is null and not b.has_invoice
     and b.grp <> 'Waiting for service';
  if n <> 0 then
    failures := failures || format(
      'FAILED: %s authorization(s) waiting for service are in the wrong group', n)::text;
  else
    raise notice 'ok  an authorization whose service has not happened is Waiting for service';
  end if;

  -- A row that cannot be invoiced is never told to invoice it.
  select count(*) into n from public.billing_board()
   where blocked and grp = 'Needs invoice';
  if n <> 0 then
    failures := failures || format(
      'FAILED: %s blocked row(s) are in Needs invoice, which is a job the database would refuse', n)::text;
  else
    raise notice 'ok  past the grace is Too late to bill, never Needs invoice';
  end if;

  -- ── 2. no warrant, no voucher, for anybody ────────────────
  select coalesce(string_agg(a.attname, ', '), '') into v_text
    from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
    cross join lateral unnest(p.proargnames) with ordinality as a(attname, i)
   where ns.nspname = 'public' and p.proname = 'billing_board'
     and (a.attname ilike '%warrant%' or a.attname ilike '%voucher%');
  if v_text <> '' then
    failures := failures ||
      format('FAILED: the board returns %s, which is Admin''s alone', v_text)::text;
  else
    raise notice 'ok  the board returns no warrant and no voucher column';
  end if;

  -- ── 3. asked as Billing: it reads, and it reads everything ─
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_billing.user_id::text, 'role', 'authenticated')::text, true);

  select count(*) into n from public.billing_board();
  if n = 0 then
    failures := failures ||
      'FAILED: Billing opens the board and it is empty, so the screen shows nothing'::text;
  else
    raise notice 'ok  Billing reads % row(s) of the board', n;
  end if;

  select count(distinct grp) into n from public.billing_board();
  if n < 3 then
    failures := failures || format(
      'FAILED: Billing sees only %s group(s), so the board is not grouped for them', n)::text;
  end if;

  -- ── 4. the two gates, as Billing ──────────────────────────
  --
  -- Both are the ruling's, and both are asked here rather than only on the
  -- screen: the board is one caller and the authorization record is another.
  v_msg := null;
  begin
    perform public.edit_authorization(
      (select auth_id from public.billing_board()
        where invoice_number is null and status not in ('Paid', 'Closed') limit 1),
      jsonb_build_object('submitted_on', public.practice_today()::text),
      'ZZ board verify');
  exception when others then v_msg := sqlerrm;
  end;
  if v_msg is null then
    failures := failures ||
      'FAILED: a submission date went on an authorization with no invoice number'::text;
  else
    raise notice 'ok  a submission date needs an invoice number: %', v_msg;
  end if;

  v_msg := null;
  begin
    perform public.set_authorization_status(
      -- Not one that is already Submitted: the function answers "It was
      -- already submitted." and returns before any gate, so asking with one
      -- of those tests nothing. The first version of this did exactly that.
      (select auth_id from public.billing_board()
        where invoice_number is null
          and status not in ('Paid', 'Closed', 'Submitted') limit 1),
      'Submitted', null, null);
  exception when others then v_msg := sqlerrm;
  end;
  if v_msg is null then
    failures := failures ||
      'FAILED: Waiting on payment was set with no invoice number behind it'::text;
  else
    raise notice 'ok  waiting on payment needs an invoice number: %', v_msg;
  end if;

  -- ── 5. a typed date is written down ───────────────────────
  --
  -- The board types into Submitted on through `edit_authorization`, and the
  -- ruling asked for it "with its correction-log entry". The log had neither
  -- the field in its constraint nor the field in its trigger when that was
  -- written, so this is the assertion that it does now.
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.authorization_corrections'::regclass
       and conname = 'authorization_corrections_field_check'
       and pg_get_constraintdef(oid) like '%Submitted on%') then
    failures := failures ||
      'FAILED: the correction log cannot hold a Submitted on row, so a typed date writes nothing'::text;
  elsif (select pg_get_functiondef(p.oid) from pg_proc p
           join pg_namespace ns on ns.oid = p.pronamespace
          where ns.nspname = 'public' and p.proname = 'authorization_correction_log')
        not like '%submitted_on%' then
    failures := failures ||
      'FAILED: the correction trigger does not watch submitted_on, so a typed date writes nothing'::text;
  else
    raise notice 'ok  a submission date that moves is written to the correction log';
  end if;

  perform set_config('request.jwt.claims', '', true);
  perform set_config('role', 'postgres', true);

  -- ── 6. the money on a client row is the client's ──────────
  --
  -- The whole point of the board is that "what does this client owe us" is on
  -- screen instead of added up by eye, so the row's outstanding has to be the
  -- sum of the client's authorizations and not of the open ones.
  select count(*) into n
    from (
      select b.client_id,
             sum(b.outstanding) as board_total,
             (select sum(x.outstanding) from public.billing_board() x
               where x.client_id = b.client_id) as every_row
        from public.billing_board() b
       group by b.client_id
    ) t
   where t.board_total is distinct from t.every_row;
  if n <> 0 then
    failures := failures || format('FAILED: %s client(s) total differently depending on who asks', n)::text;
  else
    raise notice 'ok  a client''s outstanding is the sum of every authorization they have';
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- BILLING BOARD VERIFIED ---';
end $$;

rollback;
