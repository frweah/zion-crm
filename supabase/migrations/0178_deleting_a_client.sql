-- Zion Vocational Rehab CRM — deleting a client
--
-- Admin can close a client, and closing is right nearly always: the record
-- stays, the history reads true, and §9's working list stops showing their
-- work. What there was no way to do is remove somebody who should never have
-- been a record at all — a duplicate typed twice, a referral entered against
-- the wrong person, a test somebody made on the live site.
--
-- So: a delete that is hard to do by accident and impossible to do quietly.
--
--   Admin's alone, and through this function only — DELETE is revoked from
--   everybody, the same way entering a bill goes through one door (§10).
--
--   A reason is required. Not asked for afterwards: afterwards there is
--   nothing left to attach it to, which is the whole problem with deleting
--   things.
--
--   Refused while any authorization is Submitted or Paid. Money has been
--   asked for or has moved. Those are closed first, deliberately, by somebody
--   who can see what they are.
--
--   Refused while the ledger holds postings naming them. That is the books,
--   and the books are not edited by deleting something else.
--
--   Refused under a legal hold, and refused while a records request exists. A
--   hold is there to stop exactly this. A records request is a legal
--   obligation discharged, and erasing the evidence of it along with the
--   client is not something to do in one click.
--
--   Recorded first, deleted second: what was removed, who removed it, why,
--   and how much went with it, in a table the delete cannot reach.
--
-- ─────────────────────────────────────────────────────────────
-- What the delete runs into, and what gives way
--
-- Thirty-three tables name a client, and they fall into two groups. Twenty-one
-- cascade, which is the point: notes, tasks, forms, attachments, their
-- authorizations - the client's own record. Eight keep their row and let the
-- client go, because they are the practice's record of what it did rather than
-- the client's: the access log, ledger lines, work sessions, expenses.
--
-- That second group is where this got interesting. Three of those eight are
-- append-only, and an emptied pointer is still an update, so they refused:
--
--   access_log       refuses every update, full stop
--   journal_lines    refuses every update, full stop
--   work_sessions    refuses any change to the fields that make a claim,
--                    client_id among them
--
-- Which meant a client who had ever been *looked at* could not be deleted,
-- and almost every client has been looked at. The feature did not work on a
-- single real record.
--
-- The ledger keeps its rule, and the delete is refused instead - see above.
-- The other two learn one narrow exception: a client_id may go from a value to
-- null, and only to null, and only when that client no longer exists. Nothing
-- a row asserts is touched - the access log still says who opened what and
-- when, the time record still says who worked which hours on which day. The
-- only thing lost is the pointer to a record the practice has decided was
-- never real, and client_deletions keeps that name and that id.
--
-- The exception cannot be used as an edit, which is the whole reason it is
-- phrased this way: from a screen the client still exists, so the guard
-- refuses exactly as before. Only the referential action, firing after the
-- parent row is gone, ever sees the state that allows it.
-- ─────────────────────────────────────────────────────────────

create table if not exists public.client_deletions (
  id              uuid primary key default gen_random_uuid(),
  seq             bigserial,
  client_id       uuid not null,
  client_name     text not null,
  client_no       integer,
  agency_id       text not null default '',
  stage           text not null default '',
  status          text not null default '',
  reason          text not null,
  carried         jsonb not null default '{}'::jsonb,
  cleared         jsonb not null default '{}'::jsonb,
  deleted_by      uuid references public.staff (id),
  deleted_by_name text not null default '',
  at              timestamptz not null default now(),
  constraint client_deletions_reason_said check (btrim(reason) <> '')
);

comment on table public.client_deletions is
  'What was removed when a client was deleted, who removed it and why. No foreign key to clients: the row has to outlive the thing it is about.';
comment on column public.client_deletions.carried is
  'How many rows went with them, per table, counted before the delete — so "it cascaded cleanly" is a number somebody can read rather than a claim.';
comment on column public.client_deletions.cleared is
  'How many rows kept their own record and had the pointer to this client emptied, per table. The other half of the same question.';

alter table public.client_deletions enable row level security;

drop policy if exists client_deletions_admin_reads on public.client_deletions;
create policy client_deletions_admin_reads on public.client_deletions
  for select using ((select public.is_admin()));

grant select on public.client_deletions to authenticated;

-- The agent reads and never writes, here as everywhere (0149).
select public.apply_system_read_only('public.client_deletions'::regclass);

/**
 * True when this id names no client — so a pointer to it is pointing at
 * nothing.
 *
 * Only one caller can ever see this: the referential action emptying a
 * pointer, which fires after the parent row has gone. From anywhere a person
 * works, the client is still there and this is false.
 */
create or replace function public.client_is_gone(p_client uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select p_client is not null
     and not exists (select 1 from public.clients where id = p_client)
$$;

comment on function public.client_is_gone is
  'True when no client has this id. Lets an append-only guard tell an emptied pointer apart from an edit.';

revoke all on function public.client_is_gone(uuid) from anon, authenticated;

-- ── the access log, with one pointer it may let go of ────────
create or replace function public.access_log_append_only()
returns trigger language plpgsql
security definer set search_path = public as $$
begin
  -- A client being deleted empties this row's pointer. Who looked, when, and
  -- what they did is untouched; client_deletions holds the name.
  if new.client_id is null and old.client_id is not null
     and public.client_is_gone(old.client_id)
     and to_jsonb(new) - 'client_id' = to_jsonb(old) - 'client_id' then
    return new;
  end if;
  raise exception 'The access log cannot be changed.' using errcode = 'check_violation';
end;
$$;

-- ── and a time record, on the same terms ─────────────────────
create or replace function public.work_sessions_append_only()
returns trigger language plpgsql
security definer set search_path = public as $$
declare
  pointer_emptied boolean := new.client_id is null
                         and old.client_id is not null
                         and public.client_is_gone(old.client_id);
begin
  if new.staff_id      is distinct from old.staff_id
  or new.worked_on     is distinct from old.worked_on
  or new.hours         is distinct from old.hours
  or new.description   is distinct from old.description
  or (new.client_id    is distinct from old.client_id and not pointer_emptied)
  or new.corrects_id   is distinct from old.corrects_id
  or new.created_by    is distinct from old.created_by then
    raise exception
      'A time record cannot be edited. Add a correction referencing this entry and say why.'
      using errcode = 'check_violation';
  end if;

  if old.category is not null and new.category is distinct from old.category then
    raise exception
      'The category on a time record cannot be changed. Add a correction referencing this entry and say why.'
      using errcode = 'check_violation';
  end if;

  return new;
end;
$$;

/**
 * Remove a client, and say what was removed.
 *
 * Returns the audit row's id, so the caller can show what was recorded rather
 * than report success on its own authority.
 */
create or replace function public.delete_client(p_client uuid, p_reason text)
returns uuid
language plpgsql security definer set search_path = public as $$
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

  delete from public.clients where id = p_client;
  return v_id;
end;
$$;

comment on function public.delete_client is
  'Remove a client, with a reason, recording what went with them. Admin only; refused while billing has gone out, while the ledger names them, while a legal hold stands, or while a records request exists.';

revoke all on function public.delete_client(uuid, text) from anon, authenticated;
grant execute on function public.delete_client(uuid, text) to authenticated;

-- One door. A delete that does not come through the function carries no
-- reason and leaves nothing behind saying it happened.
revoke delete on public.clients from anon, authenticated;
