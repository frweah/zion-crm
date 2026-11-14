-- Zion Vocational Rehab CRM - the phone says what the day was too
--
-- Clock out asks for the day's account (0353), and the phone is where half
-- this practice clocks out: in a car park after a job site visit, often with
-- no signal. So the question is asked there, the answer goes in the outbox
-- with the clock-out it belongs to, and the two arrive together or not at
-- all.
--
-- A new signature is a new function (0309), so the old three-argument form
-- goes rather than sitting beside this one with the phone app calling
-- whichever Postgres picks.
--
-- No upload from the phone at clock out. The outbox puts its bytes under
-- `clients/<id>/` in the client bucket, which is the right place for a
-- recording and the wrong place for somebody's own account of their day -
-- that belongs in their staff file, which the outbox has no path to. The
-- phone takes the words; a file goes on from the End of day form, which is
-- where the owner said editing lives.

begin;

drop function if exists public.phone_clock(uuid, text, timestamptz);

CREATE OR REPLACE FUNCTION public.phone_clock(
  p_key uuid,
  p_kind text,
  p_at timestamp with time zone,
  p_said text DEFAULT '',
  p_category text DEFAULT NULL,
  p_client uuid DEFAULT NULL)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_me   uuid := public.current_staff_id();
  t      public.work_session_timers;
  v_last timestamptz;
  v_id   uuid;
begin
  if p_kind not in ('clock in', 'break', 'back', 'clock out') then
    raise exception 'Say clock in, break, back or clock out.' using errcode = 'check_violation';
  end if;
  if p_at is null then
    raise exception 'That came without the time it was pressed.' using errcode = 'check_violation';
  end if;
  if p_at > now() + interval '2 minutes' then
    raise exception 'The phone''s clock is ahead of the practice''s — check the time on the phone, then send it again.'
      using errcode = 'check_violation';
  end if;
  if p_at < now() - interval '1 day' then
    raise exception 'That was pressed more than a day ago — correct it on Time clock instead.'
      using errcode = 'check_violation';
  end if;
  if not public.phone_claim(p_key, p_kind, p_at) then
    return 'already';
  end if;
  select * into t from public.work_session_timers where staff_id = v_me;
  if p_kind = 'clock in' then
    if t.staff_id is not null then
      raise exception 'You are already clocked in.'
        using hint = 'Clock out first, or start a break.', errcode = 'unique_violation';
    end if;
    select max(ended_at) into v_last from public.work_sessions where staff_id = v_me;
    if v_last is not null and p_at < v_last then
      raise exception 'That is before your last session ended — correct it on Time clock instead.'
        using errcode = 'check_violation';
    end if;
    insert into public.work_session_timers (staff_id, started_at, note, client_id, last_seen_at)
    values (v_me, p_at, '', null, now());
  elsif p_kind = 'break' then
    if t.staff_id is null then
      raise exception 'You are not clocked in.' using errcode = 'no_data_found';
    end if;
    if t.break_started_at is not null then
      raise exception 'You are already on a break.' using errcode = 'check_violation';
    end if;
    if p_at < t.started_at then
      raise exception 'That break starts before you clocked in.' using errcode = 'check_violation';
    end if;
    update public.work_session_timers
       set break_started_at = p_at, last_seen_at = now()
     where staff_id = v_me;
  elsif p_kind = 'back' then
    if t.staff_id is null then
      raise exception 'You are not clocked in.' using errcode = 'no_data_found';
    end if;
    if t.break_started_at is null then
      raise exception 'You are not on a break.' using errcode = 'check_violation';
    end if;
    if p_at < t.break_started_at then
      raise exception 'That is before the break started.' using errcode = 'check_violation';
    end if;
    update public.work_session_timers
       set break_seconds = break_seconds + greatest(0, extract(epoch from (p_at - t.break_started_at))::integer),
           break_started_at = null,
           last_seen_at = now()
     where staff_id = v_me;
  else
    if t.staff_id is not null and p_at < t.started_at then
      raise exception 'That clock-out is before you clocked in.' using errcode = 'check_violation';
    end if;
    -- The day's account, written on the phone and carried through the
    -- outbox with the clock-out it belongs to. A phone with no signal keeps
    -- both together, so the account cannot arrive without its segment or
    -- the segment without its account.
    v_id := public.clock_out(coalesce(p_said, ''), nullif(btrim(coalesce(p_category, '')), ''), p_at, p_client);
    update public.phone_receipts set result = v_id where key = p_key;
  end if;
  return 'done';
end $function$;

revoke all on function public.phone_clock(uuid, text, timestamptz, text, text, uuid)
  from public, anon, authenticated;
grant execute on function public.phone_clock(uuid, text, timestamptz, text, text, uuid)
  to authenticated;

commit;
