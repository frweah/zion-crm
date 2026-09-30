-- Zion Vocational Rehab CRM — the kinds of thing that can raise a task
--
-- A task could say where it came from, and the list of answers was three:
-- Interview prep, Interview day, Follow-up. Two things have been taught to
-- raise tasks since and neither is on it - the billing follow-up at fourteen
-- days (0124) and the text nobody answered (0130).
--
-- Neither had fired yet. The follow-up waits for an item to have been
-- submitted a fortnight ago, and the first item was submitted this week, so
-- the first night it ran it would have failed against this constraint and
-- raised nothing - with the failure inside a nightly job nobody watches.
-- The test for the text escalation found it, four days before the billing one
-- would have found it the hard way.
--
-- The list stays a list rather than becoming "anything": a source that is not
-- named here is almost always a typo, and a typo that silently becomes a new
-- kind of task is how "where did this come from?" stops having an answer.

alter table public.tasks drop constraint if exists tasks_source_kind_check;
alter table public.tasks add constraint tasks_source_kind_check
  check (source_kind = any (array[
    'Interview prep',
    'Interview day',
    'Follow-up',
    -- Submitted a fortnight ago with no answer (0124).
    'billing_item',
    -- A client texted and nobody replied (0130).
    'text_unanswered'
  ]));

comment on constraint tasks_source_kind_check on public.tasks is
  'What raised this task. A named list (0131): an unnamed source is nearly always a typo, and a typo that becomes a new kind of task is how the question stops having an answer.';
