-- Zion Vocational Rehab CRM — a closing reason belongs to a closed record
--
-- Owner, 6 November 2026: "V1028168 and V1041336: clear the 'never billed'
-- closed reason — they are Paid. Correction log."
--
-- Both were Closed, both turned out to have been paid, and the Phase 2
-- correction moved them to Paid and left the reason they had been closed with
-- sitting on them. The record said Paid in one field and said why it was
-- closed in the next one.
--
-- One of the two carries a different sentence from the one the exceptions
-- list reported: V1028168 says "never billed" and V1041336 gives a reason
-- about the client's services having ended. The contradiction is the same in
-- both and so is the fix; the report was wrong about the wording and this
-- migration is not quoting the second one, because it names a client.
--
-- ── why it is not just two updates ───────────────────────────
--
-- Nothing stopped this and nothing would have stopped the next one. The
-- warrant reader moves a Closed authorization to Paid every time it finds one
-- the state had paid, and nothing on that path has anything to say about a
-- field that only means something while the record is closed.
--
-- The reason a close happened is not lost by clearing the field, which is
-- what makes this safe: authorization_transition writes it into
-- authorization_events at the moment of closing - "was Due, became Closed,
-- note: <the reason>". The column is only the answer to "why is this record
-- closed", and off Closed there is no such question.
--
-- So the rule is now Closed if and only if there is a reason, in three
-- places, each for a different way in:
--
--   Leaving Closed clears it, silently, because by then it is a leftover and
--   the event log has it.
--
--   Writing one onto a record that is not closed is refused in a sentence,
--   because that is the path a person is on - the Closed reason is an
--   editable field on the Billing form - and a person who typed something
--   should be told rather than have it quietly dropped.
--
--   And a check constraint, which catches an insert and anything written
--   around the trigger. It is the half that cannot phrase itself, which is
--   why it is not the only half.
--
-- The two are a pair rather than two tries at the same thing, and the
-- consequence is worth knowing before somebody meets it: with the trigger
-- off - `disable trigger user`, which a bulk migration does - moving a
-- closed authorization to anything else is refused by the constraint until
-- the reason is cleared in the same statement. verify_authorization_is_the_bill
-- fails with that sentence rather than with a constraint's.
--
-- The function is replaced from the definition the database had, not from
-- 0315 which last defined it.

begin;

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
            case when new.status = 'Closed' then new.closed_reason
                 when new.status = 'Paid' then nullif(new.warrant, '')
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

-- ── the two records, and the log row each gets ───────────────
-- The reason is set for the transaction, which is what makes the correction
-- log hold these: a change to the Closed reason is a field that needs no
-- reason, so it is recorded only when somebody gives one.

select set_config('zion.correction_reason',
                  'Paid, so there is no reason it is closed. Cleared on the owner''s ruling of 6 November 2026.',
                  true);

update public.authorizations
   set closed_reason = ''
 where number in ('V1028168', 'V1041336')
   and status <> 'Closed'
   and coalesce(btrim(closed_reason), '') <> '';

-- ── and the half that catches an insert ──────────────────────
-- The other way round has been enforced since 0155: a closed authorization
-- says why. This is the same rule read from the other end.

alter table public.authorizations drop constraint if exists authorizations_reason_means_closed;
alter table public.authorizations add constraint authorizations_reason_means_closed
  check (status = 'Closed' or coalesce(btrim(closed_reason), '') = '');

commit;
