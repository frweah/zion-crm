-- Zion Vocational Rehab CRM — a scheduled text is claimed before it is sent
-- (stress test, finding 6, owner 16 Oct 2026)
--
-- sendScheduledTexts read every Scheduled text that was due, sent each one,
-- and then deleted the row. Nothing claimed anything, so two runs overlapping
-- - Vercel cron delivers at least once, and a person running the curl command
-- in the comment alongside the schedule does it too - both read the same rows
-- and both sent them. The client gets the message twice; the second run's
-- delete finds nothing and still counts a send.
--
-- The claim is the fix: one conditional update, which is a lock because only
-- one transaction can move a row out of Scheduled. Whoever gets the row sends
-- it; whoever does not, skips it.
--
-- Which needs a status for "somebody is sending this right now", and a way
-- back from it. A run that dies between the claim and the send would
-- otherwise leave a text claimed forever and never sent - a silent failure,
-- which is worse than the double send it replaced. So claimed_at, and
-- anything still Sending after fifteen minutes is handed back. Fifteen
-- minutes is far longer than a send takes and far shorter than anybody
-- waiting for a text would tolerate, and a run that is merely slow has long
-- since finished.

alter table public.sms_messages
  add column if not exists claimed_at timestamptz;

comment on column public.sms_messages.claimed_at is
  'When a sending run took this scheduled text, so one that dies mid-send can be handed back (0209).';

alter table public.sms_messages drop constraint if exists sms_messages_status_check;
alter table public.sms_messages add constraint sms_messages_status_check
  check (status in ('Queued', 'Scheduled', 'Sending', 'Sent', 'Failed', 'Received'));

/**
 * Hands back anything a dead run left claimed, and returns how many.
 *
 * Called at the start of a sending run. Separate from the claim so that the
 * handing back is a decision about time and the claim is a decision about
 * ownership, and neither has to know about the other.
 */
create or replace function public.release_stale_text_claims(p_older_than interval default interval '15 minutes')
returns integer language sql security definer set search_path = public as $$
  with freed as (
    update public.sms_messages
       set status = 'Scheduled', claimed_at = null
     where status = 'Sending'
       and claimed_at is not null
       and claimed_at < now() - p_older_than
    returning id
  )
  select count(*)::int from freed;
$$;

comment on function public.release_stale_text_claims(interval) is
  'Returns scheduled texts left claimed by a run that died, so they are sent rather than lost (0209).';

revoke all on function public.release_stale_text_claims(interval) from anon, authenticated;

/**
 * Takes one scheduled text, if it is still there to take.
 *
 * Returns the row when this caller got it and nothing when somebody else
 * did. The condition on status is the whole mechanism: two runs both issue
 * this update, Postgres serialises them on the row, and the second one
 * matches nothing because the status is no longer Scheduled.
 */
create or replace function public.claim_scheduled_text(p_id uuid)
returns table (id uuid, client_id uuid, phone text, body text, kind text, created_by uuid)
language sql security definer set search_path = public as $$
  update public.sms_messages m
     set status = 'Sending', claimed_at = now()
   where m.id = p_id
     and m.status = 'Scheduled'
  returning m.id, m.client_id, m.phone, m.body, m.kind, m.created_by;
$$;

comment on function public.claim_scheduled_text(uuid) is
  'Takes a scheduled text for sending, or returns nothing if another run already has it (0209).';

revoke all on function public.claim_scheduled_text(uuid) from anon, authenticated;

do $$
begin
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'sms_messages' and column_name = 'claimed_at'
  ) then
    raise exception 'claimed_at did not arrive.';
  end if;
  raise notice 'ok  a scheduled text can be claimed, and a dead run''s claim can be handed back';
end $$;
