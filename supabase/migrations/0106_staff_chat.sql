-- Zion Vocational Rehab CRM — staff chat (Messaging brief, B)
--
-- Direct messages already work (0104). This is the rest of what colleagues
-- need to talk to each other inside the CRM rather than outside it:
--
--   Groups, named, started by anybody. Admin can see who is in one and can
--   archive it. Leaving is allowed, and is not the same as being removed:
--   what was said stays where it was said.
--
--   Threads about a client, started from the client's record and listed on
--   that client's Activity. The people in the thread read it - and Admin,
--   because a conversation about a client is client information, the same
--   rule that logged mail and texts already follow.
--
--   Files by reference, never a second copy: a document or a form is attached
--   by pointing at the row it already is, so it keeps its own tier and its own
--   retention. A restricted document cannot be attached where somebody in the
--   conversation could not open it anyway; the attempt is refused, and says
--   who and why, rather than half-working. (The storage rules would refuse
--   them the file itself - this refuses the promise of it.)
--
--   Mentions, five minutes to fix a typo, and removing your own message -
--   which leaves the marker, not a hole in the conversation. Search across
--   the conversations a person is in.

-- ── can somebody else see this client's restricted things ───
-- can_see_restricted answers for whoever is asking. Attaching has to ask
-- about the people who will receive it, which is a different question.
create or replace function public.can_staff_see_restricted(p_staff uuid, p_client uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.staff s
      left join public.clients c on c.id = p_client
     where s.id = p_staff and s.active
       and (s.role in ('Admin', 'Reports') or c.assigned_staff_id = s.id));
$$;

alter table public.messages add column if not exists mentions uuid[] not null default '{}'::uuid[];

-- ── starting one ────────────────────────────────────────────
create or replace function public.start_group_conversation(p_title text, p_staff uuid[], p_client uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_me   uuid := public.current_staff_id();
  v_conv uuid;
  v_id   uuid;
begin
  if v_me is null or not public.is_active_staff() then
    raise exception 'Only staff start a conversation.' using errcode = 'insufficient_privilege';
  end if;
  if p_client is null and coalesce(btrim(p_title), '') = '' then
    raise exception 'Give the group a name, so people know what it is for.' using errcode = 'check_violation';
  end if;
  if p_client is not null and not exists (select 1 from public.clients where id = p_client) then
    raise exception 'That client is not on file.' using errcode = 'check_violation';
  end if;

  insert into public.conversations (kind, title, client_id, created_by)
  values ('internal', coalesce(btrim(p_title), ''), p_client, v_me)
  returning id into v_conv;
  insert into public.conversation_participants (conversation_id, staff_id, added_by) values (v_conv, v_me, v_me);

  foreach v_id in array coalesce(p_staff, '{}'::uuid[]) loop
    if v_id <> v_me and exists (select 1 from public.staff where id = v_id and active) then
      insert into public.conversation_participants (conversation_id, staff_id, added_by)
      values (v_conv, v_id, v_me)
      on conflict (conversation_id, staff_id) do update set left_at = null;
    end if;
  end loop;
  return v_conv;
end;
$$;

create or replace function public.add_conversation_participant(p_conversation uuid, p_staff uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := public.current_staff_id();
begin
  if not public.is_conversation_participant(p_conversation) then
    raise exception 'Only somebody already in the conversation adds to it.' using errcode = 'insufficient_privilege';
  end if;
  if not exists (select 1 from public.staff where id = p_staff and active) then
    raise exception 'That person is not an active member of staff.' using errcode = 'check_violation';
  end if;
  -- A direct message stays between the two of them; a third person makes it a
  -- different conversation, and it ought to look like one.
  if exists (select 1 from public.conversations
              where id = p_conversation and kind = 'internal' and title = '' and client_id is null) then
    raise exception 'A direct message stays between the two of you. Start a group instead.' using errcode = 'check_violation';
  end if;
  insert into public.conversation_participants (conversation_id, staff_id, added_by)
  values (p_conversation, p_staff, v_me)
  on conflict (conversation_id, staff_id) do update set left_at = null, added_by = v_me;
end;
$$;

-- Leaving: what was said stays, and they stop receiving it.
create or replace function public.leave_conversation(p_conversation uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := public.current_staff_id();
begin
  update public.conversation_participants set left_at = now()
   where conversation_id = p_conversation and staff_id = v_me and left_at is null;
  if not found then
    raise exception 'You are not in that conversation.' using errcode = 'check_violation';
  end if;
end;
$$;

-- Admin, or whoever started it, puts a group away. Nothing is deleted.
create or replace function public.archive_conversation(p_conversation uuid, p_archived boolean default true)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := public.current_staff_id();
begin
  if not exists (
    select 1 from public.conversations
     where id = p_conversation and kind = 'internal'
       and (public.is_admin() or created_by = v_me)) then
    raise exception 'Only Admin, or whoever started it, archives a conversation.' using errcode = 'insufficient_privilege';
  end if;
  update public.conversations
     set archived_at = case when p_archived then now() end,
         archived_by = case when p_archived then v_me end
   where id = p_conversation;
end;
$$;

-- ── saying something ────────────────────────────────────────
-- post_message as it stood in 0104, now carrying attachments by reference and
-- mentions. The old three-argument shape goes, rather than sitting beside this
-- one refusing every attachment.
drop function if exists public.post_message(uuid, text, jsonb);

create or replace function public.post_message(p_conversation uuid, p_body text, p_attachments jsonb default '[]'::jsonb, p_mentions uuid[] default '{}'::uuid[])
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_me         uuid := public.current_staff_id();
  v_name       text;
  v_kind       text;
  v_client     uuid;
  v_id         uuid;
  v_seq        bigint;
  v_item       jsonb;
  v_ref        uuid;
  v_owner      uuid;
  v_restricted boolean;
  v_blocked    text;
  v_mentions   uuid[];
begin
  if v_me is null or not public.is_active_staff() then
    raise exception 'Only staff send messages.' using errcode = 'insufficient_privilege';
  end if;
  select kind, client_id into v_kind, v_client from public.conversations where id = p_conversation and archived_at is null;
  if v_kind is null then
    raise exception 'That conversation is not there, or has been archived.' using errcode = 'check_violation';
  end if;
  if v_kind <> 'internal' then
    raise exception 'A text or web chat is answered from its own screen, where its rules are checked.' using errcode = 'check_violation';
  end if;
  if not public.is_conversation_participant(p_conversation) then
    raise exception 'You are not in that conversation.' using errcode = 'insufficient_privilege';
  end if;
  if coalesce(btrim(p_body), '') = '' and coalesce(jsonb_array_length(p_attachments), 0) = 0 then
    raise exception 'The message is empty.' using errcode = 'check_violation';
  end if;
  if length(p_body) > 8000 then
    raise exception 'That message is too long - 8,000 characters at most.' using errcode = 'check_violation';
  end if;
  if jsonb_typeof(coalesce(p_attachments, '[]'::jsonb)) <> 'array'
     or jsonb_array_length(coalesce(p_attachments, '[]'::jsonb)) > 5 then
    raise exception 'Five attachments at most.' using errcode = 'check_violation';
  end if;

  -- ── the attachments, one at a time ───────────────────────
  for v_item in select * from jsonb_array_elements(coalesce(p_attachments, '[]'::jsonb)) loop
    -- Something that is not an id at all is a bad reference, not a database
    -- error: it gets the same plain refusal as a reference to nothing.
    begin
      v_ref := nullif(v_item ->> 'id', '')::uuid;
    exception when invalid_text_representation then
      v_ref := null;
    end;
    if v_ref is null or (v_item ->> 'kind') not in ('client_file', 'form') then
      raise exception 'An attachment is a document or a form already on a client''s record.' using errcode = 'check_violation';
    end if;

    if v_item ->> 'kind' = 'client_file' then
      select a.client_id, a.restricted into v_owner, v_restricted
        from public.attachments a where a.id = v_ref;
    else
      select f.client_id, f.sensitive into v_owner, v_restricted
        from public.forms f where f.id = v_ref;
    end if;

    if v_owner is null then
      raise exception 'That document is not on a client''s record.' using errcode = 'no_data_found';
    end if;
    -- In a thread about a client it is that client's document or nobody's.
    if v_client is not null and v_owner <> v_client then
      raise exception 'That document belongs to another client. A thread about one client carries that client''s documents.'
        using errcode = 'check_violation';
    end if;

    if v_restricted then
      if not public.can_see_restricted(v_owner) then
        raise exception 'That is a restricted document, and it is not yours to send.' using errcode = 'insufficient_privilege';
      end if;
      select string_agg(s.name, ', ' order by s.name) into v_blocked
        from public.conversation_participants p
        join public.staff s on s.id = p.staff_id
       where p.conversation_id = p_conversation and p.left_at is null and p.staff_id <> v_me
         and not public.can_staff_see_restricted(p.staff_id, v_owner);
      if v_blocked is not null then
        raise exception
          'That document is restricted and % cannot open it, so it cannot be attached here. Restricted documents are for Admin, Intake & Client Reports, and the staff member the client is assigned to. Send a link to the record instead.',
          v_blocked
          using errcode = 'insufficient_privilege';
      end if;
    end if;
  end loop;

  -- A mention is of somebody in the conversation; anybody else is just a name.
  select coalesce(array_agg(distinct m), '{}'::uuid[]) into v_mentions
    from unnest(coalesce(p_mentions, '{}'::uuid[])) m
   where exists (select 1 from public.conversation_participants p
                  where p.conversation_id = p_conversation and p.staff_id = m and p.left_at is null);

  select name into v_name from public.staff where id = v_me;
  insert into public.messages (conversation_id, sender_kind, sender_staff_id, sender_label, body, attachments, mentions)
  values (p_conversation, 'staff', v_me, coalesce(v_name, ''), p_body, coalesce(p_attachments, '[]'::jsonb), v_mentions)
  returning id, seq into v_id, v_seq;

  update public.conversations set last_message_at = now(), last_seq = v_seq where id = p_conversation;
  -- The sender has read their own message.
  insert into public.read_receipts (conversation_id, staff_id, last_read_seq, read_at)
  values (p_conversation, v_me, v_seq, now())
  on conflict (conversation_id, staff_id) do update
    set last_read_seq = greatest(public.read_receipts.last_read_seq, excluded.last_read_seq), read_at = now();
  return v_id;
end;
$$;

-- Five minutes to fix a typo. After that it stands as said.
create or replace function public.edit_message(p_message uuid, p_body text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := public.current_staff_id();
  v_at timestamptz;
begin
  select created_at into v_at from public.messages
   where id = p_message and sender_staff_id = v_me and removed_at is null;
  if v_at is null then
    raise exception 'That is not yours to change.' using errcode = 'insufficient_privilege';
  end if;
  if v_at < now() - interval '5 minutes' then
    raise exception 'A message can be changed for five minutes. After that it stands - say the correction instead.'
      using errcode = 'check_violation';
  end if;
  if coalesce(btrim(p_body), '') = '' then
    raise exception 'An empty message is a removal, not a change.' using errcode = 'check_violation';
  end if;
  if length(p_body) > 8000 then
    raise exception 'That message is too long - 8,000 characters at most.' using errcode = 'check_violation';
  end if;
  update public.messages set body = p_body, edited_at = now() where id = p_message;
end;
$$;

-- Your own message, taken back - and the conversation says so.
create or replace function public.remove_message(p_message uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := public.current_staff_id();
begin
  if not exists (
    select 1 from public.messages m
     where m.id = p_message and m.removed_at is null and m.sender_staff_id = v_me) then
    raise exception 'That is not yours to remove.' using errcode = 'insufficient_privilege';
  end if;
  update public.messages
     set removed_at = now(), body = '', attachments = '[]'::jsonb, mentions = '{}'::uuid[], status = 'removed'
   where id = p_message;
end;
$$;

-- What somebody said, across the conversations this person is in.
create or replace function public.search_messages(p_query text, p_limit integer default 50)
returns table (message_id uuid, conversation_id uuid, conversation_label text, sender_label text, body text, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select m.id, c.id,
         case
           when c.title <> '' then c.title
           when c.client_id is not null and c.kind = 'internal'
             then 'About ' || coalesce((select cl.name from public.clients cl where cl.id = c.client_id), 'a client')
           when c.kind = 'sms'
             then 'Texts with ' || coalesce((select cl.name from public.clients cl where cl.id = c.client_id), nullif(c.external_address, ''), 'a number')
           when c.kind = 'web' then 'Website chat'
           else coalesce((select string_agg(s.name, ', ') from public.conversation_participants p
                            join public.staff s on s.id = p.staff_id
                           where p.conversation_id = c.id and p.staff_id <> public.current_staff_id() and p.left_at is null), 'A conversation')
         end,
         m.sender_label, m.body, m.created_at
    from public.messages m
    join public.conversations c on c.id = m.conversation_id
   where public.is_active_staff()
     and m.removed_at is null
     and coalesce(btrim(p_query), '') <> ''
     and m.body ilike '%' || btrim(p_query) || '%'
     and (c.kind <> 'internal' or public.is_conversation_participant(c.id))
   order by m.created_at desc
   limit least(coalesce(p_limit, 50), 200);
$$;

-- ── a thread about a client, on that client's Activity ──────
-- In the one timeline with notes, texts and appointments rather than beside
-- it. The view reads as the person asking (security_invoker), so the rule from
-- 0104 decides who sees the row: the people in the thread, and Admin.
--
-- Restated in full, as 0034, 0050, 0081 and 0083 did before it: this view is
-- the one definition of what has happened to a client.
create or replace view public.client_activity as
select * from (SELECT n.client_id,
            COALESCE(n.at::timestamp with time zone, n.created_at) AS at,
            'Note'::text AS kind,
            n.type AS title,
            n.text AS detail,
            n.staff_name AS who,
            'notes'::text AS tab,
            n.id AS ref_id
           FROM notes n
        UNION ALL
         SELECT h.client_id,
            COALESCE(h.at::timestamp with time zone, h.created_at) AS "coalesce",
            'Stage'::text AS text,
            'Moved to '::text || h.stage,
            ''::text AS text,
            s.name,
            'overview'::text AS text,
            h.id
           FROM client_stage_history h
             LEFT JOIN staff s ON s.id = h.staff_id
        UNION ALL
         SELECT m.client_id,
            m.applied_on::timestamp with time zone AS applied_on,
            'Job'::text AS text,
            'Applied — '::text || COALESCE(e.name, l.title, 'a job'::text),
            COALESCE(l.title, ''::text) AS "coalesce",
            s.name,
            'overview'::text AS text,
            m.id
           FROM lead_matches m
             JOIN job_leads l ON l.id = m.lead_id
             LEFT JOIN employers e ON e.id = l.employer_id
             LEFT JOIN staff s ON s.id = m.created_by
          WHERE m.applied_on IS NOT NULL
        UNION ALL
         SELECT m.client_id,
            m.interview_on::timestamp with time zone AS interview_on,
            'Interview'::text AS text,
            'Interview — '::text || COALESCE(e.name, l.title, 'a job'::text),
            COALESCE(l.title, ''::text) AS "coalesce",
            s.name,
            'overview'::text AS text,
            m.id
           FROM lead_matches m
             JOIN job_leads l ON l.id = m.lead_id
             LEFT JOIN employers e ON e.id = l.employer_id
             LEFT JOIN staff s ON s.id = m.created_by
          WHERE m.interview_on IS NOT NULL
        UNION ALL
         SELECT m.client_id,
            m.follow_up_on::timestamp with time zone AS follow_up_on,
            'Follow-up'::text AS text,
            'Follow up — '::text || COALESCE(e.name, l.title, 'a job'::text),
            COALESCE(l.title, ''::text) AS "coalesce",
            s.name,
            'overview'::text AS text,
            m.id
           FROM lead_matches m
             JOIN job_leads l ON l.id = m.lead_id
             LEFT JOIN employers e ON e.id = l.employer_id
             LEFT JOIN staff s ON s.id = m.created_by
          WHERE m.follow_up_on IS NOT NULL
        UNION ALL
         SELECT m.client_id,
            m.decided_on::timestamp with time zone AS decided_on,
            'Job'::text AS text,
            (m.status || ' — '::text) || COALESCE(e.name, l.title, 'a job'::text),
            COALESCE(NULLIF(m.outcome, ''::text), m.notes, ''::text) AS "coalesce",
            s.name,
            'overview'::text AS text,
            m.id
           FROM lead_matches m
             JOIN job_leads l ON l.id = m.lead_id
             LEFT JOIN employers e ON e.id = l.employer_id
             LEFT JOIN staff s ON s.id = m.created_by
          WHERE m.decided_on IS NOT NULL
        UNION ALL
         SELECT t.client_id,
            t.done_at,
            'Task'::text AS text,
            'Done — '::text || t.title,
            ''::text AS text,
            s.name,
            'tasks'::text AS text,
            t.id
           FROM tasks t
             LEFT JOIN staff s ON s.id = t.assigned_staff_id
          WHERE t.status = 'Done'::text AND t.done_at IS NOT NULL
        UNION ALL
         SELECT f.client_id,
            f.completed_at,
            'Form'::text AS text,
            'Completed — '::text || COALESCE(ft.name, 'form'::text),
            ''::text AS text,
            f.completed_by_name,
            'forms'::text AS text,
            f.id
           FROM forms f
             LEFT JOIN form_templates ft ON ft.id = f.template_id
          WHERE f.completed_at IS NOT NULL
        UNION ALL
         SELECT f.client_id,
            f.sent_at,
            'Form'::text AS text,
            'Sent — '::text || COALESCE(ft.name, 'form'::text),
            COALESCE(f.sent_to, ''::text) AS "coalesce",
            f.completed_by_name,
            'forms'::text AS text,
            f.id
           FROM forms f
             LEFT JOIN form_templates ft ON ft.id = f.template_id
          WHERE f.sent_at IS NOT NULL
        UNION ALL
         SELECT cl.client_id,
            cl.date::timestamp with time zone AS date,
            'Counselor'::text AS text,
            cl.method || COALESCE(' — '::text || NULLIF(cl.topic, ''::text), ''::text),
            COALESCE(cl.outcome, ''::text) AS "coalesce",
            s.name,
            'counselors'::text AS text,
            cl.id
           FROM contact_log cl
             LEFT JOIN staff s ON s.id = cl.staff_id
          WHERE cl.client_id IS NOT NULL
        UNION ALL
         SELECT p.client_id,
            p.start_date::timestamp with time zone AS start_date,
            'Placement'::text AS text,
            'Started — '::text || COALESCE(NULLIF(p.employer, ''::text), 'a placement'::text),
            COALESCE(p.title, ''::text) AS "coalesce",
            NULL::text AS text,
            'placements'::text AS text,
            p.id
           FROM placements p
          WHERE p.start_date IS NOT NULL
        UNION ALL
         SELECT p.client_id,
            c.at::timestamp with time zone AS at,
            'Retention'::text AS text,
            (c.label || ' check — '::text) || COALESCE(NULLIF(p.employer, ''::text), 'placement'::text),
            ''::text AS text,
            NULL::text AS text,
            'placements'::text AS text,
            p.id
           FROM placements p
             CROSS JOIN LATERAL ( VALUES (p.check30,'30 day'::text), (p.check60,'60 day'::text), (p.check90,'90 day'::text)) c(at, label)
          WHERE c.at IS NOT NULL
        UNION ALL
         SELECT a.client_id,
            se.date::timestamp with time zone AS date,
            'Hours'::text AS text,
            (fmt_hours(se.hours) || ' logged'::text) ||
                CASE
                    WHEN se.non_billable THEN ' (non-billable)'::text
                    ELSE ''::text
                END,
            COALESCE(se.notes, ''::text) AS "coalesce",
            s.name,
            'authorizations'::text AS text,
            se.id
           FROM service_entries se
             JOIN authorizations a ON a.id = se.auth_id
             LEFT JOIN staff s ON s.id = se.staff_id
        UNION ALL
         SELECT ce.client_id,
            ce.starts_at,
            'Appointment'::text AS text,
            (ce.kind || ' — '::text) || ce.title,
            COALESCE(ce.location, ''::text) AS "coalesce",
            s.name,
            'calendar'::text AS text,
            ce.id
           FROM calendar_events ce
             LEFT JOIN staff s ON s.id = ce.staff_id
          WHERE ce.client_id IS NOT NULL
        UNION ALL
         SELECT ml.client_id,
            ml.sent_at,
            'Mail'::text AS text,
                CASE ml.direction
                    WHEN 'Incoming'::text THEN 'From '::text
                    ELSE 'To '::text
                END || ml.counterpart_email,
            ml.subject,
            NULL::text AS text,
            'calendar'::text AS text,
            ml.id
           FROM mail_log ml
          WHERE ml.client_id IS NOT NULL
        UNION ALL
         SELECT sm.client_id,
            COALESCE(sm.sent_at, sm.created_at) AS "coalesce",
            'Text'::text AS text,
                CASE sm.direction
                    WHEN 'Incoming'::text THEN 'From the client'::text
                    ELSE 'To the client'::text
                END ||
                CASE
                    WHEN sm.status = 'Failed'::text THEN ' — not delivered'::text
                    WHEN sm.kind = 'Reminder'::text THEN ' — appointment reminder'::text
                    ELSE ''::text
                END,
            sm.body,
            s.name,
            'calendar'::text AS text,
            sm.id
           FROM sms_messages sm
             LEFT JOIN staff s ON s.id = sm.created_by
          WHERE sm.client_id IS NOT NULL
        UNION ALL
         SELECT a.client_id,
            COALESCE(pay.warrant_date::timestamp with time zone, pay.created_at) AS "coalesce",
            'Payment'::text AS text,
            (('Paid $'::text || to_char(pay.amount, 'FM999,999,990.00'::text)) || ' — '::text) || COALESCE(NULLIF(a.number, ''::text), a.service_type),
            COALESCE('Warrant '::text || NULLIF(pay.warrant_no, ''::text), 'No warrant number'::text) || COALESCE(' · voucher '::text || NULLIF(pay.voucher, ''::text), ''::text),
            NULLIF(pay.recorded_by_name, ''::text) AS "nullif",
            'payments'::text AS text,
            pay.id
           FROM payments pay
             JOIN authorizations a ON a.id = pay.auth_id
        UNION ALL
         SELECT c.client_id,
            COALESCE(c.last_message_at, c.created_at) AS "coalesce",
            'Chat'::text AS text,
                CASE
                    WHEN c.title <> ''::text THEN 'Staff thread — '::text || c.title
                    ELSE 'Staff thread about this client'::text
                END,
            COALESCE(( SELECT string_agg(s.name, ', '::text ORDER BY s.name) AS string_agg
                   FROM conversation_participants p
                     JOIN staff s ON s.id = p.staff_id
                  WHERE p.conversation_id = c.id AND p.left_at IS NULL), ''::text) AS "coalesce",
            ( SELECT s.name
                   FROM staff s
                  WHERE s.id = c.created_by),
            'chat'::text AS text,
            c.id
           FROM conversations c
          WHERE c.kind = 'internal'::text AND c.client_id IS NOT NULL) feed;

alter view public.client_activity set (security_invoker = true);
grant select on public.client_activity to authenticated;

-- ── function access ─────────────────────────────────────────
revoke execute on function public.can_staff_see_restricted(uuid, uuid) from public, anon;
revoke execute on function public.start_group_conversation(text, uuid[], uuid) from public, anon;
revoke execute on function public.add_conversation_participant(uuid, uuid) from public, anon;
revoke execute on function public.leave_conversation(uuid) from public, anon;
revoke execute on function public.archive_conversation(uuid, boolean) from public, anon;
revoke execute on function public.post_message(uuid, text, jsonb, uuid[]) from public, anon;
revoke execute on function public.edit_message(uuid, text) from public, anon;
revoke execute on function public.remove_message(uuid) from public, anon;
revoke execute on function public.search_messages(text, integer) from public, anon;
grant execute on function public.can_staff_see_restricted(uuid, uuid) to authenticated, service_role;
grant execute on function public.start_group_conversation(text, uuid[], uuid) to authenticated;
grant execute on function public.add_conversation_participant(uuid, uuid) to authenticated;
grant execute on function public.leave_conversation(uuid) to authenticated;
grant execute on function public.archive_conversation(uuid, boolean) to authenticated;
grant execute on function public.post_message(uuid, text, jsonb, uuid[]) to authenticated;
grant execute on function public.edit_message(uuid, text) to authenticated;
grant execute on function public.remove_message(uuid) to authenticated;
grant execute on function public.search_messages(text, integer) to authenticated;
