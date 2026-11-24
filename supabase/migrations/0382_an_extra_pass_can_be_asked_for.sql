/**
 * Run now: an extra pass, asked for from the CRM (owner, 23 November 2026).
 *
 * The documents agent on the owner's machine stops walking the client folders
 * every fifteen minutes and does it twice a day, at ten and at seven. That is
 * right for two thousand files that change a few times a week and wrong for
 * the afternoon somebody drops a stub or an authorization in and wants it
 * read. So the CRM can ask for one extra pass, and the agent - which still
 * wakes every fifteen minutes to read phone photos - picks the ask up on its
 * next wake.
 *
 * A row rather than a flag, because the question "who asked, and did it
 * happen" is worth being able to answer. The agent clears it by saying which
 * run did the work, which is also what stops a stuck request asking forever.
 *
 * Tolerates the old code: nothing writes or reads this table until the agent
 * and the screen that come with it, so an older deployment is unaffected -
 * and an older *agent* simply never asks, which is the state it is in today.
 */

create table if not exists public.inbox_scan_requests (
  id            uuid primary key default gen_random_uuid(),
  asked_at      timestamptz not null default now(),
  asked_by      uuid references public.staff(id) on delete set null,
  asked_by_name text not null default '',
  -- Which run did it, and when the agent said so. Null means still waiting.
  -- `inbox_runs.id` is a bigint, not a uuid - this said uuid and Postgres
  -- refused the foreign key, which is the right answer and a cheap reminder
  -- to read the column rather than assume the house style.
  done_at       timestamptz,
  done_run      bigint references public.inbox_runs(id) on delete set null
);

create index if not exists inbox_scan_requests_open
  on public.inbox_scan_requests (asked_at)
  where done_at is null;

comment on table public.inbox_scan_requests is
  'An extra pass over the client folders, asked for from Admin - Documents. The agent clears each one with the run that did the work.';

alter table public.inbox_scan_requests enable row level security;

/**
 * Who may ask, which is whoever may open the screen it is asked from.
 *
 * Admin, or somebody holding a billing edit grant - the same pair the
 * document inbox itself admits since 0103. Asking is harmless by
 * construction: it makes a machine look at a folder sooner, reads nothing and
 * changes nothing on any record.
 *
 * And they ask as themselves. A row that could name somebody else would make
 * "who asked for this" a thing nobody can rely on.
 */
create policy inbox_scan_requests_read on public.inbox_scan_requests
  for select using ((select public.is_active_staff()));

create policy inbox_scan_requests_ask on public.inbox_scan_requests
  for insert with check (
    ((select public.is_admin()) or (select public.staff_has_area('billing', 'edit')))
    and not (asked_by is distinct from (select public.current_staff_id()))
    and done_at is null
    and done_run is null
  );

/**
 * Nobody signed in marks one done.
 *
 * The agent does, as the service role, and the row is the record of whether
 * the pass happened. A staff member who could write `done_at` could make a
 * request that never ran look as though it had.
 */
create policy inbox_scan_requests_no_edit on public.inbox_scan_requests
  as restrictive for update using (false);

create policy inbox_scan_requests_no_delete on public.inbox_scan_requests
  as restrictive for delete using (false);

revoke all on public.inbox_scan_requests from anon;
grant select, insert on public.inbox_scan_requests to authenticated;
