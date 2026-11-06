-- Zion Vocational Rehab CRM — Phase 2 of the warrant reconciliation, part two
--
-- Ruling 4 of the owner's instruction of 6 November 2026: fold the lettered
-- authorizations back into the real ones, and put the letter where it belongs.
--
-- ── what the letter is ────────────────────────────────────────
--
-- The warrant index says it in one line: "The Billing column holds the letter
-- the state adds to the authorization on repeat claims: V1021825A and
-- V1021825B are the first and second claims billed against authorization
-- V1021825."
--
-- So the letter is a claim sequence. The CRM had read it as part of the
-- number and made a separate authorization of each claim - thirty of them,
-- across fourteen real authorizations, and not one of the fourteen base
-- numbers existed in the CRM at all. There was no V991262; there were
-- V991262A, V991262B and V991262C, each with its own slice of the hours.
--
-- (The Phase 1 report said thirteen. It is fourteen: V987000, V991262,
-- V996569, V999069, V999510, V1002111, V1002962, V1005727, V1007417,
-- V1009255, V1018375, V1021815, V1021825, V1037306. Four of those have a
-- single lettered row, so for them this file is a rename and nothing else.)
--
-- ── what folding means for the figures ────────────────────────
--
-- The hours add up. Every one of the ten hourly bases has claims whose hours
-- times the rate come to exactly what the state paid - V1002111 is 12 + 20 +
-- 17 + 20 hours at $45, which is $3,105, which is 540 + 900 + 765 + 900. So
-- the folded authorization's ceiling is the sum of its claims' hours, and
-- that is not a guess: it is what the thirty rows already assert between them.
--
-- V1021825 is the one flat-fee base with two claims, $450 each. Its folded
-- rate is $900, under the owner's own rule for anything taken from a warrant:
-- the amount is the total paid, and the authorization document is not on file
-- to say otherwise. The correction log says as much.
--
-- V996569 is the one mixed base: two hourly claims and a third, claim C, for
-- $250 at a flat rate under the same V-number. Its ceiling is the two hourly
-- claims; claim C sits on its payment, where the ruling puts it, and the
-- correction log says the hours do not account for it. Nothing is invented to
-- make the arithmetic close.
--
-- ── how ──────────────────────────────────────────────────────
--
-- The keeper of each base is the row carrying correction-log entries, because
-- those cannot be moved: authorization_corrections is append-only against both
-- UPDATE and DELETE, so a correction can neither follow its authorization nor
-- be cascaded away with it. Where no row has any, the first letter keeps the
-- base. This is the staff-change-log lesson in a different table - the log
-- decides what may be deleted, not the other way round.
--
-- The correction log for each fold writes itself. authorizations_correction_log
-- demands a reason for a change to the number, the hours or the rate, and
-- refuses the update without one, so the reason is set first and the log entry
-- is the trigger's own work rather than a second thing to remember.
--
-- Both totals assertions on payments and authorizations are deferred
-- constraint triggers, so the intermediate states while payments move are
-- allowed and the end state is what is checked - at commit, by the database.

begin;

-- ── the claim sequence, on the payment ───────────────────────
alter table public.payments
  add column if not exists claim text;

comment on column public.payments.claim is
  'The letter the state adds to the authorization number on a repeat claim: A '
  'is the first claim billed against that authorization, B the second. Null '
  'where the state gave none, which is most of them.';

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'payments_claim_is_a_letter') then
    alter table public.payments
      add constraint payments_claim_is_a_letter
      check (claim is null or claim ~ '^[A-Z]$');
  end if;
end $$;

-- ── which letter each payment was billed under, before anything moves ──
--
-- Written down first, and from the only place that knows: the authorization
-- number the payment is attached to right now. Every payment is stamped from
-- it in one statement before a single row is moved, so no later step can
-- stamp the keeper's letter onto a claim that was not the keeper's.
--
-- That is not a precaution in the abstract. The check first written here
-- counted how many payments carried a letter, and a fault that gave sixteen
-- of them the wrong letter passed it - because a later statement filled in
-- whatever was still null with the keeper's own letter. A count near the rule
-- is not the rule. The snapshot below is what the end state is measured
-- against, row by row.
create temp table claim_was (payment_id uuid primary key, letter text not null) on commit drop;

insert into claim_was (payment_id, letter)
select p.id, right(a.number, 1)
  from public.payments p join public.authorizations a on a.id = p.auth_id
 where a.number ~ '^V[0-9]+[A-Z]$';

update public.payments p
   set claim = w.letter
  from claim_was w
 where w.payment_id = p.id;

do $$
declare
  v_admin   uuid;
  v_uid     uuid;
  r         record;
  o         record;
  v_keeper  uuid;
  v_hours   numeric;
  v_flat    numeric;
  v_start   date;
  v_end     date;
  v_rate    numeric;
  v_type    text;
  v_claims  integer;
  v_reason  text;
  v_folded  integer := 0;
  v_gone    integer := 0;
  v_flatpaid numeric;
begin
  select id, user_id into v_admin, v_uid
    from public.staff where role = 'Admin' and active and not is_system
   order by created_at limit 1;
  if v_admin is null or v_uid is null then
    raise exception 'no active Admin with a sign-in, so there is nobody these corrections could be made by';
  end if;

  /*
   * The claims are set and the role is not.
   *
   * This file moves rows rather than calling the functions a person calls, and
   * `authenticated` is granted no UPDATE on payments - by design, since every
   * write a person makes goes through a definer function. So it runs with the
   * migration's own privileges and sets only the claims, which is all
   * current_staff_id() reads: the work is the schema owner's, the name against
   * every correction is the Admin who ordered it.
   */
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);

  for r in
    select regexp_replace(number, '[A-Z]$', '') as base, count(*) as rows
      from public.authorizations
     where number ~ '^V[0-9]+[A-Z]$'
     group by 1 order by 1
  loop
    -- The keeper: whoever holds history that cannot move.
    select a.id into v_keeper
      from public.authorizations a
     where a.number ~ ('^' || r.base || '[A-Z]$')
       and exists (select 1 from public.authorization_corrections c where c.auth_id = a.id)
     order by a.number limit 1;

    if v_keeper is null then
      select a.id into v_keeper
        from public.authorizations a
       where a.number ~ ('^' || r.base || '[A-Z]$')
       order by a.number limit 1;
    end if;

    -- What the claims say between them.
    select sum(case when a.rate_type = 'Hourly' then a.total_hours end),
           sum(case when a.rate_type = 'Flat Fee' then a.rate end),
           min(a.start_date), max(a.end_date),
           count(*) filter (where a.rate_type = 'Flat Fee')
      into v_hours, v_flat, v_start, v_end, v_claims
      from public.authorizations a
     where a.number ~ ('^' || r.base || '[A-Z]$');

    select rate_type, rate into v_type, v_rate
      from public.authorizations where id = v_keeper;

    -- Every other row's payments come across, each carrying its letter, and
    -- everything else attached to it follows before the row goes.
    for o in
      select a.id, a.number, right(a.number, 1) as letter
        from public.authorizations a
       where a.number ~ ('^' || r.base || '[A-Z]$') and a.id <> v_keeper
       order by a.number
    loop
      update public.payments set auth_id = v_keeper where auth_id = o.id;
      update public.authorization_events set auth_id = v_keeper where auth_id = o.id;
      update public.attachments set auth_id = v_keeper where auth_id = o.id;
      update public.service_entries set auth_id = v_keeper where auth_id = o.id;
      update public.forms set auth_id = v_keeper where auth_id = o.id;
      update public.warrant_lines set auth_id = v_keeper where auth_id = o.id;

      -- A completion row with nothing in it is a shell the trigger made when
      -- the authorization was entered; it goes with the row. One with a date,
      -- a note or a billed mark is somebody's work and comes across.
      delete from public.completions
       where auth_id = o.id and completion is null and coalesce(btrim(notes), '') = '' and not billed;
      update public.completions set auth_id = v_keeper where auth_id = o.id;

      delete from public.authorizations where id = o.id;
      v_gone := v_gone + 1;
    end loop;

    v_reason := format(
      'Phase 2 of the warrant reconciliation, on the owner''s ruling of 6 November 2026. '
      || 'The Billing letter is the claim sequence the state adds on a repeat claim, not part of '
      || 'the authorization number, so %s claim(s) billed against %s are folded back into it and '
      || 'each letter now sits on its own payment. ',
      r.rows, r.base);

    if v_hours is not null then
      v_reason := v_reason || format(
        'The authorized hours are the sum of the claims'' own: %s. ', to_char(v_hours, 'FM999990.99'));
    end if;
    if v_claims > 1 then
      v_reason := v_reason || format(
        'Flat fee %s is %s claims at the rate each row carried; the authorization document is not '
        || 'on file to say what was authorized in one line. ',
        to_char(v_flat, 'FM999999.00'), v_claims);
    end if;
    if v_hours is not null and v_flat is not null then
      select coalesce(sum(p.amount), 0) into v_flatpaid
        from public.payments p join public.authorizations a on a.id = p.auth_id
       where a.number ~ ('^' || r.base || '[A-Z]$') and a.rate_type = 'Flat Fee';
      v_reason := v_reason || format(
        'One claim was billed flat under the same number rather than by the hour, and was paid %s. '
        || 'The hours above do not account for it, and nothing has been invented to make them. ',
        to_char(v_flatpaid, 'FM999999.00'));
    end if;

    perform set_config('zion.correction_reason', v_reason, true);

    update public.authorizations
       set number      = r.base,
           total_hours = coalesce(v_hours, total_hours),
           rate        = case when v_type = 'Flat Fee' and v_claims > 1 then v_flat else v_rate end,
           start_date  = coalesce(v_start, start_date),
           end_date    = coalesce(v_end, end_date)
     where id = v_keeper;

    perform set_config('zion.correction_reason', '', true);
    v_folded := v_folded + 1;
  end loop;

  raise notice 'ok  % base authorization(s) now exist, % lettered row(s) gone', v_folded, v_gone;

  perform set_config('request.jwt.claims', '', true);
end $$;

-- ── and it is checked rather than announced ──────────────────
do $$
declare
  v_left    integer;
  v_count   integer;
  v_total   numeric;
  v_claimed integer;
  v_wrong   text;
begin
  select count(*) into v_left from public.authorizations where number ~ '^V[0-9]+[A-Z]$';
  if v_left <> 0 then
    raise exception '% lettered authorization(s) are still on file', v_left;
  end if;
  raise notice 'ok  no authorization number ends in a letter any more';

  select count(*), coalesce(sum(amount), 0) into v_count, v_total from public.payments;
  if v_count <> 157 or v_total <> 160562.50 then
    raise exception 'the ledger moved: % payments, % - it was 157 and 160562.50 before the fold',
      v_count, to_char(v_total, 'FM999999.00');
  end if;
  raise notice 'ok  157 payments, 160562.50 - the fold moved money between rows and not out of the ledger';

  select count(*) into v_claimed from claim_was;
  if v_claimed <> 30 then
    raise exception 'the snapshot holds % payments and thirty claims were folded', v_claimed;
  end if;

  select string_agg(w.payment_id::text || ' should be ' || w.letter || ' and is '
                    || coalesce(p.claim, 'nothing'), ', ')
    into v_wrong
    from claim_was w join public.payments p on p.id = w.payment_id
   where p.claim is distinct from w.letter;
  if v_wrong is not null then
    raise exception 'a payment carries the wrong claim letter: %', v_wrong;
  end if;

  if exists (select 1 from public.payments p where p.claim is not null
               and not exists (select 1 from claim_was w where w.payment_id = p.id)) then
    raise exception 'a payment that was never a lettered claim has been given a letter';
  end if;
  raise notice 'ok  all 30 payments carry the letter their own claim was billed under, and no others carry one';

  -- Every base now holds the payments its claims held, which is the only
  -- thing a fold could get wrong without the totals noticing.
  select string_agg(number || ' ' || paid_amount::text || ' vs ' || s::text, ', ')
    into v_wrong
    from (select a.number, a.paid_amount,
                 (select coalesce(sum(p.amount), 0) from public.payments p where p.auth_id = a.id) as s
            from public.authorizations a
           where a.number in ('V987000','V991262','V996569','V999069','V999510','V1002111',
                              'V1002962','V1005727','V1007417','V1009255','V1018375',
                              'V1021815','V1021825','V1037306')) q
   where paid_amount is distinct from s;
  if v_wrong is not null then
    raise exception 'a folded authorization disagrees with its payments: %', v_wrong;
  end if;
  raise notice 'ok  all 14 folded authorizations agree with the payments they now hold';
end $$;

commit;
