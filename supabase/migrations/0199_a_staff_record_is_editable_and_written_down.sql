-- Zion Vocational Rehab CRM — a staff record is editable, and written down
-- (owner, 14 Oct 2026, items 2 and 4)
--
-- Two asks that share one shape. Rispah needs a second address on her record,
-- and an Admin needs to be able to change every field on anybody's record and
-- upload documents on their behalf, with a record of who did it.
--
-- ── why this log is not the directory log ───────────────────
--
-- Clients and counselors write their changes to directory_changes, and the
-- obvious move was to add staff to it. That would have been a privacy leak:
-- directory_changes is readable by every member of staff, on purpose, because
-- it is a directory of offices and counselors. A staff record carries pay
-- rates, a start date and a home phone number, and the diff this log keeps
-- holds the old and new value of every field that moved.
--
-- Adding staff to it would have put everybody's pay rate in front of
-- everybody. So staff changes go to a log of their own that only an Admin can
-- read. Two logs, and the reason is the readership rather than an oversight.
--
-- ── and nothing here lets an Admin be somebody else ─────────
--
-- The owner was explicit about the line: an Admin may fill in anybody's
-- details and upload anybody's documents, but may not sign their tax form or
-- their policy, and may not give texting or e-delivery consent on their
-- behalf. Those are the person's own act, and a signature somebody else
-- applied is not a signature.
--
-- That line is enforced where those things are written rather than here -
-- 0200 does it - because a constraint on a signature table is a sentence and
-- a convention in a screen is a hope.

-- ─────────────────────────────────────────────────────────────
-- 1. A person's other addresses
--
-- Rispah signs in as rispah@zionpersonalcareagency.com and is also written to
-- at Rispah@zionvocrehab.com. The sign-in address stays where it is, on
-- staff.email, because that is what Supabase Auth matches and changing it
-- would lock her out. Everything else she is reachable at lives here.
-- ─────────────────────────────────────────────────────────────
create table if not exists public.staff_emails (
  id          uuid primary key default gen_random_uuid(),
  staff_id    uuid not null references public.staff(id) on delete cascade,
  address     text not null,
  note        text not null default '',
  added_by    uuid references public.staff(id) on delete set null,
  created_at  timestamptz not null default now(),
  constraint staff_emails_address_check
    check (address ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$')
);

-- One address, one person. Checked without regard to case, because an address
-- is not case-sensitive and two people cannot both own one.
create unique index if not exists staff_emails_address_once
  on public.staff_emails (lower(address));
create index if not exists staff_emails_person on public.staff_emails (staff_id);

comment on table public.staff_emails is
  'The other addresses a member of staff is written to, besides the one they sign in with. An alias here never changes how they sign in.';

alter table public.staff_emails enable row level security;

-- Read by any member of staff: knowing which address reaches a colleague is
-- the point of it. Changed by an Admin.
drop policy if exists staff_emails_read on public.staff_emails;
create policy staff_emails_read on public.staff_emails
  for select using ((select public.is_active_staff()));

drop policy if exists staff_emails_write on public.staff_emails;
create policy staff_emails_write on public.staff_emails
  for all using ((select public.is_admin())) with check ((select public.is_admin()));

revoke all on public.staff_emails from anon, authenticated;
grant select, insert, update, delete on public.staff_emails to authenticated;
select public.apply_system_read_only('staff_emails');

/**
 * An alias may not be somebody's sign-in address, or their own.
 *
 * Without this, Rispah's alias could be typed as a colleague's sign-in
 * address and two records would answer to one address - which is exactly the
 * ambiguity the resolver below has to not have.
 */
create or replace function public.staff_email_is_free()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_owner uuid;
begin
  select id into v_owner from public.staff where lower(email) = lower(btrim(new.address));
  if v_owner is not null and v_owner <> new.staff_id then
    raise exception 'That address is already how % signs in',
      (select name from public.staff where id = v_owner)
      using errcode = 'unique_violation';
  end if;
  new.address := btrim(new.address);
  return new;
end;
$$;

drop trigger if exists staff_emails_free on public.staff_emails;
create trigger staff_emails_free before insert or update on public.staff_emails
  for each row execute function public.staff_email_is_free();

-- ─────────────────────────────────────────────────────────────
-- Which person is this address?
--
-- One definition, so that the sign-in address and the aliases are never asked
-- about separately. Nothing in the CRM resolved an address to a member of
-- staff before this - the mail sweep matches clients and counselors and
-- deliberately keeps everything else out - so this is the hook an alias needs
-- rather than a change to what mail is stored.
-- ─────────────────────────────────────────────────────────────
create or replace function public.staff_by_email(p_address text)
returns uuid language sql stable security definer set search_path = public as $$
  select s.id from public.staff s
   where lower(s.email) = lower(btrim(coalesce(p_address, '')))
     and btrim(coalesce(p_address, '')) <> ''
  union all
  select e.staff_id from public.staff_emails e
   where lower(e.address) = lower(btrim(coalesce(p_address, '')))
     and btrim(coalesce(p_address, '')) <> ''
  limit 1;
$$;

comment on function public.staff_by_email is
  'The member of staff an address reaches, whether it is the one they sign in with or one of their aliases. One definition, so the two are never asked about separately.';

revoke all on function public.staff_by_email(text) from anon, authenticated;
grant execute on function public.staff_by_email(text) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- 2. What changed on a staff record, and who changed it
-- ─────────────────────────────────────────────────────────────
create table if not exists public.staff_record_changes (
  id              uuid primary key default gen_random_uuid(),
  seq             bigserial,
  at              timestamptz not null default now(),
  staff_id        uuid references public.staff(id) on delete set null,
  staff_name      text not null default '',
  part            text not null check (part in ('Details', 'Address', 'Employment', 'Pay', 'Document')),
  action          text not null check (action in ('Added', 'Edited', 'Removed')),
  changes         jsonb not null default '{}'::jsonb,
  note            text not null default '',
  changed_by      uuid references public.staff(id) on delete set null,
  changed_by_name text not null default '',
  /** True when somebody did this to another person's record rather than their own. */
  on_behalf       boolean not null default false
);
create index if not exists staff_record_changes_person
  on public.staff_record_changes (staff_id, seq desc);
create index if not exists staff_record_changes_recent
  on public.staff_record_changes (seq desc);

comment on table public.staff_record_changes is
  'What changed on a staff record, from what to what, by whom, and whether they were doing it to somebody else. Admin reads it: unlike the directory log this holds pay rates and personal details, so it is not for everybody.';

alter table public.staff_record_changes enable row level security;

-- An Admin, or the person themselves reading their own history. Not everybody,
-- which is the whole reason this is not directory_changes.
drop policy if exists staff_record_changes_read on public.staff_record_changes;
create policy staff_record_changes_read on public.staff_record_changes
  for select using (
    (select public.is_admin()) or staff_id = (select public.current_staff_id())
  );

revoke all on public.staff_record_changes from anon, authenticated;
grant select on public.staff_record_changes to authenticated;

-- The agent account reads; it never writes one of these. Applied by the same
-- function every other table uses (verify_system_account.sql sweeps every
-- table for it, and caught this one missing).
select public.apply_system_read_only('staff_record_changes');

-- It is a record: added to, never changed or removed.
create or replace function public.staff_record_changes_append_only()
returns trigger language plpgsql as $$
begin
  raise exception 'The staff change log is a record; it is added to, never changed or removed.'
    using errcode = 'insufficient_privilege';
end;
$$;

drop trigger if exists staff_record_changes_append_only on public.staff_record_changes;
create trigger staff_record_changes_append_only
  before update or delete on public.staff_record_changes
  for each row execute function public.staff_record_changes_append_only();

-- ── written by the database, whatever makes the change ──────
create or replace function public.staff_record_change_log()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  k_quiet constant text[] := array['created_at', 'updated_at', 'seq', 'id'];
  v_old     jsonb := case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) else '{}'::jsonb end;
  v_new     jsonb := case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) else '{}'::jsonb end;
  v_changes jsonb := '{}'::jsonb;
  v_key     text;
  v_part    text;
  v_person  uuid;
  v_name    text;
  v_staff   public.staff%rowtype;
begin
  v_part := case tg_table_name
    when 'staff'            then 'Details'
    when 'staff_emails'     then 'Address'
    when 'staff_employment' then 'Employment'
    when 'staff_pay'        then 'Pay'
    else null end;
  if v_part is null then
    raise exception 'The staff change log does not know what a row of % is', tg_table_name
      using hint = 'Name the table in staff_record_change_log and in the part check.';
  end if;

  v_person := coalesce((v_new ->> 'staff_id')::uuid, (v_old ->> 'staff_id')::uuid,
                       (v_new ->> 'id')::uuid, (v_old ->> 'id')::uuid);

  -- A person invented for a test is not news, however the write arrived.
  select * into v_staff from public.staff where id = v_person;
  if public.is_fixture_name(v_staff.name) then
    return null;
  end if;

  for v_key in select k from jsonb_object_keys(v_old || v_new) as k where not (k = any(k_quiet))
  loop
    if (v_old -> v_key) is distinct from (v_new -> v_key) then
      v_changes := v_changes || jsonb_build_object(v_key,
        jsonb_build_object('from', v_old -> v_key, 'to', v_new -> v_key));
    end if;
  end loop;
  if tg_op = 'UPDATE' and v_changes = '{}'::jsonb then
    return null;
  end if;

  select name into v_name from public.staff where id = public.current_staff_id();

  insert into public.staff_record_changes
    (staff_id, staff_name, part, action, changes, note, changed_by, changed_by_name, on_behalf)
  values (v_person, coalesce(v_staff.name, ''), v_part,
          case tg_op when 'INSERT' then 'Added' when 'DELETE' then 'Removed' else 'Edited' end,
          v_changes,
          coalesce(nullif(current_setting('zion.staff_change_note', true), ''), ''),
          public.current_staff_id(), coalesce(v_name, 'System'),
          public.current_staff_id() is distinct from v_person);
  return null;
end;
$$;

comment on function public.staff_record_change_log is
  'Records a change to a staff record - details, addresses, employment or pay - with who made it and whether they were acting on somebody else''s record. A trigger rather than a line in a screen, because the sweeps and the imports write these tables too.';

drop trigger if exists staff_details_log on public.staff;
create trigger staff_details_log after insert or update or delete on public.staff
  for each row execute function public.staff_record_change_log();

drop trigger if exists staff_emails_log on public.staff_emails;
create trigger staff_emails_log after insert or update or delete on public.staff_emails
  for each row execute function public.staff_record_change_log();

drop trigger if exists staff_employment_log on public.staff_employment;
create trigger staff_employment_log after insert or update or delete on public.staff_employment
  for each row execute function public.staff_record_change_log();

drop trigger if exists staff_pay_log on public.staff_pay;
create trigger staff_pay_log after insert or update or delete on public.staff_pay
  for each row execute function public.staff_record_change_log();

-- ─────────────────────────────────────────────────────────────
-- 3. Rispah's second address
-- ─────────────────────────────────────────────────────────────
select set_config('zion.staff_change_note',
  'Added by the owner, 14 Oct 2026. Her sign-in address is unchanged.', true);

insert into public.staff_emails (staff_id, address, note, added_by)
select s.id, 'Rispah@zionvocrehab.com',
       'Written to at the practice address; signs in as ' || s.email, s.id
  from public.staff s
 where lower(s.email) = 'rispah@zionpersonalcareagency.com'
   and not exists (
     select 1 from public.staff_emails e
      where lower(e.address) = lower('Rispah@zionvocrehab.com'));

select set_config('zion.staff_change_note', '', true);

do $$
declare
  v_id uuid;
begin
  v_id := public.staff_by_email('rispah@ZIONVOCREHAB.com');
  if v_id is null then
    raise exception 'The alias did not take: that address resolves to nobody.';
  end if;
  raise notice 'ok  % reaches %', 'Rispah@zionvocrehab.com',
    (select name from public.staff where id = v_id);
  raise notice 'ok  and she still signs in as %',
    (select email from public.staff where id = v_id);
end $$;

-- ─────────────────────────────────────────────────────────────
-- The note the log carries
--
-- A server action cannot run set_config() itself - it speaks to the database
-- over HTTP and every statement is its own transaction, so a transaction-local
-- setting would be gone before the write arrived. This sets it for the
-- connection, which is what a request has, and the screen clears it after.
--
-- It carries a note and nothing else: it cannot name a person, a field or a
-- value, so the worst it can do is mislabel a change the caller was already
-- allowed to make.
-- ─────────────────────────────────────────────────────────────
create or replace function public.set_staff_change_note(p_note text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then
    raise exception 'Only an Admin notes a change to a staff record.'
      using errcode = 'insufficient_privilege';
  end if;
  perform set_config('zion.staff_change_note', left(coalesce(p_note, ''), 500), false);
end;
$$;

comment on function public.set_staff_change_note is
  'Sets the note the staff change log carries for the writes that follow on this connection. Admin only, and it can say nothing about who or what changed - only why.';

revoke all on function public.set_staff_change_note(text) from anon, authenticated;
grant execute on function public.set_staff_change_note(text) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- A document changing hands is logged too
--
-- The triggers above cover the tables they are on. A document is not one of
-- those: the row lives in staff_files and the bytes live in storage, and
-- "replaced" is both of them moving together - so the screen that does it
-- says so, through here, rather than writing the log table directly (nothing
-- but a definer function may).
--
-- Admin, or the person themselves. part is fixed at 'Document' so this
-- cannot be used to forge a pay change.
-- ─────────────────────────────────────────────────────────────
create or replace function public.log_staff_document(
  p_staff uuid, p_action text, p_changes jsonb, p_note text default '')
returns void language plpgsql security definer set search_path = public as $$
declare
  v_me   uuid := public.current_staff_id();
  v_name text;
begin
  if v_me is null or not (public.is_admin() or v_me = p_staff) then
    raise exception 'You can record a document on your own file; an Admin can on anybody''s.'
      using errcode = 'insufficient_privilege';
  end if;
  if p_action not in ('Added', 'Edited', 'Removed') then
    raise exception '"%" is not something that happens to a document.', p_action
      using errcode = 'invalid_parameter_value';
  end if;

  select name into v_name from public.staff where id = v_me;

  insert into public.staff_record_changes
    (staff_id, staff_name, part, action, changes, note, changed_by, changed_by_name, on_behalf)
  values (p_staff, coalesce((select name from public.staff where id = p_staff), ''),
          'Document', p_action, coalesce(p_changes, '{}'::jsonb), left(coalesce(p_note, ''), 500),
          v_me, coalesce(v_name, 'System'), v_me is distinct from p_staff);
end;
$$;

comment on function public.log_staff_document is
  'Records that a document on somebody''s file was added, replaced or removed, and by whom. part is fixed at Document, so this cannot be used to write a pay change into the log.';

revoke all on function public.log_staff_document(uuid, text, jsonb, text) from anon, authenticated;
grant execute on function public.log_staff_document(uuid, text, jsonb, text) to authenticated;
