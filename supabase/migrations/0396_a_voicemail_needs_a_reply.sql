/**
 * A voicemail is the client speaking, and the board says so (owner, 27
 * November 2026).
 *
 * `client_threads_board` is the practice's answer to "who are we not
 * answering", and it had three assumptions that a voicemail breaks. All three
 * were right when the only thing a client could do was send a text.
 *
 *   1. **Their last word is a text.** `heard` read `sms_messages` alone, and
 *      its own comment said so: "the only channel a client speaks to the
 *      practice on".
 *   2. **Every line in the contact log is the practice answering.**
 *      `said_on` took the whole table. A voicemail written there would have
 *      marked the thread answered by the very thing that needs answering -
 *      which is the fault worth being frightened of, because the row would
 *      have disappeared off the board rather than appearing wrongly on it.
 *   3. **A client with nothing but a voicemail is not on the board at all.**
 *      `seen` is texts, conversations, mail and weekly updates, so their
 *      row would not have existed to be wrong.
 *
 * The rule now: a contact-log line is the practice's answer **unless nobody
 * from the practice took part in it**. A voicemail is inbound and its method
 * is not a real contact, so it is theirs; an answered inbound call is inbound
 * and its method *is* a real contact, so it is ours, because somebody spoke.
 * One expression, in both places that need it, asked of the two columns
 * rather than of a list of method words.
 *
 * The whole function is written out below because that is what
 * `create or replace function` takes - and it is the function's own
 * definition, dumped and edited at six anchors rather than retyped. 365 lines
 * copied by hand is a transcription fault that would drive the one screen
 * that decides who gets rung back.
 *
 * Tolerates the old code: the signature, the return columns and every
 * existing behaviour are unchanged. Nothing deployed writes an inbound
 * contact-log line yet, so until the voice routes are live this reads exactly
 * as it read before.
 */

CREATE OR REPLACE FUNCTION public.client_threads_board(p_today date DEFAULT NULL::date)
 RETURNS TABLE(row_key text, grp text, kind text, client_id uuid, client_name text, client_no integer, conversation_id uuid, update_id uuid, who text, numbers jsonb, channels text[], last_at timestamp with time zone, last_channel text, last_sender_kind text, last_sender text, last_body text, last_status text, last_media_url text, waiting_hours integer, quiet_days integer, assigned_staff_id uuid, assigned_name text, unread integer, next_scheduled timestamp with time zone, next_update date, failed integer, drafts integer, consent_missing boolean, opted_out boolean, can_text boolean, status text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  with day as (
    select coalesce(p_today, public.practice_today()) as today
  ),
    -- Every client the practice has said anything to or heard anything from.
  -- Closed clients included: a closed client who texts is still a person
  -- waiting for an answer, and the status shows on the row.
  seen as (
    select distinct client_id from (
      select client_id from public.sms_messages where client_id is not null
      union all
      select client_id from public.conversations where kind = 'sms' and client_id is not null
      union all
      select client_id from public.mail_log where client_id is not null
      union all
      select client_id from public.weekly_updates where state in ('Draft', 'Approved')
      union all
      -- A client whose only word to the practice is a message on the
      -- answerphone. Without this they are not on the board at all, which
      -- is the quietest way to owe somebody an answer (0394).
      select client_id from public.contact_log
       where client_id is not null and direction = 'Inbound'
         and not public.is_real_contact(method)
    ) z
  ),
  -- Their last word, by text. The only channel a client speaks to the
  -- practice on: an email arrives in somebody's Outlook and is only on the
  -- record once it is filed, and filing it is itself an answer.
  -- A message nobody was there to take. The outcome carries the client's
    -- own words once Azure has read it, and "a message, not read yet"
    -- before that.
    voicemails as (
      select client_id, max(created_at) as at
        from public.contact_log
       where client_id is not null and direction = 'Inbound'
         and not public.is_real_contact(method)
       group by 1
    ),
    voicemail_said as (
      select distinct on (client_id) client_id, created_at as at, outcome, method
        from public.contact_log
       where client_id is not null and direction = 'Inbound'
         and not public.is_real_contact(method)
       order by client_id, created_at desc
    ),
    -- Their last word, on either channel they can speak to the practice on.
    -- An email arrives in somebody's Outlook and is only on the record once
    -- it is filed, and filing it is itself an answer - so email is still not
    -- one of them. A voicemail is: nobody from the practice was there, and
    -- the message is the client talking.
    heard as (
      select client_id, max(at) as at from (
        select s.client_id, s.created_at as at
          from public.sms_messages s
         where s.direction = 'Incoming' and s.client_id is not null
        union all
        select v.client_id, v.at from voicemails v
      ) z group by 1
    ),
  -- Ours, with a time on it.
  said_at as (
    select client_id, max(at) as at from (
      select client_id, created_at as at
        from public.sms_messages
       where direction = 'Outgoing' and client_id is not null
      union all
      select client_id, sent_at
        from public.mail_log
       where client_id is not null and direction = 'Outgoing' and sent_at is not null
    ) z group by 1
  ),
  -- Ours, dated by the day.
  said_on as (
    select client_id, max(on_day) as on_day from (
      -- Every line in the log is the practice's own answer, with one
      -- exception: one nobody from the practice took part in. A voicemail
      -- would otherwise mark the thread answered by the very thing that
      -- needs answering (0394). An answered inbound call still counts,
      -- because somebody spoke.
      select client_id, date as on_day from public.contact_log
       where client_id is not null
         and not (direction = 'Inbound' and not public.is_real_contact(method))
      union all
      select client_id, at from public.notes
       where client_id is not null and coalesce(category, '') <> 'Personal'
    ) z group by 1
  ),
  -- Anything at all, either way, for "quiet 14+ days" (ruling 4: the same
  -- cross-channel reading).
  touched as (
    select client_id, max(at) as at from (
      select client_id, created_at as at from public.sms_messages where client_id is not null
      union all
      select client_id, sent_at from public.mail_log where client_id is not null and sent_at is not null
      union all
      select client_id, (date + time '12:00') at time zone 'America/Denver'
        from public.contact_log where client_id is not null
      union all
      select client_id, ts from public.notes
       where client_id is not null and coalesce(category, '') <> 'Personal'
    ) z group by 1
  ),
  -- The client's numbers, each with its own consent. The same view the
  -- sending gate reads (ruling 6b), so a dot on this board and a refusal on
  -- the send cannot disagree.
  dots as (
    select n.client_id,
           jsonb_agg(
             jsonb_build_object(
               'phone', n.phone,
               'label', coalesce(nullif(n.label, ''), n.whose),
               'whose', n.whose,
               'whose_name', coalesce(n.whose_name, ''),
               'relationship', coalesce(n.relationship, ''),
               'can_text', coalesce(n.can_text, false),
               'state', coalesce(n.state, 'None'),
               'since', n.since
             )
             order by case when n.whose = 'Client' then 0 else 1 end, n.phone
           ) as numbers,
           bool_or(coalesce(n.can_text, false)) as any_consent,
           bool_or(n.state = 'Withdrawn') as any_withdrawn
      from public.sms_consent_numbers n
     group by 1
  ),
  -- The most recent text thread, and everything unread across all of them.
  threads as (
    select c.client_id,
           (array_agg(c.id order by c.last_message_at desc nulls last))[1] as conversation_id,
           (array_agg(c.assigned_staff_id order by c.last_message_at desc nulls last)
              filter (where c.assigned_staff_id is not null))[1] as assigned_staff_id,
           sum(
             (select count(*)
                from public.messages m
                left join public.read_receipts r
                  on r.conversation_id = c.id and r.staff_id = public.current_staff_id()
               where m.conversation_id = c.id
                 and m.hidden_at is null
                 and m.seq > coalesce(r.last_read_seq, 0)
                 and m.sender_kind in ('client', 'visitor'))
           )::integer as unread
      from public.conversations c
     where c.kind = 'sms' and c.client_id is not null and not coalesce(c.spam, false)
     group by 1
  ),
  -- What was last said on the thread, whoever said it.
  latest as (
    select t.client_id, m.sender_kind, m.sender_label, m.body, m.status, m.created_at, m.media_url
      from threads t
      join lateral (
        select m.sender_kind, m.sender_label, m.body, m.status, m.created_at, m.media_url
          from public.messages m
         where m.conversation_id = t.conversation_id and m.hidden_at is null
         order by m.seq desc limit 1
      ) m on true
  ),
  stuck as (
    select client_id, count(*)::integer as failed, max(created_at) as at
      from public.sms_messages
     where client_id is not null and status in ('Failed', 'Not delivered')
     group by 1
  ),
  scheduled as (
    select client_id, min(send_after) as at
      from public.sms_messages
     where client_id is not null and status = 'Scheduled' and send_after is not null
     group by 1
  ),
  waiting_updates as (
    select client_id, count(*)::integer as drafts, min(week_start) as week_start
      from public.weekly_updates
     where state in ('Draft', 'Approved')
     group by 1
  ),
  -- Which channels this client has ever been reached on, for the Via chips.
  -- A call is a note that says how it happened, or a line in the log that
  -- says Call - which is 0378's whole point.
  channel_use as (
    select client_id, array_agg(distinct ch order by ch) as channels from (
      select client_id, 'Text' as ch from public.sms_messages where client_id is not null
      union all
      select client_id, 'Email' from public.mail_log where client_id is not null
      union all
      select client_id, 'Call' from public.notes
       where client_id is not null and method = 'Phone' and coalesce(category, '') <> 'Personal'
      union all
      select client_id, 'Call' from public.contact_log
       where client_id is not null and method in ('Call', 'Voicemail', 'Missed call')
    ) z group by 1
  ),

  -- ── one row per client ──────────────────────────────────────
  rows_client as (
    select
      'client:' || cl.id::text as row_key,
      'client'::text as kind,
      cl.id as client_id,
      cl.name as client_name,
      cl.client_no,
      th.conversation_id,
      null::uuid as update_id,
      ''::text as who,
      coalesce(d.numbers, '[]'::jsonb) as numbers,
      coalesce(cu.channels, array[]::text[]) as channels,
      -- The newest of the two, and named for what it was. A row that said
      -- "Text" over a voicemail would send somebody to a thread with nothing
      -- new on it.
      greatest(lt.created_at, vs.at) as last_at,
      case when vs.at is not null and coalesce(lt.created_at, '-infinity'::timestamptz) < vs.at
           then 'Voicemail'::text else 'Text'::text end as last_channel,
      case when vs.at is not null and coalesce(lt.created_at, '-infinity'::timestamptz) < vs.at
           then 'client'::text else lt.sender_kind end as last_sender_kind,
      case when vs.at is not null and coalesce(lt.created_at, '-infinity'::timestamptz) < vs.at
           then split_part(btrim(cl.name), ' ', 1) else lt.sender_label end as last_sender,
      case when vs.at is not null and coalesce(lt.created_at, '-infinity'::timestamptz) < vs.at
           then vs.outcome else lt.body end as last_body,
      case when vs.at is not null and coalesce(lt.created_at, '-infinity'::timestamptz) < vs.at
           then 'Received'::text else lt.status end as last_status,
      case when vs.at is not null and coalesce(lt.created_at, '-infinity'::timestamptz) < vs.at
           then null::text else lt.media_url end as last_media_url,
      case
        when hd.at is not null
         and coalesce(sa.at, '-infinity'::timestamptz) < hd.at
         and coalesce(so.on_day, '-infinity'::date) < hd.at::date
        then greatest(0, floor(extract(epoch from (now() - hd.at)) / 3600))::integer
      end as waiting_hours,
      case when tc.at is not null
           then greatest(0, (day.today - tc.at::date))::integer end as quiet_days,
      th.assigned_staff_id,
      st.name as assigned_name,
      coalesce(th.unread, 0)::integer as unread,
      sc.at as next_scheduled,
      wu.week_start as next_update,
      coalesce(sk.failed, 0) as failed,
      coalesce(wu.drafts, 0) as drafts,
      not coalesce(d.any_consent, false) as consent_missing,
      coalesce(d.any_withdrawn, false) as opted_out,
      coalesce(d.any_consent, false) as can_text
      from public.clients cl
      join seen on seen.client_id = cl.id
      cross join day
      left join dots d on d.client_id = cl.id
      left join threads th on th.client_id = cl.id
      left join latest lt on lt.client_id = cl.id
      left join heard hd on hd.client_id = cl.id
    left join voicemail_said vs on vs.client_id = cl.id
      left join said_at sa on sa.client_id = cl.id
      left join said_on so on so.client_id = cl.id
      left join touched tc on tc.client_id = cl.id
      left join stuck sk on sk.client_id = cl.id
      left join scheduled sc on sc.client_id = cl.id
      left join waiting_updates wu on wu.client_id = cl.id
      left join channel_use cu on cu.client_id = cl.id
      left join public.staff st on st.id = th.assigned_staff_id
     where cl.merged_into is null
  ),
  -- ── and one row per draft waiting on somebody ───────────────
  -- A row of its own rather than a count on the client's row, because the
  -- brief asks for Approve & send *on the row* and a client with two contacts
  -- receiving updates has two drafts going to two different numbers. One
  -- button cannot stand for both.
  rows_draft as (
    select
      'update:' || u.id::text as row_key,
      'draft'::text as kind,
      u.client_id,
      cl.name as client_name,
      cl.client_no,
      th.conversation_id,
      u.id as update_id,
      coalesce(ct.name || ' (' || ct.relationship || ')', cl.name) as who,
      coalesce(
        (select jsonb_agg(x) from jsonb_array_elements(d.numbers) x
          where x->>'phone' = u.phone),
        '[]'::jsonb
      ) as numbers,
      array['Text']::text[] as channels,
      u.drafted_at as last_at,
      'Text'::text as last_channel,
      'staff'::text as last_sender_kind,
      'Not sent yet'::text as last_sender,
      u.body as last_body,
      u.state as last_status,
      null::text as last_media_url,
      null::integer as waiting_hours,
      null::integer as quiet_days,
      th.assigned_staff_id,
      st.name as assigned_name,
      0::integer as unread,
      null::timestamp with time zone as next_scheduled,
      u.week_start as next_update,
      0 as failed,
      1 as drafts,
      not coalesce(
        (select (x->>'can_text')::boolean from jsonb_array_elements(d.numbers) x
          where x->>'phone' = u.phone limit 1), false) as consent_missing,
      false as opted_out,
      coalesce(
        (select (x->>'can_text')::boolean from jsonb_array_elements(d.numbers) x
          where x->>'phone' = u.phone limit 1), false) as can_text
      from public.weekly_updates u
      join public.clients cl on cl.id = u.client_id
      left join public.client_contacts ct on ct.id = u.contact_id
      left join dots d on d.client_id = u.client_id
      left join threads th on th.client_id = u.client_id
      left join public.staff st on st.id = th.assigned_staff_id
     where u.state in ('Draft', 'Approved')
  ),
  -- ── and whoever is not a client yet (ruling 1) ──────────────
  -- A website chat, or a text from a number nobody has placed. Answered in
  -- the panel exactly as they are answered today; the board is where they
  -- stop being a seventh view somebody has to know about.
  rows_stranger as (
    select
      'conv:' || c.id::text as row_key,
      'stranger'::text as kind,
      null::uuid as client_id,
      null::text as client_name,
      null::integer as client_no,
      c.id as conversation_id,
      null::uuid as update_id,
      coalesce(nullif(w.visitor_name, ''), nullif(c.external_address, ''), 'Unknown number') as who,
      '[]'::jsonb as numbers,
      array[case when c.kind = 'web' then 'Website' else 'Text' end]::text[] as channels,
      lm.created_at as last_at,
      case when c.kind = 'web' then 'Website' else 'Text' end as last_channel,
      lm.sender_kind as last_sender_kind,
      lm.sender_label as last_sender,
      lm.body as last_body,
      lm.status as last_status,
      lm.media_url as last_media_url,
      case when lm.sender_kind in ('client', 'visitor')
           then greatest(0, floor(extract(epoch from (now() - lm.created_at)) / 3600))::integer end as waiting_hours,
      null::integer as quiet_days,
      c.assigned_staff_id,
      st.name as assigned_name,
      (select count(*)
         from public.messages m
         left join public.read_receipts r
           on r.conversation_id = c.id and r.staff_id = public.current_staff_id()
        where m.conversation_id = c.id and m.hidden_at is null
          and m.seq > coalesce(r.last_read_seq, 0)
          and m.sender_kind in ('client', 'visitor'))::integer as unread,
      null::timestamp with time zone as next_scheduled,
      null::date as next_update,
      0 as failed,
      0 as drafts,
      true as consent_missing,
      false as opted_out,
      false as can_text
      from public.conversations c
      left join public.web_chats w on w.conversation_id = c.id
      left join public.staff st on st.id = c.assigned_staff_id
      left join lateral (
        select m.sender_kind, m.sender_label, m.body, m.status, m.created_at, m.media_url
          from public.messages m
         where m.conversation_id = c.id and m.hidden_at is null
         order by m.seq desc limit 1
      ) lm on true
     where not coalesce(c.spam, false)
       and c.archived_at is null
       and ((c.kind = 'sms' and c.client_id is null) or c.kind = 'web')
  ),
  everything as (
    select * from rows_client
    union all select * from rows_draft
    union all select * from rows_stranger
  )
  select
    e.row_key,
    -- The groups, in the order the brief lists them, and a row is in the
    -- first one it belongs to. A client who is owed a reply *and* has a draft
    -- waiting is owed a reply first.
    case
      when e.kind = 'stranger' then 'stranger'
      when e.kind = 'draft' then 'approval'
      when e.waiting_hours is not null then 'needs-reply'
      when e.failed > 0 then 'stuck'
      when e.quiet_days is null or e.quiet_days >= 14 then 'quiet'
      else 'ok'
    end as grp,
    e.kind, e.client_id, e.client_name, e.client_no, e.conversation_id, e.update_id, e.who,
    e.numbers, e.channels,
    e.last_at, e.last_channel, e.last_sender_kind, e.last_sender, e.last_body, e.last_status,
    e.last_media_url,
    e.waiting_hours, e.quiet_days,
    e.assigned_staff_id, e.assigned_name, e.unread,
    e.next_scheduled, e.next_update, e.failed, e.drafts,
    e.consent_missing, e.opted_out, e.can_text,
    case
      when e.kind = 'stranger' then 'Not a client yet'
      when e.kind = 'draft' then case when e.last_status = 'Approved' then 'Approved, not sent' else 'Waiting on approval' end
      when e.waiting_hours is not null then 'Needs a reply'
      when e.failed > 0 then 'Not delivered'
      when e.quiet_days is null or e.quiet_days >= 14 then 'Quiet'
      else 'Up to date'
    end as status
   from everything e
  -- Longest wait first (ruling 4), then the quietest, then whatever happened
  -- most recently. One order for the whole board: the screen groups the rows
  -- it is given rather than sorting them again.
  order by e.waiting_hours desc nulls last, e.quiet_days desc nulls last, e.last_at desc nulls last;
$function$
;

/**
 * The grants go back on by hand.
 *
 * `create or replace function` keeps them, but the drop-and-create that a
 * changed signature would need does not - and a board nobody can call is a
 * blank screen with no error on it (0352).
 */
revoke all on function public.client_threads_board(p_today date) from public, anon;
grant execute on function public.client_threads_board(p_today date) to authenticated;

do $$
declare v_def text; v_n integer;
begin
  select pg_get_functiondef(p.oid) into v_def from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'client_threads_board';

  -- Asked with strpos rather than a regular expression. The text being looked
  -- for is full of parentheses, and an escaped regex written inside a
  -- generated SQL string inside a JavaScript template literal is three levels
  -- of escaping to get wrong at once. It was wrong on the first run, and the
  -- migration refused to apply at all rather than passing wrongly - which is
  -- the better of the two ways for that mistake to show up.
  if strpos(v_def, 'voicemails as (') = 0 then
    raise exception 'the board still has no voicemail in it';
  end if;
  if strpos(v_def, 'not (direction = ''Inbound'' and not public.is_real_contact(method))') = 0 then
    raise exception 'the board still reads a voicemail as the practice answering';
  end if;
  if strpos(v_def, 'voicemail_said vs on vs.client_id') = 0 then
    raise exception 'the board has no voicemail to put on a row';
  end if;

  select count(*) into v_n from information_schema.routine_privileges
   where routine_schema = 'public' and routine_name = 'client_threads_board'
     and grantee = 'authenticated';
  if v_n = 0 then
    raise exception 'nobody signed in can open the board';
  end if;

  raise notice 'ok  a voicemail is their last word, and is not the practice answering';
end $$;
