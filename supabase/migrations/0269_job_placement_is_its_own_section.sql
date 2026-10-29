-- Job placement is its own section
--
-- 0266 folded the Job Placement stage into the Job development category, on the
-- argument that placement is what development is for and the practice bills it
-- that way. The owner's answer: it is a service of its own, 36 authorizations
-- carry it, and a counselor reading a report about a client who has been placed
-- wants the placement, not a development section with a hire buried in it.
--
-- So eight categories rather than seven, the stage maps to the new one, and
-- 189 of the 832 notes that were going to be Job development are Job placement
-- instead.
--
-- This migration also runs the backfill, which the brief asked to have reported
-- before it ran. It was reported on 29 October and approved with that one
-- change.

-- ── the eighth category ──────────────────────────────────────
alter table public.notes drop constraint if exists notes_category_check;
alter table public.notes
  add constraint notes_category_check check (
    category is null or category = any (array[
      'Job development',
      'Job placement',
      'Job coaching',
      'Job search',
      'Assessment',
      'Life skills',
      'General progress',
      'Personal'
    ])
  );

-- ── the stage map ────────────────────────────────────────────
-- One map for the screens, the backfill and the checks; the only change is the
-- second line. Job Placement had been folded in with Job Development and is
-- now its own answer.
create or replace function public.category_for_stage(p_stage text)
returns text
language sql immutable set search_path = public as $$
  select case p_stage
           when 'Job Development' then 'Job development'
           when 'Job Placement'   then 'Job placement'
           when 'Job Coaching'    then 'Job coaching'
           when 'Job Search'      then 'Job search'
           when 'Assessment'      then 'Assessment'
           when 'Life Skills'     then 'Life skills'
           else 'General progress'
         end
$$;

comment on function public.category_for_stage(text) is
  'The note category a client stage implies. One map for the screens, the backfill and the checks.';

-- ── the backfill ─────────────────────────────────────────────
/*
 * The stage the client was on, on the day the note was written - not the stage
 * they are on now. A note from the assessment in June belongs in the
 * assessment section whatever has happened since, and dating it by the client's
 * current stage would move eight months of history into whatever they are
 * doing today.
 *
 * `client_stage_history` holds a row per change, so the rule is the latest row
 * on or before the note's date. 57 notes have no stage row on or before them -
 * mostly notes imported with the workbook, predating the first recorded stage
 * change - and those fall to General progress along with the 119 written while
 * the client was at Intake. A guess that lands in the general section is one
 * somebody can correct; a guess that lands in a billed service is one that
 * reaches a counselor.
 *
 * Only rows with no category are touched, so running this twice changes
 * nothing the second time and the notes written since 0266 keep what the
 * screens asked for.
 */
update public.notes nt
   set category = public.category_for_stage(
         (select h.stage from public.client_stage_history h
           where h.client_id = nt.client_id and h.at <= nt.at
           order by h.at desc, h.created_at desc
           limit 1))
 where nt.category is null;

-- ── and required from here ───────────────────────────────────
-- The insert trigger from 0266 fills a missing category from the client's
-- stage, so nothing can arrive without one. NOT NULL says the same thing one
-- layer down, where a migration or a script with the service key cannot write
-- round it.
do $$
declare v_blank int;
begin
  select count(*) into v_blank from public.notes where category is null;
  if v_blank > 0 then
    raise exception 'The backfill left % note(s) with no category; NOT NULL would refuse them.', v_blank;
  end if;
end $$;

alter table public.notes alter column category set not null;

comment on column public.notes.category is
  'The service this note is about, which is how a monthly report sorts it. Personal is never in a report or an export.';
