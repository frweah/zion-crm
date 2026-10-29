-- A note says which service it is about
--
-- A monthly report has one section per service the client was authorized for,
-- and each section may contain only the work done under that service (Rei's
-- request, and 34 CFR 361.38 besides). Until now a note carried a *type* -
-- Meeting, Interview, Coaching session - which says what happened and not what
-- it was about. A meeting can be about job coaching or about life skills, so
-- the type cannot sort a report.
--
-- So a note carries a category as well as a type. They are orthogonal on
-- purpose: the type is the shape of the contact, the category is the service
-- it belongs to, and a report is sorted by the second.
--
-- Personal is the exception that the whole column exists to make possible. A
-- note about somebody's housing, health or family is on the record because the
-- practice needs it to do the work, and is none of a counselor's business. It
-- cannot be sorted out of a report if nothing says which notes it is.

-- ── the categories ───────────────────────────────────────────
-- Not an enum. Six of the seven line up with a service the practice bills for
-- and that list has changed twice in four months; a text column with a check
-- is one migration to change and an enum is three.
alter table public.notes
  add column if not exists category text;

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.notes'::regclass and conname = 'notes_category_check'
  ) then
    alter table public.notes
      add constraint notes_category_check check (
        category is null or category = any (array[
          'Job development',
          'Job coaching',
          'Job search',
          'Assessment',
          'Life skills',
          'General progress',
          'Personal'
        ])
      );
  end if;
end $$;

comment on column public.notes.category is
  'The service this note is about, which is how a monthly report sorts it. Personal is never in a report or an export. Null only on notes written before the column existed.';

-- Nullable, and that is the one thing here worth explaining. Eight hundred and
-- thirty-two notes predate the column and the brief asks for the backfill to be
-- reported before it is run, so NOT NULL cannot land in the same migration as
-- the column. Required going forward is enforced on insert instead, below, so
-- the rule is live from the moment this applies rather than from whenever the
-- backfill is approved.

-- ── the stage a note was written under ───────────────────────
/**
 * Which category a client's stage implies.
 *
 * One map, here, because three things need it and three copies would drift:
 * the screens guess a category from the client's stage, the backfill reads the
 * stage the client was on the day the note was written, and verify_notes.sql
 * asserts both get the same answer.
 *
 * Job Placement maps to Job development rather than to a category of its own.
 * Placement is what job development is for, the practice bills it under
 * development, and a seventh section nobody authorized would be a section
 * saying "No activity recorded" on every report.
 *
 * Intake, and anything the stage list grows later, falls to General progress.
 * A guess that lands in the general section is a guess somebody can correct;
 * one that lands in a billed service is a guess that reaches a counselor.
 */
create or replace function public.category_for_stage(p_stage text)
returns text
language sql immutable set search_path = public as $$
  select case p_stage
           when 'Job Development' then 'Job development'
           when 'Job Placement'   then 'Job development'
           when 'Job Coaching'    then 'Job coaching'
           when 'Job Search'      then 'Job search'
           when 'Assessment'      then 'Assessment'
           when 'Life Skills'     then 'Life skills'
           else 'General progress'
         end
$$;

comment on function public.category_for_stage(text) is
  'The note category a client stage implies. One map for the screens, the backfill and the checks.';

grant execute on function public.category_for_stage(text) to authenticated;

-- ── required, from now on ────────────────────────────────────
/**
 * A note written without a category.
 *
 * On insert only. The eight hundred and thirty-two notes already on file are
 * left exactly as they are - an update trigger would make every one of them
 * unsaveable until the backfill ran, which is the opposite of letting the
 * backfill wait for an answer.
 *
 * It fills rather than refuses, because every screen that writes a note now
 * sends a category and the ones that do not are the machine-written ones -
 * filed mail, a matched job lead - where the client's stage is the best answer
 * available and stopping the write would lose the note. A category somebody
 * can correct beats a note nobody has.
 */
create or replace function public.notes_need_a_category()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.category is null then
    new.category := public.category_for_stage(
      (select stage from public.clients where id = new.client_id));
  end if;
  return new;
end $$;

drop trigger if exists notes_need_a_category on public.notes;
create trigger notes_need_a_category
  before insert on public.notes
  for each row execute function public.notes_need_a_category();

-- ── Personal is restricted ───────────────────────────────────
-- "Restricted like sensitive files" (brief, section A). Documents have a
-- `restricted` flag and notes have `visible_roles`, so the mechanism here is
-- the roles: a Personal note is narrowed to the roles that run the practice,
-- and the four roles a report is built for (REPORT_ROLES in lib/report-shape)
-- no longer all see it - which is what makes the report withhold its words
-- even if a category filter were ever removed.
--
-- Two guards again, and deliberately: lib/report-period excludes the category,
-- and the roles exclude the words. Either alone would do it. A note about
-- somebody's family reaching their counselor is not a thing to guard once.
create or replace function public.personal_notes_are_narrow()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.category = 'Personal' then
    new.visible_roles := array['Admin', 'Case Manager']::text[];
  end if;
  return new;
end $$;

drop trigger if exists personal_notes_are_narrow on public.notes;
create trigger personal_notes_are_narrow
  before insert or update of category, visible_roles on public.notes
  for each row execute function public.personal_notes_are_narrow();

comment on function public.personal_notes_are_narrow() is
  'A Personal note is visible to Admin and Case Manager only, whatever the screen asked for.';
