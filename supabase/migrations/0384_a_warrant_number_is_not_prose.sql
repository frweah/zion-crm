/**
 * A warrant number is not prose (owner, 24 November 2026).
 *
 * Warrants are Admin's (owner, 14 November). Every structured route was
 * closed that week: `payments.warrant_no`, `invoices.warrant` and
 * `authorizations.warrant` are not granted to `authenticated` at all, a
 * correction whose field is 'Warrant' is hidden from everybody but Admin, and
 * the warrant tables answer `warrant_hands()`.
 *
 * Prose was the one route none of that could close. On 24 November a search
 * of every text column found exactly one leak - a sentence somebody had typed
 * into an authorization's note, which Billing reads - and the owner approved
 * taking it out. A column grant cannot stop the next one, because the column
 * it would have to close is the one the note is typed into.
 *
 * So the sentence is refused as it is saved. Admin may write one: they may
 * read warrants, so a note of theirs that names one tells nobody anything
 * they could not already see. For every other role it is refused with a
 * sentence naming where the number belongs, and `verify_no_warrant_in_prose`
 * then asserts that no Billing-readable text column holds one - which is the
 * same rule asked of the data rather than of the next keystroke.
 *
 * Tolerates the old code: the refusal fires only on text no screen is
 * supposed to send, and every screen that saves a note already shows
 * `error.message` as it comes back, so an older deployment refuses the same
 * save with the same sentence. Nothing has to change to send it.
 */

/**
 * What a warrant or a voucher looks like here, which is a question about this
 * practice's numbers rather than about numbers in general:
 *
 *   a warrant is F and eight digits - 163 payments, 160 invoices and 143
 *   authorizations, every one of them that shape;
 *
 *   a voucher is two digits, two letters and eleven digits - all 588 of them;
 *
 *   and the words themselves, followed by a long run of digits, because
 *   "paid on warrant 12345678" is the same leak written another way. Six
 *   digits is the floor: a four-digit number after the word is a year or an
 *   amount.
 *
 * An authorization number is C or V and seven to thirteen digits, and is
 * deliberately not matched. Staff write those in notes all day; they are the
 * one number on a Billing screen that belongs to Billing.
 */
create or replace function public.warrant_shaped(p_text text)
returns boolean
language sql
immutable
set search_path = public, pg_temp
as $$
  select coalesce(p_text, '') ~* '(\yF[0-9]{8}\y)|(\y[0-9]{2}[A-Za-z]{2}[0-9]{11}\y)|((warrant|voucher)[^0-9A-Za-z]{0,12}[0-9]{6,})'
$$;

comment on function public.warrant_shaped(text) is
  'Whether a string holds a warrant number, a voucher number, or either word followed by a long run of digits.';

revoke all on function public.warrant_shaped(text) from anon, public;
grant execute on function public.warrant_shaped(text) to authenticated;

/**
 * The refusal.
 *
 * One function for both tables, taking the column it guards as a trigger
 * argument, because the rule is the same rule and the sentence somebody reads
 * should not depend on which screen they typed it into.
 *
 * Only when the text changed. A note from before this rule - there are none,
 * which is what the verify script asserts - would otherwise refuse every
 * later edit of the row it is on, including the edit taking the number out.
 */
create or replace function public.prose_is_not_a_warrant()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
  v_col text := tg_argv[0];
  v_new text;
  v_old text;
begin
  execute format('select ($1).%I', v_col) into v_new using new;
  if tg_op = 'UPDATE' then
    execute format('select ($1).%I', v_col) into v_old using old;
    if v_new is not distinct from v_old then
      return new;
    end if;
  end if;

  if not public.warrant_shaped(v_new) then
    return new;
  end if;

  -- Admin reads warrants, so an Admin writing one here tells nobody anything.
  if (select public.is_admin()) then
    return new;
  end if;

  raise exception 'A warrant or voucher number goes on the payment, not in the text - take it out and ask Admin to record the payment.';
end $$;

comment on function public.prose_is_not_a_warrant() is
  'Refuses a warrant or voucher number typed into a text column, for every role but Admin.';

-- Tolerates the old code: the refusal fires only on a warrant or voucher
-- number typed into a note, which no screen is supposed to send, and every
-- screen that saves one already shows error.message as it comes back - so an
-- older deployment refuses the same save with the same sentence.
create trigger notes_no_warrant_number
  before insert or update on public.notes
  for each row execute function public.prose_is_not_a_warrant('text');

create trigger authorizations_no_warrant_number
  before insert or update on public.authorizations
  for each row execute function public.prose_is_not_a_warrant('note');
