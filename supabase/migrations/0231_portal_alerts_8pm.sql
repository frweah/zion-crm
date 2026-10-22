-- 0231 — Portal text alerts stop at 8 p.m., as the portal terms say.
--
-- Terms v2, section 7: "We do not send texts between 8 p.m. and 8 a.m." The
-- portal's alerts were allowed until 9 p.m., the CRM's general texting
-- window. Between 8 and 9 p.m. an alert now goes by email if there is one,
-- and otherwise waits for the client to sign in.

create or replace function public.portal_claim_notice(p_conversation uuid)
returns table (notice_id uuid, channel text, destination text, name text)
language plpgsql security definer set search_path = public as $$
declare
  v_acc     public.portal_accounts%rowtype;
  v_local   time := (now() at time zone 'America/Denver')::time;
  v_text    boolean;
  v_channel text;
  v_dest    text;
  v_id      uuid;
  v_why     text := '';
begin
  select a.* into v_acc
    from public.conversations c join public.portal_accounts a on a.id = c.portal_account_id
   where c.id = p_conversation and c.kind = 'portal';
  if v_acc.id is null then
    raise exception 'That is not a portal conversation.' using errcode = 'check_violation';
  end if;
  if not public.can_manage_portal(v_acc.client_id) then
    raise exception 'Only Admin, Reports or the assigned staff member writes to this client''s portal.' using errcode = 'insufficient_privilege';
  end if;

  -- One an hour. A notice that was skipped sent nothing, so it does not count.
  if exists (select 1 from public.portal_notices n
              where n.conversation_id = p_conversation and n.status <> 'Skipped'
                and n.at > now() - interval '1 hour') then
    return;
  end if;

  if v_acc.disabled_at is not null or v_acc.first_signed_in_at is null then
    v_channel := 'None';
    v_why := case when v_acc.disabled_at is not null then 'Account disabled' else 'Not signed in yet' end;
  else
    v_text := public.portal_can_text(v_acc.id) and v_local >= time '08:00' and v_local < time '20:00';
    if coalesce(v_acc.notice_channel, case when nullif(v_acc.email, '') is not null then 'Email' else 'Text' end) = 'Text' and v_text then
      v_channel := 'Text'; v_dest := v_acc.phone;
    elsif nullif(v_acc.email, '') is not null then
      v_channel := 'Email'; v_dest := v_acc.email;
      if v_acc.notice_channel = 'Text' then v_why := 'Text not possible now, sent by email'; end if;
    elsif v_acc.phone is not null and public.portal_can_text(v_acc.id) then
      v_channel := 'None'; v_why := 'Outside texting hours';
    else
      v_channel := 'None'; v_why := 'No way to reach them';
    end if;
  end if;

  insert into public.portal_notices (conversation_id, account_id, channel, status, detail)
  values (p_conversation, v_acc.id, v_channel, case when v_channel = 'None' then 'Skipped' else 'Claimed' end, v_why)
  returning id into v_id;

  if v_channel = 'None' then return; end if;
  return query select v_id, v_channel, v_dest, v_acc.name;
end;
$$;

