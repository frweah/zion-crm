/**
 * Calls in the browser, and what a voicemail is (owner, 27 November 2026).
 *
 * Part B of the telephony move. The client line will ring in the CRM rather
 * than on a cell phone, which means three things have to exist that did not:
 * a record of each call, a way to know who is at their desk to ring, and a
 * home for a message nobody was there to take.
 *
 * ── A voicemail is the client speaking ─────────────────────
 *
 * The brief asked for a contact-log line with `is_real_contact false` and
 * `direction inbound`. Neither of those was a column: `is_real_contact` is a
 * function of the *method* - 'Call' counts towards a client's month and 'End
 * of day report' does not - and there was no direction at all. So the two
 * halves are done the way the practice already decides these things:
 *
 *   - a voicemail's method is **'Voicemail'**, which is not in
 *     `is_real_contact`'s list and therefore does not count towards the
 *     month. Nobody from the practice spoke, so nothing was contacted. A
 *     missed call with no message is 'Missed call', for the same reason.
 *
 *   - `contact_log.direction` says who started it, and is **nullable**, which
 *     is what every line written before today means: ours.
 *
 * The consequence that mattered is the one the owner approved separately. A
 * contact-log line reads on the client threads board as *the practice having
 * answered* - that is the rule CLAUDE.md names by file. A voicemail is the
 * client speaking, so a line written naively would mark the thread answered
 * by the very thing that needs answering. 0395 teaches the board the
 * difference; this migration only gives it something to read.
 *
 * ── Who is there to ring ───────────────────────────────────
 *
 * `staff_voice_presence` is one row per member of staff with a live voice
 * token, refreshed while their window is open. Nothing infers it: a token
 * issued five hours ago says nothing about whether anybody is at the desk,
 * and ringing eight browsers that are not there is how a caller waits
 * twenty-five seconds for a voicemail that could have come immediately.
 *
 * Ninety seconds of grace on a sixty-second refresh, so one missed beat -
 * a slow request, a tab the browser throttled for a moment - does not take
 * somebody off the phones mid-call.
 *
 * Tolerates the old code: three new tables nothing deployed writes, and one
 * new nullable column on contact_log whose null means exactly what every
 * existing row already means.
 */

-- ── which way a contact-log line went ────────────────────────

alter table public.contact_log
  add column if not exists direction text;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'contact_log_direction_check') then
    alter table public.contact_log
      add constraint contact_log_direction_check
      check (direction is null or direction in ('Inbound', 'Outbound'));
  end if;
end $$;

comment on column public.contact_log.direction is
  'Who started it: Inbound, Outbound, or null for every line written before 0394, which means ours.';

/**
 * The new column has to be granted by name.
 *
 * `contact_log` carries column grants rather than a table grant, so a column
 * added without this is a column no screen can read - and `select` of the
 * others goes on working, which is what makes it quiet (the `select *`
 * lesson, 0282).
 */
grant select (direction) on public.contact_log to authenticated;
grant insert (direction), update (direction) on public.contact_log to authenticated;

-- ── every call, either way ───────────────────────────────────

create table if not exists public.voice_calls (
  id             uuid primary key default gen_random_uuid(),
  call_sid       text not null unique,
  direction      text not null check (direction in ('Inbound', 'Outbound')),
  from_phone     text not null,
  to_phone       text not null,
  /**
   * Who it was, if the number is one we hold. Null is an honest answer and a
   * common one: a counselor's direct line, a wrong number, somebody ringing
   * about a job advert. The screen says "Unknown caller" and the call is
   * still on file.
   */
  client_id      uuid references public.clients(id) on delete set null,
  contact_id     uuid references public.client_contacts(id) on delete set null,
  answered_by    uuid references public.staff(id) on delete set null,
  state          text not null default 'Ringing'
                 check (state in ('Ringing', 'Answered', 'Voicemail', 'Missed', 'Failed')),
  started_at     timestamptz not null default now(),
  answered_at    timestamptz,
  ended_at       timestamptz,
  seconds        integer,
  /** The voicemail, where there is one. */
  recording_sid  text,
  recording_secs integer,
  /** Where the audio was filed, and the reading of it, once there is a client. */
  attachment_id  uuid references public.attachments(id) on delete set null,
  recording_id   uuid references public.recordings(id) on delete set null,
  contact_log_id uuid references public.contact_log(id) on delete set null,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

comment on table public.voice_calls is
  'One row per call on the practice line, inbound or outbound, with the voicemail and its reading where there is one.';

create index if not exists voice_calls_client_idx on public.voice_calls (client_id, started_at desc);
create index if not exists voice_calls_state_idx on public.voice_calls (state, started_at desc);

alter table public.voice_calls enable row level security;

create policy voice_calls_read on public.voice_calls
  for select using ((select public.is_active_staff()));

/**
 * Written by the webhook routes through their own functions, which run as the
 * service role. Nothing on a screen writes a call: a call is a thing that
 * happened, not a thing somebody types.
 *
 * The three below are belt over a door that is already shut - there is no
 * permissive insert, update or delete policy on this table, and with row
 * level security on, no policy means no write. The fault suite found that out
 * the useful way: dropping the restrictive insert policy changed nothing,
 * because it was never the thing refusing. They stay because they say so out
 * loud, and because a permissive policy added later for one reason would
 * otherwise quietly open all three.
 */
create policy voice_calls_no_insert on public.voice_calls
  as restrictive for insert with check (false);
create policy voice_calls_no_edit on public.voice_calls
  as restrictive for update using (false);
create policy voice_calls_no_delete on public.voice_calls
  as restrictive for delete using (false);

revoke all on public.voice_calls from anon, public;
grant select on public.voice_calls to authenticated;
select public.apply_system_read_only('public.voice_calls'::regclass);

-- ── who is at their desk ─────────────────────────────────────

create table if not exists public.staff_voice_presence (
  staff_id uuid primary key references public.staff(id) on delete cascade,
  since    timestamptz not null default now(),
  at       timestamptz not null default now()
);

comment on table public.staff_voice_presence is
  'Who has a live voice token right now, refreshed every 60 seconds. Read by the inbound TwiML to decide whose browser to ring.';

alter table public.staff_voice_presence enable row level security;

create policy staff_voice_presence_read on public.staff_voice_presence
  for select using ((select public.is_active_staff()));
create policy staff_voice_presence_no_insert on public.staff_voice_presence
  as restrictive for insert with check (false);
create policy staff_voice_presence_no_edit on public.staff_voice_presence
  as restrictive for update using (false);
create policy staff_voice_presence_no_delete on public.staff_voice_presence
  as restrictive for delete using (false);

revoke all on public.staff_voice_presence from anon, public;
grant select on public.staff_voice_presence to authenticated;
select public.apply_system_read_only('public.staff_voice_presence'::regclass);

/**
 * How long a refresh is good for.
 *
 * Named once, in the database, because the browser's refresh interval and the
 * window the TwiML trusts have to agree - and if they drift apart the symptom
 * is a caller ringing a desk nobody is at, which looks like a broken phone
 * rather than a mistuned number.
 */
create or replace function public.voice_presence_seconds()
returns integer language sql immutable as $$ select 90 $$;

-- ── I am at my desk ──────────────────────────────────────────

/**
 * Said by the browser that has a voice token, every sixty seconds.
 *
 * It writes for the caller and nobody else, which is why it takes no
 * argument: a function that let one person say somebody *else* was on the
 * phones would ring a desk at the wrong end of the building.
 */
create or replace function public.voice_here()
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_me uuid := public.current_staff_id();
begin
  if v_me is null or not public.is_active_staff() then
    raise exception 'You are not signed in.' using errcode = 'insufficient_privilege';
  end if;

  insert into public.staff_voice_presence (staff_id, since, at)
  values (v_me, now(), now())
  on conflict (staff_id) do update set at = now();

  return v_me::text;
end $$;

/** And gone, when the window closes or the microphone is refused. */
create or replace function public.voice_gone()
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_me uuid := public.current_staff_id();
begin
  if v_me is null then return; end if;
  delete from public.staff_voice_presence where staff_id = v_me;
end $$;

/**
 * Whose browser to ring.
 *
 * Active staff, with a fresh beat, and a role that takes client calls. The
 * roles are the ones that already send texts from a client's record - if a
 * seat may not text a client, their desk is not where the client line should
 * ring.
 */
create or replace function public.staff_on_the_phones()
returns table (staff_id uuid, name text)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select s.id, s.name
    from public.staff_voice_presence p
    join public.staff s on s.id = p.staff_id
   where s.active
     and not s.is_system
     and s.role = any (array['Admin', 'Job Search', 'Reports'])
     and p.at > now() - make_interval(secs => public.voice_presence_seconds())
   order by p.since
$$;

revoke all on function public.voice_here() from anon, public;
revoke all on function public.voice_gone() from anon, public;
revoke all on function public.staff_on_the_phones() from anon, public;
revoke all on function public.voice_presence_seconds() from anon, public;
grant execute on function public.voice_here() to authenticated;
grant execute on function public.voice_gone() to authenticated;
grant execute on function public.staff_on_the_phones() to authenticated, service_role;
grant execute on function public.voice_presence_seconds() to authenticated, service_role;

-- ── a call arriving ──────────────────────────────────────────

/**
 * Who is calling, by the number they are calling from.
 *
 * `client_numbers` is the same view the texting gate reads, so a name on the
 * incoming banner and a name on a text thread cannot disagree. The client's
 * own numbers come before their contacts' - the owner's order, and the only
 * one that cannot label a client as their own daughter-in-law.
 */
create or replace function public.who_is_calling(p_phone text)
returns table (client_id uuid, contact_id uuid, label text)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select n.client_id,
         n.contact_id,
         case
           when n.contact_id is null then coalesce(c.name, 'Unknown caller')
           else coalesce(n.whose_name, 'Somebody') ||
                coalesce(' (' || nullif(btrim(coalesce(n.relationship, '')), '') || ' of ' ||
                         coalesce(c.name, 'a client') || ')', ' for ' || coalesce(c.name, 'a client'))
         end as label
    from public.client_numbers n
    join public.clients c on c.id = n.client_id
   where n.phone = public.normalize_phone(p_phone)
   order by case when n.whose = 'Client' then 0 else 1 end,
            case when c.status = 'Active' then 0 else 1 end,
            c.created_at
   limit 1
$$;

revoke all on function public.who_is_calling(text) from anon, public;
grant execute on function public.who_is_calling(text) to authenticated, service_role;

/**
 * A call is arriving, or we are placing one.
 *
 * Written before anybody's browser rings, so a call that nothing answers and
 * nothing records still happened and is still on the record. Keyed by the
 * call SID: Twilio retries a webhook, and a retry is the same call.
 */
create or replace function public.record_call_started(
  p_sid       text,
  p_direction text,
  p_from      text,
  p_to        text
)
returns table (call_id uuid, client_id uuid, contact_id uuid, label text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_who    record;
  v_call   uuid;
  v_phone  text := case when p_direction = 'Inbound' then p_from else p_to end;
begin
  if coalesce(btrim(coalesce(p_sid, '')), '') = '' then
    raise exception 'That call has no id on it, so there is nothing to put it against.'
      using errcode = 'check_violation';
  end if;
  if p_direction not in ('Inbound', 'Outbound') then
    raise exception 'A call goes one way or the other, not %.', p_direction
      using errcode = 'check_violation';
  end if;

  select * into v_who from public.who_is_calling(v_phone);

  insert into public.voice_calls (call_sid, direction, from_phone, to_phone, client_id, contact_id)
  values (p_sid, p_direction,
          public.normalize_phone(p_from), public.normalize_phone(p_to),
          v_who.client_id, v_who.contact_id)
  on conflict (call_sid) do update set updated_at = now()
  returning id into v_call;

  return query select v_call, v_who.client_id, v_who.contact_id,
                      coalesce(v_who.label, 'Unknown caller')::text;
end $$;

/**
 * Somebody picked it up.
 *
 * The identity Twilio reports is the staff id the token was issued for, which
 * is why the token carries one: a call answered by "a browser" is a call
 * nobody can be asked about afterwards.
 */
create or replace function public.record_call_answered(p_sid text, p_identity text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_staff uuid;
begin
  begin
    v_staff := nullif(btrim(coalesce(p_identity, '')), '')::uuid;
  exception when invalid_text_representation then
    v_staff := null;
  end;

  update public.voice_calls
     set state = 'Answered',
         answered_at = coalesce(answered_at, now()),
         answered_by = coalesce(v_staff, answered_by),
         updated_at = now()
   where call_sid = p_sid;
end $$;

/**
 * And it ended.
 *
 * This is where a call becomes a contact, and only when somebody spoke:
 * an answered call is a contact on the client's month, method 'Call', and an
 * unanswered one is not. A missed call that left no message is on the record
 * as a missed call and counts towards nothing, which is the truth of it.
 *
 * The contact-log line is keyed to the call SID, so Twilio calling this twice
 * writes one line rather than two.
 */
create or replace function public.record_call_ended(
  p_sid     text,
  p_seconds integer default null,
  p_state   text default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  c        public.voice_calls;
  v_state  text;
  v_line   uuid;
  v_name   text;
  v_day    date;
begin
  select * into c from public.voice_calls where call_sid = p_sid;
  if c.id is null then return null; end if;

  -- A state already settled by the recording webhook wins: 'Voicemail' is
  -- more than 'the call ended', and the two webhooks race.
  v_state := case
    when c.state = 'Voicemail' then 'Voicemail'
    when p_state in ('Answered', 'Missed', 'Failed', 'Voicemail') then p_state
    when c.state = 'Answered' then 'Answered'
    else 'Missed'
  end;

  update public.voice_calls
     set state = v_state,
         ended_at = coalesce(ended_at, now()),
         seconds = coalesce(p_seconds, seconds),
         updated_at = now()
   where id = c.id
  returning * into c;

  -- Nothing to add to a month without a client, and nothing to add for a
  -- call nobody spoke on. The voicemail writes its own line, in
  -- record_voicemail, because it has words to put in it.
  if c.client_id is null or v_state <> 'Answered' then
    return c.contact_log_id;
  end if;

  select name into v_name from public.staff where id = c.answered_by;
  v_day := (coalesce(c.started_at, now()) at time zone 'America/Denver')::date;

  insert into public.contact_log
    (client_id, date, method, direction, topic, outcome, staff_id, source, source_key)
  values
    (c.client_id, v_day, 'Call', c.direction,
     case when c.direction = 'Inbound' then 'They called' else 'We called' end,
     case
       when coalesce(c.seconds, 0) > 0
         then coalesce(v_name, 'Somebody') || ' spoke to them for ' ||
              to_char((coalesce(c.seconds, 0) || ' seconds')::interval, 'MI:SS')
       else coalesce(v_name, 'Somebody') || ' spoke to them'
     end,
     c.answered_by, 'Call', p_sid)
  on conflict (source, source_key) where source is not null do nothing
  returning id into v_line;

  if v_line is null then
    select id into v_line from public.contact_log
     where source = 'Call' and source_key = p_sid limit 1;
  end if;

  update public.voice_calls set contact_log_id = v_line, updated_at = now() where id = c.id;
  return v_line;
end $$;

/**
 * A message nobody was there to take.
 *
 * The contact-log line goes in now, with no transcript, because the client
 * rang at ten past four whether or not Azure has read it yet - and a line
 * that only appears once a transcription finishes is a line that never
 * appears when transcription is off.
 *
 * `method` is 'Voicemail': nobody from the practice spoke, so it is not a
 * contact on the month. `direction` is 'Inbound', which is what 0395's board
 * reads to know the client is still waiting.
 */
create or replace function public.record_voicemail(
  p_sid           text,
  p_recording_sid text,
  p_seconds       integer default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  c      public.voice_calls;
  v_line uuid;
  v_day  date;
begin
  select * into c from public.voice_calls where call_sid = p_sid;
  if c.id is null then
    raise exception 'That call is not on file, so there is nothing to put a message against.'
      using errcode = 'no_data_found';
  end if;

  update public.voice_calls
     set state = 'Voicemail',
         recording_sid = coalesce(nullif(btrim(coalesce(p_recording_sid, '')), ''), recording_sid),
         recording_secs = coalesce(p_seconds, recording_secs),
         ended_at = coalesce(ended_at, now()),
         updated_at = now()
   where id = c.id
  returning * into c;

  if c.client_id is null then
    -- Nobody to put it on yet. It is on the call record, and a member of
    -- staff can say whose it is.
    return null;
  end if;

  v_day := (coalesce(c.started_at, now()) at time zone 'America/Denver')::date;

  insert into public.contact_log
    (client_id, date, method, direction, topic, outcome, source, source_key)
  values
    (c.client_id, v_day, 'Voicemail', 'Inbound', 'They left a message',
     case when coalesce(c.recording_secs, 0) > 0
          then 'A ' || c.recording_secs || '-second message, not read yet'
          else 'A message, not read yet' end,
     'Call', p_sid)
  on conflict (source, source_key) where source is not null do nothing
  returning id into v_line;

  if v_line is null then
    select id into v_line from public.contact_log
     where source = 'Call' and source_key = p_sid limit 1;
  end if;

  update public.voice_calls set contact_log_id = v_line, updated_at = now() where id = c.id;
  return v_line;
end $$;

/**
 * What the message said, once Azure has read it.
 *
 * The outcome on the contact-log line is replaced by the client's own words,
 * which is the point of reading it at all: "needs a reply" on a board is a
 * row somebody has to open, and "too far by bus, can we talk Monday" is a row
 * somebody can act on.
 */
create or replace function public.voicemail_was_read(
  p_sid        text,
  p_transcript text
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare c public.voice_calls; v_said text := btrim(coalesce(p_transcript, ''));
begin
  select * into c from public.voice_calls where call_sid = p_sid;
  if c.id is null or c.contact_log_id is null or v_said = '' then return; end if;

  update public.contact_log
     set outcome = left(v_said, 600), updated_at = now()
   where id = c.contact_log_id;
end $$;

revoke all on function public.record_call_started(text, text, text, text) from anon, public, authenticated;
revoke all on function public.record_call_answered(text, text) from anon, public, authenticated;
revoke all on function public.record_call_ended(text, integer, text) from anon, public, authenticated;
revoke all on function public.record_voicemail(text, text, integer) from anon, public, authenticated;
revoke all on function public.voicemail_was_read(text, text) from anon, public, authenticated;

-- Only the webhooks, which run as the service role. Nothing on a screen has
-- any business saying a call happened.

do $$
declare v_n integer; v_name text;
begin
  for v_name in select unnest(array[
    'voice_here', 'voice_gone', 'staff_on_the_phones', 'who_is_calling',
    'record_call_started', 'record_call_answered', 'record_call_ended',
    'record_voicemail', 'voicemail_was_read', 'voice_presence_seconds'])
  loop
    select count(*) into v_n from pg_proc p
     where p.pronamespace = 'public'::regnamespace and p.proname = v_name;
    if v_n <> 1 then
      raise exception '% exists at % signatures, not one', v_name, v_n;
    end if;
  end loop;

  select count(*) into v_n from information_schema.routine_privileges
   where routine_schema = 'public'
     and routine_name in ('record_call_started', 'record_call_answered', 'record_call_ended',
                          'record_voicemail', 'voicemail_was_read')
     and grantee in ('anon', 'public', 'authenticated');
  if v_n <> 0 then
    raise exception 'a screen can say a call happened (% grant(s))', v_n;
  end if;

  if public.is_real_contact('Voicemail') or public.is_real_contact('Missed call') then
    raise exception 'a voicemail counts as a contact on the month, and nobody spoke';
  end if;
  if not public.is_real_contact('Call') then
    raise exception 'an answered call stopped counting as a contact';
  end if;

  raise notice 'ok  a call has a home, a voicemail is the client speaking, and no screen writes either';
end $$;
