-- Zion Vocational Rehab CRM — 0239 a sent message says it was sent
--
-- `filed_how` has had three values since 0233 - "sent", "auto", "by hand" -
-- and until now only two of them could ever be written. The sweep writes
-- "auto" and filing writes "by hand"; nothing wrote "sent", because the only
-- function that files by hand had the word built into it.
--
-- The difference matters on the screen. "Filed by Rei" and "Sent by Rei" are
-- two different facts about a message and somebody reading a client's record
-- needs to know which: one means Rei decided this belonged here, the other
-- means Rei wrote it. So filing takes the word as an argument, and refuses
-- the sweep's word, because a person filing something is by definition not
-- the thing nobody chose.
--
-- A new argument is a new signature and a new signature is a new function
-- with a new function's grants - which is how 0234 quietly opened three
-- writers to anybody signed in. The old one is dropped and the new one's
-- grants are set explicitly, in that order.

drop function if exists public.file_mail_to_client(uuid, jsonb, text);

create or replace function public.file_mail_to_client(
  p_client   uuid,
  p_messages jsonb default '[]'::jsonb,
  p_thread   text default null,
  p_how      text default 'by hand'
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
  if p_how not in ('sent', 'by hand') then
    raise exception 'Mail is filed by hand or by sending it. "auto" is the sweep''s and not this.'
      using errcode = 'check_violation';
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
      v_me, now(), p_how
    )
    on conflict (mailbox_key, graph_message_id) do update
       set client_id      = p_client,
           counselor_id   = null,
           filed_by       = v_me,
           filed_at       = now(),
           filed_how      = p_how,
           unfiled_at     = null,
           unfiled_by     = null,
           unfiled_reason = null
     where mail_log.client_id is distinct from p_client
        or mail_log.unfiled_at is not null;
    get diagnostics v_n = row_count;
    v_filed := v_filed + v_n;
  end loop;

  -- A thread is what somebody means when they drag the whole conversation:
  -- everything of it already here comes too. Always "by hand" - sending one
  -- message does not mean the practice sent the rest of the thread.
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
  'Files messages, or a whole thread, onto a client - by hand, or because the practice sent it (0239).';

revoke all on function public.file_mail_to_client(uuid, jsonb, text, text) from anon, authenticated;
grant execute on function public.file_mail_to_client(uuid, jsonb, text, text) to authenticated;
