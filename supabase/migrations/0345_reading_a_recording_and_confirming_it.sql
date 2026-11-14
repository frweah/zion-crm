-- Zion Vocational Rehab CRM — reading a recording, and confirming it
--
-- The pipeline, the cost guard and the one door onto the record.
--
-- Nothing in this file talks to Azure. The route does that — it is the only
-- thing that can, because submitting a batch job needs a signed URL to the
-- audio and storage cannot be signed from SQL. What is here is every decision
-- about the recording: whether the practice will pay to read it, what state
-- it is in, and what happens when a person confirms what it says.

begin;

-- ── what a person has had read this month ────────────────────

create or replace function public.recording_minutes_this_month(p_staff uuid, p_month date)
returns numeric
language sql
stable
security definer
set search_path to 'public'
as $$
  /*
   * Minutes already sent to Azure this month, for one person.
   *
   * Counted from the states that mean the money was spent - anything that
   * reached Azure - and not from what is still waiting or was held. A
   * recording that failed is counted too: Azure was paid to try.
   */
  select coalesce(sum(r.minutes), 0)
    from public.recordings r
   where r.staff_id = p_staff
     and r.state in ('Reading', 'Read', 'Drafted', 'Confirmed', 'Not used', 'Failed')
     and r.created_at >= date_trunc('month', p_month)
     and r.created_at < (date_trunc('month', p_month) + interval '1 month');
$$;

revoke all on function public.recording_minutes_this_month(uuid, date) from public, anon;
grant execute on function public.recording_minutes_this_month(uuid, date) to authenticated, service_role;

create or replace function public.recording_hours_by_person(p_month date)
returns table(staff_id uuid, staff_name text, minutes numeric, hours numeric,
              allowed_hours integer, recordings integer, held integer)
language sql
stable
security definer
set search_path to 'public'
as $$
  select * from (
    select s.id, s.name,
           public.recording_minutes_this_month(s.id, coalesce(p_month, public.practice_today())),
           round(public.recording_minutes_this_month(s.id, coalesce(p_month, public.practice_today())) / 60.0, 2),
           (select o.recording_hours_per_person from public.org_settings o limit 1),
           (select count(*)::int from public.recordings r
             where r.staff_id = s.id
               and r.created_at >= date_trunc('month', coalesce(p_month, public.practice_today()))
               and r.created_at < (date_trunc('month', coalesce(p_month, public.practice_today())) + interval '1 month')),
           (select count(*)::int from public.recordings r
             where r.staff_id = s.id and r.state = 'Held')
      from public.staff s
     where s.active and not s.is_system
     order by 3 desc, s.name
  ) as rows_for_staff
   where public.reader_may_answer();
$$;

comment on function public.recording_hours_by_person is
  'How much recording each person has had read this month, against what the '
  'practice allows. Admin > Money reads it: the guard is on the money, so '
  'the figure belongs where the money is.';

revoke all on function public.recording_hours_by_person(date) from public, anon;
grant execute on function public.recording_hours_by_person(date) to authenticated, service_role;

-- ── a recording arrives ──────────────────────────────────────

create or replace function public.start_recording(p_attachment uuid)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_att public.attachments%rowtype;
  v_id  uuid;
begin
  select * into v_att from public.attachments where id = p_attachment;
  if not found then
    raise exception 'That document is not on file.' using errcode = 'no_data_found';
  end if;
  if coalesce(v_att.mime_type, '') not like 'audio/%' then
    raise exception 'That is not a recording.' using errcode = 'check_violation';
  end if;

  -- The same key twice is the upload being retried, which the phone does.
  select id into v_id from public.recordings where attachment_id = p_attachment;
  if v_id is not null then
    return v_id;
  end if;

  insert into public.recordings (attachment_id, client_id, staff_id, state)
  values (p_attachment, v_att.client_id,
          coalesce(v_att.uploaded_by, public.current_staff_id()), 'Waiting')
  returning id into v_id;
  return v_id;
end;
$$;

comment on function public.start_recording is
  'Puts an uploaded recording in the queue to be read. Idempotent on the '
  'attachment, because the phone retries an upload with the key it already '
  'used.';

revoke all on function public.start_recording(uuid) from public, anon, authenticated;
grant execute on function public.start_recording(uuid) to authenticated, service_role;

-- ── what the reader should pick up ───────────────────────────

create or replace function public.recordings_to_read()
returns table(id uuid, attachment_id uuid, client_id uuid, storage_path text,
              mime_type text, state text, job_url text, minutes_left numeric)
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_allowed integer;
  r         record;
begin
  if coalesce(auth.role(), '') <> 'service_role' and not public.is_active_staff() then
    raise exception 'Only the reader picks up recordings.' using errcode = 'insufficient_privilege';
  end if;

  select o.recording_hours_per_person into v_allowed from public.org_settings o limit 1;

  /*
   * The cost guard, where the money is spent.
   *
   * Not at upload: a recording can sit waiting across the turn of a month,
   * and several can pass a check at upload and then all be submitted at once.
   * This is the moment the practice pays, so this is where the limit is
   * asked - and a recording over it is **held**, not refused. The audio is
   * already on the client's record; what the limit stops is paying to read
   * it, and an Admin can raise the limit and let it through.
   */
  for r in
    select g.id, g.staff_id, a.size_bytes
      from public.recordings g
      join public.attachments a on a.id = g.attachment_id
     where g.state = 'Waiting'
  loop
    if public.recording_minutes_this_month(r.staff_id, public.practice_today())
         >= coalesce(v_allowed, 20) * 60 then
      /*
       * Aliased, because this function returns a column called `id`.
       *
       * A plpgsql function with RETURNS TABLE(id ...) has `id` in scope as an
       * output parameter, so an unqualified `where id = r.id` is ambiguous
       * and Postgres says so at run time rather than at create time. The
       * verify script found it on the first run.
       */
      update public.recordings as g
         set state = 'Held',
             reason = format('%s hours of recording have been read for this person this month, which is the month''s limit.',
                             coalesce(v_allowed, 20)),
             updated_at = now()
       where g.id = r.id;
    end if;
  end loop;

  return query
    select g.id, g.attachment_id, g.client_id, a.storage_path, a.mime_type,
           g.state, g.job_url,
           round(coalesce(v_allowed, 20) * 60
                 - public.recording_minutes_this_month(g.staff_id, public.practice_today()), 1)
      from public.recordings g
      join public.attachments a on a.id = g.attachment_id
     where g.state in ('Waiting', 'Reading')
       and g.attempts < 3
     order by g.created_at;
end;
$$;

comment on function public.recordings_to_read is
  'Recordings waiting to be sent to Azure and jobs waiting for an answer. '
  'Holds anything over the month''s hours as it goes, because this is the '
  'moment the practice pays.';

revoke all on function public.recordings_to_read() from public, anon;
grant execute on function public.recordings_to_read() to service_role;

-- ── and what the reader reports back ─────────────────────────

create or replace function public.recording_reading(p_id uuid, p_job_url text)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'Only the reader records a job.' using errcode = 'insufficient_privilege';
  end if;
  update public.recordings
     set state = 'Reading', job_url = btrim(p_job_url),
         attempts = attempts + 1, updated_at = now()
   where id = p_id and state in ('Waiting', 'Reading');
end;
$$;

create or replace function public.recording_read(
  p_id uuid, p_turns jsonb, p_transcript text, p_minutes numeric
) returns void
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'Only the reader records a reading.' using errcode = 'insufficient_privilege';
  end if;

  /*
   * An empty reading is a reading.
   *
   * The same rule a photo follows (0343): the audio was read and there were
   * no words in it - a pocket recording, a silent room - and that is an
   * answer. It is recorded as read with nothing in it, and the reader stops
   * asking. A *failure* is different and is never recorded as a reading.
   */
  update public.recordings
     set state = 'Read',
         turns = p_turns,
         transcript = coalesce(p_transcript, ''),
         minutes = p_minutes,
         reason = case when coalesce(btrim(p_transcript), '') = ''
                       then 'Read, and there were no words in it' else '' end,
         updated_at = now()
   where id = p_id and state in ('Reading', 'Waiting');
end;
$$;

create or replace function public.recording_drafted(p_id uuid, p_summary jsonb)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'Only the reader records a draft.' using errcode = 'insufficient_privilege';
  end if;
  update public.recordings
     set state = 'Drafted', summary = p_summary, updated_at = now()
   where id = p_id and state = 'Read';
end;
$$;

create or replace function public.recording_failed(p_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'Only the reader records a failure.' using errcode = 'insufficient_privilege';
  end if;
  /*
   * Three tries, and then it says so.
   *
   * A photo that will not read is asked for again on the next run and left
   * alone after a week. A batch job is different: Azure has already been
   * paid for the attempt, so a recording that fails three times stops being
   * asked for and waits for a person to look at it.
   */
  update public.recordings
     set state = case when attempts >= 3 then 'Failed' else 'Waiting' end,
         reason = btrim(coalesce(p_reason, 'Azure could not read it')),
         job_url = '',
         updated_at = now()
   where id = p_id and state in ('Waiting', 'Reading');
end;
$$;

revoke all on function public.recording_reading(uuid, text) from public, anon, authenticated;
revoke all on function public.recording_read(uuid, jsonb, text, numeric) from public, anon, authenticated;
revoke all on function public.recording_drafted(uuid, jsonb) from public, anon, authenticated;
revoke all on function public.recording_failed(uuid, text) from public, anon, authenticated;
grant execute on function public.recording_reading(uuid, text) to service_role;
grant execute on function public.recording_read(uuid, jsonb, text, numeric) to service_role;
grant execute on function public.recording_drafted(uuid, jsonb) to service_role;
grant execute on function public.recording_failed(uuid, text) to service_role;

-- ── the one door onto the record ─────────────────────────────

create or replace function public.confirm_recording(
  p_id uuid,
  p_about text,
  p_agreed text,
  p_next text,
  p_note text,
  p_category text
) returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_rec   public.recordings%rowtype;
  v_staff uuid := public.current_staff_id();
  v_name  text;
  v_log   uuid;
  v_note  uuid;
begin
  if v_staff is null then
    raise exception 'You are not signed in.' using errcode = 'insufficient_privilege';
  end if;

  select * into v_rec from public.recordings where id = p_id for update;
  if not found then
    raise exception 'That recording is not on file.' using errcode = 'no_data_found';
  end if;

  /*
   * Only somebody who could have heard it.
   *
   * A recording is a restricted document, so the people who may confirm what
   * it said are the people who may open it. Anybody else would be confirming
   * a machine reading of a conversation they are not allowed to listen to.
   */
  if not public.can_see_restricted(v_rec.client_id) then
    raise exception 'This recording is restricted to the people who may open this client''s restricted documents.'
      using errcode = 'insufficient_privilege';
  end if;

  if v_rec.state not in ('Read', 'Drafted') then
    raise exception 'That recording is %, so there is nothing to confirm.', lower(v_rec.state)
      using errcode = 'check_violation';
  end if;
  if coalesce(btrim(p_about), '') = '' then
    raise exception 'Say what it was about — it is the line the contact log shows.'
      using errcode = 'check_violation';
  end if;
  if coalesce(btrim(p_note), '') = '' then
    raise exception 'The note is what goes on the record. Write it, or set the recording aside.'
      using errcode = 'check_violation';
  end if;

  select name into v_name from public.staff where id = v_staff;

  /*
   * The contact log: what it was about, and what came of it.
   *
   * `follow_up` is a **date** on this table, not a sentence - the day
   * somebody is to be chased - and the draft's "what happens next" is words.
   * So the words go with the outcome, as their own sentence, and the
   * follow-up date is left to whoever sets one: a machine reading of
   * "ring on Thursday" is not a date this should pick.
   *
   * All four fields are kept on the recording itself whatever happens here,
   * so nothing a person confirmed is lost by the contact log holding three.
   */
  insert into public.contact_log
    (client_id, date, method, topic, outcome, staff_id, category)
  values
    (v_rec.client_id,
     coalesce((select a.document_date from public.attachments a where a.id = v_rec.attachment_id),
              public.practice_today()),
     'Meeting', btrim(p_about),
     btrim(concat_ws(' ',
       nullif(btrim(coalesce(p_agreed, '')), ''),
       case when coalesce(btrim(p_next), '') <> ''
            then 'Next: ' || btrim(p_next) end)),
     v_staff,
     nullif(btrim(coalesce(p_category, '')), ''))
  returning id into v_log;

  -- And the note, which is what a report reads. Attached to the recording, so
  -- anybody reading the note can see what it came from.
  insert into public.notes
    (client_id, staff_id, staff_name, text, type, category, attachment_id)
  values
    (v_rec.client_id, v_staff, coalesce(v_name, ''), btrim(p_note), 'Meeting',
     nullif(btrim(coalesce(p_category, '')), ''), v_rec.attachment_id)
  returning id into v_note;

  update public.recordings
     set state = 'Confirmed',
         summary = jsonb_build_object(
           'about', btrim(p_about),
           'agreed', btrim(coalesce(p_agreed, '')),
           'next', btrim(coalesce(p_next, '')),
           'note', btrim(p_note)),
         confirmed_at = now(), confirmed_by = v_staff,
         contact_log_id = v_log, note_id = v_note,
         reason = '', updated_at = now()
   where id = p_id;

  return jsonb_build_object('contact_log', v_log, 'note', v_note);
end;
$$;

comment on function public.confirm_recording is
  'What a person confirmed a recording said, written onto the record as a '
  'contact log entry and a note. The only way anything from a recording '
  'reaches a client''s record.';

revoke all on function public.confirm_recording(uuid, text, text, text, text, text)
  from public, anon, authenticated;
grant execute on function public.confirm_recording(uuid, text, text, text, text, text) to authenticated;

create or replace function public.set_recording_aside(p_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_rec public.recordings%rowtype;
begin
  select * into v_rec from public.recordings where id = p_id for update;
  if not found then
    raise exception 'That recording is not on file.' using errcode = 'no_data_found';
  end if;
  if not public.can_see_restricted(v_rec.client_id) then
    raise exception 'This recording is restricted to the people who may open this client''s restricted documents.'
      using errcode = 'insufficient_privilege';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'Say why it is not going on the record.' using errcode = 'check_violation';
  end if;
  if v_rec.state = 'Confirmed' then
    raise exception 'That one is already on the record.' using errcode = 'check_violation';
  end if;

  update public.recordings
     set state = 'Not used', reason = btrim(p_reason), updated_at = now()
   where id = p_id;
end;
$$;

comment on function public.set_recording_aside is
  'A recording a person has read and decided does not go on the record, with '
  'the reason. The audio stays on the client''s documents either way.';

revoke all on function public.set_recording_aside(uuid, text) from public, anon, authenticated;
grant execute on function public.set_recording_aside(uuid, text) to authenticated;

/*
 * A held recording, let through.
 *
 * Admin's, because it is a decision to spend money the limit was set to stop.
 * It goes back to Waiting and the next run picks it up - and if the month's
 * hours are still over the limit it will be held again, which is why raising
 * the limit is the other half of this.
 */
create or replace function public.read_held_recording(p_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if not public.is_admin() then
    raise exception 'Only Admin pays to read a recording over the month''s hours.'
      using errcode = 'insufficient_privilege';
  end if;
  update public.recordings
     set state = 'Waiting', reason = '', attempts = 0, updated_at = now()
   where id = p_id and state = 'Held';
  if not found then
    raise exception 'That recording is not being held.' using errcode = 'check_violation';
  end if;
end;
$$;

revoke all on function public.read_held_recording(uuid) from public, anon, authenticated;
grant execute on function public.read_held_recording(uuid) to authenticated;

commit;
