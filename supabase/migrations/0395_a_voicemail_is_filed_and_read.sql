/**
 * A voicemail is filed on the client and read by the path that already reads
 * recordings (owner, 27 November 2026).
 *
 * The brief said "transcribed through our existing Azure Speech path, not
 * Twilio transcription", and the existing path turned out to fit almost
 * exactly: `recordings` hangs off an attachment, carries the transcript and
 * the state, and the quarter-hourly `zion-recordings` job walks
 * `recordings_to_read()`. So a voicemail is an attachment on the client's
 * record with a `recordings` row waiting beside it, and nothing new reads
 * anything.
 *
 * Three decisions in here that are not obvious.
 *
 * **A voicemail is read against the practice's own account, not a person's.**
 * `recordings.staff_id` is whose monthly transcription hours a reading counts
 * against, and a voicemail is nobody's upload. Left null it would be read
 * outside the limit for ever, which is how a bill surprises somebody; put on
 * a member of staff it would eat the hours of whoever happened to be on the
 * phones. So it goes on the system account, which gives voicemail a bucket of
 * its own that Admin can raise like any other.
 *
 * **The contact-log line is written before the transcript exists.** The
 * client rang at ten past four whether or not Azure has read it yet, and a
 * line that only appears once a transcription finishes is a line that never
 * appears at all when transcription is switched off. The words replace the
 * placeholder when they arrive.
 *
 * **They arrive by trigger, not by editing the sweep.** The sweep's job is to
 * talk to Azure; whether a transcript belongs to a voicemail is not its
 * business, and a sweep that had to know would be a sweep to change again
 * next time something is read.
 *
 * Tolerates the old code: one new function nothing deployed calls, and a
 * trigger that only ever writes - it puts the client's words onto a
 * contact-log line that this migration's own function created, and raises
 * nothing at all, so no write that is being made today can be refused by it.
 */

-- ── where a file can come from ───────────────────────

/**
 * `attachments.source` allowed 'Staff' or 'Portal', and a voicemail is
 * neither. The function below would have raised on its first real message.
 *
 * 'Phone' rather than 'Twilio', deliberately. The carrier is a setting now
 * (0392), and a client's record is not the place the practice's choice of
 * supplier gets written down - a file filed as 'Twilio' would still say
 * 'Twilio' years after the practice had left, which is the same mistake the
 * two sentences in `record_text_status` were making.
 *
 * Widening a check constraint permits more and refuses nothing, so there is
 * no write anywhere that this can break.
 */
-- Tolerates the old code: this widens the vocabulary rather than narrowing
-- it. 'Staff' and 'Portal' are both still accepted, every row on file is one
-- of those two, and nothing deployed writes 'Phone' - so there is no write
-- being made today that the new constraint can refuse.

alter table public.attachments drop constraint if exists attachments_source_check;
alter table public.attachments
  add constraint attachments_source_check
  check (source = any (array['Staff', 'Portal', 'Phone']));

-- ── filing it ────────────────────────────────────────────────

/**
 * The audio is already in the bucket; this puts it on the record.
 *
 * The route uploads the bytes, because only the route has them, and then says
 * where they went. Everything about what a voicemail *is* - whose record it
 * belongs on, which category it is filed under, whose hours read it - is
 * here, so a second caller of this (a voicemail assigned to a client by hand,
 * later) gets the same answers.
 */
drop function if exists public.file_voicemail(text, text, text, text, bigint, text, integer);

create or replace function public.file_voicemail(
  p_sid          text,
  p_storage_path text,
  p_filename     text,
  p_mime         text,
  p_bytes        bigint,
  p_sha256       text default null,
  p_seconds      integer default null
)
/**
 * Named `filed_*` rather than for the columns they are.
 *
 * `attachment_id` and `recording_id` are columns on the two tables this
 * writes, and an output parameter of the same name shadows them - so an
 * unqualified reference is ambiguous, and an `on conflict (attachment_id)`
 * target, which cannot be qualified, has no way out of it at all. Postgres
 * says so at run time rather than at create time; the verify script said so
 * on the first run.
 */
returns table (filed_attachment uuid, filed_recording uuid)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  c          public.voice_calls;
  v_attach   uuid;
  v_record   uuid;
  v_system   uuid;
  v_label    text;
  v_day      date;
begin
  select * into c from public.voice_calls where call_sid = p_sid;
  if c.id is null then
    raise exception 'That call is not on file, so there is nothing to file a message against.'
      using errcode = 'no_data_found';
  end if;
  if c.client_id is null then
    raise exception 'That message is from a number nobody has placed yet, so there is no record to put it on.'
      using errcode = 'check_violation';
  end if;

  -- Already filed: the recording webhook is retried like any other.
  if c.attachment_id is not null then
    return query select c.attachment_id, c.recording_id;
    return;  -- already filed: the recording webhook is retried like any other
  end if;


  v_day := (coalesce(c.started_at, now()) at time zone 'America/Denver')::date;
  select coalesce(label, 'Unknown caller') into v_label from public.who_is_calling(c.from_phone);

  insert into public.attachments
    (client_id, storage_path, filename, mime_type, size_bytes, category, restricted,
     document_date, sha256, note, source)
  values
    (c.client_id, p_storage_path, p_filename, coalesce(nullif(btrim(coalesce(p_mime, '')), ''), 'audio/mpeg'),
     coalesce(p_bytes, 0), 'Voicemail', false, v_day,
     nullif(btrim(coalesce(p_sha256, '')), ''),
     'Voicemail from ' || coalesce(v_label, 'an unknown caller') ||
       coalesce(', ' || nullif(p_seconds, 0) || ' seconds', ''),
     'Phone')
  on conflict (client_id, sha256) where sha256 is not null and sha256 <> ''
  do nothing
  returning id into v_attach;

  /**
   * The same bytes twice.
   *
   * `attachments_one_copy_per_client` is a unique index on the client and the
   * hash, so a second message with identical audio - two seconds of silence
   * is the realistic case - is the same file. The one already there is used
   * rather than a second row made, and rather than the call failing to file.
   */
  if v_attach is null then
    select a.id into v_attach from public.attachments a
     where a.client_id = c.client_id
       and a.sha256 = nullif(btrim(coalesce(p_sha256, '')), '')
     order by a.created_at limit 1;
  end if;
  if v_attach is null then
    raise exception 'That message could not be filed on the record.'
      using errcode = 'check_violation';
  end if;

  /**
   * Whose hours read it. See the note at the top: the practice's own account,
   * so voicemail has a bucket of its own rather than nobody's or somebody
   * else's. If there is no system account the reading still happens, because
   * a voicemail nobody can read is worse than one read outside a limit.
   */
  select id into v_system from public.staff
   where is_system and active order by created_at limit 1;

  insert into public.recordings as g (attachment_id, client_id, staff_id, state)
  values (v_attach, c.client_id, v_system, 'Waiting')
  on conflict (attachment_id) do nothing
  returning g.id into v_record;
  if v_record is null then
    -- Qualified, because this function returns a column called
    -- `attachment_id`: that name is in scope as an output parameter, so an
    -- unqualified reference is ambiguous and Postgres says so at run time
    -- rather than at create time (the same trap 0345 left a note about).
    select g.id into v_record from public.recordings g where g.attachment_id = v_attach;
  end if;

  update public.voice_calls
     set attachment_id = v_attach, recording_id = v_record, updated_at = now()
   where id = c.id;

  return query select v_attach, v_record;
end $$;

revoke all on function public.file_voicemail(text, text, text, text, bigint, text, integer)
  from anon, public, authenticated;

-- Only the recording webhook, which runs as the service role.

-- ── and the words, when they come back ──────────────────────

/**
 * Azure has read a recording; if it was a voicemail, the client's own words
 * go onto the contact-log line.
 *
 * Only ever an update of one text column, and only when there is something to
 * put there - so there is no write anywhere in the practice that this can
 * refuse. A summarised voicemail would stop being a quotation, which is why
 * it is the transcript and not the draft.
 */
create or replace function public.voicemail_words_arrive()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare v_said text := btrim(coalesce(new.transcript, ''));
begin
  if v_said = '' or coalesce(old.transcript, '') = v_said then
    return new;
  end if;

  update public.contact_log cl
     set outcome = left(v_said, 600), updated_at = now()
    from public.voice_calls vc
   where vc.recording_id = new.id
     and cl.id = vc.contact_log_id;

  return new;
end $function$;

drop trigger if exists voicemail_words on public.recordings;
create trigger voicemail_words
  after update of transcript on public.recordings
  for each row execute function public.voicemail_words_arrive();

comment on function public.voicemail_words_arrive() is
  'Puts a voicemail transcript onto its contact-log line when Azure answers. Writes one column and refuses nothing.';

-- ── asked of itself ─────────────────────────────────────────

do $$
declare v_n integer;
begin
  select count(*) into v_n from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'file_voicemail';
  if v_n <> 1 then
    raise exception 'file_voicemail exists at % signatures, not one', v_n;
  end if;

  select count(*) into v_n from information_schema.routine_privileges
   where routine_schema = 'public' and routine_name = 'file_voicemail'
     and grantee in ('anon', 'public', 'authenticated');
  if v_n <> 0 then
    raise exception 'a screen can file a voicemail (% grant(s))', v_n;
  end if;

  select count(*) into v_n from pg_trigger
   where tgrelid = 'public.recordings'::regclass and tgname = 'voicemail_words' and not tgisinternal;
  if v_n <> 1 then
    raise exception 'the trigger that puts a voicemail''s words on its line is not there';
  end if;

  -- A voicemail is filed under a category of its own, so the client's files
  -- can be read without a recording of a meeting and a message on the
  -- answerphone looking like the same thing.
  if not exists (select 1 from pg_proc p where p.pronamespace = 'public'::regnamespace
                  and p.proname = 'file_voicemail'
                  and pg_get_functiondef(p.oid) like '%''Voicemail''%') then
    raise exception 'a voicemail is not filed as a voicemail';
  end if;

  if exists (select 1 from pg_proc p where p.pronamespace = 'public'::regnamespace
              and p.proname = 'file_voicemail'
              and pg_get_functiondef(p.oid) ~* 'twilio') then
    raise exception 'a voicemail is filed with the carrier''s name on it';
  end if;

  raise notice 'ok  a voicemail is filed on the client, read on the practice''s own hours, and quoted when it is';
end $$;
