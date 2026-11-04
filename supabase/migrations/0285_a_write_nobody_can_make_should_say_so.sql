-- A write nobody is allowed to make should say so
--
-- `sms_messages` and `staff_files` each carry a **restrictive** policy for
-- UPDATE and nothing permissive. A restrictive policy only ever subtracts; it
-- never grants. So with no permissive policy for the command, every update and
-- delete by a signed-in staff member matched no rows - and matching no rows is
-- not an error. PostgREST reported success, the code carried on, and nobody
-- found out.
--
-- What that cost:
--
--   * **Every text a person has ever sent from a screen stayed on 'Queued'.**
--     `sendClientSms` inserts the row, sends the text, then updates it to
--     'Sent' with the provider's id. The update did nothing. The screen said
--     "Sent." and the list said "sending", and both were describing the same
--     successful send. `fail()` did nothing either, which is why not one of
--     the fifteen carried an error and why the 3 November outage looked like
--     GoHighLevel going quiet: eight of those fifteen were delivered, and two
--     were refused with a reason the practice never saw.
--
--   * **Cancelling a scheduled text did not cancel it.** The delete matched
--     nothing and the text went out at its window.
--
--   * **Replacing a document on somebody's staff file destroyed it.** The
--     update did nothing, reported no error, and the code then removed the old
--     object from storage - leaving the row pointing at bytes that are gone.
--
-- The fix is not a permissive UPDATE policy on either table. A policy wide
-- enough to let the status be recorded is wide enough to let a browser rewrite
-- a text's words, or point a document row at somebody else's file. These are
-- the system recording what happened, not a person editing a record, so they
-- are functions: the rules sit in the database, the caller passes what it
-- learned, and the write either happens or raises.
--
-- Both callers are provided for. The screen runs as the staff member and the
-- nightly reminder runs as the service role, where `auth.uid()` is null and
-- `is_active_staff()` is false - so the gate is `filing_caller_role()`, which
-- already exists for exactly this.

-- ─────────────────────────────────────────────────────────────
-- A text that went

create or replace function public.record_text_sent(p_id uuid, p_provider_id text default null)
returns uuid
language plpgsql security definer set search_path = public as $$
declare m public.sms_messages; v_who text := public.filing_caller_role();
begin
  if v_who not in ('service_role', 'Admin', 'Job Search', 'Reports') then
    raise exception 'Your role does not send texts.' using errcode = 'insufficient_privilege';
  end if;

  select * into m from public.sms_messages where id = p_id;
  if m.id is null then
    raise exception 'That text is not there.' using errcode = 'no_data_found';
  end if;
  if m.direction <> 'Outgoing' then
    raise exception 'That is a text that came in.' using errcode = 'check_violation';
  end if;

  -- Said once. A second call with the same id is the same text, not a second
  -- send, and the first answer is the one the provider gave.
  if m.status = 'Sent' then
    return p_id;
  end if;

  update public.sms_messages
     set status = 'Sent',
         sent_at = coalesce(sent_at, now()),
         error = '',
         provider_message_id = coalesce(nullif(btrim(coalesce(p_provider_id, '')), ''), provider_message_id)
   where id = p_id;

  return p_id;
end $$;

revoke all on function public.record_text_sent(uuid, text) from anon, authenticated;
grant execute on function public.record_text_sent(uuid, text) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- A text that did not

create or replace function public.record_text_failed(p_id uuid, p_error text)
returns uuid
language plpgsql security definer set search_path = public as $$
declare m public.sms_messages; v_who text := public.filing_caller_role();
begin
  if v_who not in ('service_role', 'Admin', 'Job Search', 'Reports') then
    raise exception 'Your role does not send texts.' using errcode = 'insufficient_privilege';
  end if;
  if coalesce(btrim(p_error), '') = '' then
    raise exception 'A text that did not go has to say why.' using errcode = 'check_violation';
  end if;

  select * into m from public.sms_messages where id = p_id;
  if m.id is null then
    raise exception 'That text is not there.' using errcode = 'no_data_found';
  end if;
  if m.direction <> 'Outgoing' then
    raise exception 'That is a text that came in.' using errcode = 'check_violation';
  end if;

  -- One the provider took is not a failure to record, whatever the caller
  -- thinks happened next: the message is on its way and saying otherwise
  -- invites somebody to send it again.
  if m.status = 'Sent' or coalesce(m.provider_message_id, '') <> '' then
    return p_id;
  end if;

  update public.sms_messages
     set status = 'Failed', error = left(p_error, 300)
   where id = p_id;

  return p_id;
end $$;

revoke all on function public.record_text_failed(uuid, text) from anon, authenticated;
grant execute on function public.record_text_failed(uuid, text) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- A text written for later, thought better of

create or replace function public.cancel_scheduled_text(p_id uuid)
returns uuid
language plpgsql security definer set search_path = public as $$
declare m public.sms_messages; v_who text := public.filing_caller_role();
begin
  if v_who not in ('service_role', 'Admin', 'Job Search', 'Reports') then
    raise exception 'Your role does not send texts.' using errcode = 'insufficient_privilege';
  end if;

  select * into m from public.sms_messages where id = p_id;
  if m.id is null then
    raise exception 'That text is not there.' using errcode = 'no_data_found';
  end if;
  if m.status <> 'Scheduled' then
    raise exception 'Only a text still waiting for its window can be called back.'
      using errcode = 'check_violation';
  end if;
  if coalesce(m.provider_message_id, '') <> '' then
    raise exception 'The provider has that message already.' using errcode = 'check_violation';
  end if;

  delete from public.sms_messages where id = p_id;
  return p_id;
end $$;

revoke all on function public.cancel_scheduled_text(uuid) from anon, authenticated;
grant execute on function public.cancel_scheduled_text(uuid) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- A document replaced on somebody's file
--
-- It returns the path it replaced, which is the fix: the caller removes the
-- old bytes only once the row really points at the new ones. The old code
-- removed them on an update that had quietly done nothing.

create or replace function public.replace_staff_document(
  p_file     uuid,
  p_path     text,
  p_filename text,
  p_mime     text,
  p_size     bigint
)
returns text
language plpgsql security definer set search_path = public as $$
declare
  f public.staff_files;
  v_me       uuid := public.current_staff_id();
  v_role     text := public.current_staff_role();
  v_active   boolean;
  v_owner    text;
  v_system   boolean;
  v_label    text;
  v_was      text;
begin
  if v_me is null then
    raise exception 'Only staff replace a document.' using errcode = 'insufficient_privilege';
  end if;
  if coalesce(btrim(p_path), '') = '' or coalesce(btrim(p_filename), '') = '' then
    raise exception 'The upload did not complete. Nothing was replaced.' using errcode = 'check_violation';
  end if;

  select * into f from public.staff_files where id = p_file;
  if f.id is null then
    raise exception 'That document is not there any more.' using errcode = 'no_data_found';
  end if;

  if f.staff_id <> v_me and v_role <> 'Admin' then
    raise exception 'You can replace one on your own file; Admin can on anybody''s.'
      using errcode = 'insufficient_privilege';
  end if;

  select s.active, s.name into v_active, v_owner from public.staff s where s.id = f.staff_id;
  if v_active is false then
    raise exception '% is inactive; their file is kept as it was, for retention and audits.', v_owner
      using errcode = 'check_violation';
  end if;

  select c.system_only, c.label into v_system, v_label
    from public.staff_file_categories c where c.key = f.category;
  if v_system then
    raise exception 'A % is produced from what somebody signed. Replacing the file under it would leave a signature over a document nobody signed - complete a new one in Paperwork instead.', v_label
      using errcode = 'check_violation';
  end if;

  v_was := f.storage_path;
  update public.staff_files
     set storage_path = p_path,
         filename     = p_filename,
         -- Both are not null on this table, so a blank from the browser
         -- keeps what was there rather than refusing the replacement over a
         -- field nobody looks at.
         mime_type    = coalesce(nullif(btrim(coalesce(p_mime, '')), ''), mime_type),
         size_bytes   = coalesce(nullif(p_size, 0), size_bytes)
   where id = p_file;

  -- The path that is now unused. Returned rather than deleted here: the bytes
  -- are in storage, which this function cannot reach, and the caller must not
  -- remove them before this update has happened.
  return v_was;
end $$;

revoke all on function public.replace_staff_document(uuid, text, text, text, bigint) from anon, authenticated;
grant execute on function public.replace_staff_document(uuid, text, text, text, bigint) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- Every one of them exists once, and is reachable from a screen
--
-- A second signature would leave the old call ambiguous, and a function the
-- browser cannot execute is the fault this file is fixing wearing different
-- clothes. The behaviour is asserted in `verify_a_write_that_does_nothing.sql`,
-- which can make a client and roll it back.

do $$
declare r record; v_n integer;
begin
  for r in
    select name from (values
      ('record_text_sent'), ('record_text_failed'),
      ('cancel_scheduled_text'), ('replace_staff_document')
    ) as t(name)
  loop
    select count(*) into v_n from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = r.name;
    if v_n <> 1 then
      raise exception '% exists at % signatures, not one', r.name, v_n;
    end if;

    select count(*) into v_n from information_schema.routine_privileges
     where routine_schema = 'public' and routine_name = r.name
       and grantee = 'authenticated' and privilege_type = 'EXECUTE';
    if v_n <> 1 then
      raise exception '% cannot be called from a screen', r.name;
    end if;
  end loop;
  raise notice 'ok  four functions, one signature each, all four reachable from a screen';
end $$;
