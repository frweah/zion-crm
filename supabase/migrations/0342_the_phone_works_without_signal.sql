-- Zion Vocational Rehab CRM — the phone works without signal
--
-- "Works without signal for the things done standing up ... Saved locally,
-- synced when back online, shown as 'waiting to send' until then; a sync that
-- fails is shown, never silent." (owner, 11 Nov 2026)
--
-- A phone that sends something while the signal comes and goes will send it
-- twice sooner or later: the request reaches the server, the answer does not
-- reach the phone, and the phone - which is right to keep what it was given -
-- tries again. So everything the phone sends carries a key it made itself,
-- once, when the person pressed the button, and the second arrival of a key is
-- answered "already done" instead of being done again.
--
-- Two ways that is held, depending on what is being written:
--
--   A note, a document: the key *is* the row's id. A second insert of the
--   same id is refused by the primary key, which needs nothing new here.
--
--   The clock, a To file confirmation, a Team message: these are database
--   functions that already exist, and their rows have ids of their own. So
--   the key goes in `phone_receipts`, in the same transaction as the work -
--   one RPC call is one transaction - and a key already there means the work
--   was done. If the work fails, the receipt rolls back with it and the phone
--   can try again.
--
-- ── the time the button was pressed ──────────────────────────
--
-- Clocking in at 8:02 in a car park with no signal, and the phone finding a
-- signal at 8:40, has to record 8:02. The existing clock functions all use
-- now(), so `phone_clock` takes the time the phone says it was pressed - and
-- since that is a person telling payroll when they started, it is bounded and
-- it is written down:
--
--   no more than two minutes in the future (a phone's clock drifts), and no
--   more than a day in the past - an offline shift is hours, not a week;
--
--   a clock-in no earlier than the end of this person's last session;
--
--   a break inside the session it belongs to;
--
--   and every receipt keeps both times, the one claimed and the one it
--   arrived, so Admin can see which sessions were clocked from a phone with no
--   signal and by how much. That is the record a correction is argued from.

begin;

create table if not exists public.phone_receipts (
  key          uuid primary key,
  staff_id     uuid not null references public.staff(id) on delete cascade,
  kind         text not null check (kind in ('clock in', 'break', 'back', 'clock out', 'to file', 'team message')),
  -- When the person pressed the button, as the phone says.
  happened_at  timestamptz not null,
  -- When it reached the practice.
  received_at  timestamptz not null default now(),
  -- What the work returned, where it returned an id.
  result       uuid
);

create index if not exists phone_receipts_staff on public.phone_receipts (staff_id, received_at desc);

alter table public.phone_receipts enable row level security;

-- A person sees their own receipts, Admin sees everybody's. Nobody writes one
-- directly: the functions below are the only way in.
drop policy if exists phone_receipts_read on public.phone_receipts;
create policy phone_receipts_read on public.phone_receipts
  for select to authenticated
  using (staff_id = public.current_staff_id() or public.current_staff_role() = 'Admin');

revoke all on public.phone_receipts from anon;
grant select on public.phone_receipts to authenticated;

-- ── one key, once ────────────────────────────────────────────
--
-- Claims the key for this person. False means it was claimed before - by this
-- person, because a key is a random uuid the phone made. A key claimed by
-- somebody else is refused rather than answered "already done": that is not a
-- retry, and saying it was done would be telling one person another's work
-- went through.
create or replace function public.phone_claim(p_key uuid, p_kind text, p_at timestamptz)
returns boolean
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_me    uuid := public.current_staff_id();
  v_owner uuid;
begin
  if v_me is null then
    raise exception 'Only staff send from the phone.' using errcode = 'insufficient_privilege';
  end if;
  if p_key is null then
    raise exception 'That came without its key. Nothing was done.' using errcode = 'check_violation';
  end if;

  select staff_id into v_owner from public.phone_receipts where key = p_key;
  if found then
    if v_owner <> v_me then
      raise exception 'That key belongs to somebody else. Nothing was done.' using errcode = 'insufficient_privilege';
    end if;
    return false;
  end if;

  begin
    insert into public.phone_receipts (key, staff_id, kind, happened_at)
    values (p_key, v_me, p_kind, coalesce(p_at, now()));
  exception when unique_violation then
    -- Two tabs sending the same thing at once: the other one has it.
    return false;
  end;
  return true;
end $$;

revoke all on function public.phone_claim(uuid, text, timestamptz) from public, anon, authenticated;

-- ── the clock, at the time it was pressed ────────────────────
create or replace function public.phone_clock(p_key uuid, p_kind text, p_at timestamptz)
returns text
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_me   uuid := public.current_staff_id();
  t      public.work_session_timers;
  v_last timestamptz;
  v_id   uuid;
begin
  if p_kind not in ('clock in', 'break', 'back', 'clock out') then
    raise exception 'Say clock in, break, back or clock out.' using errcode = 'check_violation';
  end if;
  if p_at is null then
    raise exception 'That came without the time it was pressed.' using errcode = 'check_violation';
  end if;
  if p_at > now() + interval '2 minutes' then
    raise exception 'The phone''s clock is ahead of the practice''s — check the time on the phone, then send it again.'
      using errcode = 'check_violation';
  end if;
  if p_at < now() - interval '1 day' then
    raise exception 'That was pressed more than a day ago — correct it on Time clock instead.'
      using errcode = 'check_violation';
  end if;

  if not public.phone_claim(p_key, p_kind, p_at) then
    return 'already';
  end if;

  select * into t from public.work_session_timers where staff_id = v_me;

  if p_kind = 'clock in' then
    if t.staff_id is not null then
      raise exception 'You are already clocked in.'
        using hint = 'Clock out first, or start a break.', errcode = 'unique_violation';
    end if;
    select max(ended_at) into v_last from public.work_sessions where staff_id = v_me;
    if v_last is not null and p_at < v_last then
      raise exception 'That is before your last session ended — correct it on Time clock instead.'
        using errcode = 'check_violation';
    end if;
    insert into public.work_session_timers (staff_id, started_at, note, client_id, last_seen_at)
    values (v_me, p_at, '', null, now());

  elsif p_kind = 'break' then
    if t.staff_id is null then
      raise exception 'You are not clocked in.' using errcode = 'no_data_found';
    end if;
    if t.break_started_at is not null then
      raise exception 'You are already on a break.' using errcode = 'check_violation';
    end if;
    if p_at < t.started_at then
      raise exception 'That break starts before you clocked in.' using errcode = 'check_violation';
    end if;
    update public.work_session_timers
       set break_started_at = p_at, last_seen_at = now()
     where staff_id = v_me;

  elsif p_kind = 'back' then
    if t.staff_id is null then
      raise exception 'You are not clocked in.' using errcode = 'no_data_found';
    end if;
    if t.break_started_at is null then
      raise exception 'You are not on a break.' using errcode = 'check_violation';
    end if;
    if p_at < t.break_started_at then
      raise exception 'That is before the break started.' using errcode = 'check_violation';
    end if;
    update public.work_session_timers
       set break_seconds = break_seconds + greatest(0, extract(epoch from (p_at - t.break_started_at))::integer),
           break_started_at = null,
           last_seen_at = now()
     where staff_id = v_me;

  else
    if t.staff_id is not null and p_at < t.started_at then
      raise exception 'That clock-out is before you clocked in.' using errcode = 'check_violation';
    end if;
    -- The same function the header button uses, told when.
    v_id := public.clock_out('', null, p_at);
    update public.phone_receipts set result = v_id where key = p_key;
  end if;

  return 'done';
end $$;

revoke all on function public.phone_clock(uuid, text, timestamptz) from public, anon, authenticated;
grant execute on function public.phone_clock(uuid, text, timestamptz) to authenticated;

-- ── To file, confirmed from the phone ────────────────────────
create or replace function public.phone_to_file_confirm(
  p_key      uuid,
  p_at       timestamptz,
  p_item     uuid,
  p_outcome  text,
  p_note     text default '',
  p_category text default null)
returns text
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_id uuid;
begin
  if not public.phone_claim(p_key, 'to file', p_at) then
    return 'already';
  end if;
  -- to_file_confirm asks whose the item is, itself: the claim above says only
  -- that this key is new.
  v_id := public.to_file_confirm(p_item, p_outcome, coalesce(p_note, ''), p_category);
  update public.phone_receipts set result = v_id where key = p_key;
  return 'done';
end $$;

revoke all on function public.phone_to_file_confirm(uuid, timestamptz, uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.phone_to_file_confirm(uuid, timestamptz, uuid, text, text, text) to authenticated;

-- ── a Team message from the phone ────────────────────────────
create or replace function public.phone_post_message(
  p_key          uuid,
  p_at           timestamptz,
  p_conversation uuid,
  p_body         text)
returns text
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_id uuid;
begin
  if not public.phone_claim(p_key, 'team message', p_at) then
    return 'already';
  end if;
  -- post_message checks membership, the body and everything else it checks
  -- for the desk.
  v_id := public.post_message(p_conversation, p_body, '[]'::jsonb, '{}'::uuid[], '{}'::uuid[]);
  update public.phone_receipts set result = v_id where key = p_key;
  return 'done';
end $$;

revoke all on function public.phone_post_message(uuid, timestamptz, uuid, text) from public, anon, authenticated;
grant execute on function public.phone_post_message(uuid, timestamptz, uuid, text) to authenticated;

-- ── a recording is a document too ────────────────────────────
--
-- A voice memo after a visit goes on the client's Documents like a scan does.
-- The bucket took no audio, so the recording would have been refused at the
-- upload with a message about file types. These are what iPhone and Android
-- browsers record in.
update storage.buckets
   set allowed_mime_types = (
     select array_agg(distinct m)
       from unnest(allowed_mime_types || array['audio/webm', 'audio/mp4', 'audio/mpeg', 'audio/ogg', 'audio/aac', 'audio/x-m4a']) as m)
 where id = 'client-files';

commit;
