/**
 * The provider switch is read as whoever is asking, and an unreadable switch
 * says nothing rather than guessing (0392, amended).
 *
 * `verify_portal_rls` caught this the moment 0392 was applied: a
 * SECURITY DEFINER function a signed-in session can call, with no check of
 * who is calling, is a function that reads something with the practice's own
 * authority on behalf of somebody who may have none. The rule is a good one
 * and it is right about these two.
 *
 * The obvious fix is wrong here. Adding a guard that raises would put a
 * raising function in the column default of `sms_messages.provider` — so a
 * caller the guard did not expect would not be told it cannot read the
 * switch, it would be unable to record a message at all. A gate on the
 * switch must never become a gate on writing down what was said.
 *
 * So the authority goes instead of the guard. Both functions read as the
 * caller, and `org_settings_read` — active staff only — is the check of who
 * is asking. It is the better check of the two: it is the one every other
 * read of that table already passes, and there is no second opinion inside
 * the helper to disagree with it.
 *
 * And the coalesce goes with it. `coalesce(..., 'ghl')` could not tell "no
 * row" from "not allowed to look", so a refused read would have answered
 * 'ghl' with a straight face — the exact shape of the two faults this
 * practice has already been bitten by, where middleware read an auth error as
 * "revoked" and `getCurrentStaff` read a failed query as "no access". It
 * answers null now, and `lib/text-provider.ts` refuses the send.
 *
 * Mislabelling a message is not reachable by construction, which is worth
 * writing down because it is the one thing this could have cost. The only way
 * to insert an outgoing text is `sms_messages_write`, which asks
 * `current_staff_role()`; that returns a role only for a staff row that is
 * active; and an active staff row is exactly what `org_settings_read` wants.
 * Anybody who can write a text can read the switch.
 *
 * Tolerates the old code: the two functions keep their names, their arguments
 * and their return types, nothing deployed passes them anything, and the
 * column default they feed answers 'GoHighLevel' for every caller that could
 * write a row before this migration or after it.
 */

create or replace function public.sms_provider()
returns text
language sql
stable
security invoker
set search_path = public, pg_temp
as $$
  select sms_provider from public.org_settings where id = true
$$;

comment on function public.sms_provider() is
  'Which carrier is live: ghl, twilio, or null where the row could not be read. Null is not a default - lib/text-provider.ts refuses to send on it.';

/**
 * The same answer in the ledger's own words, and the dull one when there is
 * no answer.
 *
 * This is the default on `sms_messages.provider`, so it is the one function
 * here that has to give an answer whatever happens. 'GoHighLevel' is the dull
 * case on purpose: it is what every row has said since 0050, and a row
 * stamped with the carrier the practice has used for a year is the least
 * misleading thing a message with an unreadable switch could carry. Reaching
 * it needs a caller who can write a text and cannot read org_settings, which
 * the comment above explains cannot happen.
 */
create or replace function public.sms_provider_name()
returns text
language sql
stable
security invoker
set search_path = public, pg_temp
as $$
  select case public.sms_provider() when 'twilio' then 'Twilio' else 'GoHighLevel' end
$$;

revoke all on function public.sms_provider() from anon, public;
revoke all on function public.sms_provider_name() from anon, public;
grant execute on function public.sms_provider() to authenticated, service_role;
grant execute on function public.sms_provider_name() to authenticated, service_role;

do $$
declare v_n integer; v_name text;
begin
  for v_name in select unnest(array['sms_provider', 'sms_provider_name']) loop
    select count(*) into v_n from pg_proc p
     where p.pronamespace = 'public'::regnamespace and p.proname = v_name and p.prosecdef;
    if v_n <> 0 then
      raise exception '% still reads with the practice''s own authority', v_name;
    end if;
    select count(*) into v_n from information_schema.routine_privileges
     where routine_schema = 'public' and routine_name = v_name and grantee in ('anon', 'public');
    if v_n <> 0 then
      raise exception '% can be called by anon', v_name;
    end if;
  end loop;

  -- Still the right answers, read over a direct connection as the owner.
  if public.sms_provider() <> 'ghl' or public.sms_provider_name() <> 'GoHighLevel' then
    raise exception 'the switch now reads % / %', public.sms_provider(), public.sms_provider_name();
  end if;

  raise notice 'ok  the switch is read as whoever asks, and answers nothing rather than guessing';
end $$;
