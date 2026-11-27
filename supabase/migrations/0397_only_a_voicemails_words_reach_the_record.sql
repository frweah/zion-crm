/**
 * Only a voicemail's words reach the record (owner's rule of 14 November,
 * read against 0395).
 *
 * 0395 put a trigger on `recordings` that copies a transcript onto the
 * contact-log line a voicemail wrote. That is the same shape as the thing the
 * practice refuses: "the transcript never leaves the recording", because a
 * transcript is a machine's record of an hour of somebody talking about their
 * own life - their health, their family, what the state pays them, what their
 * lawyer said - and what goes on the record is the part a person read and
 * agreed to.
 *
 * The exception is real, and it is narrow. A voicemail is not an hour of
 * conversation recorded by the practice: it is thirty seconds the client
 * chose to leave *for* the practice, as a message, meaning it to be read and
 * answered. "A message, not read yet" on a board is a row somebody has to
 * open; "too far by bus, can we talk Monday" is a row somebody can act on.
 * And a message summarised by somebody else stops being the client's own
 * words, which is the reason the Friday text's ratings are quoted too.
 *
 * So the exception is stated here rather than left to be true by accident.
 * As 0395 wrote it, the trigger fired for any recording a `voice_calls` row
 * pointed at - which today is only ever a voicemail, so it was *narrow by
 * consequence*. Nothing said so, nothing checked it, and a later change that
 * pointed a call at a meeting recording would have moved an hour of somebody's
 * life onto their contact log with no test failing.
 *
 * Now it asks the attachment what kind of recording it is, and
 * `verify_a_call_is_on_the_record` asserts both halves: a voicemail's words
 * arrive, and a meeting's do not.
 *
 * Tolerates the old code: the trigger does strictly less than it did
 * yesterday, and the only thing it ever wrote was a column 0395's own
 * function had just written a placeholder into.
 */

create or replace function public.voicemail_words_arrive()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_said  text := btrim(coalesce(new.transcript, ''));
  v_kind  text;
  v_line  uuid;
begin
  if v_said = '' or coalesce(old.transcript, '') = v_said then
    return new;
  end if;

  /**
   * What kind of recording this is, asked of the file it is a reading of.
   *
   * `category` is what the practice filed it as: 'Voicemail' for a message on
   * the answerphone, 'Recording' for a meeting somebody recorded. Only the
   * first has a contact-log line of its own to quote onto, and only the first
   * is a message the client left to be read.
   */
  select a.category into v_kind
    from public.attachments a
   where a.id = new.attachment_id;

  if coalesce(v_kind, '') <> 'Voicemail' then
    return new;
  end if;

  select vc.contact_log_id into v_line
    from public.voice_calls vc
   where vc.recording_id = new.id;

  if v_line is null then
    return new;
  end if;

  update public.contact_log
     set outcome = left(v_said, 600), updated_at = now()
   where id = v_line;

  return new;
end $function$;

comment on function public.voicemail_words_arrive() is
  'Puts a voicemail transcript onto its contact-log line. Only a voicemail: a meeting recording''s words never leave the recording (owner, 14 Nov 2026).';

do $$
declare v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'voicemail_words_arrive';

  if strpos(v_def, '''Voicemail''') = 0 then
    raise exception 'the trigger does not ask what kind of recording it is reading';
  end if;
  if strpos(v_def, 'a.category') = 0 then
    raise exception 'the trigger does not ask the file what it was filed as';
  end if;

  raise notice 'ok  only a voicemail''s words reach a contact-log line';
end $$;
