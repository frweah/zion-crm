-- Zion Vocational Rehab CRM — 0251 an authorization without a number says so
--
-- "The ones without a USOR number" has been asked in four places and spelt
-- the same way in all four:
--
--     .like("number", "(workbook)%")
--
-- which was right in January. The spreadsheet import (0079) named the
-- authorizations it could not find a number for `(workbook) coaching NNNN`,
-- and that prefix was how the practice found them again. Every one of those
-- has since been given its real number: there are **none left**.
--
-- What exists now is three authorizations with an empty number, created by
-- hand or carried in from a scan that had no number on it - and not one of
-- the four places recognises them. So the confirm queue has never offered
-- "Replace with this number" for an authorization that actually needs it, and
-- Margaret, who was asked to label them, had nothing to press.
--
-- The question is "has this authorization got a USOR number", and the honest
-- place for it is the row. A generated column answers it once, the screens
-- read it instead of each spelling the prefix again, and the next convention
-- for an unnumbered authorization - there will be one - is a change to this
-- line rather than to four queries nobody will think to look at.

alter table public.authorizations
  add column if not exists has_usor_number boolean
  generated always as (
    coalesce(btrim(number), '') <> ''
    and number not like '(workbook)%'
  ) stored;

comment on column public.authorizations.has_usor_number is
  'False when USOR has not given this one a number yet - an empty number, or an import''s "(workbook)" placeholder. The one definition the screens read (0251).';

-- The confirm queue reads this column for every authorization in the
-- practice, so it is worth an index: it is a handful of rows out of hundreds.
create index if not exists authorizations_without_a_number
  on public.authorizations (client_id)
  where not has_usor_number;
