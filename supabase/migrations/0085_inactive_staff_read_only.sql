-- Zion Vocational Rehab CRM — an inactive member of staff's record is read-only
--
-- The owner decided (14 Sept 2026): when somebody leaves, their record stays
-- whole and readable - pay history, checklists, certifications, training and
-- documents - because retention and audits need it as it was. Nothing on it
-- changes after that. Not by Admin, not by the service role, not by a script.
--
-- The one exception is the offboarding checklist, which is by nature finished
-- after the person has gone: returning a laptop is ticked off the week after
-- the last day. Everything else - including the onboarding checklist - is
-- refused until the person is reactivated, which reopens the record.
--
-- Reading is untouched; only inserts, updates and deletes are refused.

create or replace function public.staff_record_frozen()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_row      record := case when tg_op = 'DELETE' then old else new end;
  v_person   public.staff%rowtype;
  v_phase    text;
  v_since    text;
begin
  select * into v_person from public.staff where id = v_row.staff_id;
  if not found or v_person.active then
    return v_row;
  end if;

  if tg_table_name = 'staff_checklist_items' then
    select phase into v_phase from public.checklist_tasks where id = v_row.task_id;
    if v_phase = 'Offboarding' then
      return v_row;
    end if;
  end if;

  v_since := coalesce(
    to_char(v_person.deactivated_at at time zone 'America/Denver', 'YYYY-MM-DD'),
    (select to_char(o.last_day, 'YYYY-MM-DD') from public.staff_offboarding o where o.staff_id = v_person.id),
    'a date that was not recorded');

  raise exception '% has been inactive since %. Their record is kept as it was, for retention and audits; reactivate them to change it.',
    v_person.name, v_since
    using errcode = 'insufficient_privilege';
end;
$$;

revoke execute on function public.staff_record_frozen() from public, anon, authenticated;

do $$
declare
  t text;
begin
  foreach t in array array['staff_pay', 'staff_credentials', 'ce_entries', 'staff_files', 'staff_employment', 'staff_checklist_items'] loop
    execute format('drop trigger if exists %I on public.%I', t || '_frozen_when_inactive', t);
    execute format(
      'create trigger %I before insert or update or delete on public.%I for each row execute function public.staff_record_frozen()',
      t || '_frozen_when_inactive', t);
  end loop;
end $$;

-- ── the stored files, not only their rows ──────────────────
-- A document is a row in staff_files and a file in the staff-files bucket,
-- kept under a folder named for the person. The trigger above holds the row;
-- this holds the file, so an inactive person's stored copy cannot be deleted
-- directly either. Compared as text, so a path that is not somebody's folder
-- is unaffected rather than an error.
drop policy if exists "zion delete staff files" on storage.objects;
create policy "zion delete staff files" on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'staff-files'
    and public.is_admin()
    and not exists (
      select 1 from public.staff s
       where s.id::text = (storage.foldername(name))[1]
         and not s.active
    )
  );

comment on function public.staff_record_frozen() is
  'Refuses any change to an inactive staff member''s pay, credentials, training, files, employment details or onboarding checklist. The offboarding checklist stays open. Reactivating reopens the record.';
