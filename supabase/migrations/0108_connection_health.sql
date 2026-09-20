-- Zion Vocational Rehab CRM — a refused connection says so
--
-- set_microsoft_error has existed since 0029 and was never called by anything.
-- The consequence showed up on 19 September 2026: Microsoft began refusing
-- every refresh for the practice's own mailbox (AADSTS65001, consent), so mail
-- could be neither read nor sent - and the dashboard went on saying
-- "Connected … Sending and deleting from the CRM are on", because that card
-- reads the scopes recorded at connect time rather than whether the token
-- still works. Mail was down and every screen said it was fine.
--
-- That is the same failure the inbound texts webhook had: something breaks,
-- and the system reports success. The application now writes the refusal onto
-- the connection when a refresh is turned down, and clears it when one
-- succeeds. This migration adds the half that was missing - the nightly sweep
-- has no session, so it cannot use the function that checks current_staff_id.
--
-- Deliberately only a refused refresh. A single Graph call coming back 403 -
-- a shared mailbox Exchange has not granted, a permission for one feature -
-- is not a broken connection, and marking it as one would send somebody to
-- reconnect over something reconnecting cannot fix.

create or replace function public.set_microsoft_error_for_sync(p_staff_id uuid, p_error text)
returns void
language sql security definer set search_path = public as $$
  update public.microsoft_connections
     set last_error = coalesce(p_error, '')
   where staff_id = p_staff_id
     -- Nothing to write when it already says this: a healthy connection
     -- refreshes every hour and has no news each time.
     and last_error is distinct from coalesce(p_error, '');
$$;

-- The same economy for the signed-in path.
create or replace function public.set_microsoft_error(p_staff_id uuid, p_error text)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_staff_id is distinct from public.current_staff_id() and not public.is_admin() then
    raise exception 'Not yours to change.' using errcode = 'insufficient_privilege';
  end if;
  update public.microsoft_connections
     set last_error = coalesce(p_error, '')
   where staff_id = p_staff_id
     and last_error is distinct from coalesce(p_error, '');
end;
$$;

revoke execute on function public.set_microsoft_error_for_sync(uuid, text) from public, anon, authenticated;
grant execute on function public.set_microsoft_error_for_sync(uuid, text) to service_role;
