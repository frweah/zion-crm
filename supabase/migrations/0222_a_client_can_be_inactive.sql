-- Zion Vocational Rehab CRM — 0222 a client can be inactive
--
-- The practice closed out its 2025 caseload (owner, 22 Oct 2026), and the
-- state those people go into is not Closed. Closed is final: it is what
-- happens when the work with somebody has ended, and reopening it is a
-- decision. Inactive is quieter than that - the file is complete, nobody is
-- working it, and putting them back on the board is a note and a stage
-- rather than an argument.
--
-- So a third resting state, and the difference from 'On hold' is who is
-- waiting: On hold is the practice holding, Inactive is the practice having
-- stopped.
--
-- What Inactive does is decided by the screens, not here: an inactive client
-- stays in the full client list and in their own History, and leaves every
-- active list, My day and the board.

alter table public.clients drop constraint if exists clients_status_check;
alter table public.clients add constraint clients_status_check
  check (status = any (array['Active'::text, 'On hold'::text, 'Inactive'::text, 'Closed'::text]));

comment on column public.clients.status is
  'Active, On hold, Inactive or Closed. Inactive (0222) is a finished file nobody is working: it keeps the record and its history and leaves every active list and the board.';
