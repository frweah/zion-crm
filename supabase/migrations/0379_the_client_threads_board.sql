/**
 * The client threads board (Communications brief, Part 2; rulings 1, 4 and 6).
 *
 * One row per client, every channel folded in, and the groups a person works
 * in order: who is waiting on an answer, what is waiting on an approval, what
 * did not go, who has gone quiet, who is not a client yet, and everything
 * else collapsed.
 *
 * ── why a function and not a query on the screen ──
 *
 * Ruling 4: "in a database function, verified not trusted." The reason it is
 * worth the trouble is the number. Before this, three screens answered "who is
 * waiting on us" and gave 22, 8 and 4:
 *
 *   22  text threads whose last word was theirs - the inbox's reading
 *    8  conversations with something *unread* - the badge's reading
 *    4  clients where nothing outbound on any channel has happened since
 *
 * Fourteen of the twenty-two had been answered by email, by a logged contact
 * or by a note, and no screen could see it. A nag list that is wrong five
 * times in seven is a nag list people stop reading, so "a reply" means a
 * reply on any channel, and the definition lives here where a verify script
 * can put a fault in it.
 *
 * Dates and times are not the same question and are not treated as one. A
 * text and an email happened at a moment; a contact-log line and a note are
 * dated by the day. So the day-dated things count as a reply when their day is
 * on or after the day the client wrote, which is the owner's wording ("dated
 * at or after their message") and is also the only reading that does not call
 * a note written that afternoon "no reply".
 *
 * ── security invoker, deliberately ──
 *
 * Not SECURITY DEFINER, unlike `message_inbox` beside it. Everything this
 * reads already has a row-level policy that says the right thing - active
 * staff see conversations, messages, texts, mail and the contact log; notes
 * are narrowed to the roles on the row - and a definer function would have to
 * restate every one of those rules and then be trusted to have got them
 * right.
 *
 * Which is also why there is no gate of its own in here. The first version
 * refused an inactive account and a system account explicitly, and putting
 * the fault back proved the line could not matter: every table this reads
 * already requires `is_active_staff()`, so a stranger gets an empty board
 * either way. A line no fault can change is a line that is not doing
 * anything. What is asserted instead is the real mechanism - somebody not
 * signed in sees nothing, and the system account the deploy check signs in as
 * reads the board and cannot write on it, because 0120 is about writes.
 */

-- ── the board ─────────────────────────────────────────────────
--
-- Dropped first, because `create or replace` cannot change what a function
-- returns and this one's column list has already changed once: it handed out
-- `last_direction` and `last_who` until check-text-rows pointed out that
-- deciding what "from them" means is `lastLine`'s job and nobody else's. The
-- grants go with the drop, which is why they are restated below.
drop function if exists public.client_threads_board(date);

create or replace function public.client_threads_board(p_today date default null)
returns table (
  row_key text,
  grp text,
  kind text,
  client_id uuid,
  client_name text,
  client_no integer,
  conversation_id uuid,
  update_id uuid,
  who text,
  numbers jsonb,
  channels text[],
  last_at timestamp with time zone,
  last_channel text,
  -- The mirror's own two fields, not a reading of them. `lastLine` in
  -- lib/text-rows.ts is the one place that decides what "from them" means,
  -- and check-text-rows holds every list of texts to it - including this one,
  -- which is how this column stopped being `last_direction` and
  -- `last_who`.
  last_sender_kind text,
  last_sender text,
  last_body text,
  last_status text,
  last_media_url text,
  waiting_hours integer,
  quiet_days integer,
  assigned_staff_id uuid,
  assigned_name text,
  unread integer,
  next_scheduled timestamp with time zone,
  next_update date,
  failed integer,
  drafts integer,
  consent_missing boolean,
  opted_out boolean,
  can_text boolean,
  status text
)
language sql
stable
set search_path to 'public'
as $$
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
    ) z
  ),
  -- Their last word, by text. The only channel a client speaks to the
  -- practice on: an email arrives in somebody's Outlook and is only on the
  -- record once it is filed, and filing it is itself an answer.
  heard as (
    select s.client_id, max(s.created_at) as at
      from public.sms_messages s
     where s.direction = 'Incoming' and s.client_id is not null
     group by 1
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
      select client_id, date as on_day from public.contact_log where client_id is not null
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
      select client_id, 'Call' from public.contact_log where client_id is not null and method = 'Call'
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
      lt.created_at as last_at,
      'Text'::text as last_channel,
      lt.sender_kind as last_sender_kind,
      lt.sender_label as last_sender,
      lt.body as last_body,
      lt.status as last_status,
      lt.media_url as last_media_url,
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
$$;

comment on function public.client_threads_board(date) is
  'One row per client thread, per waiting Friday draft and per stranger, with the group each belongs in. A reply is a reply on any channel (ruling 4, 23 Nov 2026).';

revoke all on function public.client_threads_board(date) from public;
revoke all on function public.client_threads_board(date) from anon;
grant execute on function public.client_threads_board(date) to authenticated;

-- ── the thread, every channel, in one dated stream ────────────
/**
 * What was said to this client and by them, on every channel the practice
 * has: texts both ways, the calls somebody logged, and the counselor email
 * filed on the record.
 *
 * The words of an email are not here and will not be: `mail_log` keeps the
 * subject, the date, the direction and a link into Outlook, deliberately, so
 * that the CRM is not a second copy of the mailbox. The stream carries that
 * line and the link.
 *
 * `collected` is what stops "Add to report" being pressed twice and is also
 * what lets the panel show which messages are already on the month.
 */
create or replace function public.client_thread_stream(p_client uuid, p_since date default null)
returns table (
  item_key text,
  channel text,
  at timestamp with time zone,
  direction text,
  who text,
  body text,
  status text,
  media_url text,
  media_type text,
  ref_id uuid,
  web_link text,
  collected boolean
)
language sql
stable
set search_path to 'public'
as $$
  with   texts as (
    select 'text:' || s.id::text as item_key,
           'Text'::text as channel,
           s.created_at as at,
           case when s.direction = 'Incoming' then 'in' else 'out' end as direction,
           coalesce(
             case when s.contact_id is not null
                  then (select t.name || ' (' || t.relationship || ')'
                          from public.client_contacts t where t.id = s.contact_id)
             end,
             case when s.direction = 'Incoming'
                  then (select name from public.clients where id = s.client_id)
                  else coalesce((select name from public.staff where id = s.created_by), s.kind)
             end) as who,
           s.body, s.status, s.media_url, s.media_type,
           s.id as ref_id, null::text as web_link
      from public.sms_messages s
     where s.client_id = p_client
  ),
  calls as (
    select 'call:' || n.id::text as item_key,
           'Call'::text as channel,
           n.ts as at,
           'out'::text as direction,
           coalesce(n.staff_name, '') as who,
           n.text as body,
           n.method as status,
           null::text as media_url, null::text as media_type,
           n.id as ref_id, null::text as web_link
      from public.notes n
     where n.client_id = p_client
       and n.method = 'Phone'
       and coalesce(n.category, '') <> 'Personal'
  ),
  mail as (
    select 'mail:' || l.id::text as item_key,
           'Email'::text as channel,
           l.sent_at as at,
           case when l.direction = 'Incoming' then 'in' else 'out' end as direction,
           coalesce(l.counterpart_email, '') as who,
           l.subject as body,
           case when l.restricted then 'Restricted' else l.direction end as status,
           null::text as media_url, null::text as media_type,
           l.id as ref_id, l.web_link
      from public.mail_log l
     where l.client_id = p_client and l.sent_at is not null
  ),
  everything as (
    select * from texts union all select * from calls union all select * from mail
  )
  select e.item_key, e.channel, e.at, e.direction, e.who, e.body, e.status,
         e.media_url, e.media_type, e.ref_id, e.web_link,
         exists (
           select 1 from public.contact_log g
            where g.source = e.channel and g.source_key = e.ref_id::text
         ) as collected
    from everything e
   where p_since is null or e.at >= p_since
   order by e.at desc nulls last;
$$;

comment on function public.client_thread_stream(uuid, date) is
  'Texts, logged calls and filed counselor email about one client, newest first, each saying whether it is already on the month.';

revoke all on function public.client_thread_stream(uuid, date) from public;
revoke all on function public.client_thread_stream(uuid, date) from anon;
grant execute on function public.client_thread_stream(uuid, date) to authenticated;

-- ── add to report ─────────────────────────────────────────────
/**
 * Attach one message or call to the client's month as a collected contact.
 *
 * A line in the contact log, dated when the thing happened, which is what
 * `report_board_rows` counts and what a monthly report reads. Not the words:
 * the topic is the practice's own one-line description, the same way the log
 * has always carried a phone call, and the message stays where it is.
 *
 * Invoker, so the contact log's own policy decides (active staff, writing as
 * themselves). Pressed twice it refuses in one sentence rather than writing a
 * second line - the unique index on (source, source_key) is what makes that
 * true rather than remembered, and it is global rather than per person
 * because two people filing the same text is still one contact.
 */
create or replace function public.collect_contact(p_channel text, p_ref uuid, p_note text default '')
returns uuid
language plpgsql
set search_path to 'public'
as $$
declare
  v_me      uuid := public.current_staff_id();
  v_client  uuid;
  v_on      date;
  v_topic   text;
  v_outcome text;
  v_method  text;
  v_id      uuid;
begin
  if v_me is null or not public.is_active_staff() then
    raise exception 'You are not signed in.' using errcode = 'insufficient_privilege';
  end if;
  if p_channel not in ('Text', 'Call', 'Email') then
    raise exception 'A collected contact is a text, a call or an email.' using errcode = 'check_violation';
  end if;

  if p_channel = 'Text' then
    select s.client_id, s.created_at::date,
           case when s.direction = 'Incoming' then 'Text they sent' else 'Text we sent' end,
           case when s.contact_id is not null
                then coalesce((select t.name || ' (' || t.relationship || ')'
                                 from public.client_contacts t where t.id = s.contact_id), 'Their contact')
                else 'The client' end,
           'Text'
      into v_client, v_on, v_topic, v_outcome, v_method
      from public.sms_messages s where s.id = p_ref;
  elsif p_channel = 'Call' then
    select n.client_id, n.at, 'Call', coalesce(n.staff_name, 'Staff'), 'Call'
      into v_client, v_on, v_topic, v_outcome, v_method
      from public.notes n where n.id = p_ref and n.method = 'Phone';
  else
    select l.client_id, l.sent_at::date,
           coalesce(nullif(btrim(l.subject), ''), 'Email'),
           case when l.direction = 'Incoming' then 'From ' else 'To ' end || coalesce(l.counterpart_email, 'the counselor'),
           'Email'
      into v_client, v_on, v_topic, v_outcome, v_method
      from public.mail_log l where l.id = p_ref;
  end if;

  if v_client is null then
    raise exception 'That is not on a client''s record, so there is nothing to attach it to.'
      using errcode = 'check_violation';
  end if;

  begin
    insert into public.contact_log
      (client_id, date, method, topic, outcome, staff_id, source, source_key)
    values
      (v_client, v_on, v_method, v_topic,
       coalesce(nullif(btrim(p_note), ''), v_outcome), v_me, p_channel, p_ref::text)
    returning id into v_id;
  exception when unique_violation then
    raise exception 'That is already on this client''s month.' using errcode = 'check_violation';
  end;

  return v_id;
end $$;

comment on function public.collect_contact(text, uuid, text) is
  'Attach one text, call or filed email to the client''s month as a contact-log line, dated when it happened. Refuses a second attempt.';

revoke all on function public.collect_contact(text, uuid, text) from public;
revoke all on function public.collect_contact(text, uuid, text) from anon;
grant execute on function public.collect_contact(text, uuid, text) to authenticated;

-- ── log a call ────────────────────────────────────────────────
/**
 * A call, written down in the two places it belongs (Part 3).
 *
 * The note is the account of the call and is what a monthly report quotes;
 * the contact-log line is what the board's chip counts. One function, so a
 * call cannot be half-recorded - and the note's id is the log line's
 * `source_key`, so "Add to report" on that call later finds it already there
 * rather than writing a second line.
 *
 * Invoker, so both policies apply as written: a note is inserted as the
 * person writing it, and so is the log line.
 */
create or replace function public.log_a_call(
  p_client uuid,
  p_text text,
  p_category text,
  p_on date default null,
  p_outcome text default ''
)
returns uuid
language plpgsql
set search_path to 'public'
as $$
declare
  v_me   uuid := public.current_staff_id();
  v_name text;
  v_on   date := coalesce(p_on, public.practice_today());
  v_note uuid;
begin
  if v_me is null or not public.is_active_staff() then
    raise exception 'You are not signed in.' using errcode = 'insufficient_privilege';
  end if;
  if coalesce(btrim(p_text), '') = '' then
    raise exception 'Say what the call was about.' using errcode = 'check_violation';
  end if;
  if v_on > public.practice_today() then
    raise exception 'That date has not happened yet.' using errcode = 'check_violation';
  end if;

  select name into v_name from public.staff where id = v_me;

  insert into public.notes (client_id, staff_id, staff_name, text, type, method, category, at, ts)
  values (p_client, v_me, coalesce(v_name, ''), btrim(p_text), 'Phone call', 'Phone',
          nullif(btrim(coalesce(p_category, '')), ''), v_on,
          case when v_on = public.practice_today() then now()
               else (v_on + time '12:00') at time zone 'America/Denver' end)
  returning id into v_note;

  insert into public.contact_log
    (client_id, date, method, topic, outcome, staff_id, source, source_key)
  values
    (p_client, v_on, 'Call', 'Call',
     coalesce(nullif(btrim(p_outcome), ''), 'Spoke to them'), v_me, 'Call', v_note::text);

  return v_note;
end $$;

comment on function public.log_a_call(uuid, text, text, date, text) is
  'A phone call: the note (method Phone) and its contact-log line (method Call), written together.';

revoke all on function public.log_a_call(uuid, text, text, date, text) from public;
revoke all on function public.log_a_call(uuid, text, text, date, text) from anon;
grant execute on function public.log_a_call(uuid, text, text, date, text) to authenticated;
