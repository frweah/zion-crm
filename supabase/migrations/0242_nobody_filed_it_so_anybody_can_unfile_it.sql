-- Zion Vocational Rehab CRM — 0242 nobody filed it, so anybody can unfile it
--
-- Two of the owner's instructions pull against each other, and the resolution
-- is worth writing down rather than picking quietly.
--
--   "Replies to a filed thread file onto the same client, marked auto;
--    **anyone can unfile one**."
--   "Unfile: the person who filed, or Admin."
--
-- `unfile_mail` was built to the second, and under the second an auto-filed
-- reply can only be unfiled by an Admin - because nobody filed it, so
-- `filed_by` is null, so nobody is the person who filed it.
--
-- They are not actually in conflict. The second rule exists because the
-- person who put something on a record is the one who knows whether it
-- belonged there; the first says what to do when nobody put it there. An
-- auto-filed reply is the one case where there is no such person to defer to,
-- and leaving it to Admin alone would mean the staff member who can see the
-- mistake cannot fix it.
--
-- So: a message nobody filed can be taken off by anybody on the staff. A
-- message somebody filed - by hand, or by sending it - stays theirs or
-- Admin's.

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

  -- Nobody chose this one, so there is nobody to defer to (0242).
  if v_row.filed_how is distinct from 'auto'
     and not public.is_admin()
     and v_row.filed_by is distinct from v_me then
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
  'Takes a filed message off a client with a reason. The filer or an Admin - or anybody, when nobody filed it (0242).';

revoke all on function public.unfile_mail(uuid, text) from anon, authenticated;
grant execute on function public.unfile_mail(uuid, text) to authenticated;
