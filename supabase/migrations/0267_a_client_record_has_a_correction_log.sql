-- A client record has a correction log
--
-- Authorizations have had one since 0150-something: when a number, a date or a
-- rate is changed on a submitted authorization, what it was, what it became and
-- why are kept, and the log is added to and never edited. Client records had
-- nothing of the kind, which was survivable while the only corrections were
-- typos somebody made on a screen.
--
-- It stopped being survivable on 23 October, when a misread referral created a
-- client record that then collected 549 identical contact-log rows. Undoing
-- that means deleting 548 rows and merging a record away, and both of those are
-- the kind of thing that has to leave a trace saying who did it and on what
-- grounds. A record you can silently tidy is a record nobody can trust.
--
-- Same shape as authorization_corrections on purpose. Two logs with the same
-- columns are one thing somebody has to learn; two logs with different columns
-- are two.

create table if not exists public.client_corrections (
  id          uuid primary key default gen_random_uuid(),
  at          timestamptz not null default now(),
  -- Kept even when the client is merged away, which is the usual case for the
  -- interesting corrections. No cascade: the log outlives the row.
  client_id   uuid references public.clients (id) on delete set null,
  -- The name as it read when the correction was made, so the log still says
  -- who it was about after the record has been merged or renamed.
  client_name text not null,
  -- What was corrected: a column name where it was one field, or a plain noun
  -- for something larger ('contact log', 'the whole record').
  field       text not null,
  was_value   text,
  new_value   text,
  reason      text not null,
  staff_id    uuid references public.staff (id),
  staff_name  text not null
);

comment on table public.client_corrections is
  'Corrections made to a client record: what it was, what it became and why. Added to, never changed.';

create index if not exists client_corrections_client_idx
  on public.client_corrections (client_id, at desc);

alter table public.client_corrections enable row level security;

-- Readable by anybody on the staff, which is the point of a log.
drop policy if exists client_corrections_read on public.client_corrections;
create policy client_corrections_read on public.client_corrections
  for select using ((select public.is_active_staff()));

-- Written by Admin only. A correction is not an ordinary edit and the people
-- who make them are the people who can merge records in the first place.
drop policy if exists client_corrections_write on public.client_corrections;
create policy client_corrections_write on public.client_corrections
  for insert with check ((select public.is_admin()));

-- ── added to, never changed ──────────────────────────────────
create or replace function public.client_corrections_append_only()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  raise exception 'The correction log is a record; it is added to, never changed or removed.'
    using errcode = 'insufficient_privilege';
end $$;

drop trigger if exists client_corrections_append_only on public.client_corrections;
create trigger client_corrections_append_only
  before update or delete on public.client_corrections
  for each row execute function public.client_corrections_append_only();

-- The authorization log has an exception for the cascade behind a deleted
-- authorization. This one needs none: `on delete set null` means a client going
-- away leaves the log behind rather than taking it, which is what a log is for.

-- ── what the grants have to say out loud ─────────────────────
-- Supabase grants everything on a new table in `public` to `authenticated`
-- before any of this runs, so granting select and insert is not narrowing
-- anything - it is describing what was already there. The revoke is the part
-- that does the work.
--
-- TRUNCATE is the one that matters and the reason this is not left to row-level
-- security: a policy is checked per row and TRUNCATE has no rows. With it
-- granted, anybody signed in could empty the correction log in one statement,
-- past the append-only trigger as well, since that is a row trigger too.
--
-- The same thing was found once before on a view that arrived writable. It is
-- worse on a table, because a view has no TRUNCATE.
revoke all on public.client_corrections from authenticated;
revoke all on public.client_corrections from anon;
grant select on public.client_corrections to authenticated;
grant insert on public.client_corrections to authenticated;

-- The automated accounts read and never write, on every table. Said here
-- rather than left to the policies above, because "only Admin writes" is about
-- which person and this is about whether it is a person at all - a correction
-- recorded by a nightly job with nobody's name against it is not a correction,
-- it is a change.
select public.apply_system_read_only('client_corrections');
