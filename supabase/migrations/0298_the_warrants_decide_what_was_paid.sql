-- Zion Vocational Rehab CRM — Phase 2 of the warrant reconciliation, part one
--
-- Rulings 1 and 2 of the owner's instruction of 6 November 2026, after the
-- Phase 1 report. The warrant is the truth; where the CRM disagreed on
-- whether money arrived, the warrant wins.
--
-- ── what was wrong ────────────────────────────────────────────
--
-- Warrant F15658189 was recorded twice. Three payments were entered by hand
-- on 20 October with the warrant number typed without its F and no voucher,
-- and the warrant import read the same page on 5 November and inserted the
-- same three again with the right number and the right vouchers. Nothing
-- refused the second set, because to the import the hand-entered rows did not
-- look like the same money - no voucher to match on, and a warrant number
-- that is not the warrant's number.
--
-- V1028879 was worse: three payments of $585 where the warrants pay it once,
-- and one of the three carried voucher 27AW00000091193, which on warrant
-- F15617525 belongs to V1028161 for $560.
--
-- And two payments the state made were not on the record at all, because the
-- import would not take them: V1028168 was Closed and V1041336 was Due, and
-- record_payment accepts neither. Its own refusal said so in as many words -
-- "has not been submitted (it is closed), so there is nothing waiting to be
-- paid". That rule is being changed under item 3a; this file does not change
-- it, it records the two payments the warrants prove arrived.
--
-- ── how, and in whose name ────────────────────────────────────
--
-- Through remove_payment and record_payment rather than against the tables,
-- so every change takes the path a person takes: the correction log entry,
-- the warrant line going back to needing review, the authorization total
-- recomputed from its payments by the trigger that owns that number.
--
-- Those functions require a staff identity, and rightly - "A correction has
-- to say who made it". The identity used is the Admin who ordered the
-- corrections, and each reason names this exercise so the log reads as what
-- it was rather than as somebody tidying up.
--
-- Every row is found by what makes it wrong rather than by its id, so if the
-- data is not what the report said it was, this file stops instead of
-- removing something else.

begin;

do $$
declare
  v_admin   uuid;
  v_uid     uuid;
  v_ids     uuid[];
  v_id      uuid;
  v_auth    uuid;
  v_n       integer;
  v_total   numeric;
  v_count   integer;
  v_reason  text;
begin
  -- ── who is making the correction ───────────────────────────
  select id, user_id into v_admin, v_uid
    from public.staff where role = 'Admin' and active and not is_system
   order by created_at limit 1;
  if v_admin is null or v_uid is null then
    raise exception 'no active Admin with a sign-in, so there is nobody these corrections could be made by';
  end if;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);

  -- ── 1. warrant F15658189, recorded twice ───────────────────
  --
  -- The hand-entered three go and the imported three stay, because the
  -- imported ones carry the warrant number the warrant actually has and the
  -- voucher for each line. Keyed on that malformed number, which is the
  -- thing that made them invisible to the import in the first place.
  v_reason := 'Phase 2 of the warrant reconciliation, on the owner''s ruling of 6 November 2026. '
           || 'Warrant F15658189 was recorded twice: by hand on 20 October with the warrant number '
           || 'typed without its F and no voucher, and again by the import on 5 November with both '
           || 'right. This is the hand-entered copy; the imported one stands.';

  select array_agg(p.id) into v_ids
    from public.payments p
   where p.source = 'By hand' and p.warrant_no = '15658189';

  if coalesce(array_length(v_ids, 1), 0) <> 3 then
    raise exception 'expected 3 payments on the malformed warrant number 15658189, found %',
      coalesce(array_length(v_ids, 1), 0);
  end if;

  foreach v_id in array v_ids loop
    perform public.remove_payment(v_id, v_reason);
  end loop;
  raise notice 'ok  3 hand-entered copies of warrant F15658189 taken back';

  -- ── 1b. the third copy, wearing another authorization''s voucher ──
  select p.id into v_id
    from public.payments p join public.authorizations a on a.id = p.auth_id
   where a.number = 'V1028879' and p.warrant_no = 'F15617525'
     and p.voucher = '27AW00000091193';
  if v_id is null then
    raise exception 'the V1028879 payment carrying voucher 27AW00000091193 is not where the report found it';
  end if;

  perform public.remove_payment(v_id,
    'Phase 2 of the warrant reconciliation, on the owner''s ruling of 6 November 2026. '
    || 'A third copy of the same $585. It was dated 7 September on warrant F15617525 and carried '
    || 'voucher 27AW00000091193, which on that warrant belongs to V1028161 for $560. The warrants '
    || 'pay V1028879 once, on F15658189.');
  raise notice 'ok  the third copy of V1028879, carrying V1028161''s voucher, taken back';

  -- V1028879 is now what the warrant says it is, and that is asserted rather
  -- than assumed: the whole point of the ruling was one payment of 585.
  select count(*), coalesce(sum(p.amount), 0) into v_count, v_total
    from public.payments p join public.authorizations a on a.id = p.auth_id
   where a.number = 'V1028879';
  if v_count <> 1 or v_total <> 585.00 then
    raise exception 'V1028879 has % payment(s) totalling %, and the warrant pays it once for 585.00',
      v_count, v_total;
  end if;
  raise notice 'ok  V1028879 holds one payment of 585.00, which is what warrant F15658189 pays it';

  -- ── 2. the two payments the state made and the CRM never held ──
  --
  -- V1028168: $450 on 7 September, warrant F15617525, voucher
  -- 27AW00000091153, Zion invoice 950948. The CRM had it Closed, so it has to
  -- be reopened first - which is Admin''s, and the state machine says so.
  select id, status into v_auth, v_reason from public.authorizations where number = 'V1028168';
  if v_auth is null then
    raise exception 'V1028168 is not on file';
  end if;
  if v_reason <> 'Closed' then
    raise notice 'note  V1028168 is % rather than closed; reopening is skipped', lower(v_reason);
  else
    perform public.set_authorization_status(v_auth, 'Due',
      'Reopened on the owner''s ruling of 6 November 2026: warrant F15617525 paid it $450.00 on '
      || '7 September 2026, voucher 27AW00000091153, Zion invoice 950948. It was closed as unbilled '
      || 'and it was not - it was billed and paid.');
    raise notice 'ok  V1028168 reopened from closed, with the warrant named';
  end if;

  perform public.record_payment(v_auth, date '2026-09-07', 450.00, 'F15617525', '27AW00000091153');
  raise notice 'ok  V1028168 paid 450.00 on warrant F15617525';

  -- V1041336: $900 on 29 September, warrant F15640774, voucher
  -- 27AW00000093151, Zion invoice 953122. Due, which record_payment accepts.
  select id, status into v_auth, v_reason from public.authorizations where number = 'V1041336';
  if v_auth is null then
    raise exception 'V1041336 is not on file';
  end if;
  perform public.record_payment(v_auth, date '2026-09-29', 900.00, 'F15640774', '27AW00000093151');
  raise notice 'ok  V1041336 paid 900.00 on warrant F15640774';

  -- ── the two things on Margaret''s list ──────────────────────
  --
  -- Closed with the answer rather than just ticked. "Find the warrant for
  -- V1041336" has an answer now and it belongs where the question was asked;
  -- a task that disappears without one is a question somebody asks again.
  for v_id, v_reason in
    select t.id,
           case
             when t.title like 'Find the warrant for V1041336%' then
               'Found: warrant F15640774, 29 September 2026, $900.00, voucher 27AW00000093151, '
               || 'Zion invoice 953122. The payment is on the record now. It was missing because '
               || 'the authorization was still Due, and the warrant import will not pay an '
               || 'authorization that has not been submitted.'
             else
               'Answered: it was not paid twice by USOR, it was recorded three times here. '
               || 'Warrant F15658189 pays V1028879 once, for $585.00. The two extra copies have '
               || 'been taken back and the correction log has both. Nothing to raise with USOR.'
           end
      from public.tasks t
     where t.status = 'Open'
       and (t.title like 'Find the warrant for V1041336%'
         or t.title like 'Ask USOR about V1028879%')
  loop
    insert into public.task_comments (task_id, staff_id, staff_name, said)
    select v_id, v_admin, s.name, v_reason from public.staff s where s.id = v_admin;
    update public.tasks set status = 'Done', done_at = now() where id = v_id;
    v_n := coalesce(v_n, 0) + 1;
  end loop;
  raise notice 'ok  % task(s) closed with the answer written on them', coalesce(v_n, 0);

  -- And the notifications behind them, which are a separate row and would
  -- otherwise keep the same question on the dashboard after the task has gone.
  update public.notifications
     set resolved_at = now()
   where resolved_at is null
     and (dedupe_key like '%:paid-over' or text like '%V1041336%' or text like '%V1028879%');
  raise notice 'ok  the notifications behind those tasks resolved';

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
end $$;

-- ── the warrant lines behind all of this ─────────────────────
--
-- The fourth copy was never a copy. Its line, as the OCR read it, has a
-- letter O where the voucher has a zero, a letter l inside the V-number, the
-- amount read as 585.00 where the warrant says 450.00, and the reference read
-- as V1028161 where the line is V1028168. Somebody then resolved it by hand
-- onto V1028879 for $585 - a different client's authorization - and that is
-- the whole story of the third $585. It is an OCR failure that a hand
-- resolution carried the rest of the way.
--
-- So the lines are brought to the truth too: the clean copy of each line
-- points at the payment just recorded, and the other copies of the same line
-- say so in the words the import itself uses, including the badly-read one.
-- Leaving that one at "needs review" would leave a line nobody can resolve,
-- because what it needs is not a decision but the right reading.
do $$
declare
  r         record;
  v_payment uuid;
  v_best    uuid;
  v_n       integer := 0;
begin
  for r in
    select a.number, a.id as auth_id, l.amount
      from (values ('V1028168', 450.00), ('V1041336', 900.00)) as l(number, amount)
      join public.authorizations a on a.number = l.number
  loop
    select p.id into v_payment
      from public.payments p
     where p.auth_id = r.auth_id and p.amount = r.amount
     order by p.created_at desc limit 1;
    if v_payment is null then
      raise exception 'no payment of % on % to point its warrant line at', r.amount, r.number;
    end if;

    -- The clean copy: the one whose own reading agrees with the amount the
    -- warrant pays. Where several copies agree, the earliest page wins.
    select wl.id into v_best
      from public.warrant_lines wl
     where wl.described_ref = r.number and wl.amount = r.amount
     order by wl.page_id limit 1;
    if v_best is null then
      raise exception 'no warrant line for % at % to reconcile', r.number, r.amount;
    end if;

    update public.warrant_lines
       set payment_id = v_payment, status = 'Reconciled', problem = '', auth_id = r.auth_id
     where id = v_best;

    update public.warrant_lines
       set payment_id = v_payment, status = 'Already recorded', auth_id = r.auth_id,
           problem = format('Already recorded from another copy of this warrant line for %s.', r.number)
     where id <> v_best
       and (described_ref = r.number or raw like '%' || r.number || '%'
            or raw like '%' || replace(r.number, 'V1', 'V1l') || '%')
       and coalesce(payment_id, v_payment) = v_payment;

    v_n := v_n + 1;
  end loop;
  raise notice 'ok  % warrant line(s) reconciled against the payment just recorded, their copies marked', v_n;
end $$;

-- ── where the money now stands ───────────────────────────────
--
-- Said as arithmetic rather than as a feeling. After this file the ledger is
-- the warrant index exactly, plus one payment the owner has not ruled on:
-- V999364 for $560 with no warrant number at all, which appears nowhere in
-- the index. It is left alone deliberately - it was not in the ruling, and
-- taking a payment back is not something to do on an inference.
do $$
declare
  v_count integer;
  v_total numeric;
begin
  select count(*), coalesce(sum(amount), 0) into v_count, v_total from public.payments;
  raise notice 'ok  % payments, %', v_count, to_char(v_total, 'FM999999.00');
  if v_total <> 160562.50 then
    raise exception 'the ledger comes to % and the warrants plus the one unruled payment come to 160562.50',
      to_char(v_total, 'FM999999.00');
  end if;
  raise notice 'ok  160562.50 is the warrant index (160002.50) plus V999364 (560.00), which was not in the ruling';
end $$;

commit;
