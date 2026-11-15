-- Zion Vocational Rehab CRM — the audit trail keeps its words
--
-- Found by the smoke, and by nothing else. Rendering the authorization record
-- as the Billing person and reading the HTML for a warrant-shaped number
-- turned up one: "Submitted → Paid — F15677921" in the status history.
--
-- Two places, and they want opposite treatment.
--
-- ── the event note, which is only ever the number ────────────
--
-- `authorization_transition` writes an `authorization_events` row on every
-- status move, and for a move to Paid the note it writes is `new.warrant` -
-- nothing else. Thirteen of those exist and each is a bare warrant number.
-- The table is read by Admin or anybody with a billing area grant, so Billing
-- read every one of them. The number is on the payment, which is where Admin
-- reads it, so the note says nothing that is not held better elsewhere: the
-- trigger stops writing it and the thirteen are blanked.
--
-- ── the correction reason, which is somebody's account of a
--    real correction ───────────────────────────────────────────
--
-- Seven `authorization_corrections` rows name a warrant in their reason, and
-- they are not machine provenance like the notes in 0362. They are the
-- owner's own prose about money that was taken back twice over - "a third
-- copy of the same $420, dated 3 September on warrant F…, which on that
-- warrant belongs to V… for $420". Rewriting that would damage the record of
-- a real correction to make a permission true, which is the wrong way round.
--
-- So the row is kept whole and read by Admin. `admin_only` is a column rather
-- than a text match in the policy: a policy that searched each reason for
-- every warrant number on file would be a subquery per row on the busiest log
-- in the practice, and it would still be guessing. `remove_payment` stops
-- putting the warrant and the voucher in its own preamble, so what is left
-- for the flag is prose a person wrote on purpose.
--
-- The definitions are restated from what the database held
-- (scripts/dump-function.mjs), not from the migrations that created them.

begin;

-- ── 1. the flag, beside the log rather than in it ───────────

/*
 * The log is append-only and a trigger says so: "The correction log is a
 * record; it is added to, never changed or removed." The first version of
 * this migration tried to add a column and set it on the seven rows, and the
 * trigger refused - rightly. A permissions flag is not a reason to weaken the
 * one guarantee that log carries.
 *
 * So the flag sits beside it. Nothing in the log is changed; a row is added
 * here naming a correction whose words happen to name a warrant, and the read
 * policy joins to it.
 */
create table if not exists public.correction_is_admins (
  correction_id bigint primary key
    references public.authorization_corrections(id) on delete cascade,
  recorded_at timestamptz not null default now()
);

comment on table public.correction_is_admins is
  'Corrections whose reason names a warrant number, and so are read by Admin alone. Beside the log because the log is append-only.';

alter table public.correction_is_admins enable row level security;

drop policy if exists correction_is_admins_read on public.correction_is_admins;
create policy correction_is_admins_read on public.correction_is_admins
  for select using ((select public.is_active_staff()));

revoke all on public.correction_is_admins from public, anon, authenticated;
grant select on public.correction_is_admins to authenticated;

-- Every new table refuses the system account's writes, and the check that
-- holds that reads the catalogue rather than a list - so a table added without
-- this is a failure rather than an omission (verify_system_account).
select public.apply_system_read_only('public.correction_is_admins');

/*
 * Every writer at once, rather than one patch per writer.
 *
 * `remove_payment` inserts a correction directly, `authorization_correction_log`
 * writes one from a trigger, and `edit_authorization` goes through that - so a
 * flag set by each of them is a flag the fourth writer forgets. This asks the
 * question once, where the row arrives.
 *
 * Matched against the warrant and voucher numbers the practice actually holds
 * rather than against a shape: an authorization number and an invoice number
 * are both numbers in a reason, and Billing may read those.
 */
create or replace function public.correction_names_a_warrant()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $fn$
begin
  if exists (
    select 1
      from (
        select warrant_no as n from public.payments where coalesce(warrant_no, '') <> ''
        union select warrant from public.authorizations where coalesce(warrant, '') <> ''
        union select voucher from public.payments where coalesce(voucher, '') <> ''
        union select warrant_no from public.warrant_pages where coalesce(warrant_no, '') <> ''
      ) w
     where new.reason like '%' || w.n || '%'
  ) then
    insert into public.correction_is_admins (correction_id)
    values (new.id)
    on conflict (correction_id) do nothing;
  end if;
  return null;
end $fn$;

drop trigger if exists correction_names_a_warrant on public.authorization_corrections;
create trigger correction_names_a_warrant
  after insert on public.authorization_corrections
  for each row execute function public.correction_names_a_warrant();

-- The seven already on file.
insert into public.correction_is_admins (correction_id)
select k.id from public.authorization_corrections k
 where exists (
   select 1 from (
     select warrant_no as n from public.payments where coalesce(warrant_no, '') <> ''
     union select warrant from public.authorizations where coalesce(warrant, '') <> ''
     union select voucher from public.payments where coalesce(voucher, '') <> ''
     union select warrant_no from public.warrant_pages where coalesce(warrant_no, '') <> ''
   ) w
    where k.reason like '%' || w.n || '%'
 )
on conflict (correction_id) do nothing;

drop policy if exists authorization_corrections_read on public.authorization_corrections;
create policy authorization_corrections_read on public.authorization_corrections
  for select using (
    (select public.is_active_staff())
    and (
      (field <> 'Warrant'
       and not exists (select 1 from public.correction_is_admins c
                        where c.correction_id = authorization_corrections.id))
      or (select public.warrant_hands())
    )
  );

-- ── 2. the thirteen event notes that are a bare number ──────
--
-- Blanked rather than flagged: each one is nothing but a warrant number, and
-- the number is on the payment. There is no account of anything here to keep.

with w as (
  select distinct warrant_no as n from public.payments where coalesce(warrant_no, '') <> ''
  union select warrant from public.authorizations where coalesce(warrant, '') <> ''
  union select warrant_no from public.warrant_pages where coalesce(warrant_no, '') <> ''
)
update public.authorization_events e
   set note = ''
 where exists (select 1 from w where e.note like '%' || w.n || '%');

-- ── authorization_transition ──

CREATE OR REPLACE FUNCTION public.authorization_transition()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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

    /**
     * Reopening a closed authorization is Billing's as well as Admin's
     * (owner, 3 November 2026, part 3b).
     *
     * It was Admin's alone, and the person who closes an authorization in
     * error is almost always the person billing it. billing_hands() is the
     * same test record_payment and the corrections use, so "who may touch the
     * money" has one answer rather than three.
     */
    if old.status = 'Closed' and not public.billing_hands() then
      raise exception 'Reopening a closed authorization is Billing''s, or an Admin''s.'
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

    /**
     * And it stops saying why it is closed when it stops being closed
     * (0324).
     *
     * V1028168 and V1041336 were Paid and still carried the reason they had
     * been closed with, because the warrant reader moved them and had
     * nothing to say about this field. Cleared here rather than asked about:
     * the event row written below holds the reason the close happened, so
     * there is nothing here to keep.
     */
    if new.status <> 'Closed' then
      new.closed_reason := '';
    end if;

    select name into v_name from public.staff where id = v_staff;
    insert into public.authorization_events (auth_id, staff_id, staff_name, was, became, note)
    values (new.id, v_staff, v_name, old.status, new.status,
            -- Paid used to write `new.warrant` here and nothing else, so
            -- thirteen rows of this log were a bare warrant number that
            -- Billing could read (0364). The number is on the payment, where
            -- Admin reads it; what belongs here is whatever somebody said.
            case when new.status = 'Closed' then new.closed_reason
                 else nullif(new.correction_note, '') end);
  end if;

  /**
   * And it is not given a closing reason while it is not closed.
   *
   * The Closed reason is an editable field on the Billing form, so this is a
   * path a person is on rather than one only the system takes - which is why
   * it is a sentence and not a silent correction like the one above.
   */
  if tg_op = 'UPDATE'
     and new.status is not distinct from old.status
     and new.status <> 'Closed'
     and coalesce(btrim(new.closed_reason), '') <> '' then
    raise exception 'That authorization is %, so there is no reason it is closed', lower(new.status)
      using hint = 'Close it, and say why as you do.',
            errcode = 'check_violation';
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
$function$;

-- ── remove_payment ──

CREATE OR REPLACE FUNCTION public.remove_payment(p_payment uuid, p_reason text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  pay     public.payments;
  a       public.authorizations;
  v_me    uuid := public.current_staff_id();
  v_role  text := public.current_staff_role();
  v_name  text;
  v_total numeric;
begin
  -- coalesce, because `null not in (...)` is null rather than true and the
  -- guard would wave through a caller it could not identify at all. The first
  -- run of this file did exactly that: the correction landed with no staff id
  -- and no name on it, which is the fault CLAUDE.md names - not being able to
  -- get an answer is not the same as getting the answer "no".
  if coalesce(v_role, '') not in ('Admin', 'Billing') then
    raise exception 'Only Admin or Billing takes a payment back.'
      using errcode = 'insufficient_privilege';
  end if;
  if v_me is null then
    raise exception 'A correction has to say who made it.'
      using errcode = 'insufficient_privilege';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'Say why this payment is being taken back.'
      using hint = 'It goes in the correction log, and the log is what somebody reads in a year.',
            errcode = 'check_violation';
  end if;

  select * into pay from public.payments where id = p_payment;
  if pay.id is null then
    raise exception 'That payment is not on file.' using errcode = 'no_data_found';
  end if;
  select * into a from public.authorizations where id = pay.auth_id;

  select name into v_name from public.staff where id = v_me;

  select coalesce(sum(amount), 0) - pay.amount into v_total
    from public.payments where auth_id = a.id;

  -- Logged as what it changes - the amount paid - in the vocabulary the
  -- correction log already has, with the payment itself named in the reason so
  -- somebody reading it in a year can find which one went.
  --
  -- The log first. If anything below refuses, the correction rolls back with
  -- it, and a log entry for a payment that is still there would be worse than
  -- none.
  insert into public.authorization_corrections
    (auth_id, auth_number, field, was_value, new_value, reason, staff_id, staff_name)
  values (a.id, coalesce(a.number, ''), 'Amount paid',
          to_char(coalesce(a.paid_amount, 0), 'FM9999999.00'),
          to_char(v_total, 'FM9999999.00'),
          -- No warrant and no voucher: this log is read by anybody who
          -- can open the authorization, and the amount, the day and the
          -- person already say which payment was taken back (0364).
          format('Took back %s recorded %s by %s. %s',
                 to_char(pay.amount, 'FM9999999.00'),
                 to_char(pay.created_at, 'FMDD FMMonth YYYY'),
                 coalesce(pay.recorded_by_name, '(nobody recorded)'),
                 btrim(p_reason)),
          v_me, coalesce(v_name, ''));

  -- A warrant line that pointed at this payment has nothing to point at. It
  -- goes back to needing review rather than silently keeping a dead pointer:
  -- the line is still on the warrant and still unaccounted for.
  update public.warrant_lines
     set payment_id = null,
         status = 'Needs review',
         problem = format('The payment this line was matched to was taken back on %s: %s',
                          to_char(public.practice_today(), 'FMDD FMMonth'), btrim(p_reason))
   where payment_id = p_payment;

  delete from public.payments where id = p_payment;

  -- And the authorization's own total, brought back to what its payments say.
  select coalesce(sum(amount), 0) into v_total from public.payments where auth_id = a.id;

  update public.authorizations
     set paid_amount = v_total,
         status = case when v_total = 0 and status = 'Paid' then 'Submitted' else status end,
         paid_on = case when v_total = 0 then null else paid_on end
   where id = a.id;

  return p_payment;
end $function$;

-- ── 3. and the assertion, in the same transaction ───────────

do $check$
declare n integer;
begin
  with w as (
    select distinct warrant_no as nn from public.payments where coalesce(warrant_no, '') <> ''
    union select warrant from public.authorizations where coalesce(warrant, '') <> ''
    union select voucher from public.payments where coalesce(voucher, '') <> ''
    union select warrant_no from public.warrant_pages where coalesce(warrant_no, '') <> ''
  )
  select count(*) into n from public.authorization_events e
   where exists (select 1 from w where e.note like '%' || w.nn || '%');
  if n <> 0 then
    raise exception '% status-history note(s) still name a warrant.', n;
  end if;

  with w as (
    select distinct warrant_no as nn from public.payments where coalesce(warrant_no, '') <> ''
    union select warrant from public.authorizations where coalesce(warrant, '') <> ''
    union select voucher from public.payments where coalesce(voucher, '') <> ''
    union select warrant_no from public.warrant_pages where coalesce(warrant_no, '') <> ''
  )
  select count(*) into n from public.authorization_corrections k
   where not exists (select 1 from public.correction_is_admins c where c.correction_id = k.id)
     and exists (select 1 from w where k.reason like '%' || w.nn || '%');
  if n <> 0 then
    raise exception '% correction reason(s) name a warrant and are not Admin''s.', n;
  end if;

  raise notice 'no status note names a warrant, and every reason that does is Admin''s';
end $check$;

commit;
