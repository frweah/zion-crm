-- Zion Vocational Rehab CRM - a day's file knows its day
--
-- `staff_files.staff_day_id` has been on that table since 0212, for an end of
-- day that arrived as an email attachment. 0353 attached a file to the End of
-- day **line** and did not set it, so a file uploaded at clock out was
-- findable from the line and invisible to anything that asks a day for its
-- files.
--
-- Two links to the same thing is how one of them goes stale. Both are set
-- now, in the one place that attaches a file at all.

begin;

CREATE OR REPLACE FUNCTION public.clock_out(p_description text DEFAULT ''::text, p_category text DEFAULT NULL::text, p_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_client uuid DEFAULT NULL::uuid, p_staff_file uuid DEFAULT NULL::uuid, p_attachment uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_me      uuid := public.current_staff_id();
  t         public.work_session_timers;
  v_end     timestamptz;
  v_break   integer;
  v_hours   numeric;
  v_id      uuid;
  v_day     date;
  v_client  uuid;
  v_said    text;
  v_file    text;
  v_day_id  uuid;
  v_total   numeric;
  v_mgr     uuid;
  v_name    text;
  v_sort    integer;
  v_submitted timestamptz;
begin
  select * into t from public.work_session_timers where staff_id = v_me;
  if t.staff_id is null then
    raise exception 'You are not clocked in.' using errcode = 'no_data_found';
  end if;

  v_end := coalesce(p_at, now());
  v_break := t.break_seconds
             + case when t.break_started_at is null then 0
                    else greatest(0, extract(epoch from (v_end - t.break_started_at))::integer) end;

  v_hours := round(
    greatest(0, extract(epoch from (v_end - t.started_at))::numeric - v_break) / 3600.0, 2);

  if v_hours <= 0 then
    raise exception 'That session comes to nothing once the breaks are taken off.'
      using hint = 'Discard it rather than logging nothing.', errcode = 'check_violation';
  end if;

  -- The day the segment started in, which is the day it belongs to even when
  -- it finished after midnight (0293, unchanged).
  v_day := (t.started_at at time zone 'America/Denver')::date;
  v_client := coalesce(p_client, t.client_id);
  v_said := coalesce(btrim(p_description), '');

  insert into public.work_sessions
    (staff_id, worked_on, hours, description, category, client_id, created_by,
     started_at, ended_at, break_seconds)
  values (v_me, v_day, v_hours, v_said, p_category, v_client, v_me,
          t.started_at, v_end, v_break)
  returning id into v_id;

  delete from public.work_session_timers where staff_id = v_me;

  /*
   * The day's account.
   *
   * Only when there is something to record. A person who wrote nothing and
   * attached nothing is clocked out and the day is flagged until they say
   * what it was - writing an empty line here would answer the flag with
   * nothing, which is worse than the flag.
   */
  if p_staff_file is not null then
    select filename into v_file from public.staff_files where id = p_staff_file;
  elsif p_attachment is not null then
    select filename into v_file from public.attachments where id = p_attachment;
  end if;

  if v_said <> '' or v_file is not null then
    v_day_id := public.open_staff_day(v_day);

    select coalesce(max(sort_order), 0) + 1 into v_sort
      from public.staff_day_lines where day_id = v_day_id;

    insert into public.staff_day_lines
      (day_id, status, description, notes, client_id, sort_order,
       staff_file_id, attachment_id, from_clock_out)
    values (v_day_id, 'Complete',
            -- Named by the file when that is all there is, so the line says
            -- something rather than sitting blank on the form.
            case when v_said <> '' then v_said else v_file end,
            coalesce(p_category, ''), v_client, v_sort,
            p_staff_file, p_attachment, true);

    /*
     * A day somebody had already submitted, worked again.
     *
     * The line is appended - the work happened and the record is the record -
     * but the summary that went out at submission did not have it in it, so
     * the day carries an event saying so. Reopening it instead would be
     * deciding on somebody's behalf that the day is unfinished.
     */
    /*
     * And the file knows which day it belongs to.
     *
     * `staff_files.staff_day_id` has been there since 0212, for a day that
     * arrived as an email attachment. A file attached at clock out is the
     * same kind of thing, so it is linked the same way - otherwise anything
     * that looks for a day's files would have to learn about the line
     * column as well, and one of the two would be forgotten.
     */
    if p_staff_file is not null then
      update public.staff_files set staff_day_id = v_day_id where id = p_staff_file;
    end if;

    select submitted_at into v_submitted from public.staff_days where id = v_day_id;
    if v_submitted is not null then
      insert into public.staff_day_events (day_id, action, reason, by_staff)
      values (v_day_id, 'Added after submitting',
              'Clocked out again and said what the segment was', v_me);
    end if;
  end if;

  -- ── twelve hours across the day ────────────────────────────
  select sum(w.hours) into v_total
    from public.work_sessions w
   where w.staff_id = v_me and w.worked_on = v_day and public.hours_count(w.*);

  if v_total > 12 then
    select s.manager_id, s.name into v_mgr, v_name from public.staff s where s.id = v_me;
    if v_mgr is null then
      select intake_staff_id into v_mgr from public.org_settings limit 1;
    end if;
    if v_mgr is not null and v_mgr <> v_me then
      perform public.notify_person(
        v_mgr, 'clock_long_day',
        format('%s worked %s hours on %s, across %s segments.',
               coalesce(v_name, 'Somebody'), trim(to_char(v_total, 'FM990.99')),
               to_char(v_day, 'FMDD FMMon'),
               (select count(*) from public.work_sessions w
                 where w.staff_id = v_me and w.worked_on = v_day and public.hours_count(w.*))),
        -- Once for this person on this day, however many times they clock out
        -- after passing twelve.
        v_mgr::text || ':' || v_me::text || ':' || to_char(v_day, 'YYYYMMDD'),
        '/admin/hours', null, null, null, 'warn', v_me);
    end if;
  end if;

  return v_id;
end $function$;

commit;
