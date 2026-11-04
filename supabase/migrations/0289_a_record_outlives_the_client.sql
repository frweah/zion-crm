-- A record outlives the client: detach, never drop
--
-- Deleting a client was effectively impossible. Four append-only logs refused
-- it, and between them they cover almost every real client:
--
--   * `sms_consent_events` - cascade, so the consent record would be dropped,
--     and the guard refused the delete. Which is the right instinct and the
--     wrong answer: consent and opt-out are the practice's proof under the
--     TCPA that it was allowed to text somebody, and they have to outlive the
--     client record by years.
--   * `client_document_events` - the same, and reached twice over, because
--     deleting an attachment cascades into the document log too. Every client
--     with a single document on file was undeletable.
--   * `portal_activity` and `portal_consents` - restrict, and `delete_client`
--     deleted them explicitly, which the guard refused.
--
-- So `delete_client` worked only on a client with nothing on them, which is
-- not the client anybody needs to delete.
--
-- The answer the practice already had, in one place. `access_log` has carried
-- this exact carve-out since 0178: a client being deleted empties the row's
-- pointer, and who looked and what they did is untouched. 0193 did it again
-- for `authorization_corrections`. Third and fourth time is a family, so the
-- test is written once:
--
--     detaching_from_a_gone_client(to_jsonb(old), to_jsonb(new), array[...])
--
-- which is true only when the named pointers went from something to **null**,
-- the client they named is really gone, and nothing else on the row changed by
-- so much as a character. Anything else is somebody editing the log, and the
-- guard refuses it as it always did.
--
-- The keys change from cascade and restrict to `on delete set null`, which is
-- what makes it a detach rather than a drop: the record stays, whole, with
-- everything that identifies what happened. A consent row keeps the phone
-- number it was given for - the number is the thing a TCPA question is about,
-- and it was never nullable.
--
-- `delete_client` needs no list of tables. Its counting loop already reads the
-- catalogue and sorts each table by its own key - 'c' for carried away, 'n'
-- for cleared - so these four move from one half of the record to the other by
-- themselves, and `client_deletions` says so.

-- ─────────────────────────────────────────────────────────────
-- The test, once

create or replace function public.detaching_from_a_gone_client(
  p_old  jsonb,
  p_new  jsonb,
  p_cols text[]
)
returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(
    -- At least one of the named pointers is being emptied.
    exists (select 1 from unnest(p_cols) c
             where (p_old ->> c) is not null and (p_new ->> c) is null)
    -- And none of them is being set to anything: a log row repointed at a
    -- different client, or given a pointer it never had, is not a detach.
    and not exists (select 1 from unnest(p_cols) c where (p_new ->> c) is not null
                     and (p_new ->> c) is distinct from (p_old ->> c))
    -- Only a cascade ever sees a client that is already gone; nobody working
    -- in the app can arrange for one (0178). A row whose client pointer is
    -- already empty is one a cascade has been through before - the pointers
    -- empty one statement per key, so the second statement finds the first
    -- one's work already done.
    and case when (p_old ->> 'client_id') is not null
             then public.client_is_gone((p_old ->> 'client_id')::uuid)
             else true end
    -- And nothing else on the row moved, by so much as a character.
    --
    -- No test reaches this clause, and it is worth saying so rather than
    -- letting somebody think it is covered. To exercise it you would need a
    -- row still pointing at a client who is already gone, being updated in a
    -- way that empties the pointer and changes something else in the same
    -- statement - and only a referential action ever produces the first half
    -- of that, which is the whole reason the carve-out is safe (0178). It
    -- stays because it is the clause that makes "detach" mean detach.
    and (p_old - p_cols) = (p_new - p_cols),
    false)
$$;

comment on function public.detaching_from_a_gone_client is
  'True when a row is only losing its pointers to a client that has been deleted. Lets an append-only guard tell a detach apart from somebody editing the log.';

revoke all on function public.detaching_from_a_gone_client(jsonb, jsonb, text[]) from anon, authenticated;

-- ─────────────────────────────────────────────────────────────
-- Consent, which is the one that matters most

alter table public.sms_consent_events alter column client_id drop not null;
alter table public.sms_consent_events drop constraint sms_consent_events_client_id_fkey;
alter table public.sms_consent_events add constraint sms_consent_events_client_id_fkey
  foreign key (client_id) references public.clients(id) on delete set null;

create or replace function public.sms_consent_append_only()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  -- A client being deleted empties this row's pointer. What they agreed to,
  -- when, for which number and by what method is untouched: that is the
  -- practice's proof it was allowed to text them, and it outlives the record.
  if tg_op = 'UPDATE'
     and public.detaching_from_a_gone_client(to_jsonb(old), to_jsonb(new), array['client_id']) then
    return new;
  end if;
  raise exception 'A consent record cannot be changed. Record the new state instead.'
    using errcode = 'check_violation';
end $$;

-- ─────────────────────────────────────────────────────────────
-- The document log, which every client with a file on them had

create or replace function public.client_document_events_append_only()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE'
     and public.detaching_from_a_gone_client(to_jsonb(old), to_jsonb(new), array['client_id']) then
    return new;
  end if;
  raise exception 'The document log is a record; it is added to, never changed or removed.'
    using errcode = 'insufficient_privilege';
end $$;

-- Two rows name a client that is not on file, from 22 and 23 October. The
-- cascade could not have taken them: deleting an attachment fires an AFTER
-- trigger that writes to this log, so the deletion of the last client was
-- logged *after* the client row had gone, and the key was never asked about
-- the row that resulted. They point at nothing, so their pointers are emptied
-- rather than invented - which is the same detach everything else in this file
-- does, applied to the rows that got there first.
do $$
declare v_n integer;
begin
  update public.client_document_events e set client_id = null
   where e.client_id is not null
     and not exists (select 1 from public.clients c where c.id = e.client_id);
  get diagnostics v_n = row_count;
  raise notice 'ok  % document log row(s) naming a client that is gone had their pointer emptied', v_n;
end $$;

alter table public.client_document_events drop constraint client_document_events_client_id_fkey;
alter table public.client_document_events add constraint client_document_events_client_id_fkey
  foreign key (client_id) references public.clients(id) on delete set null;

-- ─────────────────────────────────────────────────────────────
-- The portal's two logs
--
-- Both empty today, which is why this is cheap to put right now rather than
-- on the morning somebody needs a client deleted.

alter table public.portal_activity alter column client_id drop not null;
alter table public.portal_activity drop constraint portal_activity_client_id_fkey;
alter table public.portal_activity add constraint portal_activity_client_id_fkey
  foreign key (client_id) references public.clients(id) on delete set null;
alter table public.portal_activity drop constraint portal_activity_account_id_fkey;
alter table public.portal_activity add constraint portal_activity_account_id_fkey
  foreign key (account_id) references public.portal_accounts(id) on delete set null;

alter table public.portal_consents alter column client_id drop not null;
alter table public.portal_consents alter column account_id drop not null;
alter table public.portal_consents drop constraint portal_consents_client_id_fkey;
alter table public.portal_consents add constraint portal_consents_client_id_fkey
  foreign key (client_id) references public.clients(id) on delete set null;
-- Deferred, and this is the reason. A portal account goes with its client, so
-- deleting a client empties both pointers on this row - but one key at a time,
-- and in between there is a moment where the client pointer is already null
-- while the account pointer still names an account that has just been deleted.
-- Checked immediately, that moment is a violation and the delete fails;
-- checked at commit, both pointers are empty and the row is consistent. The
-- rule is unchanged: a consent row never points at an account that is not
-- there. Only the instant it is asked about moves.
alter table public.portal_consents drop constraint portal_consents_account_id_fkey;
alter table public.portal_consents add constraint portal_consents_account_id_fkey
  foreign key (account_id) references public.portal_accounts(id) on delete set null
  deferrable initially deferred;

create or replace function public.portal_append_only()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  -- The account goes with the client, so both pointers empty together. What
  -- somebody agreed to on the portal, and when, stays - the same reason the
  -- texting consent does.
  if tg_op = 'UPDATE'
     and public.detaching_from_a_gone_client(to_jsonb(old), to_jsonb(new),
                                             array['client_id', 'account_id']) then
    return new;
  end if;
  raise exception '% is a record of what happened; it is added to, never changed or removed.', tg_table_name
    using errcode = 'insufficient_privilege';
end $$;
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

  -- The portal's two logs are not deleted any more. They are records of what
  -- somebody was told and what they agreed to, and they outlive the client
  -- with their pointers emptied, the same way the access log and the texting
  -- consent do (0289). Their keys do that by themselves, so there is nothing
  -- to do here but stop doing it.

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
$function$

;
