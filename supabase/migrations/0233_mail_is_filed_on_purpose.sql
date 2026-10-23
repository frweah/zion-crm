-- Zion Vocational Rehab CRM — 0233 mail is filed on purpose
--
-- The mailbox is not the CRM. What the practice keeps about a client is what
-- somebody decided to keep, and this is the row that records the decision:
-- who filed it, when, and how it came to be filed (owner, 23 Oct 2026).
--
-- `mail_log` already held the facts of a message - the thread, the subject,
-- who it was with, where it lives in Outlook. What it did not hold was
-- anything about the filing itself, because until now filing was something
-- the sweep did silently when an address matched. Three columns fix that,
-- and a fourth makes a thread restricted the same way a document is.
--
-- **Unfiling keeps the row.** It has to: the owner asked for unfiling to be
-- logged, and a log you can erase by using it is not a log. The row stays
-- with the reason on it and drops out of the client's view, which is what
-- "removes the message from the client's view, never from the mailbox"
-- means from the database's side.

alter table public.mail_log
  add column if not exists filed_by       uuid references public.staff(id) on delete set null,
  add column if not exists filed_at       timestamptz,
  add column if not exists filed_how      text,
  add column if not exists restricted     boolean not null default false,
  add column if not exists unfiled_at     timestamptz,
  add column if not exists unfiled_by     uuid references public.staff(id) on delete set null,
  add column if not exists unfiled_reason text;

comment on column public.mail_log.filed_how is
  'How it came to be filed: "sent" from the CRM, "auto" as a reply on a thread already filed, or "by hand" when somebody filed it (0233).';
comment on column public.mail_log.restricted is
  'A restricted thread is redacted for anybody the client''s restricted documents are redacted for. Same rule, same helper (0203).';
comment on column public.mail_log.unfiled_at is
  'Set when somebody took it off the client. The row stays, because unfiling is logged and a log you can erase by using it is not one.';

alter table public.mail_log drop constraint if exists mail_log_filed_how_check;
alter table public.mail_log add constraint mail_log_filed_how_check
  check (filed_how is null or filed_how in ('sent', 'auto', 'by hand'));

-- Everything already here was filed by the sweep matching an address, with
-- nobody deciding anything. "auto" is the honest word for that, and the day
-- the row was written is the closest thing to a filing date it has.
update public.mail_log
   set filed_how = 'auto', filed_at = created_at
 where filed_how is null;

create index if not exists mail_log_client_filed
  on public.mail_log (client_id, sent_at desc)
  where client_id is not null and unfiled_at is null;

create index if not exists mail_log_conversation
  on public.mail_log (conversation_id)
  where conversation_id <> '';

-- ─────────────────────────────────────────────────────────────
-- What a client's mail looks like to whoever is reading it
-- ─────────────────────────────────────────────────────────────
/**
 * The filed mail on a client, redacted rather than hidden.
 *
 * The same shape client_documents uses, deliberately: a restricted thread
 * keeps its row and loses its words, so somebody who may not read it can
 * still see that it exists and ask. Hiding it entirely teaches people the
 * record is complete when it is not.
 */
create or replace view public.client_mail as
  select m.id,
         m.client_id,
         m.conversation_id,
         m.graph_message_id,
         m.sent_at,
         m.direction,
         m.restricted,
         m.filed_how,
         m.filed_at,
         m.filed_by,
         f.name as filed_by_name,
         not m.restricted or public.can_see_restricted(m.client_id) as can_open,
         case when not m.restricted or public.can_see_restricted(m.client_id)
              then m.subject else '' end as subject,
         case when not m.restricted or public.can_see_restricted(m.client_id)
              then m.counterpart_email else '' end as counterpart_email,
         case when not m.restricted or public.can_see_restricted(m.client_id)
              then m.web_link else '' end as web_link,
         case when not m.restricted or public.can_see_restricted(m.client_id)
              then m.mailbox_address else '' end as mailbox_address
    from public.mail_log m
    left join public.staff f on f.id = m.filed_by
   where m.client_id is not null
     and m.unfiled_at is null
     and (select public.is_active_staff());

alter view public.client_mail set (security_invoker = true);
grant select on public.client_mail to authenticated;

comment on view public.client_mail is
  'The mail filed on a client, newest first when ordered: one row per message, redacted rather than hidden when the thread is restricted (0233).';

-- ─────────────────────────────────────────────────────────────
-- Filing, unfiling, and restricting
-- ─────────────────────────────────────────────────────────────
/**
 * File one message, or a whole thread, onto a client.
 *
 * By hand, which is the only kind of filing that needs a person. The sweep
 * has its own path and sending has another; both say so in `filed_how`.
 *
 * Filing the same message twice is not an error - two people reaching the
 * same conclusion about the same email is the normal case - so it moves the
 * row rather than refusing, and says which it did.
 */
create or replace function public.file_mail_to_client(
  p_client   uuid,
  p_messages text[],
  p_thread   text default null
)
returns table (filed integer, moved integer)
language plpgsql security definer set search_path = public as $$
declare
  v_me    uuid := public.current_staff_id();
  v_filed int := 0;
  v_moved int := 0;
  v_n     int;
begin
  if v_me is null then
    raise exception 'Only a member of staff files mail.' using errcode = 'insufficient_privilege';
  end if;
  if not exists (select 1 from public.clients c where c.id = p_client) then
    raise exception 'That client is not there.' using errcode = 'no_data_found';
  end if;

  -- A thread is what somebody means when they drag the whole conversation.
  if coalesce(btrim(p_thread), '') <> '' then
    update public.mail_log
       set client_id = p_client, counselor_id = null,
           filed_by = v_me, filed_at = now(), filed_how = 'by hand',
           unfiled_at = null, unfiled_by = null, unfiled_reason = null
     where conversation_id = p_thread
       and (client_id is distinct from p_client or unfiled_at is not null);
    get diagnostics v_moved = row_count;
  end if;

  if p_messages is not null then
    update public.mail_log
       set client_id = p_client, counselor_id = null,
           filed_by = v_me, filed_at = now(), filed_how = 'by hand',
           unfiled_at = null, unfiled_by = null, unfiled_reason = null
     where graph_message_id = any (p_messages)
       and (client_id is distinct from p_client or unfiled_at is not null);
    get diagnostics v_n = row_count;
    v_filed := v_filed + v_n;
  end if;

  filed := v_filed;
  moved := v_moved;
  return next;
end;
$$;

comment on function public.file_mail_to_client is
  'Files a message or a whole thread onto a client, by hand, recording who did it (0233).';

revoke all on function public.file_mail_to_client(uuid, text[], text) from anon, authenticated;
grant execute on function public.file_mail_to_client(uuid, text[], text) to authenticated;

/**
 * Take it off the client, with a reason.
 *
 * The person who filed it, or an Admin. Nobody else, because unfiling is how
 * a record becomes incomplete and the person who put it there is the one who
 * knows whether it belonged.
 *
 * Nothing is deleted and nothing leaves the mailbox. The row keeps the
 * reason and drops out of the client's view.
 */
create or replace function public.unfile_mail(p_id uuid, p_reason text)
returns table (subject text)
language plpgsql security definer set search_path = public as $$
declare
  v_me  uuid := public.current_staff_id();
  v_row public.mail_log;
begin
  if v_me is null then
    raise exception 'Only a member of staff unfiles mail.' using errcode = 'insufficient_privilege';
  end if;
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'Say why it is coming off the client.' using errcode = 'check_violation';
  end if;

  select * into v_row from public.mail_log where id = p_id for update;
  if not found then
    raise exception 'That message is not filed here.' using errcode = 'no_data_found';
  end if;
  if v_row.unfiled_at is not null then
    raise exception 'That message is already off the client.' using errcode = 'check_violation';
  end if;
  if not public.is_admin() and v_row.filed_by is distinct from v_me then
    raise exception 'Only the person who filed it, or an Admin, takes it off.'
      using errcode = 'insufficient_privilege';
  end if;

  update public.mail_log
     set unfiled_at = now(), unfiled_by = v_me, unfiled_reason = btrim(p_reason)
   where id = p_id;

  subject := v_row.subject;
  return next;
end;
$$;

comment on function public.unfile_mail is
  'Takes a filed message off a client with a reason, keeping the row and leaving the mailbox alone (0233).';

revoke all on function public.unfile_mail(uuid, text) from anon, authenticated;
grant execute on function public.unfile_mail(uuid, text) to authenticated;

/**
 * Mark a thread restricted, or let it back out.
 *
 * The same people who may restrict a document on this client, because it is
 * the same decision about the same person: clients_i_can_restrict already
 * answers it and there is no second rule here.
 */
create or replace function public.set_mail_restricted(
  p_conversation text,
  p_client       uuid,
  p_restricted   boolean
)
returns integer
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := public.current_staff_id();
  v_n  int;
begin
  if v_me is null then
    raise exception 'Only a member of staff restricts a thread.' using errcode = 'insufficient_privilege';
  end if;
  if not public.can_staff_see_restricted(v_me, p_client) then
    raise exception 'Restricting a thread is for Admin, Intake & Client Reports, or this client''s assigned staff member.'
      using errcode = 'insufficient_privilege';
  end if;

  update public.mail_log
     set restricted = p_restricted
   where conversation_id = p_conversation and client_id = p_client;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

revoke all on function public.set_mail_restricted(text, uuid, boolean) from anon, authenticated;
grant execute on function public.set_mail_restricted(text, uuid, boolean) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- A reply on a filed thread files itself
-- ─────────────────────────────────────────────────────────────
/**
 * Which client a thread is already filed on, if any.
 *
 * This is what makes a reply file itself without anybody deciding again: the
 * decision was made when the thread was filed, and a reply to it is the same
 * correspondence. Unfiled rows do not count - taking a thread off a client
 * is also a decision, and a reply should not quietly undo it.
 */
create or replace function public.client_for_thread(p_conversation text)
returns uuid
language sql stable security definer set search_path = public as $$
  select m.client_id
    from public.mail_log m
   where m.conversation_id = p_conversation
     and m.client_id is not null
     and m.unfiled_at is null
   order by m.sent_at desc
   limit 1;
$$;

revoke all on function public.client_for_thread(text) from anon, authenticated;
grant execute on function public.client_for_thread(text) to authenticated;
