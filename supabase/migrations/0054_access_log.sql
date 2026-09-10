-- ─────────────────────────────────────────────────────────────
-- 10.1 — who read what
--
-- Every rule in this system so far has been about who may do something. This
-- one is about what was done, and it exists for a question nobody has asked
-- yet: a client, or USOR, wanting to know who has looked at their file.
--
-- An audit log that can be avoided is worse than none, because it will be
-- quoted as though it were complete. So the restricted tier stops being
-- readable at all. SELECT on client_private and intakes is revoked from
-- everybody signed in, and the only way to those columns is a function that
-- writes the log first and returns the row second. Not a convention anybody
-- has to remember — the door is the only door.
--
-- What is not covered is said out loud rather than left to be discovered:
-- this logs reads through the application. Somebody with the service-role key
-- or the database password reads what they like, and no table inside the
-- database can stop that. The answer to those is that they are two secrets in
-- two places, not a log.
-- ─────────────────────────────────────────────────────────────

create table if not exists public.access_log (
  id           bigserial primary key,
  at           timestamptz not null default now(),

  -- Who, kept twice on purpose. staff_id is the link; staff_name is what the
  -- log says in two years when that person has left and their row has been
  -- deactivated, renamed, or their user deleted.
  staff_id     uuid references public.staff(id) on delete set null,
  staff_name   text not null default '',
  staff_role   text not null default '',

  subject      text not null check (subject in (
                 'Client restricted details',
                 'Client intake',
                 'Contractor tax number',
                 'Signed tax form'
               )),

  client_id    uuid references public.clients(id) on delete set null,
  about_staff  uuid references public.staff(id) on delete set null,

  -- Why it was opened, where the screen knows: "shown on the client record",
  -- "filled onto a USOR 94". A log of bare timestamps answers "did anybody
  -- look" and not "what for", and the second is the question that gets asked.
  purpose      text not null default ''
);

create index if not exists access_log_at_idx on public.access_log (at desc);
create index if not exists access_log_client_idx on public.access_log (client_id, at desc);
create index if not exists access_log_staff_idx on public.access_log (staff_id, at desc);

alter table public.access_log enable row level security;

drop policy if exists access_log_read on public.access_log;

-- Admin reads it. Nobody writes it from outside — there is no insert policy,
-- so every row in here got there through one of the functions below.
create policy access_log_read on public.access_log
  for select to authenticated using (public.is_admin());

create or replace function public.access_log_append_only()
returns trigger language plpgsql as $$
begin
  raise exception 'The access log cannot be changed.' using errcode = 'check_violation';
end;
$$;

drop trigger if exists access_log_no_edit on public.access_log;
create trigger access_log_no_edit before update or delete on public.access_log
  for each row execute function public.access_log_append_only();

-- ─────────────────────────────────────────────────────────────
-- Writing an entry
--
-- Not granted to anybody. It is called by the definer functions below, which
-- run as the owner — a person who could call this directly could write "Rei
-- read this file" into the log, and a log that can be written by hand is
-- evidence of nothing.
-- ─────────────────────────────────────────────────────────────
create or replace function public.log_access(
  p_subject     text,
  p_client_id   uuid default null,
  p_about_staff uuid default null,
  p_purpose     text default ''
)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_id   uuid := public.current_staff_id();
  v_name text;
  v_role text;
begin
  select name, role into v_name, v_role from public.staff where id = v_id;

  insert into public.access_log (staff_id, staff_name, staff_role, subject,
                                 client_id, about_staff, purpose)
  values (v_id, coalesce(v_name, '(not a staff member)'), coalesce(v_role, ''),
          p_subject, p_client_id, p_about_staff, coalesce(p_purpose, ''));
end;
$$;

revoke execute on function public.log_access(text, uuid, uuid, text) from public;
revoke execute on function public.log_access(text, uuid, uuid, text) from authenticated;
revoke execute on function public.log_access(text, uuid, uuid, text) from anon;

-- ─────────────────────────────────────────────────────────────
-- The only way to a client's restricted details
--
-- Returns nothing rather than raising when the caller may not see them: that
-- is what the policy did before, and the panel already renders the difference
-- between "no row" and "not for you". A refusal is logged too — an attempt to
-- open a file somebody had no business in is more worth recording than a
-- successful one.
-- ─────────────────────────────────────────────────────────────
create or replace function public.read_client_private(
  p_client_id uuid,
  p_purpose   text default ''
)
returns table (dob date, address text, allowed boolean)
language plpgsql security definer set search_path = public as $$
begin
  if public.current_staff_id() is null then
    raise exception 'You are not signed in.' using errcode = 'insufficient_privilege';
  end if;

  if not public.can_see_restricted(p_client_id) then
    perform public.log_access('Client restricted details', p_client_id, null,
                              coalesce(nullif(p_purpose, ''), 'refused') || ' — refused');
    return query select null::date, null::text, false;
    return;
  end if;

  perform public.log_access('Client restricted details', p_client_id, null, p_purpose);

  return query
    select p.dob, p.address, true
      from public.client_private p
     where p.client_id = p_client_id;
end;
$$;

revoke execute on function public.read_client_private(uuid, text) from public;
grant execute on function public.read_client_private(uuid, text) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- And to an intake
-- ─────────────────────────────────────────────────────────────
drop function if exists public.read_client_intake(uuid, text);
create function public.read_client_intake(
  p_client_id uuid,
  p_purpose   text default ''
)
returns table (
  phone text, email text, address text,
  emergency_name text, emergency_phone text,
  goals text, availability text, transportation text, accommodations text,
  -- Both of these are dates on the table, not timestamps. Declaring one as a
  -- timestamptz here typechecked at creation and failed at the first call
  -- that actually returned a row, with an error naming neither the column nor
  -- the type.
  submitted_at date, updated_on date, allowed boolean
)
language plpgsql security definer set search_path = public as $$
begin
  if public.current_staff_id() is null then
    raise exception 'You are not signed in.' using errcode = 'insufficient_privilege';
  end if;

  if not public.can_see_restricted(p_client_id) then
    perform public.log_access('Client intake', p_client_id, null,
                              coalesce(nullif(p_purpose, ''), 'refused') || ' — refused');
    return query select null::text, null::text, null::text, null::text, null::text,
                        null::text, null::text, null::text, null::text,
                        null::date, null::date, false;
    return;
  end if;

  perform public.log_access('Client intake', p_client_id, null, p_purpose);

  return query
    select i.phone, i.email, i.address, i.emergency_name, i.emergency_phone,
           i.goals, i.availability, i.transportation, i.accommodations,
           i.submitted_at, i.updated_on, true
      from public.intakes i
     where i.client_id = p_client_id;
end;
$$;

revoke execute on function public.read_client_intake(uuid, text) from public;
grant execute on function public.read_client_intake(uuid, text) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- Saving an intake, without reading one
--
-- The save used to check whether a row existed before deciding to insert or
-- update, which is a read — and once the table is sealed, a read it cannot
-- do. Conflict handling moves in here, where the database was doing it
-- anyway, and updated_on is set only when there was something to update.
-- ─────────────────────────────────────────────────────────────
-- Returns whether this was the first submission, because the screen needs to
-- know — a first intake moves the client from Referral to Intake and raises
-- the assessment task. It used to find that out by reading the table first,
-- which is now a logged read of the very record being written.
drop function if exists public.save_intake(uuid, jsonb);

create function public.save_intake(p_client_id uuid, p_data jsonb)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  v_staff uuid := public.current_staff_id();
  v_first boolean;
begin
  if v_staff is null then
    raise exception 'You are not signed in.' using errcode = 'insufficient_privilege';
  end if;
  if public.current_staff_role() not in ('Admin', 'Job Search', 'Reports')
     or not public.can_see_restricted(p_client_id) then
    raise exception
      'This record is limited to Admin, Intake & Reports, or this client''s assigned staff member.'
      using errcode = 'insufficient_privilege';
  end if;

  select not exists (select 1 from public.intakes where client_id = p_client_id)
    into v_first;

  insert into public.intakes (
    client_id, phone, email, address, emergency_name, emergency_phone,
    goals, availability, transportation, accommodations, consent_signed, staff_id
  )
  values (
    p_client_id,
    -- Every one of these columns is NOT NULL with no default. A key the caller
    -- left out is an empty field, not a missing one.
    coalesce(p_data ->> 'phone', ''), coalesce(p_data ->> 'email', ''),
    coalesce(p_data ->> 'address', ''),
    coalesce(p_data ->> 'emergency_name', ''), coalesce(p_data ->> 'emergency_phone', ''),
    coalesce(p_data ->> 'goals', ''), coalesce(p_data ->> 'availability', ''),
    coalesce(nullif(p_data ->> 'transportation', ''), 'Own vehicle'),
    coalesce(p_data ->> 'accommodations', ''), true, v_staff
  )
  on conflict (client_id) do update set
    phone = excluded.phone, email = excluded.email, address = excluded.address,
    emergency_name = excluded.emergency_name, emergency_phone = excluded.emergency_phone,
    goals = excluded.goals, availability = excluded.availability,
    transportation = excluded.transportation, accommodations = excluded.accommodations,
    consent_signed = true, staff_id = v_staff,
    updated_on = public.practice_today();

  return v_first;
end;
$$;

revoke execute on function public.save_intake(uuid, jsonb) from public;
grant execute on function public.save_intake(uuid, jsonb) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- Reading a tax number is worth recording
--
-- Unchanged except for the line that writes it down. Admin may read a
-- contractor's TIN; that they did should not be something only they know.
-- ─────────────────────────────────────────────────────────────
create or replace function public.get_contractor_tin(p_staff_id uuid)
returns text
-- extensions is on the path because pgcrypto lives there and pgp_sym_decrypt
-- is in it. 0016 exists solely because that was left off once already; this
-- rewrite dropped it again, and verify_tax caught it.
language plpgsql security definer set search_path = public, vault, extensions
as $$
declare
  k text;
  e bytea;
begin
  if not public.is_admin() then
    perform public.log_access('Contractor tax number', null, p_staff_id, 'refused');
    raise exception 'Only Admin can read a TIN.' using errcode = 'insufficient_privilege';
  end if;

  select tin_encrypted into e from public.contractor_profiles where staff_id = p_staff_id;
  if e is null then return null; end if;

  perform public.log_access('Contractor tax number', null, p_staff_id, '');

  select decrypted_secret into k from vault.decrypted_secrets where name = 'zion_tin_key';
  return pgp_sym_decrypt(e, k);
end;
$$;

revoke execute on function public.get_contractor_tin(uuid) from public;
grant execute on function public.get_contractor_tin(uuid) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- Opening a filed tax form
--
-- The PDF lives in storage, so the database cannot be the door. What it can
-- do is refuse to say the download is allowed without writing down that it
-- said so — the application asks here first and mints the link second.
-- ─────────────────────────────────────────────────────────────
create or replace function public.note_tax_form_access(p_submission_id uuid)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  v_staff uuid;
begin
  if not public.is_admin() then
    perform public.log_access('Signed tax form', null, null, 'refused');
    return false;
  end if;

  select staff_id into v_staff from public.tax_form_submissions where id = p_submission_id;
  if v_staff is null then return false; end if;

  perform public.log_access('Signed tax form', null, v_staff, 'opened the filed PDF');
  return true;
end;
$$;

revoke execute on function public.note_tax_form_access(uuid) from public;
grant execute on function public.note_tax_form_access(uuid) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- Sealing the tables
--
-- The lesson of 0039, applied on purpose this time: a policy decides which
-- rows, and a grant decides whether the table can be read at all. Without
-- this the functions above are a convention, and a convention is what
-- somebody works around at half past five on a Friday.
-- ─────────────────────────────────────────────────────────────
revoke select on public.client_private from authenticated;
revoke select on public.intakes from authenticated;

comment on table public.access_log is
  'Who read restricted client details, an intake, a contractor tax number or a filed tax form. Append-only, Admin-readable, and written only by the functions that are the sole way to those things.';
