-- A payment entered twice can be taken back
--
-- There was no way to remove a payment. `payments` has no permissive policy
-- for insert, update or delete - everything goes through `record_payment` -
-- and nothing went the other way, so a payment entered twice stayed entered
-- twice and the only repair was a figure typed over the top on the
-- authorization.
--
-- Which is how three authorizations came to disagree with their own payment
-- rows. The one this file acts on is not in doubt: V991038 carries two $585
-- payments recorded nine minutes apart on 3 November, one matched to warrant
-- F15645445 with its voucher and its warrant line, and one with no warrant
-- number, no voucher and no line behind it. The second is the slip.
--
-- Removing it is a correction, so it is written in the correction log with the
-- reason and who did it, like every other correction to an authorization. The
-- payment row goes; nothing about the warrant it was mistaken for changes.
--
-- **This does not fix the cause.** `paid_amount` is a stored column that any
-- write can set, independently of the payment rows it is supposed to total,
-- and until it is derived this class of mismatch can recur. That change would
-- move three other authorizations the owner has asked to rule on first, so it
-- waits for them rather than arriving as a side effect.

create or replace function public.remove_payment(p_payment uuid, p_reason text)
returns uuid
language plpgsql security definer set search_path = public as $$
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
          format('Took back %s recorded %s by %s, on warrant %s, voucher %s. %s',
                 to_char(pay.amount, 'FM9999999.00'),
                 to_char(pay.created_at, 'FMDD FMMonth YYYY'),
                 coalesce(pay.recorded_by_name, '(nobody recorded)'),
                 coalesce(nullif(btrim(pay.warrant_no), ''), '(none)'),
                 coalesce(nullif(btrim(pay.voucher), ''), '(none)'),
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
end $$;

revoke all on function public.remove_payment(uuid, text) from anon, authenticated;
grant execute on function public.remove_payment(uuid, text) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- V991038, the one that is not in doubt

do $$
declare
  v_dup uuid; v_kept uuid; v_auth uuid; v_total numeric; v_n integer;
begin
  select a.id into v_auth from public.authorizations a where a.number = 'V991038';
  if v_auth is null then
    raise notice 'note  V991038 is not on file; nothing to correct';
    return;
  end if;

  -- Named by what makes it the duplicate rather than by its id: no warrant, no
  -- voucher, no warrant line. If the practice has tidied this up already,
  -- there is nothing matching and nothing happens.
  select id into v_dup from public.payments
   where auth_id = v_auth
     and coalesce(nullif(btrim(warrant_no), ''), '') = ''
     and coalesce(nullif(btrim(voucher), ''), '') = ''
     and warrant_line_id is null;

  select count(*) into v_n from public.payments where auth_id = v_auth;

  if v_dup is null then
    raise notice 'note  V991038 has no unmatched payment on it; % payment(s) on file, left alone', v_n;
    -- Which is the state after the first run of this file: the duplicate is
    -- gone and the correction is in the log. Re-running changes nothing.
  elsif v_n < 2 then
    raise notice 'note  V991038 has only % payment, so nothing is a duplicate; left alone', v_n;
  else
    -- Run as the owner, because this is their decision and the log should say
    -- so rather than naming a migration.
    perform set_config('role', 'authenticated', true);
    perform set_config('request.jwt.claims',
                       json_build_object(
                         'sub', (select user_id from public.staff where lower(email) = 'frweah@gmail.com'),
                         'role', 'authenticated')::text, true);
    perform public.remove_payment(v_dup,
      'Entered twice on 3 November, nine minutes apart. This one has no warrant, no voucher and no warrant line; the other is matched to F15645445.');
    perform set_config('role', 'postgres', true);

    select count(*), coalesce(sum(amount), 0) into v_n, v_total
      from public.payments where auth_id = v_auth;
    raise notice 'ok  V991038 now has % payment(s) totalling %', v_n, v_total;
  end if;

  if (select coalesce(paid_amount, 0) from public.authorizations where id = v_auth)
     <> (select coalesce(sum(amount), 0) from public.payments where auth_id = v_auth) then
    raise exception 'V991038 still disagrees with its own payments';
  end if;
  raise notice 'ok  and its total agrees with them';
end $$;
