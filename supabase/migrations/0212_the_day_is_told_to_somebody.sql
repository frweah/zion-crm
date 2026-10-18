-- Zion Vocational Rehab CRM — the day is told to somebody
-- (owner, 18 Oct 2026)
--
-- Two halves of the same instruction: "on submit, send one summary to Admin
-- and the person's manager in the CRM and by email to service@".
--
--   In the CRM is this file. A notification to Admin by role, and one to the
--   manager by name when the person has one - so it appears on their bell and
--   on My day like everything else that needs them.
--
--   By email is the server action, through lib/email.ts, one message to
--   service@zionvocrehab.com. Not to the manager's own address: the owner
--   asked for one email, and service@ is where the practice already keeps the
--   finished days.
--
-- And the transition. Until everybody is in the habit, a day that arrives as
-- an email to service@ with EOD in the subject is filed against that person's
-- day record and they are reminded to put it in the CRM. The reminder says it
-- is temporary, because it is: the owner reviews this on 1 November 2026, two
-- weeks from today.

-- Where a document that arrived by email belongs.
alter table public.staff_files
  add column if not exists staff_day_id uuid references public.staff_days(id) on delete set null;

create index if not exists staff_files_day_idx on public.staff_files (staff_day_id)
  where staff_day_id is not null;

comment on column public.staff_files.staff_day_id is
  'The day this document belongs to, when it arrived as an emailed end-of-day report (0212).';

-- ─────────────────────────────────────────────────────────────
-- The summary, in the CRM
--
-- One notification per day per reader, keyed so a reopen and a second submit
-- update the same row rather than stacking up.
-- ─────────────────────────────────────────────────────────────
create or replace function public.notify_staff_day(p_day_id uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare
  v_day     public.staff_days%rowtype;
  v_name    text;
  v_text    text;
  v_href    text;
  v_made    integer := 0;
begin
  select * into v_day from public.staff_days where id = p_day_id;
  if not found or v_day.submitted_at is null then
    return 0;
  end if;

  select name into v_name from public.staff where id = v_day.staff_id;
  v_text := format('%s submitted their end of day for %s.', v_name,
                   to_char(v_day.day, 'FMMon FMDD'));
  v_href := '/end-of-day?day=' || to_char(v_day.day, 'YYYY-MM-DD')
            || '&who=' || v_day.staff_id::text;

  -- Admin, by role.
  insert into public.notifications (dedupe_key, kind, level, text, roles, href, staff_id)
  values ('staff_day:' || p_day_id::text || ':admin', 'staff_day', 'warn', v_text,
          array['Admin'], v_href, null)
  on conflict (dedupe_key) do update
     set text = excluded.text, href = excluded.href, resolved_at = null;
  v_made := v_made + 1;

  -- The manager, by name, when they have one and it is not themselves.
  if v_day.manager_id is not null and v_day.manager_id <> v_day.staff_id then
    insert into public.notifications (dedupe_key, kind, level, text, roles, href, staff_id)
    values ('staff_day:' || p_day_id::text || ':manager', 'staff_day', 'warn', v_text,
            array[]::text[], v_href, v_day.manager_id)
    on conflict (dedupe_key) do update
       set text = excluded.text, href = excluded.href, resolved_at = null;
    v_made := v_made + 1;
  end if;

  return v_made;
end;
$$;

revoke all on function public.notify_staff_day(uuid) from anon, authenticated;
grant execute on function public.notify_staff_day(uuid) to authenticated;

-- Submitting tells them. The rest of submit_staff_day is 0211's, unchanged.
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

  update public.staff_days sd
     set submitted_at = now(),
         role_at_time = coalesce(nullif(sd.role_at_time, ''), s.role),
         manager_id   = coalesce(sd.manager_id, s.manager_id)
    from public.staff s
   where sd.id = p_day_id and s.id = sd.staff_id;

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

  perform public.notify_staff_day(p_day_id);

  return public.staff_day_summary(p_day_id);
end;
$$;

revoke all on function public.submit_staff_day(uuid) from anon, authenticated;
grant execute on function public.submit_staff_day(uuid) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- The transition: a day that arrived as an email
--
-- Called by the intake cron when a message to service@ has EOD in its
-- subject and comes from a member of staff. It opens that person's day if it
-- is not there, says the document belongs to it, and reminds them to put the
-- day in properly.
--
-- Security definer because the cron runs as the service role and has no
-- staff identity of its own, and because it writes a day belonging to
-- somebody else - which nothing else in this feature is allowed to do.
-- ─────────────────────────────────────────────────────────────
create or replace function public.file_emailed_day(
  p_staff   uuid,
  p_day     date,
  p_file_id uuid
)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_id   uuid;
  v_name text;
begin
  if p_staff is null then
    raise exception 'An emailed day has to belong to somebody.' using errcode = 'check_violation';
  end if;

  select id into v_id from public.staff_days where staff_id = p_staff and day = p_day;
  if v_id is null then
    insert into public.staff_days (staff_id, day, role_at_time, manager_id)
    select p_staff, p_day, s.role, s.manager_id from public.staff s where s.id = p_staff
    returning id into v_id;
  end if;

  if p_file_id is not null then
    update public.staff_files set staff_day_id = v_id where id = p_file_id;
  end if;

  select name into v_name from public.staff where id = p_staff;

  -- On their bell and on My day. One per day, however many times they send.
  insert into public.notifications (dedupe_key, kind, level, text, roles, href, staff_id)
  values ('staff_day_email:' || v_id::text, 'staff_day_email', 'warn',
          format('Your end of day for %s arrived by email. Put it in the CRM - the emailed copy is kept on your file, and this way of sending it is being retired.',
                 to_char(p_day, 'FMMon FMDD')),
          array[]::text[], '/end-of-day?day=' || to_char(p_day, 'YYYY-MM-DD'), p_staff)
  on conflict (dedupe_key) do update
     set text = excluded.text, resolved_at = null;

  return v_id;
end;
$$;

revoke all on function public.file_emailed_day(uuid, date, uuid) from anon, authenticated;

-- The reminder clears itself once the day is actually submitted.
create or replace function public.clear_emailed_day_reminder()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.submitted_at is not null and old.submitted_at is null then
    update public.notifications
       set resolved_at = now()
     where dedupe_key = 'staff_day_email:' || new.id::text
       and resolved_at is null;
  end if;
  return new;
end;
$$;

drop trigger if exists staff_days_clear_email_reminder on public.staff_days;
create trigger staff_days_clear_email_reminder
  after update on public.staff_days
  for each row execute function public.clear_emailed_day_reminder();

do $$
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'staff_files'
                    and column_name = 'staff_day_id') then
    raise exception 'staff_files has nowhere to put the day.';
  end if;
  raise notice 'ok  a submitted day reaches Admin and the manager, and an emailed one is filed';
end $$;
