-- Zion Vocational Rehab CRM — the end of the day
-- (owner, 18 Oct 2026)
--
-- The practice already has an end-of-day report. It is an Excel template in
-- Office/TEAM/EOD REPORTS that each person copies, fills in and downloads as
-- a PDF, and the finished days arrive by email. This is that form, in the
-- CRM, with the same headings:
--
--   Name of the Employee · Department/Agency · Date Prepared ·
--   Assigned Manager/Team Leader
--   TASKS LIST: STATUS | DESCRIPTION | NOTES
--   BOTTLENECKS: ACTIONS TAKEN/SUGGESTIONS
--
-- Three things the spreadsheet could not do, and which are the reason for
-- moving it:
--
--   A line about a client lands on that client's record. In the spreadsheet
--   the day's work and the client's history were two different places, and
--   only one of them was ever read again.
--
--   What was left unfinished yesterday is already on today's form. Nobody
--   retypes a Pending line for a week.
--
--   The day can be submitted once, and reopening it is written down.
--
-- The status wording is the template's, shortened as the owner asked:
-- Complete, In-Progress, Pending. The template's third is "Pending/ To do".

-- ─────────────────────────────────────────────────────────────
-- Who a person reports to
--
-- The template's "Assigned Manager/Team Leader". Nothing in the CRM knew it
-- until now; Admin sets it on a person's record. Null is allowed and means
-- the summary goes to Admin alone, which is what happens today anyway.
-- ─────────────────────────────────────────────────────────────
alter table public.staff
  add column if not exists manager_id uuid references public.staff(id) on delete set null;

comment on column public.staff.manager_id is
  'Who this person reports to - the end-of-day report''s Assigned Manager (0211). Null means Admin.';

-- ─────────────────────────────────────────────────────────────
-- A day
--
-- The role and the manager are copied onto the day when it is submitted,
-- rather than read through a join afterwards. Both change, and a report from
-- June should read the way it read in June.
-- ─────────────────────────────────────────────────────────────
create table if not exists public.staff_days (
  id            uuid primary key default gen_random_uuid(),
  staff_id      uuid not null references public.staff(id) on delete cascade,
  day           date not null,
  role_at_time  text not null default '',
  manager_id    uuid references public.staff(id) on delete set null,
  bottlenecks   text not null default '',
  actions_taken text not null default '',
  submitted_at  timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint staff_days_one_per_person_per_day unique (staff_id, day)
);

create index if not exists staff_days_person_idx on public.staff_days (staff_id, day desc);
create index if not exists staff_days_day_idx on public.staff_days (day desc);

comment on table public.staff_days is
  'One end-of-day report per person per day, modelled on the practice''s EOD template (0211).';

create table if not exists public.staff_day_lines (
  id             uuid primary key default gen_random_uuid(),
  day_id         uuid not null references public.staff_days(id) on delete cascade,
  status         text not null check (status in ('Complete', 'In-Progress', 'Pending')),
  description    text not null check (btrim(description) <> ''),
  notes          text not null default '',
  client_id      uuid references public.clients(id) on delete set null,
  -- The line on an earlier day that this one continues, when it was carried.
  carried_from   uuid references public.staff_day_lines(id) on delete set null,
  sort_order     integer not null default 0,
  -- What it wrote to the client's contact log, so submitting twice cannot
  -- write it twice.
  contact_log_id uuid references public.contact_log(id) on delete set null,
  created_at     timestamptz not null default now()
);

create index if not exists staff_day_lines_day_idx on public.staff_day_lines (day_id, sort_order);
create index if not exists staff_day_lines_client_idx on public.staff_day_lines (client_id)
  where client_id is not null;

create table if not exists public.staff_day_events (
  id       uuid primary key default gen_random_uuid(),
  day_id   uuid not null references public.staff_days(id) on delete cascade,
  action   text not null check (action in ('Submitted', 'Reopened')),
  reason   text not null default '',
  by_staff uuid references public.staff(id) on delete set null,
  at       timestamptz not null default now()
);

create index if not exists staff_day_events_day_idx on public.staff_day_events (day_id, at);

-- ─────────────────────────────────────────────────────────────
-- A submitted day is closed
--
-- Reopening it is a decision somebody makes and it is written down; editing
-- it quietly afterwards is not a thing the form offers.
-- ─────────────────────────────────────────────────────────────
create or replace function public.staff_day_is_open()
returns trigger language plpgsql set search_path = public as $$
declare
  v_day uuid := coalesce(new.day_id, old.day_id);
  v_at  timestamptz;
begin
  select submitted_at into v_at from public.staff_days where id = v_day;
  if v_at is not null then
    raise exception 'That day has been submitted. Reopen it first if it needs changing.'
      using errcode = 'check_violation';
  end if;
  return coalesce(new, old);
end;
$$;

drop trigger if exists staff_day_lines_open on public.staff_day_lines;
create trigger staff_day_lines_open
  before insert or update or delete on public.staff_day_lines
  for each row execute function public.staff_day_is_open();

/**
 * The same for the day's own fields.
 *
 * submitted_at itself is how submitting and reopening work, so a change to
 * it is allowed; everything else on a submitted day is not.
 */
create or replace function public.staff_day_body_is_open()
returns trigger language plpgsql set search_path = public as $$
begin
  if old.submitted_at is not null and new.submitted_at is not null
     and (new.bottlenecks is distinct from old.bottlenecks
          or new.actions_taken is distinct from old.actions_taken) then
    raise exception 'That day has been submitted. Reopen it first if it needs changing.'
      using errcode = 'check_violation';
  end if;
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists staff_days_body_open on public.staff_days;
create trigger staff_days_body_open
  before update on public.staff_days
  for each row execute function public.staff_day_body_is_open();

-- ─────────────────────────────────────────────────────────────
-- Today's form
--
-- Opened on first sight, with whatever was left unfinished already on it.
--
-- "Yesterday" is the last day this person actually submitted, not the
-- calendar day before: on a Monday, what is still Pending is Friday's, and
-- carrying from an empty Sunday would lose it.
-- ─────────────────────────────────────────────────────────────
create or replace function public.open_staff_day(p_day date default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_me    uuid := public.current_staff_id();
  v_day   date := coalesce(p_day, public.practice_today());
  v_id    uuid;
  v_prev  uuid;
begin
  if v_me is null then
    raise exception 'Only a member of staff has a day to fill in.'
      using errcode = 'insufficient_privilege';
  end if;
  if v_day > public.practice_today() then
    raise exception 'That day has not happened yet.' using errcode = 'check_violation';
  end if;

  select id into v_id from public.staff_days where staff_id = v_me and day = v_day;
  if v_id is not null then
    return v_id;
  end if;

  insert into public.staff_days (staff_id, day, role_at_time, manager_id)
  select v_me, v_day, s.role, s.manager_id from public.staff s where s.id = v_me
  returning id into v_id;

  -- What was left unfinished on the last day they submitted.
  select id into v_prev
    from public.staff_days
   where staff_id = v_me and day < v_day and submitted_at is not null
   order by day desc limit 1;

  if v_prev is not null then
    insert into public.staff_day_lines (day_id, status, description, notes, client_id, carried_from, sort_order)
    select v_id, l.status, l.description, l.notes, l.client_id, l.id,
           row_number() over (order by l.sort_order, l.created_at)
      from public.staff_day_lines l
     where l.day_id = v_prev
       and l.status in ('In-Progress', 'Pending');
  end if;

  return v_id;
end;
$$;

comment on function public.open_staff_day(date) is
  'Today''s end-of-day form for the signed-in person, carrying forward what was still In-Progress or Pending on the last day they submitted (0211).';

revoke all on function public.open_staff_day(date) from anon, authenticated;
grant execute on function public.open_staff_day(date) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- The day, as a piece of writing
--
-- One shape, read by the email, by the notification and by the screen, so
-- the three cannot tell different stories.
-- ─────────────────────────────────────────────────────────────
create or replace function public.staff_day_summary(p_day_id uuid)
returns text language sql stable security definer set search_path = public as $$
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
               || case when nullif(l.notes, '') is not null then E'\n    ' || l.notes else '' end,
               E'\n' order by l.sort_order, l.created_at)
        from lines l), '- nothing recorded'),
    '',
    'BOTTLENECKS',
    coalesce(nullif(d.bottlenecks, ''), 'None.'),
    '',
    'ACTIONS TAKEN/SUGGESTIONS',
    coalesce(nullif(d.actions_taken, ''), 'None.')
  )
  from d;
$$;

revoke all on function public.staff_day_summary(uuid) from anon, authenticated;
grant execute on function public.staff_day_summary(uuid) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- Submitting
--
-- Locks the day, puts every client line on that client's record, and writes
-- down that it happened. The contact-log row is remembered on the line, so a
-- reopen and a second submit do not write the client's history twice.
-- ─────────────────────────────────────────────────────────────
create or replace function public.submit_staff_day(p_day_id uuid)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_me   uuid := public.current_staff_id();
  v_day  public.staff_days%rowtype;
  v_n    integer;
  r      record;
  v_log  uuid;
begin
  select * into v_day from public.staff_days where id = p_day_id for update;
  if not found then
    raise exception 'That day is not on file.' using errcode = 'no_data_found';
  end if;
  if v_day.staff_id is distinct from v_me then
    raise exception 'A day is submitted by the person whose day it is.'
      using errcode = 'insufficient_privilege';
  end if;
  if v_day.submitted_at is not null then
    raise exception 'That day has already been submitted.' using errcode = 'check_violation';
  end if;

  select count(*) into v_n from public.staff_day_lines where day_id = p_day_id;
  if v_n = 0 then
    raise exception 'A day needs at least one line before it is submitted.'
      using errcode = 'check_violation';
  end if;

  -- The role and the manager as they are now, so the report keeps them.
  update public.staff_days sd
     set submitted_at = now(),
         role_at_time = coalesce(nullif(sd.role_at_time, ''), s.role),
         manager_id   = coalesce(sd.manager_id, s.manager_id)
    from public.staff s
   where sd.id = p_day_id and s.id = sd.staff_id;

  -- Every line about a client, on that client's record.
  for r in
    select l.id, l.client_id, l.status, l.description, l.notes
      from public.staff_day_lines l
     where l.day_id = p_day_id
       and l.client_id is not null
       and l.contact_log_id is null
     order by l.sort_order
  loop
    insert into public.contact_log (client_id, date, method, topic, outcome, staff_id)
    values (r.client_id, v_day.day, 'End of day report',
            r.description,
            case when nullif(r.notes, '') is null then r.status
                 else r.status || ' - ' || r.notes end,
            v_me)
    returning id into v_log;

    update public.staff_day_lines set contact_log_id = v_log where id = r.id;
  end loop;

  insert into public.staff_day_events (day_id, action, by_staff) values (p_day_id, 'Submitted', v_me);

  return public.staff_day_summary(p_day_id);
end;
$$;

comment on function public.submit_staff_day(uuid) is
  'Locks a day, writes its client lines to those clients'' contact logs, and returns the summary (0211).';

revoke all on function public.submit_staff_day(uuid) from anon, authenticated;
grant execute on function public.submit_staff_day(uuid) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- Reopening
--
-- The same day only. A day reopened a week later is a different thing from a
-- correction made before going home, and only the second is a mistake being
-- fixed rather than history being rewritten.
-- ─────────────────────────────────────────────────────────────
create or replace function public.reopen_staff_day(p_day_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_me  uuid := public.current_staff_id();
  v_day public.staff_days%rowtype;
begin
  select * into v_day from public.staff_days where id = p_day_id for update;
  if not found then
    raise exception 'That day is not on file.' using errcode = 'no_data_found';
  end if;
  if v_day.staff_id is distinct from v_me and not public.is_admin() then
    raise exception 'A day is reopened by the person whose day it is, or by an Admin.'
      using errcode = 'insufficient_privilege';
  end if;
  if v_day.submitted_at is null then
    raise exception 'That day has not been submitted.' using errcode = 'check_violation';
  end if;
  if v_day.day <> public.practice_today() then
    raise exception 'A day can be reopened on the day it covers. % was % - ask an Admin to correct it.',
      to_char(v_day.day, 'FMMonth FMDD'), to_char(v_day.day, 'Dy')
      using errcode = 'check_violation';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'Say why it is being reopened.' using errcode = 'check_violation';
  end if;

  update public.staff_days set submitted_at = null where id = p_day_id;
  insert into public.staff_day_events (day_id, action, reason, by_staff)
  values (p_day_id, 'Reopened', btrim(p_reason), v_me);
end;
$$;

revoke all on function public.reopen_staff_day(uuid, text) from anon, authenticated;
grant execute on function public.reopen_staff_day(uuid, text) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- Who sees a day
--
-- Their own, an Admin's all, and a manager their own people's - because the
-- summary is sent to the manager, and a notification they cannot open is
-- not worth sending.
-- ─────────────────────────────────────────────────────────────
alter table public.staff_days enable row level security;
alter table public.staff_day_lines enable row level security;
alter table public.staff_day_events enable row level security;

create or replace function public.day_is_mine_to_see(p_staff uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select p_staff = public.current_staff_id()
      or public.is_admin()
      or exists (select 1 from public.staff s
                  where s.id = p_staff and s.manager_id = public.current_staff_id());
$$;

revoke all on function public.day_is_mine_to_see(uuid) from anon, authenticated;
grant execute on function public.day_is_mine_to_see(uuid) to authenticated;

drop policy if exists staff_days_read on public.staff_days;
create policy staff_days_read on public.staff_days
  for select to authenticated
  using ((select public.is_active_staff()) and (select public.day_is_mine_to_see(staff_id)));

drop policy if exists staff_days_write on public.staff_days;
create policy staff_days_write on public.staff_days
  for all to authenticated
  using ((select public.is_active_staff()) and staff_id = (select public.current_staff_id()))
  with check ((select public.is_active_staff()) and staff_id = (select public.current_staff_id()));

drop policy if exists staff_day_lines_read on public.staff_day_lines;
create policy staff_day_lines_read on public.staff_day_lines
  for select to authenticated
  using (exists (select 1 from public.staff_days d
                  where d.id = staff_day_lines.day_id
                    and (select public.day_is_mine_to_see(d.staff_id))));

drop policy if exists staff_day_lines_write on public.staff_day_lines;
create policy staff_day_lines_write on public.staff_day_lines
  for all to authenticated
  using (exists (select 1 from public.staff_days d
                  where d.id = staff_day_lines.day_id
                    and d.staff_id = (select public.current_staff_id())))
  with check (exists (select 1 from public.staff_days d
                  where d.id = staff_day_lines.day_id
                    and d.staff_id = (select public.current_staff_id())));

drop policy if exists staff_day_events_read on public.staff_day_events;
create policy staff_day_events_read on public.staff_day_events
  for select to authenticated
  using (exists (select 1 from public.staff_days d
                  where d.id = staff_day_events.day_id
                    and (select public.day_is_mine_to_see(d.staff_id))));

-- The log is written by the functions above, which are security definer.
-- Nobody writes it by hand.

grant select, insert, update, delete on public.staff_days to authenticated;
grant select, insert, update, delete on public.staff_day_lines to authenticated;
grant select on public.staff_day_events to authenticated;

-- A document filed against a day, for the transition (see 0212).
insert into public.staff_file_categories (key, label, detail, system_only, sort_order, active)
values ('End of day report', 'End of day report',
        'An end-of-day report that arrived by email rather than through the CRM.',
        false, 90, true)
on conflict (key) do nothing;

do $$
declare v_n integer;
begin
  select count(*) into v_n from information_schema.tables
   where table_schema = 'public' and table_name in ('staff_days', 'staff_day_lines', 'staff_day_events');
  if v_n <> 3 then
    raise exception 'Expected three tables for the day, found %.', v_n;
  end if;
  raise notice 'ok  the end of the day has somewhere to live';
end $$;
