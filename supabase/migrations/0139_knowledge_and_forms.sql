-- Zion Vocational Rehab CRM — a knowledge base, and the practice's own forms
-- (Design language, §3)
--
-- Two things, both about writing something down once instead of six times.
--
--   The SOPs are articles. They had a title, a body and a screen they belong
--   to; what they did not have is a category, which is the difference between
--   six documents and a place somebody looks things up in. "Where do I…?" is
--   the first category because it is the question people actually arrive
--   with.
--
--   The practice's own forms - a client visit, a worksite check, an incident
--   - were paper, or a note typed into Activity, or nothing. They are forms
--   now: a template somebody fills in on a phone, saved against the client.
--   USOR's forms are untouched; those are somebody else's document with
--   somebody else's rules, and they already work.
--
-- A filled form is append-only, like a note: it records what somebody saw at
-- the time, and a record of what somebody saw that can be rewritten later is
-- not a record.

alter table public.sops
  add column if not exists category text not null default 'How we work',
  add column if not exists form_key text;

comment on column public.sops.category is
  'Which shelf this article is on (0139). "Where do I…?" is the first, because it is the question people arrive with.';
comment on column public.sops.form_key is
  'A form or checklist this article hands you (0139), by key.';

update public.sops set category = 'Where do I…?' where screen is not null and category = 'How we work';

-- ── the practice's own forms ───────────────────────────────
create table if not exists public.practice_forms (
  key text primary key,
  name text not null,
  purpose text,
  -- [{ key, label, type: text|long|yes_no|number|date|photo|signature, required }]
  fields jsonb not null default '[]'::jsonb,
  about_a_client boolean not null default true,
  roles text[] not null default '{}',
  active boolean not null default true,
  sort_order integer not null default 0,
  updated_at timestamptz not null default now(),

  constraint practice_forms_fields_are_a_list check (jsonb_typeof(fields) = 'array')
);

comment on table public.practice_forms is
  'The practice''s own forms (0139): a client visit, a worksite check, an incident. USOR''s forms are elsewhere and untouched.';

create table if not exists public.practice_form_entries (
  id uuid primary key default gen_random_uuid(),
  form_key text not null references public.practice_forms(key) on delete restrict,
  client_id uuid references public.clients(id) on delete cascade,
  staff_id uuid references public.staff(id) on delete set null,
  staff_name text,
  answers jsonb not null default '{}'::jsonb,
  filled_at timestamptz not null default now(),
  -- Where a photograph or a signature went, if the form asked for one.
  attachment_path text,

  constraint practice_form_entries_answers check (jsonb_typeof(answers) = 'object')
);

comment on table public.practice_form_entries is
  'A filled form (0139). Append-only: a record of what somebody saw that can be rewritten later is not a record.';

create index if not exists practice_form_entries_client_idx
  on public.practice_form_entries (client_id, filled_at desc);

alter table public.practice_forms enable row level security;
alter table public.practice_form_entries enable row level security;

drop policy if exists practice_forms_select on public.practice_forms;
create policy practice_forms_select on public.practice_forms for select to authenticated
  using (
    active
    and (cardinality(roles) = 0 or (select public.current_staff_role()) = any (roles)
         or (select public.current_staff_role()) = 'Admin')
  );

drop policy if exists practice_forms_write on public.practice_forms;
create policy practice_forms_write on public.practice_forms for all to authenticated
  using ((select public.current_staff_role()) = 'Admin')
  with check ((select public.current_staff_role()) = 'Admin');

-- Reading a filled form follows the client, as everything about a client
-- does. Filling one is anybody's; changing one is nobody's.
drop policy if exists practice_form_entries_select on public.practice_form_entries;
create policy practice_form_entries_select on public.practice_form_entries for select to authenticated
  using (
    (select public.current_staff_role()) = any (array['Admin', 'Job Search', 'Reports', 'Billing'])
  );

drop policy if exists practice_form_entries_insert on public.practice_form_entries;
create policy practice_form_entries_insert on public.practice_form_entries for insert to authenticated
  with check (staff_id = (select public.current_staff_id()));

select public.apply_system_read_only('public.practice_forms'::regclass);
select public.apply_system_read_only('public.practice_form_entries'::regclass);

grant select, insert, update, delete on public.practice_forms to authenticated;
grant select, insert on public.practice_form_entries to authenticated;

-- ── the three the practice already does on paper ───────────
insert into public.practice_forms (key, name, purpose, about_a_client, sort_order, fields) values
  ('client_visit', 'Client visit', 'What happened when you saw them, written where it belongs.', true, 1,
   '[{"key":"where","label":"Where you met","type":"text","required":true},
     {"key":"what","label":"What you worked on","type":"long","required":true},
     {"key":"mood","label":"How they seemed","type":"text"},
     {"key":"next","label":"What happens next","type":"long"},
     {"key":"photo","label":"A photograph, if there is one","type":"photo"}]'::jsonb),
  ('worksite_check', 'Worksite check', 'The job, the supervisor, and whether it is going well.', true, 2,
   '[{"key":"employer","label":"Employer","type":"text","required":true},
     {"key":"supervisor","label":"Who you spoke to","type":"text"},
     {"key":"hours","label":"Hours they are getting","type":"number"},
     {"key":"going_well","label":"Is it going well?","type":"yes_no","required":true},
     {"key":"concerns","label":"Anything to watch","type":"long"},
     {"key":"photo","label":"A photograph of the site","type":"photo"}]'::jsonb),
  ('incident', 'Incident', 'Something that went wrong, recorded the day it happened.', true, 3,
   '[{"key":"when","label":"When it happened","type":"date","required":true},
     {"key":"what","label":"What happened","type":"long","required":true},
     {"key":"who_told","label":"Who has been told","type":"text"},
     {"key":"action","label":"What was done about it","type":"long"},
     {"key":"signature","label":"Your signature","type":"signature"}]'::jsonb)
on conflict (key) do nothing;
