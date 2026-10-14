-- Zion Vocational Rehab CRM — billing stops being a one-way street
-- (owner, 14 Oct 2026: "Billing is too locked down.")
--
-- Everything billing could do ran forwards: Authorized, Due, Submitted,
-- Paid, and a reason required at each gate. That is the right shape for an
-- authorization being worked now, and the wrong shape for the queue the
-- practice actually has — 139 authorizations already paid, 16 sitting at Due
-- that were settled months ago, and no way to say so without pretending to
-- submit a packet that went out last spring.
--
-- Five things change. What does not change is at the bottom of the owner's
-- list and the top of this file: the ledger postings and the audit logs. A
-- correction posts a reversal and is written down. That is the whole reason
-- the rest of this is safe to open up.
--
-- ── 1. a payment can be recorded on anything that is owed ──
--
-- The state machine refused Due → Paid, so clearing an old item meant
-- stepping it through Submitted first. That is worse than it sounds: the
-- Submitted gate checks the service dates against the authorized period and
-- refuses anything more than the grace past its end date — which is exactly
-- the backlog. The gate is there to stop a packet being *sent* that USOR will
-- return. Recording money that already arrived sends nothing, so the gate has
-- no business standing in front of it.
--
-- So Due → Paid and Authorized → Paid are now legal moves, and
-- post_authorization raises the receivable before clearing it, so the ledger
-- sees the same two postings in the same order as the long way round. Nothing
-- posts today either way — the books open on 1 January 2027 and post_journal
-- returns null before then — but the wiring has to be right now, because by
-- the time it matters nobody will remember this was the shortcut.
--
-- ── 2. every field is editable, and a correction says why ──
--
-- correct_authorization handled two fields and only for an Admin. The rest
-- were editable in principle (RLS has let Billing write the table all along)
-- and nowhere in practice, because no screen offered them.
--
-- The reason is now asked for by the database at the moment the value moves,
-- not by the screen afterwards. And it is asked for on a *correction*, not on
-- a first entry: filling in a number that was blank is recording what the
-- paperwork says, while changing a number that was already there is a
-- correction and somebody will ask. That distinction is what keeps warrant
-- reconciliation working — it writes paid_amount where there was none.
--
-- ── 3. bulk clear ──
--
-- Ten rows, one received date. Each row is its own savepoint, so a row that
-- cannot be priced does not take the other nine down with it; the caller gets
-- a line per row saying what happened. Six of the 21 open authorizations have
-- no amount at all (hourly, no hours logged), and those are named rather than
-- guessed at.

-- ─────────────────────────────────────────────────────────────
-- Who may do this
--
-- The same test the authorizations table already uses, in one place so the
-- functions below cannot drift from the RLS policy or from each other.
-- ─────────────────────────────────────────────────────────────
create or replace function public.billing_hands()
returns boolean language sql stable set search_path = public as $$
  select public.current_staff_role() in ('Admin', 'Billing')
      or public.staff_has_area('billing', 'edit');
$$;

comment on function public.billing_hands is
  'Whether the signed-in person may change billing records. The same test authorizations_write uses, in one place.';

revoke all on function public.billing_hands() from anon, authenticated;
grant execute on function public.billing_hands() to authenticated;

-- ─────────────────────────────────────────────────────────────
-- 1a. Due and Authorized may go straight to Paid
--
-- 0160's function, with two moves added and the gates untouched. The gates
-- live inside `if new.status = 'Submitted'`, so a move that does not pass
-- through Submitted does not meet them — which is the point.
-- ─────────────────────────────────────────────────────────────
create or replace function public.authorization_transition()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_staff   uuid := public.current_staff_id();
  v_name    text;
  v_legal   boolean;
  v_missing text;
begin
  if tg_op = 'UPDATE' and new.status is distinct from old.status then
    -- Forward, or Closed, or the two ways reality goes backwards.
    v_legal := case
      when new.status = 'Closed' then true
      when old.status = 'Authorized' and new.status = 'Due' then true
      when old.status = 'Due' and new.status = 'Submitted' then true
      when old.status = 'Submitted' and new.status = 'Paid' then true
      /**
       * Paid without a submission of ours (owner, 14 Oct 2026).
       *
       * Money arrived for something the practice never formally submitted
       * through this system - the backlog, and every item billed before the
       * CRM existed. Refusing this is what made a queue of settled work
       * unclearable, and stepping it through Submitted to get around the
       * refusal would have meant lying about a packet going out.
       */
      when old.status in ('Due', 'Authorized') and new.status = 'Paid' then true
      -- Returned for correction: the submission did not stand.
      when old.status = 'Submitted' and new.status = 'Due' then true
      -- A payment undone, which the ledger reverses off this very move.
      when old.status = 'Paid' and new.status = 'Submitted' then true
      -- Reopened from Closed, which is Admin's doing and recorded below.
      when old.status = 'Closed' then true
      -- Due back to Authorized: somebody marked it due too early.
      when old.status = 'Due' and new.status = 'Authorized' then true
      else false
    end;

    if not v_legal then
      raise exception 'An authorization does not go from % to %', old.status, new.status
        using hint = 'Authorized, Due, Submitted, Paid, and Closed from any of them.',
              errcode = 'check_violation';
    end if;

    -- Reopening a closed authorization is Admin's.
    if old.status = 'Closed' and public.current_staff_role() is distinct from 'Admin' then
      raise exception 'Only an Admin reopens a closed authorization'
        using errcode = 'check_violation';
    end if;

    /**
     * What stops a submission, and what only warns (§4, owner 7 Oct).
     *
     * Hard: the work has to have happened inside the authorization's own
     * period. That is the rule USOR actually enforces, and billing work
     * done outside the authorized dates is the mistake that gets a whole
     * submission returned.
     *
     * Hard: more than the grace past the end date. Ninety days by default,
     * and the owner's to change.
     *
     * Warning only: past the end date but inside the grace, and a missing
     * end date. Both go on the record and the worklist; neither stands in
     * front of the person billing. A wall built on inherited data stops the
     * close over something nobody at the practice did.
     *
     * None of this guards a payment being recorded. A packet that is going
     * out has to be right; money that already came in is a fact, and a
     * record that refuses to hold a fact is the bug.
     */
    if new.status = 'Submitted' then
      if new.start_date is not null and new.service_start is not null
         and new.service_start < new.start_date then
        raise exception 'The work started % and the authorization starts %',
          new.service_start, new.start_date
          using hint = 'Service dates have to sit inside the authorized period.',
                errcode = 'check_violation';
      end if;
      if new.end_date is not null and new.service_end is not null
         and new.service_end > new.end_date then
        raise exception 'The work ran to % and the authorization ends %',
          new.service_end, new.end_date
          using hint = 'Service dates have to sit inside the authorized period.',
                errcode = 'check_violation';
      end if;
      -- A coaching month is its own service period.
      if new.period is not null and new.end_date is not null
         and new.period > date_trunc('month', new.end_date)::date then
        raise exception 'That month is after the authorization ends on %', new.end_date
          using errcode = 'check_violation';
      end if;

      /**
       * The USOR forms, refused only if the practice has asked for that.
       *
       * The test is real and it is on the checklist either way; the block
       * waits for the forms to live in the system. Both sides read
       * authorization_missing_forms().
       */
      if (select require_forms_to_submit from public.org_settings where id) then
        v_missing := public.authorization_missing_forms(new.id);
        if v_missing is not null then
          raise exception 'Not ready to send: % still outstanding for %',
            v_missing, coalesce(nullif(new.number, ''), new.service_type)
            using hint = 'Finish and sign the USOR forms, then submit.',
                  errcode = 'check_violation';
        end if;
      end if;

      if public.authorization_blocked_from(new.stale_date) is not null
         and public.authorization_blocked_from(new.stale_date) < public.practice_today() then
        raise exception 'That authorization ended % and is more than % days past it',
          new.stale_date,
          (select stale_grace_days from public.org_settings where id)
          using hint = 'Enter the new authorization, or move the end date and say why.',
                errcode = 'check_violation';
      end if;
    end if;

    -- The stamps the flow is defined by, so no screen has to remember them.
    if new.status = 'Submitted' and new.submitted_on is null then
      new.submitted_on := public.practice_today();
    end if;
    if new.status = 'Submitted' then
      new.submitted_by := coalesce(new.submitted_by, v_staff);
      -- §6: fourteen days, then it is chased.
      new.followup_due := coalesce(new.followup_due, public.practice_today() + 14);
    end if;
    if new.status = 'Paid' then
      new.paid_on := coalesce(new.paid_on, public.practice_today());
      new.followup_due := null;
    end if;
    if new.status = 'Closed' then
      new.closed_at := coalesce(new.closed_at, now());
      new.closed_by := coalesce(new.closed_by, v_staff);
      new.followup_due := null;
    end if;

    select name into v_name from public.staff where id = v_staff;
    insert into public.authorization_events (auth_id, staff_id, staff_name, was, became, note)
    values (new.id, v_staff, v_name, old.status, new.status,
            case when new.status = 'Closed' then new.closed_reason
                 when new.status = 'Paid' then nullif(new.warrant, '')
                 else nullif(new.correction_note, '') end);
  end if;

  /**
   * Changing the stale date is a decision, and decisions are written down.
   *
   * §2: "yes, with logged reason". The reason is required at the moment the
   * date moves, not asked for afterwards, because afterwards nobody
   * remembers and the field stays empty forever.
   */
  if tg_op = 'UPDATE' and new.stale_date is distinct from old.stale_date then
    if coalesce(btrim(new.stale_reason), '') = '' then
      raise exception 'Moving the stale date needs a reason'
        using hint = 'Somebody will ask why this was billed after it expired.',
              errcode = 'check_violation';
    end if;
    new.stale_changed_by := coalesce(v_staff, new.stale_changed_by);
    new.stale_changed_at := now();
    select name into v_name from public.staff where id = v_staff;
    insert into public.authorization_events (auth_id, staff_id, staff_name, was, became, note)
    values (new.id, v_staff, v_name, 'stale ' || coalesce(old.stale_date::text, 'none'),
            'stale ' || coalesce(new.stale_date::text, 'none'), new.stale_reason);
  end if;

  return new;
end;
$$;

comment on function public.authorization_transition is
  'The legal moves between authorization statuses, the gates that stop a submission, and the stamps each move leaves. Due and Authorized may go straight to Paid: money that already arrived is a fact, and the submission gates guard a packet going out, not a payment coming in.';

-- ─────────────────────────────────────────────────────────────
-- 1b. The receivable exists before it is cleared
--
-- 0157's function, with one block added. On Submitted it debits AR and
-- credits revenue; on Paid it debits undeposited and credits AR. A record
-- that goes straight to Paid never met the first, so the second would credit
-- a receivable nobody ever raised - the trial balance would still balance and
-- AR would be short by the amount, quietly, forever.
--
-- So reaching Paid from anything other than Submitted makes the Submitted
-- posting first. Dated the day it was billed where that is known, and the day
-- it was paid where it is not; ledger_live_posting keeps it from happening
-- twice.
-- ─────────────────────────────────────────────────────────────
create or replace function public.post_authorization()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_amount  numeric;
  v_revenue uuid;
  v_client  public.clients;
  v_office  text;
  v_live    uuid;
  v_label   text;
begin
  if new.status = old.status then
    return new;
  end if;

  -- A coaching parent is never billed; its months are.
  if exists (select 1 from public.authorizations c where c.parent_id = new.id) then
    return new;
  end if;

  select * into v_client from public.clients where id = new.client_id;
  v_office := coalesce(
    nullif((select office from public.counselors where id = v_client.counselor_id), ''),
    v_client.referring_office, '');
  v_revenue := public.ledger_revenue_account(new.service_type);
  v_label := v_client.name || ' - ' || new.service_type
             || case when new.period is not null
                     then ', ' || to_char(new.period, 'FMMon YYYY') else '' end;

  -- ── submitted: it is owed to the practice now ──
  if new.status = 'Submitted' and old.status <> 'Submitted' then
    v_amount := public.authorization_amount(new.id);
    if v_amount > 0 and public.ledger_live_posting('Authorization', new.id, 'Submitted') is null then
      perform public.post_journal(
        coalesce(new.submitted_on, public.practice_today()),
        v_label || ' submitted',
        'Authorization', new.id,
        public.ledger_next_event('Authorization', new.id, 'Submitted'),
        jsonb_build_array(
          jsonb_build_object('account', public.ledger_account('ar'), 'debit', v_amount,
                             'client_id', new.client_id, 'service', new.service_type,
                             'counselor_id', v_client.counselor_id, 'office', v_office),
          jsonb_build_object('account', v_revenue, 'credit', v_amount,
                             'client_id', new.client_id, 'service', new.service_type,
                             'counselor_id', v_client.counselor_id, 'office', v_office)
        ),
        null, '', null, new.submitted_by,
        coalesce((select name from public.staff where id = new.submitted_by), '')
      );
    end if;
  end if;

  /**
   * ── paid without having been submitted here ──
   *
   * The receivable has to stand before it can be cleared. This is the same
   * posting as the block above, made on the way past, so a backlog item
   * cleared in one move leaves the ledger in the state the long way round
   * would have left it.
   *
   * The amount is the payment, not authorization_amount(): on these records
   * the amount is often what the warrant says and not what the record was
   * priced at, and the receivable that is about to be cleared has to be the
   * one being cleared.
   */
  if new.status = 'Paid' and old.status not in ('Paid', 'Submitted') then
    v_amount := coalesce(nullif(new.paid_amount, 0), public.authorization_amount(new.id));
    if v_amount > 0 and public.ledger_live_posting('Authorization', new.id, 'Submitted') is null then
      perform public.post_journal(
        coalesce(new.submitted_on, new.paid_on, public.practice_today()),
        v_label || ' billed',
        'Authorization', new.id,
        public.ledger_next_event('Authorization', new.id, 'Submitted'),
        jsonb_build_array(
          jsonb_build_object('account', public.ledger_account('ar'), 'debit', v_amount,
                             'client_id', new.client_id, 'service', new.service_type,
                             'counselor_id', v_client.counselor_id, 'office', v_office),
          jsonb_build_object('account', v_revenue, 'credit', v_amount,
                             'client_id', new.client_id, 'service', new.service_type,
                             'counselor_id', v_client.counselor_id, 'office', v_office)
        ),
        null, '', null, public.current_staff_id(),
        coalesce((select name from public.staff where id = public.current_staff_id()), '')
      );
    end if;
  end if;

  -- ── paid: a warrant in hand, not yet at the bank ──
  if new.status = 'Paid' and old.status <> 'Paid' then
    if coalesce(new.paid_amount, 0) > 0
       and public.ledger_live_posting('Authorization', new.id, 'Paid') is null then
      perform public.post_journal(
        coalesce(new.paid_on, public.practice_today()),
        v_label || ' paid'
          || case when coalesce(new.warrant, '') <> '' then ', warrant ' || new.warrant else '' end,
        'Authorization', new.id,
        public.ledger_next_event('Authorization', new.id, 'Paid'),
        jsonb_build_array(
          jsonb_build_object('account', public.ledger_account('undeposited'), 'debit', new.paid_amount,
                             'client_id', new.client_id, 'service', new.service_type,
                             'counselor_id', v_client.counselor_id, 'office', v_office),
          jsonb_build_object('account', public.ledger_account('ar'), 'credit', new.paid_amount,
                             'client_id', new.client_id, 'service', new.service_type,
                             'counselor_id', v_client.counselor_id, 'office', v_office)
        ),
        v_revenue
      );
    end if;
  end if;

  -- ── the receivable stops standing ──
  -- Closed is here: an authorization submitted and then closed has been
  -- refused or abandoned, and what was owed is not owed any more.
  if old.status = 'Submitted' and new.status in ('Due', 'Authorized', 'Closed') then
    v_live := public.ledger_live_posting('Authorization', new.id, 'Submitted');
    if v_live is not null then
      perform public.reverse_journal(v_live, format('Went back to %s', new.status));
    end if;
  end if;

  -- ── the payment stops standing ──
  -- Closed is deliberately not here (0154): closing something that was paid
  -- does not un-pay it, and reversing would take real money off the books.
  --
  -- The receivable raised on the way to Paid comes off with it, because a
  -- payment undone on a record that was never submitted leaves nothing owed.
  if old.status = 'Paid' and new.status in ('Submitted', 'Due', 'Authorized') then
    v_live := public.ledger_live_posting('Authorization', new.id, 'Paid');
    if v_live is not null then
      perform public.reverse_journal(v_live, format('Payment undone: now %s', new.status));
    end if;
    if new.status in ('Due', 'Authorized') then
      v_live := public.ledger_live_posting('Authorization', new.id, 'Submitted');
      if v_live is not null then
        perform public.reverse_journal(v_live, format('Payment undone: now %s', new.status));
      end if;
    end if;
  end if;

  return new;
end;
$$;

comment on function public.post_authorization is
  'Revenue when an authorization is submitted, cash when it is paid, a reversal only where one of those came undone. A record that reaches Paid without passing through Submitted has its receivable raised on the way past, so the ledger cannot credit an AR nobody debited.';

-- ─────────────────────────────────────────────────────────────
-- 2. A correction is written down, by the database
--
-- The log already exists (authorization_corrections) and so does one function
-- that writes to it for two fields. What was missing is that every other
-- field could be changed by anything at all and leave no trace.
--
-- A trigger rather than a function the screens call, for the reason this
-- codebase keeps relearning: a rule that lives in one caller is a rule the
-- next caller does not have. The sweeps, the reconciliation, the agent and
-- three screens all write this table.
--
-- Which fields, and which of them need a reason, is the list below and
-- nothing else. A short explicit list keeps the log readable - it is read by
-- a person asking what happened to this authorization, and a row for every
-- followup_set_at would bury the answer.
-- ─────────────────────────────────────────────────────────────
create or replace function public.authorization_correction_log()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  -- field, the name a person reads, whether a change to it needs a reason
  k_fields constant text[][] := array[
    ['number',         'Number',          'yes'],
    ['service_type',   'Service',         'no' ],
    ['funding_source', 'Funding source',  'no' ],
    ['total_hours',    'Authorized hours','yes'],
    ['rate_type',      'Rate type',       'yes'],
    ['rate',           'Rate',            'yes'],
    ['paid_amount',    'Amount paid',     'yes'],
    ['start_date',     'Starts',          'no' ],
    ['end_date',       'Ends',            'no' ],
    ['received_on',    'Received',        'no' ],
    ['bill_by',        'Bill by',         'no' ],
    ['paid_on',        'Paid on',         'no' ],
    ['warrant',        'Warrant',         'no' ],
    ['recipient',      'Recipient',       'no' ],
    ['requires_forms', 'Forms required',  'no' ],
    ['closed_reason',  'Closed reason',   'no' ],
    ['note',           'Note',            'no' ]
  ];
  v_old    jsonb := to_jsonb(old);
  v_new    jsonb := to_jsonb(new);
  v_reason text := coalesce(btrim(nullif(current_setting('zion.correction_reason', true), '')), '');
  v_staff  uuid := public.current_staff_id();
  v_name   text;
  v_col    text;
  v_label  text;
  v_needs  boolean;
  v_was    text;
  v_now    text;
  v_rows   jsonb := '[]'::jsonb;
  n        integer;
begin
  for n in 1 .. array_length(k_fields, 1) loop
    v_col   := k_fields[n][1];
    v_label := k_fields[n][2];
    v_needs := k_fields[n][3] = 'yes';

    if (v_old -> v_col) is distinct from (v_new -> v_col) then
      v_was := coalesce(v_old ->> v_col, '');
      v_now := coalesce(v_new ->> v_col, '');

      /**
       * A reason for a correction, not for a first entry.
       *
       * Filling in a number that was blank, or an amount paid that was null,
       * is recording what the paperwork says - there is nothing to explain.
       * Changing a number that was already there is a correction, and
       * somebody will ask which of the two was right.
       *
       * This distinction is load-bearing: warrant reconciliation writes
       * paid_amount where there was none, and requiring a reason for that
       * would have stopped every payment the warrant reader records.
       */
      if v_needs and v_was <> '' and v_reason = '' then
        raise exception 'Changing % from % to % needs a reason', lower(v_label), v_was, v_now
          using hint = 'Somebody will ask which of the two was right.',
                errcode = 'check_violation';
      end if;

      /**
       * And it is logged when it is a correction.
       *
       * A first entry is not news for this log: warrant reconciliation fills
       * in paid_on, the amount paid and the warrant number on every payment
       * it reads, and a correction log that records those buries the four
       * rows somebody opened it to find. A reason given means somebody meant
       * this to be read, so that is kept whatever the old value was.
       */
      if v_was <> '' or v_reason <> '' then
        v_rows := v_rows || jsonb_build_object('field', v_label, 'was', v_was, 'new', v_now);
      end if;
    end if;
  end loop;

  if v_rows = '[]'::jsonb then
    return null;
  end if;

  select name into v_name from public.staff where id = v_staff;

  insert into public.authorization_corrections
    (auth_id, auth_number, field, was_value, new_value, reason, staff_id, staff_name)
  select new.id, old.number, r ->> 'field', r ->> 'was', r ->> 'new',
         v_reason, v_staff, coalesce(v_name, 'the system')
    from jsonb_array_elements(v_rows) as r;

  return null;
end;
$$;

comment on function public.authorization_correction_log is
  'Writes every change to an authorization field a person edits into authorization_corrections, and refuses a change to the number, the rate or the amount paid that has no reason - unless the value was empty, which is a first entry and not a correction.';

drop trigger if exists authorizations_correction_log on public.authorizations;
create trigger authorizations_correction_log after update on public.authorizations
  for each row execute function public.authorization_correction_log();

-- The log is a record. It is added to, never changed or removed.
create or replace function public.authorization_corrections_append_only()
returns trigger language plpgsql as $$
begin
  raise exception 'The correction log is a record; it is added to, never changed or removed.'
    using errcode = 'insufficient_privilege';
end;
$$;

drop trigger if exists authorization_corrections_append_only on public.authorization_corrections;
create trigger authorization_corrections_append_only
  before update or delete on public.authorization_corrections
  for each row execute function public.authorization_corrections_append_only();

-- ─────────────────────────────────────────────────────────────
-- 2b. Correcting the service or the client stays one function
--
-- 0177's correct_authorization moves the attachments and the forms with a
-- client change, which is the part nobody should reimplement. It was Admin's
-- alone; the owner has asked for Billing to have it. The Admin test becomes
-- the billing test and nothing else moves.
-- ─────────────────────────────────────────────────────────────
create or replace function public.correct_authorization(
  p_auth uuid, p_reason text, p_service_type text default null, p_client uuid default null)
returns table (field text, was_value text, new_value text)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare
  v_staff uuid := public.current_staff_id();
  v_name  text;
  v_auth  public.authorizations%rowtype;
  v_svc   text := nullif(btrim(coalesce(p_service_type, '')), '');
  v_was   text;
  v_now   text;
begin
  if not public.billing_hands() then
    raise exception 'Correcting an authorization on file is Billing''s, or an Admin''s.'
      using errcode = 'insufficient_privilege';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'Say why it is being corrected.' using errcode = 'check_violation';
  end if;
  if v_svc is null and p_client is null then
    raise exception 'Nothing to correct.' using errcode = 'invalid_parameter_value';
  end if;

  select * into v_auth from public.authorizations where id = p_auth for update;
  if not found then
    raise exception 'That authorization does not exist.' using errcode = 'no_data_found';
  end if;

  select name into v_name from public.staff where id = v_staff;

  -- The correction log trigger sees this reason too, so a service change
  -- recorded here is not also recorded there without one.
  perform set_config('zion.correction_reason', btrim(p_reason), true);

  if v_svc is not null and v_svc <> v_auth.service_type then
    if v_svc not in ('Job Coaching', 'Job Development', 'Job Development + HQ Indicator', 'Job Placement',
                     'Job Placement (SE)', 'WSA Tier 1', 'WSA Tier 2', 'HQ Indicator',
                     'Temporary Work Experience', 'Life Skills', 'CRP Group Training', 'Job Readiness',
                     'Supported Employment', 'Follow-Along', 'Other') then
      raise exception '"%" is not a service on the list.', v_svc using errcode = 'check_violation';
    end if;

    update public.authorizations set service_type = v_svc where id = p_auth;

    field := 'Service'; was_value := v_auth.service_type; new_value := v_svc;
    return next;
  end if;

  if p_client is not null and p_client <> v_auth.client_id then
    select name into v_now from public.clients where id = p_client;
    if not found then
      raise exception 'That client does not exist.' using errcode = 'no_data_found';
    end if;
    select name into v_was from public.clients where id = v_auth.client_id;

    -- The authorization's own paperwork goes with it. Its hours and invoices
    -- hang off the authorization and follow without being touched.
    update public.authorizations set client_id = p_client where id = p_auth;
    update public.attachments    set client_id = p_client where auth_id = p_auth;
    update public.forms          set client_id = p_client where auth_id = p_auth;

    insert into public.authorization_corrections
      (auth_id, auth_number, field, was_value, new_value, reason, staff_id, staff_name)
    values (p_auth, v_auth.number, 'Client', coalesce(v_was, ''), v_now, btrim(p_reason), v_staff, coalesce(v_name, ''));

    field := 'Client'; was_value := coalesce(v_was, ''); new_value := v_now;
    return next;
  end if;

  perform set_config('zion.correction_reason', '', true);
end;
$$;

comment on function public.correct_authorization is
  'Corrects the service or the client on an authorization already on file, with a reason, moving its papers and its forms with it when the client changes. Billing''s or an Admin''s.';

revoke all on function public.correct_authorization(uuid, text, text, uuid) from anon, authenticated;
grant execute on function public.correct_authorization(uuid, text, text, uuid) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- 2c. Editing the rest of the fields
--
-- One function rather than a screen writing the table directly, so the reason
-- reaches the correction log in the same transaction as the change. Only the
-- keys present in p_fields are touched: a screen that shows six fields sends
-- six, and an absent key is not the same as a null one.
--
-- Status is not here. It has its own moves and its own log
-- (authorization_events), and a status typed into a field alongside a rate is
-- how a state machine stops meaning anything. set_authorization_status below
-- is the one way.
-- ─────────────────────────────────────────────────────────────
create or replace function public.edit_authorization(
  p_auth uuid, p_fields jsonb, p_reason text default null)
returns table (field text, was_value text, new_value text)
language plpgsql security definer set search_path = public as $$
declare
  k_text   constant text[] := array['number', 'funding_source', 'rate_type', 'recipient',
                                    'requires_forms', 'note', 'warrant', 'closed_reason'];
  k_num    constant text[] := array['total_hours', 'rate', 'paid_amount'];
  k_date   constant text[] := array['start_date', 'end_date', 'received_on', 'bill_by', 'paid_on',
                                    'service_start', 'service_end'];
  v_auth   public.authorizations%rowtype;
  v_before jsonb;
  v_after  jsonb;
  v_key    text;
  v_sets   text[] := '{}';
  v_svc    text;
  v_client uuid;
begin
  if not public.billing_hands() then
    raise exception 'Editing an authorization is Billing''s, or an Admin''s.'
      using errcode = 'insufficient_privilege';
  end if;

  select * into v_auth from public.authorizations where id = p_auth for update;
  if not found then
    raise exception 'That authorization does not exist.' using errcode = 'no_data_found';
  end if;
  v_before := to_jsonb(v_auth);

  -- The reason goes in first, so the correction log sees it whichever field
  -- below turns out to have moved.
  perform set_config('zion.correction_reason', coalesce(btrim(p_reason), ''), true);

  -- The service and the client are the other function's, because they move
  -- the papers. Done first, and the same reason covers them.
  v_svc    := nullif(btrim(coalesce(p_fields ->> 'service_type', '')), '');
  v_client := nullif(p_fields ->> 'client_id', '')::uuid;
  if (v_svc is not null and v_svc <> v_auth.service_type)
     or (v_client is not null and v_client <> v_auth.client_id) then
    perform public.correct_authorization(p_auth, coalesce(btrim(p_reason), ''), v_svc, v_client);
    -- Re-read: the row moved, and what follows must build on that.
    perform set_config('zion.correction_reason', coalesce(btrim(p_reason), ''), true);
    select * into v_auth from public.authorizations where id = p_auth for update;
  end if;

  foreach v_key in array k_text loop
    if p_fields ? v_key then
      v_sets := v_sets || format('%I = %L', v_key, coalesce(p_fields ->> v_key, ''));
    end if;
  end loop;

  foreach v_key in array k_num loop
    if p_fields ? v_key then
      -- An empty string is "no figure", which is null for the nullable ones
      -- and refused by the table for rate. Said here rather than by a
      -- constraint violation nobody can read.
      if nullif(btrim(coalesce(p_fields ->> v_key, '')), '') is null then
        if v_key = 'rate' then
          raise exception 'A rate of nothing is a rate of zero. Type 0 if that is what it is.'
            using errcode = 'invalid_parameter_value';
        end if;
        v_sets := v_sets || format('%I = null', v_key);
      else
        if (p_fields ->> v_key) !~ '^-?\d+(\.\d+)?$' then
          raise exception '% is not a number.', p_fields ->> v_key
            using errcode = 'invalid_parameter_value';
        end if;
        v_sets := v_sets || format('%I = %L::numeric', v_key, p_fields ->> v_key);
      end if;
    end if;
  end loop;

  foreach v_key in array k_date loop
    if p_fields ? v_key then
      if nullif(btrim(coalesce(p_fields ->> v_key, '')), '') is null then
        if v_key = 'received_on' then
          raise exception 'Every authorization has a day it came in.'
            using errcode = 'invalid_parameter_value';
        end if;
        v_sets := v_sets || format('%I = null', v_key);
      else
        if (p_fields ->> v_key) !~ '^\d{4}-\d{2}-\d{2}$' then
          raise exception '"%" is not a date.', p_fields ->> v_key
            using errcode = 'invalid_parameter_value';
        end if;
        v_sets := v_sets || format('%I = %L::date', v_key, p_fields ->> v_key);
      end if;
    end if;
  end loop;

  if array_length(v_sets, 1) is not null then
    execute format('update public.authorizations set %s, updated_at = now() where id = %L',
                   array_to_string(v_sets, ', '), p_auth);
  end if;

  perform set_config('zion.correction_reason', '', true);

  select to_jsonb(a) into v_after from public.authorizations a where a.id = p_auth;

  -- What actually moved, read back off the row rather than echoed from the
  -- form: a field the database rounded, defaulted or stamped is reported as
  -- the database left it.
  return query
    select k,
           coalesce(v_before ->> k, ''),
           coalesce(v_after  ->> k, '')
      from jsonb_object_keys(v_after) as k
     where (v_before -> k) is distinct from (v_after -> k)
       and k not in ('updated_at')
     order by k;
end;
$$;

comment on function public.edit_authorization is
  'Changes the fields of an authorization that a person edits, with one reason covering the change. Only the keys present in p_fields are touched. The service and the client go through correct_authorization, because those move the papers; the status goes through set_authorization_status.';

revoke all on function public.edit_authorization(uuid, jsonb, text) from anon, authenticated;
grant execute on function public.edit_authorization(uuid, jsonb, text) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- 1c. Recording a payment
--
-- "Record payment on any Submitted or Due authorization: date received
-- (default today), amount (default the authorization amount), optional
-- warrant/check number. Sets that one authorization to Paid and nothing else
-- - not the client, not its other authorizations."
--
-- One authorization, named by its id, and a payment row beside it. The
-- payment is what makes a later warrant line recognise this as already
-- recorded instead of paying it twice - see 0191, which teaches the warrant
-- reader to match a payment that has no warrant number yet.
-- ─────────────────────────────────────────────────────────────
create or replace function public.record_payment(
  p_auth    uuid,
  p_received date default null,
  p_amount  numeric default null,
  p_warrant text default null,
  p_voucher text default null)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_auth    public.authorizations%rowtype;
  v_amount  numeric;
  v_when    date := coalesce(p_received, public.practice_today());
  v_warrant text := coalesce(btrim(p_warrant), '');
  v_staff   uuid := public.current_staff_id();
  v_name    text;
  v_pay     uuid;
begin
  if not public.billing_hands() then
    raise exception 'Recording a payment is Billing''s, or an Admin''s.'
      using errcode = 'insufficient_privilege';
  end if;

  select * into v_auth from public.authorizations where id = p_auth for update;
  if not found then
    raise exception 'That authorization does not exist.' using errcode = 'no_data_found';
  end if;

  if v_auth.status not in ('Submitted', 'Due') then
    raise exception 'That authorization is %, and a payment is recorded against one that is Submitted or Due.',
      lower(v_auth.status)
      using hint = 'Set the status on the record if it needs to move first.',
            errcode = 'check_violation';
  end if;

  -- A coaching parent is never paid; its months are.
  if exists (select 1 from public.authorizations c where c.parent_id = p_auth) then
    raise exception 'That is the coaching authorization itself. Its months are what get paid.'
      using errcode = 'check_violation';
  end if;

  if v_when > public.practice_today() then
    raise exception 'A payment cannot have arrived on %, which has not happened yet.', v_when
      using errcode = 'invalid_parameter_value';
  end if;

  v_amount := coalesce(nullif(p_amount, 0), public.authorization_amount(p_auth));
  if coalesce(v_amount, 0) <= 0 then
    raise exception '% comes to nothing, so there is no amount to record.',
      coalesce(nullif(v_auth.number, ''), v_auth.service_type)
      using hint = 'Type the amount received, or put the rate and hours on the record first.',
            errcode = 'invalid_parameter_value';
  end if;

  select name into v_name from public.staff where id = v_staff;

  insert into public.payments
    (auth_id, amount, warrant_no, warrant_date, voucher, source, recorded_by, recorded_by_name)
  values
    (p_auth, v_amount, v_warrant, v_when, coalesce(btrim(p_voucher), ''), 'By hand',
     v_staff, coalesce(v_name, ''))
  returning id into v_pay;

  /**
   * And the one authorization moves. Nothing else: not the client, not its
   * other authorizations, not the coaching parent. The where clause is the
   * whole guarantee and it is one id.
   *
   * The warrant is only written when one was given - an empty warrant number
   * overwriting one already on the record would lose it.
   */
  update public.authorizations
     set status      = 'Paid',
         paid_on     = v_when,
         paid_amount = v_amount,
         warrant     = case when v_warrant <> '' then v_warrant else warrant end
   where id = p_auth;

  return v_pay;
end;
$$;

comment on function public.record_payment is
  'Records money received against one Submitted or Due authorization: a payment row and that one authorization set to Paid. The amount defaults to what the authorization comes to and the date to today. Nothing else is touched.';

revoke all on function public.record_payment(uuid, date, numeric, text, text) from anon, authenticated;
grant execute on function public.record_payment(uuid, date, numeric, text, text) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- 2d. Setting the status from the record or the row
--
-- "Status can be set directly to Paid or Closed from the record and from the
-- working-list row."
--
-- Paid goes through record_payment, so a status set to Paid and a payment
-- recorded are the same act and cannot produce an authorization that says
-- Paid with no payment behind it. Closed needs its reason.
-- ─────────────────────────────────────────────────────────────
create or replace function public.set_authorization_status(
  p_auth uuid, p_status text, p_reason text default null, p_received date default null)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_auth public.authorizations%rowtype;
begin
  if not public.billing_hands() then
    raise exception 'Changing an authorization''s status is Billing''s, or an Admin''s.'
      using errcode = 'insufficient_privilege';
  end if;

  select * into v_auth from public.authorizations where id = p_auth for update;
  if not found then
    raise exception 'That authorization does not exist.' using errcode = 'no_data_found';
  end if;
  if v_auth.status = p_status then
    return format('It was already %s.', lower(p_status));
  end if;

  if p_status = 'Paid' then
    perform public.record_payment(p_auth, p_received, null, null, null);
    return 'Paid, and the payment is on the record.';
  end if;

  if p_status = 'Closed' then
    if coalesce(btrim(p_reason), '') = '' then
      raise exception 'Say why it is being closed. Somebody will ask.' using errcode = 'check_violation';
    end if;
    update public.authorizations
       set status = 'Closed', closed_reason = btrim(p_reason) where id = p_auth;
    return 'Closed, with the reason on the record.';
  end if;

  if p_status not in ('Authorized', 'Due', 'Submitted') then
    raise exception '"%" is not a status an authorization has.', p_status using errcode = 'check_violation';
  end if;

  -- The state machine decides whether this move is legal, and says so itself.
  perform set_config('zion.correction_reason', coalesce(btrim(p_reason), ''), true);
  update public.authorizations set status = p_status where id = p_auth;
  perform set_config('zion.correction_reason', '', true);
  return format('Now %s.', lower(p_status));
end;
$$;

comment on function public.set_authorization_status is
  'Sets one authorization''s status. Paid goes through record_payment so there is no Paid without a payment behind it; Closed needs a reason. The state machine still decides whether the move is legal.';

revoke all on function public.set_authorization_status(uuid, text, text, date) from anon, authenticated;
grant execute on function public.set_authorization_status(uuid, text, text, date) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- 3. Bulk clear
--
-- "Many items in the queue were paid long ago; this is how they get cleared."
--
-- Each row is its own savepoint - the begin/exception block inside the loop -
-- so one row that cannot be priced does not take the rest down with it. The
-- caller gets a line per row, and the six open authorizations that come to
-- nothing are named rather than silently skipped.
-- ─────────────────────────────────────────────────────────────
create or replace function public.bulk_mark_paid(p_auths uuid[], p_received date default null)
returns table (auth_id uuid, auth_number text, client_name text, outcome text, detail text)
language plpgsql security definer set search_path = public as $$
declare
  v_id   uuid;
  v_when date := coalesce(p_received, public.practice_today());
  v_pay  uuid;
begin
  if not public.billing_hands() then
    raise exception 'Marking authorizations paid is Billing''s, or an Admin''s.'
      using errcode = 'insufficient_privilege';
  end if;

  foreach v_id in array coalesce(p_auths, '{}'::uuid[]) loop
    select a.id, coalesce(nullif(a.number, ''), '(no number)'), coalesce(c.name, '')
      into auth_id, auth_number, client_name
      from public.authorizations a
      left join public.clients c on c.id = a.client_id
     where a.id = v_id;

    if auth_id is null then
      auth_id := v_id; auth_number := ''; client_name := '';
      outcome := 'not found'; detail := 'That authorization is not there any more.';
      return next;
      continue;
    end if;

    begin
      v_pay := public.record_payment(v_id, v_when, null, null, null);
      outcome := 'paid';
      detail  := format('%s on %s',
                        (select to_char(amount, 'FM999999990.00') from public.payments where id = v_pay),
                        v_when);
    exception when others then
      outcome := 'left alone';
      detail  := sqlerrm;
    end;
    return next;
  end loop;
end;
$$;

comment on function public.bulk_mark_paid is
  'Records a payment on each of several authorizations with one received date. Each row stands or falls on its own, and the result says per row what happened.';

revoke all on function public.bulk_mark_paid(uuid[], date) from anon, authenticated;
grant execute on function public.bulk_mark_paid(uuid[], date) to authenticated;

create or replace function public.bulk_close(p_auths uuid[], p_reason text)
returns table (auth_id uuid, auth_number text, client_name text, outcome text, detail text)
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
begin
  if not public.billing_hands() then
    raise exception 'Closing authorizations is Billing''s, or an Admin''s.'
      using errcode = 'insufficient_privilege';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'Say why they are being closed. Somebody will ask.' using errcode = 'check_violation';
  end if;

  foreach v_id in array coalesce(p_auths, '{}'::uuid[]) loop
    select a.id, coalesce(nullif(a.number, ''), '(no number)'), coalesce(c.name, '')
      into auth_id, auth_number, client_name
      from public.authorizations a
      left join public.clients c on c.id = a.client_id
     where a.id = v_id;

    if auth_id is null then
      auth_id := v_id; auth_number := ''; client_name := '';
      outcome := 'not found'; detail := 'That authorization is not there any more.';
      return next;
      continue;
    end if;

    begin
      perform public.set_authorization_status(v_id, 'Closed', btrim(p_reason), null);
      outcome := 'closed';
      detail  := btrim(p_reason);
    exception when others then
      outcome := 'left alone';
      detail  := sqlerrm;
    end;
    return next;
  end loop;
end;
$$;

comment on function public.bulk_close is
  'Closes several authorizations with one reason. Each row stands or falls on its own, and the result says per row what happened.';

revoke all on function public.bulk_close(uuid[], text) from anon, authenticated;
grant execute on function public.bulk_close(uuid[], text) to authenticated;
