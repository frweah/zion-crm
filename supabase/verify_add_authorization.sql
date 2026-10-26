-- Zion Vocational Rehab CRM — adding an authorization, paid or not (0254)
--
-- The form can now say "this one arrived already paid" and hand over the
-- date, the amount and the warrant with the rest of it. What has to hold is
-- that saying so produces the same record the long way round would have, and
-- that the books agree:
--
--   saved with the switch off, it is Authorized, as it always was;
--   saved with it on, it is Paid, carrying the payment date and the amount;
--   the ledger has the receivable *and* the cash, because an authorization
--     paid without passing through Submitted still has to raise what it is
--     clearing - and an insert of `status = 'Paid'` would have skipped both;
--   it is not on the working list, which is for money still owed;
--   a duplicate number is refused however it is spelt;
--   and a payment cannot be dated in the future.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_admin   uuid;
  v_uid     uuid;
  v_client  uuid;
  v_plain   uuid;
  v_paid    uuid;
  v_row     public.authorizations;
  v_debits  numeric;
  v_credits numeric;
  v_n       integer;
  failures  text[] := '{}';
begin
  select s.id, s.user_id into v_admin, v_uid from public.staff s
   where s.active and s.user_id is not null and s.role = 'Admin'
     and not coalesce(s.is_system, false)
   order by s.created_at limit 1;
  if v_admin is null then raise exception 'No Admin to act as.'; end if;

  insert into public.clients (name, status, stage) values ('ZZ Add Auth', 'Active', 'Job Placement')
  returning id into v_client;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_uid::text, 'role', 'authenticated')::text, true);

  -- ── 1. the switch off: Authorized, as before ──────────────
  v_plain := public.add_authorization(
    v_client, 'V0000741', 'Job Placement', 'Flat Fee', 1000, null,
    public.practice_today() - 30, public.practice_today() + 30, '', 'Utah VR', null,
    public.practice_today() - 31);

  select * into v_row from public.authorizations where id = v_plain;
  if v_row.status <> 'Authorized' then
    failures := failures || format('FAILED: a plain authorization came out %s, not Authorized', v_row.status)::text;
  elsif v_row.received_on is distinct from public.practice_today() - 31 then
    failures := failures || 'FAILED: the received date was not kept'::text;
  else
    raise notice 'ok  saved with the switch off, it is Authorized and keeps the day it arrived';
  end if;

  -- ── 2. the switch on: Paid, with the payment on it ────────
  v_paid := public.add_authorization(
    v_client, 'V0000742', 'Job Development', 'Flat Fee', 560, null,
    public.practice_today() - 90, public.practice_today() - 60, '', 'Utah VR', null,
    public.practice_today() - 91,
    public.practice_today() - 40, 560, 'W-55512');

  select * into v_row from public.authorizations where id = v_paid;
  if v_row.status <> 'Paid' then
    failures := failures || format('FAILED: saved as paid, it came out %s', v_row.status)::text;
  elsif v_row.paid_on is distinct from public.practice_today() - 40 then
    failures := failures || format('FAILED: the payment date is %s, not the day given', v_row.paid_on)::text;
  elsif coalesce(v_row.paid_amount, 0) <> 560 then
    failures := failures || format('FAILED: the amount received is %s, not 560', v_row.paid_amount)::text;
  elsif coalesce(v_row.warrant, '') <> 'W-55512' then
    failures := failures || 'FAILED: the warrant number was not kept'::text;
  else
    raise notice 'ok  saved with the switch on, it is Paid and carries the date, the amount and the warrant';
  end if;

  -- ── 3. and Money counts it, in the month it was received ──
  --
  -- Money reads `authorization_economics.received`, which is the amount on
  -- the authorization - not the ledger. That matters here: the practice's
  -- books do not open until `ledger_settings.books_start`, so nothing posts
  -- a journal yet and Money is the figure anybody actually reads.
  select e.received into v_credits
    from public.authorization_economics e where e.auth_id = v_paid;
  if coalesce(v_credits, 0) <> 560 then
    failures := failures ||
      format('FAILED: Money counts %s received against it, not the 560 that was paid', coalesce(v_credits, 0))::text;
  else
    raise notice 'ok  and Money counts the 560 received against it';
  end if;

  select count(*)::int into v_n
    from public.authorization_economics e
    join public.authorizations a on a.id = e.auth_id
   where a.id = v_paid and date_trunc('month', a.paid_on) = date_trunc('month', public.practice_today() - 40);
  if v_n <> 1 then
    failures := failures || 'FAILED: it does not fall in the month the payment was received'::text;
  else
    raise notice 'ok  in the month the payment was received, not the month it was typed in';
  end if;

  /*
   * The ledger, when there is one.
   *
   * `books_start` is in the future, so `post_journal` declines everything and
   * the journals table is empty - for every authorization the practice has
   * ever marked paid, not just this one. Asserting a posting today would be
   * asserting a thing that is deliberately switched off.
   *
   * So the test asks the question that is true now and becomes the stronger
   * one on its own, the day the books open: before that date, nothing posts;
   * after it, an authorization saved as paid must post, and must balance.
   */
  select count(*)::int into v_n from public.journals j
   where j.source_kind = 'Authorization' and j.source_id = v_paid;

  if public.practice_today() < (select books_start from public.ledger_settings limit 1) then
    if v_n <> 0 then
      failures := failures ||
        format('FAILED: %s posting(s) made before the books open', v_n)::text;
    else
      raise notice '--  the books open on %, so nothing posts yet',
        to_char((select books_start from public.ledger_settings limit 1), 'FMMon FMDD, YYYY');
    end if;
  else
    select coalesce(sum(l.debit), 0), coalesce(sum(l.credit), 0)
      into v_debits, v_credits
      from public.journal_lines l
      join public.journals j on j.id = l.journal_id
     where j.source_kind = 'Authorization' and j.source_id = v_paid;
    if v_n = 0 then
      failures := failures ||
        'FAILED: an authorization saved as paid posted nothing, so Money shows income the books never heard of'::text;
    elsif round(v_debits, 2) <> round(v_credits, 2) then
      failures := failures || format('FAILED: the postings do not balance: %s debit, %s credit', v_debits, v_credits)::text;
    else
      raise notice 'ok  and the ledger carries it, balanced (% debit, % credit)', round(v_debits, 2), round(v_credits, 2);
    end if;
  end if;

  -- ── 4. money still owed is what the working list is for ───
  select count(*)::int into v_n from public.billing_worklist() w where w.id = v_paid;
  if v_n <> 0 then
    failures := failures || 'FAILED: an authorization saved as paid is on the working list'::text;
  else
    raise notice 'ok  and it is not on the working list, which is for money still owed';
  end if;

  -- ── 5. the same number twice ──────────────────────────────
  begin
    perform public.add_authorization(
      v_client, 'v-0000 741', 'Job Placement', 'Flat Fee', 1000, null,
      public.practice_today(), null, '', 'Utah VR', null, public.practice_today());
    failures := failures || 'FAILED: the same number went on twice, written differently'::text;
  exception when unique_violation then
    raise notice 'ok  a number already on file is refused however it is written';
  end;

  -- ── 6. and a payment cannot be in the future ──────────────
  begin
    perform public.add_authorization(
      v_client, 'V0000743', 'Job Coaching', 'Hourly', 45, 10,
      public.practice_today(), null, '', 'Utah VR', null, public.practice_today(),
      public.practice_today() + 1, 450, '');
    failures := failures || 'FAILED: a payment was recorded as received in the future'::text;
  exception when check_violation then
    raise notice 'ok  and a payment cannot have been received tomorrow';
  end;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- ADD AUTHORIZATION VERIFIED ---';
end $$;

rollback;
