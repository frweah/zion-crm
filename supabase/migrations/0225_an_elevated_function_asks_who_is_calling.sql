-- Zion Vocational Rehab CRM — 0225 an elevated function asks who is calling
--
-- `verify_portal_rls` (which arrived with the portal) counts security-definer
-- functions a signed-in account can execute whose body never asks who is
-- calling. It named 39. Checked one at a time against the database, that
-- number is wrong in both directions, and both are worth writing down.
--
-- **Ten of the 39 are guarded and the check could not see it.** It looks for
-- the *names* of the guard helpers in the function body, so a guard one call
-- deeper is invisible to it. `bulk_close` checks `billing_hands()`, which
-- checks `current_staff_role()`; the check sees neither. Called as a real Job
-- Search member of staff, `bulk_close`, `bulk_mark_paid`,
-- `set_authorization_status`, `edit_authorization` and
-- `records_request_bundle` all refuse, in their own words. They were never
-- open. The check is corrected below to resolve guards through the call
-- graph, so a helper counts and a false alarm is not the thing people learn
-- to ignore.
--
-- **A portal client is `authenticated`.** There is a `portal_client`
-- database role, which is what made this look narrower than it is for a
-- while: it exists, and it is not what the portal signs in as. A client with
-- a portal login is a Supabase auth user with role `authenticated` and a
-- session claim, told apart from staff by `is_active_staff()` being false.
-- So everything `authenticated` may execute, a client of the practice may
-- execute. That is the right way to read the check, and it makes the readers
-- it names matter more rather than less.
--
-- That leaves five that genuinely never asked. Of those, `billing_followups_on`
-- went through: any member of staff could raise chase tasks across the whole
-- practice and shift every follow-up date fourteen days. The rest were closed
-- by luck rather than by design.
--
-- The twenty-four readers the check also names are left alone here and
-- reported instead. They are staff-only by role membership and they do not
-- write; narrowing them is its own piece of work with its own argument.

-- ─────────────────────────────────────────────────────────────
-- Refusing, and saying so
-- ─────────────────────────────────────────────────────────────
/**
 * One refusal, said the same way every time.
 *
 * The refusal is written to the database log rather than to a table, and not
 * for want of a table: the exception rolls the calling transaction back, and
 * an INSERT made just before it goes back with everything else. A WARNING
 * survives, because it is written by the server rather than by the
 * transaction. It carries who, what and when, and Supabase keeps it.
 *
 * So: `raise warning` for the record, then the exception for the caller, in
 * the words the person reading it needs.
 */
create or replace function public.refuse_elevated(p_function text, p_why text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_staff uuid := public.current_staff_id();
  v_role  text := public.current_staff_role();
begin
  raise warning '[refused] % by staff=% role=% at %',
    p_function, coalesce(v_staff::text, 'not staff'), coalesce(v_role, 'none'), now();
  raise exception '%', p_why using errcode = 'insufficient_privilege';
end;
$$;

comment on function public.refuse_elevated is
  'Logs a refused call to an elevated function and then refuses it (0225). The log is a server WARNING because an INSERT would be rolled back by the exception.';

revoke all on function public.refuse_elevated(text, text) from anon, authenticated;

-- ─────────────────────────────────────────────────────────────
-- 1. The sweep that any member of staff could run
-- ─────────────────────────────────────────────────────────────
--
-- billing_followups_on raises a chase task for every authorization still
-- unpaid after fourteen days and moves every follow-up date on. It is the
-- nightly sweep, called from /api/cron/notify with the service role, and it
-- is the one that went through when a Job Search account called it.
--
-- The caller check here is the grant itself. There is nobody signed in who
-- should be running the practice's nightly sweep by hand, so the answer is
-- not "which role" - it is "not a person at all". The service role is not
-- `authenticated` and keeps working.
revoke execute on function public.billing_followups_on(date) from authenticated;

-- ─────────────────────────────────────────────────────────────
-- 2 and 3. Two that are only ever called from inside the database
-- ─────────────────────────────────────────────────────────────
--
-- notify_staff_day is called by submit_staff_day, and placement_clock_started
-- by the two triggers on lead_matches. All three are security definer, so
-- they run as the owner and do not need the caller to hold the grant. Nothing
-- in the application calls either. Taking the grant away costs nothing and
-- closes both.
revoke execute on function public.notify_staff_day(uuid) from authenticated;
revoke execute on function public.placement_clock_started(uuid) from authenticated;

-- ─────────────────────────────────────────────────────────────
-- 4. The one that is not a writer at all
-- ─────────────────────────────────────────────────────────────
--
-- authorization_is_coaching only reads: it asks whether a service type starts
-- with "Job Coaching". It was marked volatile, which is what put it among the
-- writers. It is used inside the RLS policy on service_entries, so it has to
-- stay callable by staff; marking it stable is the honest fix and takes it
-- out of the writers without pretending it is guarded.
create or replace function public.authorization_is_coaching(p_auth uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.authorizations a
     where a.id = p_auth and a.service_type like 'Job Coaching%'
  )
$$;

-- ─────────────────────────────────────────────────────────────
-- 5. Sending the packet, and who it is sent by
-- ─────────────────────────────────────────────────────────────
--
-- submit_authorization_on_send moves an authorization to Submitted when the
-- signed USOR packet goes out. It is called from the client's Forms tab, by
-- whoever sends the packet, so the guard cannot be billing_hands() without
-- taking the forms flow away from the caseworkers who do it.
--
-- Two things change. It refuses anybody who is not active staff. And it stops
-- believing the caller about who they are: p_staff was passed in and written
-- to submitted_by, so a caller could record a submission under somebody
-- else's name. The caller's own staff id is used, and the parameter is kept
-- only so the screen does not have to change.
create or replace function public.submit_authorization_on_send(
  p_auth uuid, p_month text, p_recipient text, p_staff uuid
)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  a        public.authorizations;
  rule     public.billing_service_rules;
  v_period date;
  v_target uuid;
  v_me     uuid := public.current_staff_id();
begin
  if v_me is null then
    perform public.refuse_elevated('submit_authorization_on_send',
      'Only a member of staff marks a packet as sent.');
  end if;

  select * into a from public.authorizations where id = p_auth;
  if not found then return null; end if;
  select * into rule from public.billing_service_rules where service = a.service_type;

  if coalesce(rule.recurrence, 'One-time') = 'Monthly' then
    v_period := date_trunc('month',
      coalesce(to_date(nullif(p_month, ''), 'YYYY-MM'), public.practice_today()))::date;

    select id into v_target from public.authorizations
     where parent_id = coalesce(a.parent_id, a.id) and period = v_period;

    if v_target is null then
      insert into public.authorizations
        (client_id, number, service_type, funding_source, rate_type, rate,
         start_date, end_date, status, parent_id, period, requires_forms, note)
      select a.client_id, '', a.service_type, a.funding_source, a.rate_type, a.rate,
             a.start_date, a.end_date, 'Due', coalesce(a.parent_id, a.id), v_period,
             a.requires_forms,
             'Opened when the signed packet for ' || to_char(v_period, 'FMMonth YYYY') || ' was sent.'
        returning id into v_target;
    end if;
  else
    v_target := coalesce(a.parent_id, a.id);
  end if;

  -- Due first when it is still only Authorized: the flow does not skip a step
  -- just because the packet went out quickly.
  update public.authorizations set status = 'Due'
   where id = v_target and status = 'Authorized';

  update public.authorizations
     set status = 'Submitted',
         recipient = coalesce(nullif(p_recipient, ''), recipient),
         -- The caller's own id, not the one they handed in.
         submitted_by = coalesce(submitted_by, v_me)
   where id = v_target and status = 'Due';

  return v_target;
end;
$$;

revoke all on function public.submit_authorization_on_send(uuid, text, text, uuid) from anon, authenticated;
grant execute on function public.submit_authorization_on_send(uuid, text, text, uuid) to authenticated;
