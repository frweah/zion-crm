-- Zion Vocational Rehab CRM — 0231 a client with documents can be deleted
--
-- Deleting sixteen records that were never clients, fifteen went and one did
-- not:
--
--   insert or update on table "client_document_events" violates foreign key
--   constraint "client_document_events_client_id_fkey"
--
-- Not the rule refusing - the rule had already said yes. Both
-- client_document_events and attachments cascade from clients, so deleting
-- the client removes the attachments, and removing an attachment fires
-- client_document_log, which inserts an event naming the client. By the time
-- the foreign key is checked at the end of the statement the client is gone,
-- and the insert has nothing to point at.
--
-- So it is the same shape as the staff change log that made a staff row
-- undeletable: an audit trigger that fires while the thing it is auditing is
-- being removed. The fix is the same shape too - the log stands aside, and
-- only for the client actually being deleted, said with a setting that
-- delete_client sets and clears around the one statement.
--
-- Munahi Ngarambe was the one that stopped. She has documents on file; the
-- other fifteen did not, which is the only reason they went through.

CREATE OR REPLACE FUNCTION public.client_document_log()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  k_watched constant text[] := array['filename', 'document_date', 'category', 'restricted', 'note'];
  v_old     jsonb := case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) else '{}'::jsonb end;
  v_new     jsonb := case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) else '{}'::jsonb end;
  v_changes jsonb := '{}'::jsonb;
  v_key     text;
  v_row     public.attachments;
  v_me      uuid := public.current_staff_id();
  v_name    text;
  v_default boolean;
begin
  v_row := case when tg_op = 'DELETE' then old else new end;

  -- While the client is being deleted, their documents are going with them
  -- and there is nothing to write a history against. Writing one anyway is
  -- what stopped a deletion: the cascade removes the attachments, this
  -- trigger inserts an event naming the client, and the client is gone by
  -- the time the foreign key is checked (0231).
  if coalesce(current_setting('zion.deleting_client', true), '') = v_row.client_id::text then
    return case when tg_op = 'DELETE' then old else new end;
  end if;

  if tg_op = 'UPDATE' then
    foreach v_key in array k_watched loop
      if (v_old -> v_key) is distinct from (v_new -> v_key) then
        v_changes := v_changes || jsonb_build_object(v_key,
          jsonb_build_object('from', v_old -> v_key, 'to', v_new -> v_key));
      end if;
    end loop;
    -- A save that moved none of the fields a person edits is not news.
    if v_changes = '{}'::jsonb then
      return null;
    end if;
  end if;

  /**
   * The default declined.
   *
   * On the way in, and on an edit that takes the restriction back off a
   * sensitive type. Written as its own key so it can be looked for, rather
   * than inferred later by joining the log to a category list that may have
   * changed its mind since.
   */
  if tg_op in ('INSERT', 'UPDATE') and not coalesce(v_row.restricted, false) then
    select restricted_by_default into v_default
      from public.client_file_categories where key = v_row.category;
    if coalesce(v_default, false) then
      v_changes := v_changes || jsonb_build_object('restricted_default_declined',
        jsonb_build_object('category', v_row.category, 'by', coalesce(v_me::text, 'the system')));
    end if;
  end if;

  select name into v_name from public.staff where id = v_me;

  insert into public.client_document_events
    (attachment_id, client_id, filename, category, restricted, action, changes, staff_id, staff_name)
  values (v_row.id, v_row.client_id, coalesce(v_row.filename, ''), coalesce(v_row.category, ''),
          coalesce(v_row.restricted, false),
          case tg_op when 'INSERT' then 'Added' when 'DELETE' then 'Removed' else 'Edited' end,
          v_changes, v_me, coalesce(v_name, 'the system'));
  return null;
end;
$function$;

CREATE OR REPLACE FUNCTION public.delete_client(p_client uuid, p_reason text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  cl        public.clients;
  v_staff   uuid := public.current_staff_id();
  v_name    text;
  v_blocked text;
  v_carried jsonb := '{}'::jsonb;
  v_cleared jsonb := '{}'::jsonb;
  v_n       bigint;
  v_id      uuid;
  t         text;
  d         text;
begin
  if public.current_staff_role() is distinct from 'Admin' then
    raise exception 'Only an Admin deletes a client.'
      using errcode = 'insufficient_privilege';
  end if;

  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'Say why this client is being deleted.'
      using hint = 'There will be nothing left to attach the reason to afterwards.',
            errcode = 'check_violation';
  end if;

  select * into cl from public.clients where id = p_client;
  if not found then
    raise exception 'That client is not there.' using errcode = 'no_data_found';
  end if;

  -- ── what stops it ───────────────────────────────────────────
  select string_agg(coalesce(nullif(a.number, ''), a.service_type) ||
                    ' (' || a.status || ')', ', ' order by a.status, a.number)
    into v_blocked
    from public.authorizations a
   where a.client_id = p_client
     and a.status in ('Submitted', 'Paid');
  if v_blocked is not null then
    raise exception 'That client has billing that has gone out or been paid: %', v_blocked
      using hint = 'Close those authorizations first — the ledger holds postings against them.',
            errcode = 'check_violation';
  end if;

  select count(*) into v_n from public.journal_lines where client_id = p_client;
  if v_n > 0 then
    raise exception 'The ledger holds % posting(s) naming that client.', v_n
      using hint = 'That is the practice''s books. Close the client instead — closing keeps the record and takes their work off the list.',
            errcode = 'check_violation';
  end if;

  if exists (select 1 from public.legal_holds h
              where h.client_id = p_client and h.lifted_at is null) then
    raise exception 'That client is under a legal hold.'
      using hint = 'A hold is there to stop this. Lift it first, with a reason.',
            errcode = 'check_violation';
  end if;

  if exists (select 1 from public.records_requests r where r.client_id = p_client) then
    raise exception 'A records request has been made for that client.'
      using hint = 'That is a legal obligation on the record. It is not deleted in one click.',
            errcode = 'check_violation';
  end if;

  -- ── what is about to happen, counted ────────────────────────
  -- Read from the catalogue rather than from a list somebody has to keep up to
  -- date, so a table added next year is counted too — and counted into the
  -- right half, because the key itself says which half it is in.
  for t, d in
    select rel.relname, con.confdeltype
      from pg_constraint con
      join pg_class rel on rel.oid = con.conrelid
     where con.confrelid = 'public.clients'::regclass
       and con.contype = 'f'
       and con.confdeltype in ('c', 'n')
       and rel.relname <> 'clients'
     order by rel.relname
  loop
    execute format('select count(*) from public.%I where client_id = $1', t)
      using p_client into v_n;
    if v_n > 0 then
      if d = 'c' then
        v_carried := v_carried || jsonb_build_object(t, v_n);
      else
        v_cleared := v_cleared || jsonb_build_object(t, v_n);
      end if;
    end if;
  end loop;

  select name into v_name from public.staff where id = v_staff;

  insert into public.client_deletions
    (client_id, client_name, client_no, agency_id, stage, status, reason,
     carried, cleared, deleted_by, deleted_by_name)
  values (cl.id, cl.name, cl.client_no, coalesce(cl.agency_id, ''),
          coalesce(cl.stage, ''), coalesce(cl.status, ''), btrim(p_reason),
          v_carried, v_cleared, v_staff, coalesce(v_name, ''))
  returning id into v_id;

  -- The portal's own rows are held out of a client's reach by a restricting
  -- key, which is there to stop an accident rather than to stop this.
  delete from public.portal_activity where client_id = p_client;
  delete from public.portal_consents where client_id = p_client;

  -- A record merged into this one points at it. The pointer goes; the merged
  -- record stays, because it is somebody else's history.
  update public.clients set merged_into = null where merged_into = p_client;

  -- Said out loud for the document log, which would otherwise write an
  -- event about a client that is halfway out of the door (0231).
  perform set_config('zion.deleting_client', p_client::text, true);
  delete from public.clients where id = p_client;
  perform set_config('zion.deleting_client', '', true);
  return v_id;
end;
$function$;
