-- Zion Vocational Rehab CRM — 0232 taking somebody off the board
--
-- Two ways off, and they are not the same thing (owner, 22 Oct 2026).
--
--   **Make inactive** is a filing decision. Nobody is working this person
--   today, so their card leaves the board - and nothing else happens. The
--   authorizations stand, the billing stands, the record stands, and putting
--   them back is a note and a stage. Anybody who can move a card can do it,
--   because deciding a card does not belong on today's board is the same
--   kind of decision as deciding which column it sits in.
--
--   **Close** ends the work. It takes the open authorizations with it and
--   refuses while money is out with USOR. That stays with Admin, Intake &
--   Client Reports and Billing (0223).
--
-- Making somebody inactive used to be done by the screen: a direct update
-- and a line in the contact log, written in the server action. That put the
-- rule in one caller rather than in the database, so an import or the agent
-- could take a client off the board with no note and no log at all. It is a
-- function now, for the same reason move_client is.

/**
 * Off the board, with a note, and nothing else touched.
 *
 * The note is required here as it is for a move: a card that leaves without
 * one is a card nobody can account for later. It lands in three places - the
 * client's own contact log, the directory change log beside the status
 * change, and nowhere else, because nothing else changes.
 */
create or replace function public.deactivate_client(p_client uuid, p_note text)
returns table (name text, was text)
language plpgsql security definer set search_path = public as $$
declare
  v_name text;
  v_was  text;
begin
  if public.current_staff_id() is null then
    raise exception 'Only a member of staff takes a client off the board.'
      using errcode = 'insufficient_privilege';
  end if;
  if coalesce(btrim(p_note), '') = '' then
    raise exception 'Say why they are coming off the board.'
      using errcode = 'check_violation';
  end if;

  select c.name, c.status into v_name, v_was
    from public.clients c where c.id = p_client for update;
  if not found then
    raise exception 'That client is not there.' using errcode = 'no_data_found';
  end if;
  if v_was = 'Inactive' then
    raise exception '% is already off the board.', v_name using errcode = 'check_violation';
  end if;
  if v_was = 'Closed' then
    raise exception '% is closed, which is further than off the board.', v_name
      using errcode = 'check_violation';
  end if;

  -- The reason rides on the setting the client change log reads, so the
  -- status change carries it without a second copy being written here.
  perform set_config('zion.directory_reason', btrim(p_note), true);
  update public.clients set status = 'Inactive' where id = p_client;
  perform set_config('zion.directory_reason', '', true);

  insert into public.contact_log (client_id, date, method, topic, outcome, staff_id)
  values (p_client, public.practice_today(), 'Off the board',
          'Made inactive from ' || v_was, btrim(p_note), public.current_staff_id());

  name := v_name;
  was := v_was;
  return next;
end;
$$;

comment on function public.deactivate_client is
  'Takes a client off the board with a note, changing nothing else (0232). Anybody who can move a card may do it; Close is the other, narrower way off.';

revoke all on function public.deactivate_client(uuid, text) from anon, authenticated;
grant execute on function public.deactivate_client(uuid, text) to authenticated;
