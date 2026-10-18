-- Zion Vocational Rehab CRM — report a problem
-- (owner, 18 Oct 2026)
--
-- Staff find things wrong with this system and tell somebody in the corridor,
-- or do not tell anybody at all. There has been nowhere in the CRM to say
-- "this screen is wrong" since it was built, so the only faults that ever got
-- fixed were the ones the owner happened to hear about.
--
-- One form, reached from the avatar menu on every screen, which records which
-- screen they were on when they pressed it. The screen matters: half of what
-- people report is "this page" and they should not have to describe where
-- they were.
--
-- Admin is told, in the CRM. Not by email: a problem report is not urgent
-- enough to interrupt somebody's evening, and the bell is where everything
-- else that needs Admin already is.

create table if not exists public.problem_reports (
  id          uuid primary key default gen_random_uuid(),
  staff_id    uuid not null references public.staff(id) on delete cascade,
  -- Where they were. Recorded by the form, not typed.
  screen      text not null default '',
  what        text not null check (btrim(what) <> ''),
  created_at  timestamptz not null default now(),
  -- Admin's side of it.
  resolved_at timestamptz,
  resolved_by uuid references public.staff(id) on delete set null,
  note        text not null default ''
);

create index if not exists problem_reports_open_idx
  on public.problem_reports (created_at desc) where resolved_at is null;
create index if not exists problem_reports_person_idx
  on public.problem_reports (staff_id, created_at desc);

comment on table public.problem_reports is
  'What staff say is wrong with the CRM, from the avatar menu on any screen (0216).';

alter table public.problem_reports enable row level security;

-- Anybody may report one, and read their own. Admin reads them all.
drop policy if exists problem_reports_read on public.problem_reports;
create policy problem_reports_read on public.problem_reports
  for select to authenticated
  using ((select public.is_active_staff())
         and (staff_id = (select public.current_staff_id()) or (select public.is_admin())));

drop policy if exists problem_reports_write on public.problem_reports;
create policy problem_reports_write on public.problem_reports
  for insert to authenticated
  with check ((select public.is_active_staff())
              and staff_id = (select public.current_staff_id()));

-- Only Admin closes one. Nobody edits what was said, including the person who
-- said it: a report is an account of a moment, and the useful thing about it
-- is what they thought at the time.
drop policy if exists problem_reports_resolve on public.problem_reports;
create policy problem_reports_resolve on public.problem_reports
  for update to authenticated
  using ((select public.is_admin()))
  with check ((select public.is_admin()));

grant select, insert on public.problem_reports to authenticated;
grant update (resolved_at, resolved_by, note) on public.problem_reports to authenticated;

select public.apply_system_read_only('problem_reports');

/**
 * What was said is not rewritten.
 *
 * The update policy is Admin's, and the column grant above is the three
 * fields that close a report. This is the same rule said where it cannot be
 * got round: if somebody were granted more columns later, the text still
 * cannot change.
 */
create or replace function public.problem_report_is_an_account()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.what is distinct from old.what
     or new.staff_id is distinct from old.staff_id
     or new.screen is distinct from old.screen
     or new.created_at is distinct from old.created_at then
    raise exception 'What somebody reported is not edited. Add a note instead.'
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

drop trigger if exists problem_reports_are_accounts on public.problem_reports;
create trigger problem_reports_are_accounts
  before update on public.problem_reports
  for each row execute function public.problem_report_is_an_account();

/**
 * Admin is told, once per report.
 *
 * On the bell rather than by email. The notification resolves itself when the
 * report is closed, so the list of open reports and the list of notifications
 * cannot disagree.
 */
create or replace function public.tell_admin_of_problem()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_who text;
begin
  select name into v_who from public.staff where id = new.staff_id;

  insert into public.notifications (dedupe_key, kind, level, text, roles, href, staff_id)
  values ('problem:' || new.id::text, 'problem_report', 'warn',
          format('%s reported a problem%s.', coalesce(v_who, 'Somebody'),
                 case when nullif(new.screen, '') is null then '' else ' on ' || new.screen end),
          array['Admin'], '/admin/system#problems', null)
  on conflict (dedupe_key) do nothing;

  return new;
end;
$$;

drop trigger if exists problem_reports_tell_admin on public.problem_reports;
create trigger problem_reports_tell_admin
  after insert on public.problem_reports
  for each row execute function public.tell_admin_of_problem();

create or replace function public.close_problem_notification()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.resolved_at is not null and old.resolved_at is null then
    update public.notifications set resolved_at = now()
     where dedupe_key = 'problem:' || new.id::text and resolved_at is null;
  end if;
  return new;
end;
$$;

drop trigger if exists problem_reports_close_notification on public.problem_reports;
create trigger problem_reports_close_notification
  after update on public.problem_reports
  for each row execute function public.close_problem_notification();

do $$
begin
  if not exists (select 1 from information_schema.tables
                  where table_schema = 'public' and table_name = 'problem_reports') then
    raise exception 'problem_reports did not arrive.';
  end if;
  raise notice 'ok  there is somewhere to say the CRM is wrong';
end $$;
