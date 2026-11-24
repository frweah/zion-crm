/**
 * The ledger says who did it (owner, 24 November 2026).
 *
 * On 23 November another session working for the owner recorded four payments
 * from warrant stubs by direct SQL. The money was right and the stubs prove
 * it, but `recorded_by` was null on all four and `recorded_by_name` was a
 * string nothing in this practice issues - so the ledger held four entries
 * that no account, no session and no screen was answerable for, and three of
 * them were missing the invoice they paid. `verify_invoices` found the
 * missing invoices the next evening. Nothing found the missing authorship,
 * because nothing was asking.
 *
 * Grants were not the gap. Nobody signed in can write `payments`, `invoices`,
 * `authorization_corrections` or `warrant_lines` at all - `authenticated` has
 * no insert, update or delete on any of them, which is how the ledger has
 * been held since 0114, and the only way in for a person is a SECURITY
 * DEFINER function that stamps who they are. The service role and a direct
 * connection go round both grants and row level security, and that is the
 * door this closes.
 *
 * What it asks of a write: either it came from inside one of the ledger's own
 * functions, or it names a real active staff member. The first is how the
 * practice's own paths work, including the ones with no person behind them -
 * the reader reconciling a warrant page runs as the service role and has no
 * staff id, and `reconcile_warrant_line` is what vouches for it. The second
 * is what a hand-written repair has to do: name whose act it is.
 *
 * It asks by reading the call stack, not a session variable. The practice
 * already has the variable convention - `zion.reconciling`, set and cleared
 * by the function around its work - and it is the right shape for telling a
 * trigger what is going on. It is the wrong shape for a rule about who may
 * write, because anybody who can write directly can also set the variable.
 * A call stack cannot be arranged without actually calling the function.
 *
 * What this deliberately does not do is make `payments.recorded_by` NOT NULL.
 * 147 of the 164 payments on file have no `recorded_by`: they came in from
 * the workbook and from warrant stubs before there was a person to record,
 * and filling them in with the owner's name would be inventing an authorship
 * for 147 rows to satisfy a constraint. A NOT VALID check would refuse any
 * later edit of those rows, which is exactly what reconciliation does to
 * them. So the rule is enforced where the authorship is actually decided - on
 * the way in - and the 147 are left saying what they honestly know.
 *
 * Tolerates the old code: the refusal fires only on a write that comes from
 * outside the ledger functions and names nobody, and no screen can make one -
 * there are no write grants on these tables for anybody signed in. An older
 * deployment sends exactly what the new one sends.
 */

create or replace function public.the_ledger_says_who()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
  /**
   * The ledger's own functions, every one of which stamps who the caller is
   * or has already checked that the caller may do this without being a
   * person. `verify_the_ledger_says_who` asserts this list against the
   * catalog, so a twelfth function that writes one of these tables cannot
   * quietly arrive and be refused in production.
   *
   * `reconcile_warrant_line` is here and `reconcile_warrant_page` is not:
   * the page function only calls the line function, which is what writes,
   * and the stack names the inner one. The catalog assertion found it on
   * this list, writing nothing.
   */
  k_blessed constant text[] := array[
    'record_payment',
    'remove_payment',
    'payment_settles_the_invoice',
    'raise_invoice',
    'reconcile_warrant_line',
    'correct_authorization',
    'authorization_correction_log',
    'add_warrant_line',
    'correct_warrant_line',
    'dismiss_warrant_line'
  ];
  v_col   text := tg_argv[0];
  v_what  text := tg_argv[1];
  v_stack text;
  v_fn    text;
  v_who   uuid;
begin
  get diagnostics v_stack = pg_context;
  foreach v_fn in array k_blessed loop
    if position('function ' || v_fn || '(' in v_stack) > 0 then
      return new;
    end if;
  end loop;

  execute format('select ($1).%I', v_col) into v_who using new;
  if v_who is not null and exists (select 1 from public.staff s where s.id = v_who and s.active) then
    return new;
  end if;

  raise exception '% has to say who did it - record it on the screen that does, or name the staff member whose act it is.', v_what
    using errcode = 'check_violation';
end $$;

comment on function public.the_ledger_says_who() is
  'Refuses a ledger write that comes from outside the ledger functions and names no active staff member.';

-- Tolerates the old code: the refusal fires only on a write that comes from
-- outside the ledger functions and names nobody, and no screen can make one -
-- there are no write grants on these four tables for anybody signed in, so
-- every path a deployment has is a function on the blessed list. An older
-- deployment sends exactly what the new one sends.
drop trigger if exists payments_say_who on public.payments;
create trigger payments_say_who
  before insert on public.payments
  for each row execute function public.the_ledger_says_who('recorded_by', 'A payment');

drop trigger if exists invoices_say_who on public.invoices;
create trigger invoices_say_who
  before insert on public.invoices
  for each row execute function public.the_ledger_says_who('submitted_by', 'An invoice');

drop trigger if exists authorization_corrections_say_who on public.authorization_corrections;
create trigger authorization_corrections_say_who
  before insert on public.authorization_corrections
  for each row execute function public.the_ledger_says_who('staff_id', 'A correction');

/**
 * A warrant line arrives undecided - the reader posts the page and the lines
 * on it, and nobody has said anything yet - so the insert is not the act this
 * is about. The decision is: this line pays that authorization, and here is
 * the payment. That is what has to say who.
 */
drop trigger if exists warrant_lines_say_who on public.warrant_lines;
create trigger warrant_lines_say_who
  before update on public.warrant_lines
  for each row
  when (new.decided_at is distinct from old.decided_at
        or new.payment_id is distinct from old.payment_id)
  execute function public.the_ledger_says_who('decided_by', 'A warrant decision');
