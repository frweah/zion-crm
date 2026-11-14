-- Zion Vocational Rehab CRM - a recorded phone call is a phone call
--
-- 0350 wrote every confirmed recording onto the record as a note of type
-- 'Meeting', including the ones whose type of contact is Phone. The note
-- types are what somebody filters a client's notes by, and 'Phone call' is
-- one of them, so a recorded call was findable under the wrong heading.
--
-- The contact log already said Phone - it takes the type of contact straight
-- through. This is the note catching up with it.

begin;

CREATE OR REPLACE FUNCTION public.confirm_recording(p_id uuid, p_kind text, p_on date, p_present text, p_discussed text, p_decisions text, p_next text, p_question text, p_category text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_rec   public.recordings%rowtype;
  v_staff uuid := public.current_staff_id();
  v_name  text;
  v_log   uuid;
  v_note  uuid;
  v_text  text;
  v_on    date;
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

  if coalesce(btrim(p_kind), '') not in ('Job site visit', 'Planning meeting', 'Phone') then
    raise exception 'Choose the type of contact: job site visit, planning meeting or phone.'
      using errcode = 'check_violation';
  end if;
  if coalesce(btrim(p_present), '') = '' then
    raise exception 'Say who was present — it is what makes this a record of a meeting.'
      using errcode = 'check_violation';
  end if;
  if coalesce(btrim(p_discussed), '') = '' then
    raise exception 'Say what was discussed — it is the line the contact log shows.'
      using errcode = 'check_violation';
  end if;

  v_on := coalesce(
    p_on,
    (select a.document_date from public.attachments a where a.id = v_rec.attachment_id),
    public.practice_today());

  select name into v_name from public.staff where id = v_staff;

  /*
   * The note, in the shape: the day and what kind of contact it was, who was
   * there, what was said, what was decided, what happens next, and the one
   * thing to ask next time.
   *
   * Assembled here rather than in the browser so that a note written from a
   * recording reads the same whoever confirmed it and whatever screen they
   * were on. Nothing of the transcript is copied in: every line is something
   * a person read and agreed to.
   */
  v_text := concat_ws(chr(10),
    format('%s, %s.', btrim(p_kind), to_char(v_on, 'FMDD Mon YYYY')),
    'Present: ' || btrim(p_present),
    'Discussed: ' || btrim(p_discussed),
    case when coalesce(btrim(p_decisions), '') <> '' then 'Decisions: ' || btrim(p_decisions) end,
    case when coalesce(btrim(p_next), '') <> '' then 'Next steps: ' || btrim(p_next) end,
    case when coalesce(btrim(p_question), '') <> '' then 'Follow-up question: ' || btrim(p_question) end);

  /*
   * The contact log: what it was about, and what came of it.
   *
   * `follow_up` is a **date** on this table - the day somebody is to be
   * chased - and the next steps are words, which may name a day somebody
   * said. So the words go with the outcome and the follow-up date is left to
   * whoever sets one. Never guess a date.
   */
  insert into public.contact_log
    (client_id, date, method, topic, outcome, staff_id, category)
  values
    (v_rec.client_id, v_on, btrim(p_kind), btrim(p_discussed),
     btrim(concat_ws(' ',
       nullif(btrim(coalesce(p_decisions, '')), ''),
       case when coalesce(btrim(p_next), '') <> ''
            then 'Next: ' || btrim(p_next) end)),
     v_staff,
     nullif(btrim(coalesce(p_category, '')), ''))
  returning id into v_log;

  -- Attached to the recording, so anybody reading the note can see what it
  -- came from and go and listen to it.
  insert into public.notes
    (client_id, staff_id, staff_name, text, type, category, attachment_id, at)
  values
    (v_rec.client_id, v_staff, coalesce(v_name, ''), v_text,
     -- A recorded phone call is a phone call. The note types are what a
     -- person filters by, and one of them is 'Phone call'.
     case when btrim(p_kind) = 'Phone' then 'Phone call' else 'Meeting' end,
     nullif(btrim(coalesce(p_category, '')), ''), v_rec.attachment_id, v_on)
  returning id into v_note;

  update public.recordings
     set state = 'Confirmed',
         summary = jsonb_build_object(
           'kind', btrim(p_kind),
           'on', to_char(v_on, 'YYYY-MM-DD'),
           'present', btrim(p_present),
           'discussed', btrim(p_discussed),
           'decisions', btrim(coalesce(p_decisions, '')),
           'next', btrim(coalesce(p_next, '')),
           'question', btrim(coalesce(p_question, ''))),
         confirmed_at = now(), confirmed_by = v_staff,
         contact_log_id = v_log, note_id = v_note,
         reason = '', updated_at = now()
   where id = p_id;

  return jsonb_build_object('contact_log', v_log, 'note', v_note);
end $function$;

commit;
