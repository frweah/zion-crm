-- Zion Vocational Rehab CRM — 0248 anybody can take off what nobody filed
--
-- 0242 let anybody on the staff unfile a reply that filed itself, because
-- nobody filed it and so there is nobody to defer to. The same reasoning
-- applies with more force to a message the sweep merely recognised by address
-- (owner, 23 Oct 2026): not only did nobody choose it, nobody even read it.
--
-- So the rule is one sentence rather than a list: **a message somebody chose
-- to put on a client can be taken off by that person or an Admin; a message
-- nobody chose can be taken off by anybody on the staff.** "Chose" is
-- `filed_how in ('by hand', 'sent')`, which is exactly the two values that
-- record a person in `filed_by`.
--
-- A reason is still required either way. Unfiling is logged, and a log with
-- no reason in it only says that somebody did something.

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

  -- Somebody chose this one, so it is theirs or Admin's to undo. Nobody chose
  -- an "auto" or a "matched" one (0242, 0248).
  if v_row.filed_how in ('by hand', 'sent')
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
  'Takes a filed message off a client with a reason. What somebody chose is theirs or Admin''s to undo; what nobody chose, anybody may (0248).';

revoke all on function public.unfile_mail(uuid, text) from anon, authenticated;
grant execute on function public.unfile_mail(uuid, text) to authenticated;
