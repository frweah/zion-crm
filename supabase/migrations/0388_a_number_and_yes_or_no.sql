/**
 * The body that lists, the reply that answers, and the warning that follows
 * (owner, 24 November 2026). 0387 holds the tables and the helpers.
 *
 * -- Tolerates the old code: an older deployment drafts the old wording and
 * -- sends it; the list and the parser are both inside the database.
 *
 * Nothing here refuses a write. The parser only ever adds a row of its own,
 * the body is composed in the database so a screen sends whatever it is
 * given, and the numbered list that a reply is read against is written by
 * the same drafting function that prints it.
 */

-- ── the body ─────────────────────────────────────────────────

create or replace function public.weekly_update_body(p_client uuid, p_contact uuid, p_facts jsonb)
returns text
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $function$
declare
  v_may           boolean := public.reader_may_answer();
  v_client_first  text;
  v_to_first      text;
  v_subject       text;
  v_has           text;
  v_applied       integer := coalesce((p_facts ->> 'applied')::integer, 0);
  v_interviews    integer := coalesce((p_facts ->> 'interviews')::integer, 0);
  v_started       jsonb   := p_facts -> 'started';
  v_next_iv       date    := (p_facts ->> 'interview_next')::date;
  v_next_appt     timestamptz := (p_facts ->> 'next_appointment')::timestamptz;
  v_lines         text[] := '{}';
  v_opening       text;
  v_from          date := (p_facts ->> 'from')::date;
  v_to            date := (p_facts ->> 'to')::date;
  v_list          text[] := '{}';
  r               record;
begin
  -- The same check, for the same reason: this one would read a client's and
  -- a contact's names out to anybody with a session.
  if not v_may then
    raise exception 'Only staff and the Friday sweep draft the weekly updates.'
      using errcode = 'insufficient_privilege';
  end if;

  select split_part(btrim(c.name), ' ', 1) into v_client_first
    from public.clients c where c.id = p_client;
  if p_contact is null then
    v_to_first := v_client_first;
    v_subject := 'You';
    v_has := 'have';
  else
    select split_part(btrim(t.name), ' ', 1) into v_to_first
      from public.client_contacts t where t.id = p_contact;
    v_subject := v_client_first;
    v_has := 'has';
  end if;

  /**
   * The client's own copy names the places, numbered, and a contact's copy
   * does not.
   *
   * The count-not-a-list ruling that `weekly_update_facts` carries was about
   * a text that reads as a report, and listing where somebody else's client
   * applied is the half of that worth keeping. The client is being asked a
   * question about their own week, which is the half the owner reversed on
   * 24 November 2026.
   */
  if p_contact is null and v_from is not null and v_to is not null then
    for r in select item_no, label from public.weekly_update_list(p_client, v_from, v_to) loop
      v_list := v_list || format('%s. %s', r.item_no, r.label);
    end loop;
  end if;

  -- ── what happened ──────────────────────────────────────────
  if array_length(v_list, 1) is not null then
    -- The sentence counts the list rather than the facts, so the number and
    -- the places under it can never disagree.
    v_lines := v_lines || case
      when array_length(v_list, 1) = 1 then 'You applied for one job this week:'
      else format('You applied for %s jobs this week:', array_length(v_list, 1)) end;
    v_lines := v_lines || array_to_string(v_list, E'\n');
  elsif v_applied = 1 then
    v_lines := v_lines || format('%s applied for one job this week.', v_subject);
  elsif v_applied > 1 then
    v_lines := v_lines || format('%s applied for %s jobs this week.', v_subject, v_applied);
  end if;

  if v_interviews = 1 then
    v_lines := v_lines || format('%s had an interview.',
      case when p_contact is null then 'You' else v_client_first end);
  elsif v_interviews > 1 then
    v_lines := v_lines || format('%s had %s interviews.',
      case when p_contact is null then 'You' else v_client_first end, v_interviews);
  end if;

  if v_started is not null and v_started <> 'null'::jsonb then
    v_lines := v_lines || format('%s started at %s on %s.',
      v_subject,
      coalesce(nullif(btrim(v_started ->> 'employer'), ''), 'a new job'),
      to_char((v_started ->> 'on')::date, 'FMDay FMDD FMMonth'));
  end if;

  -- ── and what is next ───────────────────────────────────────
  if v_next_iv is not null then
    v_lines := v_lines || format('%s %s an interview on %s.', v_subject, v_has,
      to_char(v_next_iv, 'FMDay FMDD FMMonth'));
  end if;
  if v_next_appt is not null then
    v_lines := v_lines || format('%s next appointment with us is %s.',
      case when p_contact is null then 'Your' else v_client_first || '''s' end,
      to_char(v_next_appt at time zone 'America/Denver', 'FMDay FMDD FMMonth at FMHH12:MIam'));
  end if;

  -- ── the opening, and the week with nothing in it ───────────
  if p_contact is null then
    v_opening := format('Hi %s. Here is your week from Zion.', coalesce(v_to_first, 'there'));
  else
    v_opening := format('Hi %s. Here is this week about %s, from Zion.',
      coalesce(v_to_first, 'them'), coalesce(v_client_first, 'them'));
  end if;

  /*
   * A week with nothing in it asks a question instead (the owner's ruling).
   *
   * Not "no activity this week", which reads as an accusation when it is the
   * practice that has nothing to report. A question is the honest thing: the
   * record is empty, and the person at the other end knows what happened.
   *
   * There is no numbered list here and so no invitation to answer one: a
   * text asking somebody to reply with a number nobody sent them is worse
   * than a text that asks how they got on.
   */
  if array_length(v_lines, 1) is null then
    if p_contact is null then
      return public.sms_plain(v_opening || ' We have nothing to report from our side. How did you get on with what we agreed? '
             || 'Do you have any updates for us this week?');
    end if;
    return public.sms_plain(v_opening || format(' We have nothing to report from our side. Do you have any updates for us about %s this week?',
                               coalesce(v_client_first, 'them')));
  end if;

  /**
   * And the end of it.
   *
   * With a list, the invitation replaces "If anything has changed, reply to
   * this text": two instructions to reply, one of them vaguer, is how a
   * person ends up answering neither. Without a list, the old line stands.
   */
  return public.sms_plain(
    v_opening || E'\n' || array_to_string(v_lines, E'\n')
    || E'\n'
    || case when array_length(v_list, 1) is not null
            then public.weekly_update_invitation()
            else 'If anything has changed, reply to this text.' end);
end;
$function$;

-- ── the draft writes the numbers down ────────────────────────

create or replace function public.draft_weekly_updates(p_week_start date)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_from   date := p_week_start;
  v_to     date := p_week_start + 6;
  v_made   integer := 0;
  r        record;
  v_facts  jsonb;
  v_update uuid;
begin
  if coalesce(auth.role(), '') <> 'service_role' and not public.is_active_staff() then
    raise exception 'Only the Friday sweep and staff draft the weekly updates.'
      using errcode = 'insufficient_privilege';
  end if;
  if extract(isodow from p_week_start) <> 1 then
    raise exception 'A week starts on a Monday.' using errcode = 'check_violation';
  end if;

  -- The client themselves, for every active client.
  for r in
    select c.id, c.language from public.clients c
     where c.status = 'Active' and c.merged_into is null
  loop
    v_facts := public.weekly_update_facts(r.id, v_from, v_to);
    v_update := null;
    insert into public.weekly_updates
      (week_start, client_id, contact_id, phone, language, body, facts)
    values
      (p_week_start, r.id, null, public.client_texting_number(r.id), r.language,
       public.weekly_update_body(r.id, null, v_facts), v_facts)
    on conflict do nothing
    returning id into v_update;

    if v_update is not null then
      /**
       * The list as sent, so a reply of "3 NO" is answerable next week.
       *
       * Taken from the same function the body printed, in the same order. If
       * this were recomputed when the reply arrived, one more application
       * logged on the Saturday would renumber everything and the client's
       * answer would land on an employer they never rated.
       */
      insert into public.weekly_update_items (update_id, item_no, match_id, label)
      select v_update, item_no, match_id, label
        from public.weekly_update_list(r.id, v_from, v_to);
      v_made := v_made + 1;
    end if;
  end loop;

  -- And each contact who receives them, on an active client. A contact with
  -- no number gets a draft too: the screen says it cannot be sent and why,
  -- which is how somebody finds out that a number is missing.
  for r in
    select t.id as contact_id, t.client_id, t.phone, c.language
      from public.client_contacts t
      join public.clients c on c.id = t.client_id
     where t.active and t.receives_updates
       and c.status = 'Active' and c.merged_into is null
  loop
    v_facts := public.weekly_update_facts(r.client_id, v_from, v_to);
    insert into public.weekly_updates
      (week_start, client_id, contact_id, phone, language, body, facts)
    values
      (p_week_start, r.client_id, r.contact_id, r.phone, r.language,
       public.weekly_update_body(r.client_id, r.contact_id, v_facts), v_facts)
    on conflict do nothing;
    if found then v_made := v_made + 1; end if;
  end loop;

  return v_made;
end;
$function$;

-- ── a reply that answers ─────────────────────────────────────

/**
 * "3 NO" and what it is allowed to mean.
 *
 * What counts: the client's own number, a weekly update actually sent to that
 * client inside seven days that carried a list, and a number followed by YES,
 * Y, NO or N. Several pairs in one message all count.
 *
 * What does not, and stays a message for somebody to answer: a bare YES or
 * NO, a number on its own, a number that was not on the list, any other
 * word, a reply from a contact's number, anything after seven days - and the
 * reversed form, "YES 3". "NO 3" cannot be told from "number 3", and a wrong
 * guess here does not just mislabel a row: it warns the next member of staff
 * off an employer the client never rejected.
 *
 * The whole message is kept as the client's words. The screens show the
 * answer and the words, because "too far by bus" is the part anybody can act
 * on, and a rating with the sentence taken off it is a thumb with no reason.
 */
create or replace function public.rate_applications_from_text(p_sms uuid)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_sms     public.sms_messages%rowtype;
  v_update  uuid;
  v_body    text;
  v_said    text;
  v_pos     integer;
  v_ans     text;
  v_match   uuid;
  v_n       integer := 0;
  m         text[];
begin
  select * into v_sms from public.sms_messages where id = p_sms;
  if not found
     or v_sms.direction <> 'Incoming'
     or v_sms.client_id is null
     or v_sms.contact_id is not null then
    return 0;
  end if;

  select w.id into v_update
    from public.weekly_updates w
   where w.client_id = v_sms.client_id
     and w.contact_id is null
     and w.sent_at is not null
     and w.sent_at >= coalesce(v_sms.sent_at, now()) - interval '7 days'
     and w.sent_at <= coalesce(v_sms.sent_at, now())
     and exists (select 1 from public.weekly_update_items i where i.update_id = w.id)
   order by w.sent_at desc
   limit 1;
  if v_update is null then
    return 0;
  end if;

  v_said := btrim(coalesce(v_sms.body, ''));
  if v_said = '' then
    return 0;
  end if;

  /**
   * A space between a digit and a letter before anything else, so "1yes2no"
   * is read the same way as "1 yes 2 no". Postgres has no lookbehind, and
   * without this the second pair of a run-together reply is invisible.
   */
  v_body := regexp_replace(v_said, '([0-9])([A-Za-z])', '\1 \2', 'g');
  v_body := regexp_replace(v_body, '([A-Za-z])([0-9])', '\1 \2', 'g');

  for m in
    select regexp_matches(v_body, '\y([0-9]{1,2})\s*[-.):=]*\s*(yes|y|no|n)\y', 'gi')
  loop
    v_pos := m[1]::integer;
    v_ans := case when lower(m[2]) in ('y', 'yes') then 'Yes' else 'No' end;

    select i.match_id into v_match
      from public.weekly_update_items i
     where i.update_id = v_update and i.item_no = v_pos;
    if v_match is null then
      continue;  -- a number that was not on the list is not an answer
    end if;

    insert into public.application_feedback
      (match_id, client_id, update_id, answer, said, sms_id)
    values (v_match, v_sms.client_id, v_update, v_ans, v_said, p_sms)
    on conflict (sms_id, match_id) do nothing;
    if found then
      v_n := v_n + 1;
    end if;
  end loop;

  /**
   * And it counts as a contact, once for the message rather than once per
   * number in it. `contact_log.source` is constrained to Text, Call or
   * Email, so the source is Text and the key is the message - which is what
   * makes a provider retry harmless.
   */
  if v_n > 0 then
    insert into public.contact_log
      (client_id, date, method, topic, outcome, source, source_key)
    values (
      v_sms.client_id,
      (coalesce(v_sms.sent_at, now()) at time zone 'America/Denver')::date,
      'Text',
      'Replied about the jobs we applied for',
      left(v_said, 300),
      'Text',
      p_sms::text)
    -- The index is partial - unique on (source, source_key) where source is
    -- not null - so the predicate has to be named or Postgres cannot infer it.
    on conflict (source, source_key) where source is not null do nothing;
  end if;

  return v_n;
end;
$function$;

revoke all on function public.rate_applications_from_text(uuid) from anon, public, authenticated;

-- ── the inbound text, with the digits kept ───────────────────

create or replace function public.record_incoming_sms(
  p_phone text,
  p_body text,
  p_provider_id text default null,
  p_payload jsonb default null,
  p_media text default null,
  p_media_type text default null
)
returns table (client_id uuid, contact_id uuid, action text)
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_phone   text := public.normalize_phone(p_phone);
  v_client  uuid;
  v_contact uuid;
  /**
   * Punctuation and spaces come out; digits stay.
   *
   * This stripped every non-letter until 24 November 2026, which meant
   * "3 YES" reduced to "YES" and was recorded as consent given by text - the
   * exact reply the Friday update now asks for. A bare YES still reads as
   * YES, which is what the carrier rules are about. "YES 3" no longer does,
   * and that is the point.
   */
  v_word    text := upper(regexp_replace(coalesce(p_body, ''), '[^A-Za-z0-9]', '', 'g'));
  v_action  text := 'logged';
  v_sms     uuid;
  v_rated   integer := 0;
begin
  if v_phone is null then
    raise exception 'That is not a phone number we can match: %', p_phone
      using errcode = 'check_violation';
  end if;

  /*
   * The client's own numbers first, their contacts' second.
   *
   * The owner's order, and the only one that cannot mislabel a client as
   * their own daughter-in-law. Within each, an active client before a closed
   * one, and the oldest record before a newer duplicate - which is what the
   * version before this did when `clients.phone` was the only number there
   * was.
   */
  select n.client_id, n.contact_id into v_client, v_contact
    from public.client_numbers n
    join public.clients c on c.id = n.client_id
   where n.phone = v_phone
   order by case when n.whose = 'Client' then 0 else 1 end,
            case when c.status = 'Active' then 0 else 1 end,
            c.created_at
   limit 1;

  -- The message is written down whether or not we know whose it is. A STOP
  -- from a number we cannot place still has to be honoured, and an unmatched
  -- reply is a thing somebody should see rather than lose.
  insert into public.sms_messages (client_id, contact_id, direction, phone, body, kind,
                                   provider_message_id, provider_payload, status, sent_at,
                                   media_url, media_type)
  values (v_client, v_contact, 'Incoming', v_phone, coalesce(p_body, ''), 'Reply',
          p_provider_id, p_payload, 'Received', now(),
          nullif(btrim(coalesce(p_media, '')), ''),
          nullif(btrim(coalesce(p_media_type, '')), ''))
  returning id into v_sms;

  /**
   * An answer to the Friday text, before anything else is considered.
   *
   * A rating is not a consent decision and must never be read as one. It
   * stays on the thread exactly as it is - this adds a row of its own and
   * changes nothing about the message.
   */
  if v_client is not null and v_contact is null then
    v_rated := public.rate_applications_from_text(v_sms);
    if v_rated > 0 then
      v_action := 'rated';
    end if;
  end if;

  -- The keywords carriers require, plus the ones people actually send.
  --
  -- A picture with no words in it must not read as a keyword. `v_word` strips
  -- punctuation and spaces, so a text whose body is empty gives an empty
  -- string, which matches none of the lists below - but it is worth saying
  -- out loud, because a picture message is the commonest way a body arrives
  -- empty and "withdrew consent by sending a photograph" would be a bad
  -- afternoon.
  --
  -- And it applies to the number it came from. A daughter-in-law who stops
  -- hearing about appointments has not withdrawn the client's consent, and
  -- the row says whose number it was.
  if v_rated = 0 then
    if v_word in ('STOP', 'STOPALL', 'UNSUBSCRIBE', 'CANCEL', 'END', 'QUIT', 'REVOKE', 'OPTOUT') then
      if v_client is not null then
        insert into public.sms_consent_events (client_id, contact_id, state, phone, method, note)
        values (v_client, v_contact, 'Withdrawn', v_phone, 'Text reply',
                'Replied ' || v_word || ' — consent withdrawn automatically');
      end if;
      v_action := 'withdrawn';

    elsif v_word in ('START', 'UNSTOP', 'YES', 'OPTIN') then
      -- A person can put themselves back on, and only for the number they sent
      -- from. Anything less would mean a withdrawal that cannot be undone
      -- without ringing the office.
      if v_client is not null then
        insert into public.sms_consent_events (client_id, contact_id, state, phone, method, note)
        values (v_client, v_contact, 'Granted', v_phone, 'Text reply',
                'Replied ' || v_word || ' — consent given by text');
      end if;
      v_action := 'granted';
    end if;
  end if;

  return query select v_client, v_contact, v_action;
end $function$;

-- ── and the warning the next application gets ────────────────

/**
 * Has this client said they would not work there?
 *
 * The newest No for that employer, with the words they said it in. Asked by
 * the screen that starts an application, which is the moment it is worth
 * knowing - a 👎 that only appears on the record it came from is a 👎 that
 * gets applied past.
 */
create or replace function public.client_said_no_to(p_client uuid, p_employer uuid)
returns table (at timestamptz, said text)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select f.at, f.said
    from public.application_feedback f
    join public.lead_matches m on m.id = f.match_id
    join public.job_leads l on l.id = m.lead_id
   where public.is_active_staff()
     and f.client_id = p_client
     and l.employer_id = p_employer
     and f.answer = 'No'
   order by f.at desc
   limit 1
$$;

revoke all on function public.client_said_no_to(uuid, uuid) from anon, public;
grant execute on function public.client_said_no_to(uuid, uuid) to authenticated;
