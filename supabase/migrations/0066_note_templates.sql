-- ─────────────────────────────────────────────────────────────
-- 10.2 — case note templates
--
-- A case note is the record. When USOR asks what was done for a client, the
-- notes are the answer, and a note reading "met with client, went well" is
-- not one. The gap is never willingness — it is that a blank box at the end
-- of a long day asks a person to remember what a good note contains.
--
-- So the box is not blank. Choosing an activity type puts that type's
-- headings in it, and the headings are the questions an auditor asks: what
-- was worked on, how the client responded, what is in the way, what happens
-- next and by when.
--
-- Three things this deliberately does not do:
--
--   It does not require anything. A template is a starting point, editable
--   and deletable in the box. A required field on a case note produces notes
--   written to satisfy the field.
--
--   It does not overwrite. Text somebody has typed is never replaced by a
--   template, whatever they do with the type dropdown afterwards.
--
--   It leaves no trace on the note. A note is its text and nothing else —
--   there is no "templated" flag, because a note half-filled from a skeleton
--   and finished by hand is just a note.
-- ─────────────────────────────────────────────────────────────

create table if not exists public.note_templates (
  -- The activity type it belongs to, from NOTE_TYPES. One template per type,
  -- so choosing a type is the whole of choosing a template — there is no
  -- second decision to make and no list to browse.
  note_type   text primary key,

  body        text not null,

  -- Switched off rather than deleted, so turning one off does not lose the
  -- wording somebody worked out.
  active      boolean not null default true,

  updated_by  uuid references public.staff(id) on delete set null,
  updated_at  timestamptz not null default now()
);

alter table public.note_templates enable row level security;

drop policy if exists note_templates_read on public.note_templates;
drop policy if exists note_templates_write on public.note_templates;

-- Everybody who writes a note reads these, which is everybody.
create policy note_templates_read on public.note_templates
  for select to authenticated using (public.is_active_staff());

-- The wording is the practice's documentation standard. One person keeps it.
create policy note_templates_write on public.note_templates
  for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

drop trigger if exists note_templates_updated_at on public.note_templates;
create trigger note_templates_updated_at before update on public.note_templates
  for each row execute function public.set_updated_at();

-- ─────────────────────────────────────────────────────────────
-- The starting set
--
-- Written as questions with room after them rather than as prose, because a
-- heading with a blank line under it gets answered and a paragraph of
-- instructions gets deleted.
--
-- "General" has none on purpose. It is the type people choose when what
-- happened does not fit a shape, and handing them a shape anyway would be
-- the one case where this makes notes worse.
-- ─────────────────────────────────────────────────────────────
insert into public.note_templates (note_type, body) values
  ('Phone call',
E'Who I spoke to:\n\nWhat it was about:\n\nWhat was agreed:\n\nNext step and by when:\n'),

  ('Meeting',
E'Who was there:\n\nWhat we covered:\n\nWhat the client decided:\n\nNext step and by when:\n'),

  ('Job search',
E'What we worked on:\n\nEmployers or postings looked at:\n\nWhat the client did themselves:\n\nNext step and by when:\n'),

  ('Application submitted',
E'Employer and role:\n\nHow it was submitted:\n\nWho followed up, and when they will:\n'),

  ('Interview',
E'Employer and role:\n\nDate and time:\n\nHow the client prepared:\n\nHow it went:\n\nNext step and by when:\n'),

  ('Employer contact',
E'Employer and who I spoke to:\n\nWhat it was about:\n\nWhat they said:\n\nNext step and by when:\n'),

  ('Coaching session',
E'Where, and how long:\n\nWhat was worked on:\n\nHow the client did:\n\nWhat is still in the way:\n\nWhat we agreed to try next:\n\nNext step and by when:\n'),

  ('Counselor contact',
E'Counselor:\n\nWhat it was about:\n\nWhat was asked of us:\n\nWhat we asked of them:\n\nNext step and by when:\n'),

  ('No-show / not responding',
E'What was arranged:\n\nHow I tried to reach them (and when):\n\nWhat I will try next, and by when:\n\nWhether the counselor needs telling:\n')
on conflict (note_type) do nothing;

-- ─────────────────────────────────────────────────────────────
-- What the note box should start with
--
-- One call, one answer, so the screen has no rules of its own to get wrong.
-- An inactive type or one with no template returns nothing, and nothing means
-- a blank box — not an error and not a default from somewhere else.
-- ─────────────────────────────────────────────────────────────
create or replace function public.note_template_for(p_type text)
returns text language sql stable security invoker set search_path = public as $$
  select t.body from public.note_templates t
   where t.note_type = p_type and t.active
   limit 1;
$$;

comment on function public.note_template_for(text) is
  'The skeleton a new note of this type starts with, or nothing. Never required, never applied over typed text.';
