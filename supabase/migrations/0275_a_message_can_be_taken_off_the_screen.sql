-- A message can be taken off the screen
--
-- The owner's rule (30 Oct 2026): no delete - messages are kept - and Admin
-- can hide one, logged.
--
-- Two different things, which is why both exist:
--
--   `remove_message` (0106) is the author taking their own words back within
--   the five minutes. It blanks the body and leaves the marker, so the
--   conversation still reads as a conversation.
--
--   Hiding is Admin taking something off everybody else's screen - a client's
--   name in a thread that should not have carried it, somebody's temper. The
--   words are kept and only Admin can read them, because a thing taken down
--   is still something that was said and Admin is who has to answer for it.
--
-- So the log is a table rather than a column. A column would say the message
-- is hidden; it would not say that it was hidden on Tuesday, shown again on
-- Wednesday because the complaint was wrong, and hidden again on Friday. A
-- moderation decision that can be reversed needs the history of the decision,
-- which is the same reason the correction log is a table.

alter table public.messages
  add column if not exists hidden_at timestamptz,
  add column if not exists hidden_by uuid references public.staff (id);

comment on column public.messages.hidden_at is
  'Set while a message is off everybody but Admin''s screen. Why, and by whom, each time, is message_moderation (0275).';

create index if not exists messages_hidden_idx on public.messages (hidden_at)
  where hidden_at is not null;

-- ─────────────────────────────────────────────────────────────
-- The log
-- ─────────────────────────────────────────────────────────────
create table if not exists public.message_moderation (
  id         uuid primary key default gen_random_uuid(),
  message_id uuid not null references public.messages (id) on delete cascade,
  action     text not null check (action in ('Hidden', 'Shown again')),
  reason     text not null,
  at         timestamptz not null default clock_timestamp(),
  staff_id   uuid references public.staff (id),
  staff_name text not null
);

comment on table public.message_moderation is
  'Every time Admin took a message off the screen or put it back, and why. Added to, never changed.';

create index if not exists message_moderation_message_idx
  on public.message_moderation (message_id, at desc);

alter table public.message_moderation enable row level security;

-- Admin only, both ways. Everybody on the staff can read the correction log
-- because it is about the practice's own records; this is about a colleague's
-- words, and who moderated whom is not the practice's gossip.
drop policy if exists message_moderation_read on public.message_moderation;
create policy message_moderation_read on public.message_moderation
  for select using ((select public.is_admin()));

create or replace function public.message_moderation_append_only()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  -- The message this is about has already gone, so this row is being carried
  -- off by the cascade behind it rather than edited by anybody.
  if tg_op = 'DELETE'
     and not exists (select 1 from public.messages where id = old.message_id) then
    return old;
  end if;
  raise exception 'What was taken down and why is a record; it is added to, never changed or removed.'
    using errcode = 'insufficient_privilege';
end $$;

drop trigger if exists message_moderation_append_only on public.message_moderation;
create trigger message_moderation_append_only
  before update or delete on public.message_moderation
  for each row execute function public.message_moderation_append_only();

-- Supabase grants everything on a new table to `authenticated` before any of
-- this runs, TRUNCATE included - which has no rows, so neither the policy nor
-- the trigger above would be consulted.
revoke all on public.message_moderation from authenticated;
revoke all on public.message_moderation from anon;
grant select on public.message_moderation to authenticated;

select public.apply_system_read_only('message_moderation');

-- ─────────────────────────────────────────────────────────────
-- Doing it
-- ─────────────────────────────────────────────────────────────
create or replace function public.hide_message(p_message uuid, p_hidden boolean, p_reason text)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_me   uuid := public.current_staff_id();
  v_name text;
  v_now  timestamptz;
begin
  if not public.is_admin() then
    raise exception 'Only Admin takes a message off the screen.' using errcode = 'insufficient_privilege';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'Say why it is coming down.' using errcode = 'check_violation';
  end if;

  select hidden_at into v_now from public.messages where id = p_message;
  if not found then
    raise exception 'That message is not there.' using errcode = 'no_data_found';
  end if;
  -- Said twice is said once. Without this the log fills with Tuesday's
  -- decision repeated by whoever clicked it again.
  if p_hidden = (v_now is not null) then
    raise exception 'That message is already %.',
      case when p_hidden then 'off the screen' else 'on the screen' end
      using errcode = 'check_violation';
  end if;

  select name into v_name from public.staff where id = v_me;

  update public.messages
     set hidden_at = case when p_hidden then now() else null end,
         hidden_by = case when p_hidden then v_me else null end
   where id = p_message;

  insert into public.message_moderation (message_id, action, reason, staff_id, staff_name)
  values (p_message, case when p_hidden then 'Hidden' else 'Shown again' end,
          btrim(p_reason), v_me, coalesce(v_name, ''));
end $$;

revoke all on function public.hide_message(uuid, boolean, text) from anon, authenticated;
grant execute on function public.hide_message(uuid, boolean, text) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- And it is off the screen
--
-- Four places read messages and every one of them has to agree, which is the
-- part that would otherwise be found by somebody searching for a phrase and
-- getting back the message that had been taken down.
-- ─────────────────────────────────────────────────────────────
drop policy if exists messages_read on public.messages;
create policy messages_read on public.messages
  for select using (
    exists (select 1 from public.conversations c where c.id = messages.conversation_id)
    and (hidden_at is null or (select public.is_admin()))
  );

-- `search_messages`, `my_unread` and `client_chat_mentions` read messages
-- inside SECURITY DEFINER code or as the view's owner, where the policy above
-- does not apply, so each says it itself.
create or replace function public.search_messages(p_query text, p_limit integer default 50)
returns table(message_id uuid, conversation_id uuid, conversation_label text, sender_label text,
              body text, created_at timestamptz)
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
     and (m.hidden_at is null or public.is_admin())
     and coalesce(btrim(p_query), '') <> ''
     and m.body ilike '%' || btrim(p_query) || '%'
     and (c.kind <> 'internal' or public.is_conversation_participant(c.id))
   order by m.created_at desc
   limit least(coalesce(p_limit, 50), 200);
$$;

revoke all on function public.search_messages(text, integer) from anon, authenticated;
grant execute on function public.search_messages(text, integer) to authenticated;

create or replace function public.my_unread()
returns table(conversation_id uuid, unread integer)
language sql stable security definer set search_path = public as $$
  select p.conversation_id,
         (select count(*)::integer from public.messages m
           where m.conversation_id = p.conversation_id
             and m.seq > coalesce(r.last_read_seq, 0)
             and m.removed_at is null
             and (m.hidden_at is null or public.is_admin())
             and m.sender_staff_id is distinct from public.current_staff_id())
    from public.conversation_participants p
    join public.conversations c on c.id = p.conversation_id and c.kind = 'internal' and c.archived_at is null
    left join public.read_receipts r on r.conversation_id = p.conversation_id and r.staff_id = p.staff_id
   where p.staff_id = public.current_staff_id() and p.left_at is null and public.is_active_staff();
$$;

revoke all on function public.my_unread() from anon, authenticated;
grant execute on function public.my_unread() to authenticated;

create or replace view public.client_chat_mentions as
select m.id            as message_id,
       c.id            as conversation_id,
       cl.id           as client_id,
       m.created_at,
       m.sender_label,
       coalesce(nullif(c.title, ''), 'a direct message') as thread
  from public.messages m
  join public.conversations c on c.id = m.conversation_id
  cross join lateral unnest(m.client_mentions) as cl(id)
 where m.removed_at is null
   and m.hidden_at is null
   and c.kind = 'internal';

alter view public.client_chat_mentions set (security_invoker = true);
revoke all on public.client_chat_mentions from authenticated;
revoke all on public.client_chat_mentions from anon;
grant select on public.client_chat_mentions to authenticated;

-- ─────────────────────────────────────────────────────────────
-- Taking your own words back clears the chip as well
--
-- `remove_message` blanked the body and the mentions and knew nothing about
-- `client_mentions`, which 0274 added - so a removed message would have gone
-- on naming a client in a row nobody could read.
-- ─────────────────────────────────────────────────────────────
create or replace function public.remove_message(p_message uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := public.current_staff_id();
begin
  if not exists (
    select 1 from public.messages m
     where m.id = p_message and m.removed_at is null and m.sender_staff_id = v_me) then
    raise exception 'That is not yours to remove.' using errcode = 'insufficient_privilege';
  end if;
  update public.messages
     set removed_at = now(), body = '', attachments = '[]'::jsonb,
         mentions = '{}'::uuid[], client_mentions = '{}'::uuid[], status = 'removed'
   where id = p_message;
end $$;

revoke all on function public.remove_message(uuid) from anon, authenticated;
grant execute on function public.remove_message(uuid) to authenticated;
