-- An application says where it got to
--
-- `lead_matches.status` has held one word per application since 0013, and the
-- word has been overwritten every time something happened. So an application
-- that reads "Not selected" today cannot say when it was applied for, whether
-- the employer ever answered, or who found out - and the three date columns
-- bolted on since (applied_on, interview_on, decided_on) cover three of the
-- nine things that happen and nothing else.
--
-- The owner's list (30 Oct 2026) is nine statuses, each with a date and the
-- person who reported it, and the history kept:
--
--   Applied - Employer responded - Interview scheduled - Interviewed - Offer
--   Hired - Declined by employer - Client withdrew - No response
--
-- So the status becomes a row rather than a column. `job_status_history` is
-- added to and never changed, which is the only shape that can answer "when
-- did we hear" - an overwritten column cannot, however many columns there are.
--
-- `lead_matches.status` stays, as the latest, maintained here rather than by
-- whoever writes the row. Seven functions, four views and most of the leads
-- board read it, and a rename of its eight words is a separate decision with
-- 281 rows and 30 call sites in it. Until that decision is made the nine words
-- map onto the eight, which `lead_status_for_application` does in one place
-- and says out loud.
--
-- 'Saved' is not in the nine and is not missing from them: a job somebody
-- saved to try is not an application, and gets its first status when it
-- becomes one.

-- ─────────────────────────────────────────────────────────────
-- The nine
-- ─────────────────────────────────────────────────────────────
create table if not exists public.job_status_history (
  id               uuid primary key default gen_random_uuid(),
  -- This client against this job. The client is reached through it rather than
  -- copied here, so merging two records moves the applications and their
  -- history together - the same reason service_entries holds auth_id and not
  -- client_id.
  match_id         uuid not null references public.lead_matches (id) on delete cascade,
  status           text not null check (status in (
                     'Applied',
                     'Employer responded',
                     'Interview scheduled',
                     'Interviewed',
                     'Offer',
                     'Hired',
                     'Declined by employer',
                     'Client withdrew',
                     'No response'
                   )),
  -- The day it happened, which is not always the day somebody typed it in.
  at               date not null default public.practice_today(),
  -- Who found out. Null where nobody did: the fourteen-day sweep below, and
  -- the applications carried over from the job tracker, which recorded no
  -- author at all.
  reported_by      uuid references public.staff (id),
  reported_by_name text not null default '',
  note             text not null default '',
  -- Written by a rule rather than by a person, so a screen can say so.
  automatic        boolean not null default false,
  -- clock_timestamp() rather than now(), which is fixed for a whole
  -- transaction. Two entries added in one transaction - an application carried
  -- over as "applied, then declined", or a screen that records two steps at
  -- once - would otherwise share a timestamp exactly, and with the dates equal
  -- too there would be nothing left to say which came last. The assertion at
  -- the bottom of this file caught that on 52 of the 281 applications.
  created_at       timestamptz not null default clock_timestamp()
);

comment on table public.job_status_history is
  'Where a job application got to, one row per status, with the day and who reported it. Added to, never changed.';

create index if not exists job_status_history_match_idx
  on public.job_status_history (match_id, at desc, created_at desc);

-- ─────────────────────────────────────────────────────────────
-- The nine, said in the eight words the rest of the system knows
--
-- Two of them are deliberately quiet:
--
--   'No response' means nothing happened, so the application is still
--   'Applied' as far as every other screen is concerned. Mapping it anywhere
--   else would write a contact note on every client whose application went
--   fourteen days without an answer, which on the day this ships is 202 of
--   them - a sentence in 202 records saying that nothing happened.
--
--   'Employer responded' and the interview pair collapse, because what the
--   eight words are asked for is whether an application is over and roughly
--   how far along, and both pairs answer the same.
-- ─────────────────────────────────────────────────────────────
create or replace function public.lead_status_for_application(p_status text)
returns text language sql immutable as $$
  select case p_status
    when 'Applied'              then 'Applied'
    when 'Employer responded'   then 'Follow-up'
    when 'Interview scheduled'  then 'Interview'
    when 'Interviewed'          then 'Interview'
    when 'Offer'                then 'Offer'
    when 'Hired'                then 'Hired'
    when 'Declined by employer' then 'Not selected'
    when 'Client withdrew'      then 'Withdrawn'
    when 'No response'          then 'Applied'
  end;
$$;

comment on function public.lead_status_for_application is
  'One of the nine application statuses in the eight words lead_matches.status uses (0270).';

revoke all on function public.lead_status_for_application(text) from anon, authenticated;
grant execute on function public.lead_status_for_application(text) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- What the applications already on file have been through
--
-- Derived, not invented. A row that says applied_on was applied for on that
-- day, and a row that says 'Not selected' with a decided_on was declined on
-- that day, so both are written as the entries they are. Nothing is guessed:
-- the fourteen 'Interview' rows split on interview_result, which 0117 added
-- for exactly this question ("what happened to the interview itself"), and the
-- six that say 'Done' become 'Interviewed' while the other eight stay
-- 'Interview scheduled'.
--
-- Seeded before the trigger below exists, so an intermediate 'Applied' entry
-- cannot move lead_matches.status backwards on its way to the current one.
-- Nothing on any existing row is changed, and the assertion at the bottom of
-- this file is what proves it.
-- ─────────────────────────────────────────────────────────────
insert into public.job_status_history (match_id, status, at, note, automatic)
select m.id, 'Applied', m.applied_on, 'Carried over from the job tracker', true
  from public.lead_matches m
 where m.applied_on is not null
   and m.status <> 'Saved'
   and not exists (select 1 from public.job_status_history h where h.match_id = m.id);

insert into public.job_status_history (match_id, status, at, note, automatic)
select m.id,
       case m.status
         when 'Applied'      then 'Applied'
         when 'Follow-up'    then 'Employer responded'
         when 'Interview'    then case when m.interview_result = 'Done'
                                       then 'Interviewed' else 'Interview scheduled' end
         when 'Offer'        then 'Offer'
         when 'Hired'        then 'Hired'
         when 'Not selected' then 'Declined by employer'
         when 'Withdrawn'    then 'Client withdrew'
       end,
       -- The day it was decided, where the row knows one. None of the 58
       -- applications that have got past Applied has a decided_on, because the
       -- import that created them carried no decision date, so what is left is
       -- the day the practice's own record last said so. Never earlier than
       -- the day they applied, which would be a history in the wrong order.
       greatest(
         coalesce(m.decided_on, m.interview_on, m.updated_at::date),
         coalesce(m.applied_on, m.updated_at::date)
       ),
       case
         when m.decided_on is not null or m.interview_on is not null
           then 'Carried over from the job tracker'
         else 'Carried over from the job tracker, which recorded no date for it'
       end,
       true
  from public.lead_matches m
 where m.status <> 'Saved'
   -- The 'Applied' entry above is the current status as well, for the 202 that
   -- have got no further. One entry, not two identical ones.
   and not (m.status = 'Applied' and m.applied_on is not null)
   and not exists (
     select 1 from public.job_status_history h
      where h.match_id = m.id
        and h.status = case m.status
              when 'Applied'      then 'Applied'
              when 'Follow-up'    then 'Employer responded'
              when 'Interview'    then case when m.interview_result = 'Done'
                                            then 'Interviewed' else 'Interview scheduled' end
              when 'Offer'        then 'Offer'
              when 'Hired'        then 'Hired'
              when 'Not selected' then 'Declined by employer'
              when 'Withdrawn'    then 'Client withdrew'
            end);

-- ─────────────────────────────────────────────────────────────
-- The latest entry is the application's status
--
-- Recomputed from the history rather than taken from the row just inserted, so
-- a back-dated entry - somebody recording on Thursday that the employer rang
-- on Monday, after Tuesday's interview is already on file - does not move the
-- application backwards.
-- ─────────────────────────────────────────────────────────────
create or replace function public.application_status_lands_on_the_job()
returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_word text;
  v_now  text;
begin
  select public.lead_status_for_application(h.status) into v_word
    from public.job_status_history h
   where h.match_id = new.match_id
   order by h.at desc, h.created_at desc
   limit 1;

  select status into v_now from public.lead_matches where id = new.match_id;

  -- The dates the eight-word column still carries. Filled in where they are
  -- blank and left alone where they are not: a date somebody typed is not
  -- ours to move.
  update public.lead_matches m
     set status           = v_word,
         applied_on       = case when m.applied_on is null and new.status = 'Applied'
                                 then new.at else m.applied_on end,
         interview_on     = case when m.interview_on is null
                                   and new.status in ('Interview scheduled', 'Interviewed')
                                 then new.at else m.interview_on end,
         decided_on       = case when m.decided_on is null
                                   and new.status in ('Hired', 'Declined by employer', 'Client withdrew')
                                 then new.at else m.decided_on end,
         interview_result = case when m.interview_result = '' and new.status = 'Interviewed'
                                 then 'Done' else m.interview_result end
   where m.id = new.match_id
     -- Nothing to say is nothing to write. Without this the fourteen-day sweep
     -- would touch 202 rows to set each one to the word it already holds.
     and (v_word is distinct from v_now
          or (m.applied_on is null and new.status = 'Applied')
          or (m.interview_on is null and new.status in ('Interview scheduled', 'Interviewed'))
          or (m.decided_on is null and new.status in ('Hired', 'Declined by employer', 'Client withdrew'))
          or (m.interview_result = '' and new.status = 'Interviewed'));

  return new;
end $$;

drop trigger if exists application_status_lands_on_the_job on public.job_status_history;
create trigger application_status_lands_on_the_job
  after insert on public.job_status_history
  for each row execute function public.application_status_lands_on_the_job();

-- ─────────────────────────────────────────────────────────────
-- Added to, never changed or removed
--
-- With the one exception the authorization correction log already has: a row
-- being carried off by the cascade behind a deleted application is not being
-- edited by anybody. Without it, removing a job that should not have been
-- added - which the client's Job Search tab has offered since 0013 - fails
-- with a sentence about a record, and the first run of the verification script
-- is how that was found.
--
-- `on delete cascade` rather than `on delete set null`, because an application
-- that is gone was added by mistake. The contact notes it wrote stay on the
-- record, which is where what happened is kept.
-- ─────────────────────────────────────────────────────────────
create or replace function public.application_is_gone(p_match uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select p_match is not null
     and not exists (select 1 from public.lead_matches where id = p_match)
$$;

revoke all on function public.application_is_gone(uuid) from anon, authenticated;

create or replace function public.job_status_history_append_only()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'DELETE' and public.application_is_gone(old.match_id) then
    return old;
  end if;
  raise exception 'Where an application got to is a record; it is added to, never changed or removed. Add the next status instead.'
    using errcode = 'insufficient_privilege';
end $$;

drop trigger if exists job_status_history_append_only on public.job_status_history;
create trigger job_status_history_append_only
  before update or delete on public.job_status_history
  for each row execute function public.job_status_history_append_only();

-- ─────────────────────────────────────────────────────────────
-- Who may say where an application got to
--
-- The owner's rule: whoever may record a job search update, and the person the
-- client is assigned to. The second clause widens nothing today - every
-- assigned staff member is already one of the five roles - and it is the rule
-- that was asked for rather than the roster that happens to satisfy it.
-- ─────────────────────────────────────────────────────────────
create or replace function public.can_record_application_status(p_match uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_active_staff()
     and (
       public.can_record_job_search()
       or exists (
         select 1
           from public.lead_matches m
           join public.clients c on c.id = m.client_id
          where m.id = p_match
            and c.assigned_staff_id = public.current_staff_id()
       )
     );
$$;

comment on function public.can_record_application_status is
  'Whether this person may record where a job application got to: anybody who can record a job search update, or the staff member the client is assigned to (0270).';

revoke all on function public.can_record_application_status(uuid) from anon, authenticated;
grant execute on function public.can_record_application_status(uuid) to authenticated;

alter table public.job_status_history enable row level security;

-- Everybody on the staff sees it, which is what the owner asked and what the
-- applications themselves already do.
drop policy if exists job_status_history_read on public.job_status_history;
create policy job_status_history_read on public.job_status_history
  for select using ((select public.is_active_staff()));

-- And the writer is recorded by the rule rather than by the caller, the same
-- way 0250 does it for the three tables behind a job search update. A status a
-- person adds has to say which person; the sweep below adds its own with
-- nobody's name against it, under the service key.
drop policy if exists job_status_history_write on public.job_status_history;
create policy job_status_history_write on public.job_status_history
  for insert with check (
    (select public.can_record_application_status(match_id))
    and reported_by = (select public.current_staff_id())
    and automatic = false
  );

-- Supabase has already granted everything on this table to `authenticated`,
-- TRUNCATE included - which has no rows, so neither the read policy nor the
-- append-only trigger would be consulted. The revoke is the work here.
revoke all on public.job_status_history from authenticated;
revoke all on public.job_status_history from anon;
grant select on public.job_status_history to authenticated;
grant insert on public.job_status_history to authenticated;

select public.apply_system_read_only('job_status_history');

-- ─────────────────────────────────────────────────────────────
-- Nothing heard for a fortnight
--
-- The owner's rule: 'No response' automatically after 14 days, overridable.
-- Overriding it is adding the next status, which is what this table is for -
-- the sweep reads the latest entry, so once anything later exists it never
-- speaks again about that application.
--
-- It notifies nobody and emails nobody. "No response" is the absence of an
-- event, and a notification about something not happening, on every
-- application that has gone quiet, is how a notification list stops being
-- read.
-- ─────────────────────────────────────────────────────────────
create or replace function public.mark_applications_with_no_reply(p_days integer)
returns integer
language plpgsql security definer set search_path = public as $$
declare v_n integer;
begin
  if p_days is null or p_days < 1 then
    raise exception 'How many days of silence counts as no response?';
  end if;

  with latest as (
    select distinct on (h.match_id) h.match_id, h.status, h.at
      from public.job_status_history h
     order by h.match_id, h.at desc, h.created_at desc
  )
  insert into public.job_status_history (match_id, status, at, note, automatic)
  select l.match_id, 'No response', public.practice_today(),
         'Nothing heard for ' || p_days || ' days', true
    from latest l
   where l.status = 'Applied'
     and l.at <= public.practice_today() - p_days;

  get diagnostics v_n = row_count;
  return v_n;
end $$;

comment on function public.mark_applications_with_no_reply is
  'Records "No response" on every application that has sat at Applied for p_days with nothing since. Called daily by /api/cron/chase (0270).';

revoke all on function public.mark_applications_with_no_reply(integer) from anon, authenticated;

-- ─────────────────────────────────────────────────────────────
-- Where every application got to, for a screen and for a report
-- ─────────────────────────────────────────────────────────────
create or replace view public.client_application_status as
select h.id,
       h.match_id,
       m.client_id,
       h.status,
       h.at,
       h.note,
       h.automatic,
       h.reported_by,
       h.reported_by_name,
       h.created_at,
       (h.id = first_value(h.id) over (
          partition by h.match_id order by h.at desc, h.created_at desc
        )) as latest,
       l.title,
       e.name as employer_name
  from public.job_status_history h
  join public.lead_matches m on m.id = h.match_id
  join public.job_leads l on l.id = m.lead_id
  join public.employers e on e.id = l.employer_id;

alter view public.client_application_status set (security_invoker = true);

-- A view arrives writable in this project, which is how a read-only view
-- turned out to accept an insert once before.
revoke all on public.client_application_status from authenticated;
revoke all on public.client_application_status from anon;
grant select on public.client_application_status to authenticated;

-- ─────────────────────────────────────────────────────────────
-- The seed changed nothing
--
-- Said here rather than checked by hand: every application that now has
-- history must still hold exactly the word it held before this file ran, which
-- is true if and only if the mapping above is faithful to what was on file.
-- ─────────────────────────────────────────────────────────────
do $$
declare v_bad integer;
begin
  select count(*) into v_bad
    from public.lead_matches m
    join lateral (
      select h.status from public.job_status_history h
       where h.match_id = m.id order by h.at desc, h.created_at desc limit 1
    ) latest on true
   where m.status <> public.lead_status_for_application(latest.status);

  if v_bad > 0 then
    raise exception
      '% application(s) would have their status rewritten by the seed, so the mapping does not match what is on file',
      v_bad;
  end if;

  raise notice 'ok  % applications have history, and every one still reads as it did',
    (select count(distinct match_id) from public.job_status_history);
  raise notice 'ok  % applications have none, being saved jobs rather than applications',
    (select count(*) from public.lead_matches m
      where not exists (select 1 from public.job_status_history h where h.match_id = m.id));
end $$;
