/**
 * The quarter-hourly pass says it ran (owner, 24 November 2026).
 *
 * The folder walk leaves a row in `inbox_runs`, so the agent card can say
 * when the folders were last read. The light pass leaves nothing: it reads
 * phone photos, sends no manifest, and writes no run. Which means the task
 * that has to be quick - somebody is standing in a kitchen with a signed
 * form - is the one half of the agent nothing can see has stopped.
 *
 * One timestamp, updated in place, rather than a row every fifteen minutes.
 * Ninety-six rows a day for the right to read the newest one is a table that
 * has to be trimmed by something, and the something would be the next thing
 * to stop quietly. The primary key is the kind, so a second recurring pass
 * later takes a row of its own instead of a column here.
 *
 * `kind` is 'light pass' and it is stamped by the pass the quarter-hourly
 * task runs - the script invoked without -Scan - after the photos are read
 * and whether or not there were any. Not by the ask at the top of the run: a
 * pass that started and then hung on Tesseract would stamp itself healthy.
 * Not by a full pass either, because the two tasks can stop independently
 * and a heartbeat that both of them write cannot tell the owner which.
 *
 * Tolerates the old code: nothing reads or writes this table until the agent
 * and the card that come with it. An older deployment never stamps it, and
 * an older agent cannot - which is the state the machine is in today, and
 * the card says "not heard from" rather than anything worse.
 */

create table if not exists public.agent_heartbeat (
  kind   text primary key,
  at     timestamptz not null default now(),
  detail text not null default ''
);

comment on table public.agent_heartbeat is
  'When each recurring agent pass last finished. One row per kind, updated in place.';
comment on column public.agent_heartbeat.detail is
  'What that pass did, in a few words, for the card to show beside the time.';

alter table public.agent_heartbeat enable row level security;

/**
 * Who reads it: whoever reads the card it is on.
 *
 * `inbox_runs` admits any active staff member and the heartbeat is the same
 * fact about the same machine, so it admits the same people. There is
 * nothing about a client in it.
 */
create policy agent_heartbeat_read on public.agent_heartbeat
  for select using ((select public.is_active_staff()));

/**
 * And nobody signed in writes it.
 *
 * The agent does, as the service role. A staff member who could stamp this
 * row could make a stopped task look alive, which is the one thing the row
 * exists to answer.
 */
create policy agent_heartbeat_no_insert on public.agent_heartbeat
  as restrictive for insert with check (false);
create policy agent_heartbeat_no_edit on public.agent_heartbeat
  as restrictive for update using (false);
create policy agent_heartbeat_no_delete on public.agent_heartbeat
  as restrictive for delete using (false);

revoke all on public.agent_heartbeat from anon;
revoke all on public.agent_heartbeat from public;
grant select on public.agent_heartbeat to authenticated;
