-- Zion Vocational Rehab CRM — 0252 a USOR number looks like one
--
-- 0251 added `has_usor_number` and defined "no number" as an empty string or
-- the spreadsheet import's `(workbook)` prefix. That was right about the two
-- empty ones and wrong about everything else, because the four placeholders
-- on file are not called `(workbook) coaching 1006`. They are called
--
--     coaching 1006
--
-- so the column said they had a USOR number, and every dropdown and list in
-- the practice showed `coaching 1006 · Anne Stahulak · Job Coaching` with the
-- placeholder's label sitting exactly where a real number sits (owner,
-- 26 Oct 2026). It reads as a number, it is not one, and nothing downstream
-- could tell.
--
-- The fault was defining the question by the shapes that were wrong. There is
-- an unlimited supply of those and the next convention will be a fifth. A
-- USOR number is `V` and digits - all 163 real ones on file are, with an
-- occasional letter on the end for a reissue - so that is what the column
-- asks now. An authorization whose number does not look like a USOR number
-- has not got one, whatever it is called instead.
--
-- Generated columns cannot be altered, so it is dropped and rebuilt, and the
-- index with it.

drop index if exists authorizations_without_a_number;
alter table public.authorizations drop column if exists has_usor_number;

alter table public.authorizations
  add column has_usor_number boolean
  generated always as (number ~* '^V[0-9]+') stored;

comment on column public.authorizations.has_usor_number is
  'Whether USOR has given this one a number: V and digits, which every real one is. A placeholder label is not a number however it is spelt (0252).';

create index authorizations_without_a_number
  on public.authorizations (client_id)
  where not has_usor_number;
