-- Zion Vocational Rehab CRM — 0249 the day is sent as it was written
--
-- Rei writes a day's tasks with sub-points indented under them, and until now
-- the form threw the indentation away: the fields were trimmed on the way in
-- and single-line inputs could not hold a line break at all. They are boxes
-- that keep what is typed now, which leaves the summary - the thing that is
-- actually emailed - as the one place the text could still be altered.
--
-- The note used to be written out as `E'\n    ' || notes`: four spaces, then
-- the note. **That was not mangling it** - a prefix leaves the note itself
-- untouched, and this was checked rather than assumed, by putting the four
-- spaces back and watching the round-trip still pass. What actually destroyed
-- Rei's indentation was the `trim()` on the way in and a single-line input
-- that could not hold a line break at all, and both of those are in the app.
--
-- The four spaces go for a different and smaller reason: they indent the
-- *first* line of a three-line note and leave the other two flush against the
-- margin, which reads as a hierarchy that is not there. The day record and
-- the team view now show a note in its own shape, and the email should agree
-- with them rather than add a shape of its own.
--
-- **So nothing is added to it.** The note goes into the summary exactly as it
-- was typed, on its own lines, which also makes the owner's test a thing that
-- can be asked rather than argued about: the note is a substring of the
-- email, byte for byte. The fault that test is really guarding against is a
-- summary that re-indents the note's *inner* lines - `replace(notes, E'\n',
-- E'\n    ')` - which looks tidier and is somebody's writing rewritten.
--
-- The cost of that choice, stated rather than discovered later: a note whose
-- own line begins with a hyphen or a number will be read back as a task if
-- somebody pastes yesterday's email into the paste box. The alternative was
-- to re-indent every line, and re-indenting is changing what somebody wrote.
--
-- The blank line before the note is what separates it from the task above
-- when the task itself runs to several lines. It is outside the note, so it
-- does not touch the text.

create or replace function public.staff_day_summary(p_day_id uuid)
returns text
language sql stable security definer set search_path = public as $$
  select case when public.reader_may_answer() then (
    with d as (
        select sd.*, s.name as staff_name, m.name as manager_name
          from public.staff_days sd
          join public.staff s on s.id = sd.staff_id
          left join public.staff m on m.id = sd.manager_id
         where sd.id = p_day_id
      ),
      lines as (
        select l.status, l.description, l.notes, c.name as client_name, l.sort_order, l.created_at
          from public.staff_day_lines l
          left join public.clients c on c.id = l.client_id
         where l.day_id = p_day_id
      )
      select concat_ws(E'\n',
        'END OF THE DAY REPORT',
        '',
        'Name of the Employee: ' || d.staff_name,
        'Department/Agency: ' || coalesce(nullif(d.role_at_time, ''), '-'),
        'Date Prepared: ' || to_char(d.day, 'FMMonth FMDD, YYYY'),
        'Assigned Manager/Team Leader: ' || coalesce(d.manager_name, '-'),
        '',
        'TASKS LIST',
        coalesce((
          select string_agg(
                   '- [' || l.status || '] ' || l.description
                   || case when l.client_name is not null then ' (' || l.client_name || ')' else '' end
                   -- The note, as it was typed. Nothing is prefixed to it and
                   -- nothing is inserted into it.
                   || case when nullif(l.notes, '') is not null then E'\n' || l.notes else '' end,
                   E'\n' order by l.sort_order, l.created_at)
            from lines l), '- nothing recorded'),
        '',
        'BOTTLENECKS',
        coalesce(nullif(d.bottlenecks, ''), 'None.'),
        '',
        'ACTIONS TAKEN/SUGGESTIONS',
        coalesce(nullif(d.actions_taken, ''), 'None.')
      )
      from d
  ) end;
$$;

comment on function public.staff_day_summary is
  'The day as an email. Every field goes in exactly as it was typed, so a multi-line note is a substring of the message (0249).';

revoke all on function public.staff_day_summary(uuid) from anon, authenticated;
grant execute on function public.staff_day_summary(uuid) to authenticated;
