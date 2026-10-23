-- Zion Vocational Rehab CRM — 0236 filing a message, and telling two people
--
-- Two things 0233 left unfinished, both of them consequences of the rule the
-- owner set: nothing in a mailbox is stored unless somebody files it.
--
-- The first is that `file_mail_to_client` could only move rows that were
-- already in `mail_log`, and under the new rule almost nothing is. The Mail
-- screen reads a mailbox live from Microsoft and stores none of it, so when
-- somebody drags a message onto a client there is no row to move - the act of
-- filing is what creates one. Filing therefore has to carry the message with
-- it, which is what the jsonb argument is for. The text[] version goes: it
-- answered a question the screen never asks.
--
-- The second is who hears about a reply. A reply that files itself (0233) is
-- the one piece of mail nobody chose, so it is the one piece somebody has to
-- be told about: the client's assigned staff member, and one standing
-- recipient the practice names. Nobody else, which means the notification is
-- written by name rather than by role - `notify_person` puts the recipient's
-- role in `roles`, and on this notification that would show one client's
-- correspondence to every Job Coach in the practice.

-- ─────────────────────────────────────────────────────────────
-- Who is told, besides the person the client belongs to
-- ─────────────────────────────────────────────────────────────
alter table public.org_settings
  add column if not exists mail_notice_staff_id uuid references public.staff(id) on delete set null;

comment on column public.org_settings.mail_notice_staff_id is
  'The one person told about every reply that files itself, whichever client it is about. Set in Admin (0236).';

-- Margaret, by the address rather than by an id copied into a migration: if
-- the row is not there the setting stays null and nothing breaks.
update public.org_settings
   set mail_notice_staff_id = (
         select id from public.staff
          where lower(email) = 'margaret@zionvocrehab.com' and active
          limit 1)
 where mail_notice_staff_id is null;

-- ─────────────────────────────────────────────────────────────
-- Filing, when the message is not in the CRM yet
-- ─────────────────────────────────────────────────────────────
drop function if exists public.file_mail_to_client(uuid, text[], text);

/**
 * File messages, or a whole thread, onto a client.
 *
 * Each element of `p_messages` is the message itself, because filing is the
 * moment it enters the CRM:
 *
 *   {"id", "conversation", "subject", "sent_at", "direction",
 *    "counterpart", "web_link", "mailbox"}
 *
 * `mailbox` empty means the person's own mailbox, which is how `mailbox_key`
 * tells one person's copy of a message from another's. A shared mailbox names
 * itself.
 *
 * Filing the same message twice is not an error - two people reaching the
 * same conclusion about the same email is the normal case - so it moves the
 * row rather than refusing, and says which it did. `p_thread` catches the rest
 * of a conversation that is already here, which is what dragging a whole
 * thread means.
 */
create or replace function public.file_mail_to_client(
  p_client   uuid,
  p_messages jsonb default '[]'::jsonb,
  p_thread   text default null
)
returns table (filed integer, moved integer)
language plpgsql security definer set search_path = public as $$
declare
  v_me    uuid := public.current_staff_id();
  v_filed int := 0;
  v_moved int := 0;
  v_n     int;
  m       jsonb;
  v_dir   text;
begin
  if v_me is null then
    raise exception 'Only a member of staff files mail.' using errcode = 'insufficient_privilege';
  end if;
  if not exists (select 1 from public.clients c where c.id = p_client) then
    raise exception 'That client is not there.' using errcode = 'no_data_found';
  end if;

  for m in select * from jsonb_array_elements(coalesce(p_messages, '[]'::jsonb))
  loop
    if coalesce(btrim(m->>'id'), '') = '' then
      raise exception 'A message with no id cannot be filed.' using errcode = 'check_violation';
    end if;

    -- Outgoing unless the message says it came from the other person. The
    -- column only allows the two words, so it is decided here rather than
    -- taken on trust from the screen.
    v_dir := case when m->>'direction' = 'Incoming' then 'Incoming' else 'Outgoing' end;

    insert into public.mail_log (
      staff_id, mailbox_address, client_id, counselor_id, graph_message_id, conversation_id,
      subject, sent_at, direction, counterpart_email, web_link,
      filed_by, filed_at, filed_how
    ) values (
      case when coalesce(btrim(m->>'mailbox'), '') = '' then v_me else null end,
      coalesce(btrim(m->>'mailbox'), ''),
      p_client, null,
      m->>'id',
      coalesce(m->>'conversation', ''),
      left(coalesce(nullif(btrim(coalesce(m->>'subject', '')), ''), '(no subject)'), 500),
      coalesce((m->>'sent_at')::timestamptz, now()),
      v_dir,
      lower(coalesce(m->>'counterpart', '')),
      coalesce(m->>'web_link', ''),
      v_me, now(), 'by hand'
    )
    on conflict (mailbox_key, graph_message_id) do update
       set client_id      = p_client,
           counselor_id   = null,
           filed_by       = v_me,
           filed_at       = now(),
           filed_how      = 'by hand',
           unfiled_at     = null,
           unfiled_by     = null,
           unfiled_reason = null
     where mail_log.client_id is distinct from p_client
        or mail_log.unfiled_at is not null;
    get diagnostics v_n = row_count;
    v_filed := v_filed + v_n;
  end loop;

  -- A thread is what somebody means when they drag the whole conversation:
  -- everything of it already here comes too.
  if coalesce(btrim(p_thread), '') <> '' then
    update public.mail_log
       set client_id = p_client, counselor_id = null,
           filed_by = v_me, filed_at = now(), filed_how = 'by hand',
           unfiled_at = null, unfiled_by = null, unfiled_reason = null
     where conversation_id = p_thread
       and (client_id is distinct from p_client or unfiled_at is not null);
    get diagnostics v_moved = row_count;
  end if;

  filed := v_filed;
  moved := v_moved;
  return next;
end;
$$;

comment on function public.file_mail_to_client is
  'Files messages, or a whole thread, onto a client by hand, writing the message itself if filing is how it entered the CRM (0236).';

revoke all on function public.file_mail_to_client(uuid, jsonb, text) from anon, authenticated;
grant execute on function public.file_mail_to_client(uuid, jsonb, text) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- A reply that filed itself tells two people
-- ─────────────────────────────────────────────────────────────
/**
 * The bell and the My day item for a reply nobody filed.
 *
 * Written by name, not by role. `notify_person` stamps the recipient's role
 * into `roles`, and the read policy on `notifications` lets anybody with that
 * role see the row - which on a client's correspondence would mean every Job
 * Coach reading about a client who is not theirs. An empty `roles` and a
 * `staff_id` is the same table saying "this person, nobody else".
 *
 * Admin still sees it, because Admin sees every notification in the practice.
 * That is the existing rule and not one this changes.
 */
create or replace function public.notify_mail_reply(p_mail uuid)
returns integer
language plpgsql security definer set search_path = public as $$
declare
  v_row    public.mail_log;
  v_client public.clients;
  v_who    uuid;
  v_text   text;
  v_href   text;
  v_made   int := 0;
  v_task   uuid;
begin
  select * into v_row from public.mail_log where id = p_mail;
  if not found or v_row.client_id is null or v_row.unfiled_at is not null then
    return 0;
  end if;

  select * into v_client from public.clients where id = v_row.client_id;
  if not found then
    return 0;
  end if;

  v_text := format('%s replied on %s.',
                   coalesce(nullif(v_row.counterpart_email, ''), 'Somebody'),
                   v_client.name);
  v_href := '/clients/' || v_row.client_id::text || '#mail';

  -- The person the client belongs to, and the one person the practice names.
  -- A set, so when they are the same person they are told once.
  for v_who in
    select s.id
      from public.staff s
     where s.active
       and s.id in (
             v_client.assigned_staff_id,
             (select o.mail_notice_staff_id from public.org_settings o limit 1)
           )
  loop
    insert into public.notifications (dedupe_key, kind, level, text, roles, href, client_id, staff_id)
    values ('mail_reply:' || v_row.id::text || ':' || v_who::text,
            'mail_reply', 'warn', v_text, array[]::text[], v_href, v_row.client_id, v_who)
    on conflict (dedupe_key) do nothing;
    if found then
      v_made := v_made + 1;
    end if;

    select id into v_task from public.tasks
     where source_kind = 'mail_reply'
       and source_ref = v_row.id
       and assigned_staff_id = v_who
       and status = 'Open';
    if v_task is null then
      insert into public.tasks
        (title, client_id, assigned_staff_id, due, status, system_generated, source_kind, source_ref)
      values (format('Read the reply on %s', v_client.name), v_row.client_id, v_who,
              public.practice_today(), 'Open', true, 'mail_reply', v_row.id);
    end if;
  end loop;

  return v_made;
end;
$$;

revoke all on function public.notify_mail_reply(uuid) from anon, authenticated;

/**
 * Only a reply that arrived, and only one that filed itself.
 *
 * Outgoing mail is somebody in the practice writing, and they know they wrote
 * it. A message filed by hand was read by the person filing it. "auto" is the
 * only case where a client's correspondence moved without anybody looking at
 * it, and so the only case worth a notification.
 */
create or replace function public.mail_reply_notifies() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.filed_how = 'auto' and new.direction = 'Incoming' and new.client_id is not null then
    perform public.notify_mail_reply(new.id);
  end if;
  return null;
end;
$$;

drop trigger if exists mail_reply_notifies on public.mail_log;
create trigger mail_reply_notifies
  after insert on public.mail_log
  for each row execute function public.mail_reply_notifies();
