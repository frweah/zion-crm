-- Zion Vocational Rehab CRM — 0013 employers, job leads, and matches
--
-- Phase 6 A2. The point is that job-search effort is recorded once: matching a
-- client to a lead writes the typed note that USOR 96 autofill and the client
-- activity report already read, so nobody enters the same work twice.

-- ─────────────────────────────────────────────────────────────
-- Employers
-- ─────────────────────────────────────────────────────────────
create table public.employers (
  id                  uuid primary key default gen_random_uuid(),
  name                text not null,
  industry            text not null default '',
  address             text not null default '',
  contact_name        text not null default '',
  contact_phone       text not null default '',
  contact_email       text not null default '',
  notes               text not null default '',
  relationship_status text not null default 'Prospect'
                        check (relationship_status in ('Prospect', 'Active partner', 'Do not use')),
  hiring_pattern      text not null default '',
  created_by          uuid references public.staff(id) on delete set null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create unique index employers_name_idx on public.employers (lower(name));
create index employers_status_idx on public.employers (relationship_status);
create trigger employers_updated_at before update on public.employers
  for each row execute function public.set_updated_at();

-- ─────────────────────────────────────────────────────────────
-- Openings
-- ─────────────────────────────────────────────────────────────
create table public.job_leads (
  id             uuid primary key default gen_random_uuid(),
  employer_id    uuid not null references public.employers(id) on delete cascade,
  title          text not null,
  wage_range     text not null default '',
  hours_week     text not null default '',
  shift          text not null default '',
  requirements   text not null default '',
  source         text not null default '',
  posted_date    date,
  status         text not null default 'Open'
                   check (status in ('Open', 'Submitted', 'Interviewing', 'Filled', 'Closed')),
  owner_staff_id uuid references public.staff(id) on delete set null,
  created_by     uuid references public.staff(id) on delete set null,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index job_leads_employer_idx on public.job_leads (employer_id);
create index job_leads_status_idx on public.job_leads (status);
create index job_leads_owner_idx on public.job_leads (owner_staff_id);
create trigger job_leads_updated_at before update on public.job_leads
  for each row execute function public.set_updated_at();

-- ─────────────────────────────────────────────────────────────
-- Which clients we put forward for which opening
-- ─────────────────────────────────────────────────────────────
create table public.lead_matches (
  id           uuid primary key default gen_random_uuid(),
  lead_id      uuid not null references public.job_leads(id) on delete cascade,
  client_id    uuid not null references public.clients(id) on delete cascade,
  status       text not null default 'Considering'
                 check (status in ('Considering', 'Applied', 'Interview', 'Offer', 'Hired', 'Declined')),
  applied_on   date,
  interview_on date,
  decided_on   date,
  notes        text not null default '',
  placement_id uuid references public.placements(id) on delete set null,
  created_by   uuid references public.staff(id) on delete set null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (lead_id, client_id)
);
create index lead_matches_client_idx on public.lead_matches (client_id);
create index lead_matches_lead_idx on public.lead_matches (lead_id);
create trigger lead_matches_updated_at before update on public.lead_matches
  for each row execute function public.set_updated_at();

-- ─────────────────────────────────────────────────────────────
-- The note that means it only gets typed once
--
-- Every match, and every step it moves through, writes a note on the client
-- with one of the four activity types USOR 96 autofill reads. Doing it in a
-- trigger rather than the screen means it holds whoever writes the row — the
-- board, an import, a correction run months from now.
--
-- Job-search activity is not restricted content, so the note is visible to the
-- roles that already see the pipeline.
-- ─────────────────────────────────────────────────────────────
create or replace function public.note_type_for_match(p_status text)
returns text language sql immutable as $$
  select case p_status
    when 'Applied'   then 'Application submitted'
    when 'Interview' then 'Interview'
    when 'Offer'     then 'Employer contact'
    when 'Hired'     then 'Employer contact'
    else 'Job search'
  end;
$$;

create or replace function public.log_lead_match()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_title    text;
  v_employer text;
  v_actor    uuid := public.current_staff_id();
  v_name     text;
  v_text     text;
begin
  if tg_op = 'UPDATE' and new.status is not distinct from old.status then
    return new;
  end if;

  select l.title, e.name into v_title, v_employer
    from public.job_leads l
    join public.employers e on e.id = l.employer_id
   where l.id = new.lead_id;

  select name into v_name from public.staff where id = coalesce(new.created_by, v_actor);

  v_text := case new.status
    when 'Considering' then 'Considering ' || v_title || ' at ' || v_employer || '.'
    when 'Applied'     then 'Applied for ' || v_title || ' at ' || v_employer || '.'
    when 'Interview'   then 'Interview for ' || v_title || ' at ' || v_employer || '.'
    when 'Offer'       then 'Offer received for ' || v_title || ' at ' || v_employer || '.'
    when 'Hired'       then 'Hired for ' || v_title || ' at ' || v_employer || '.'
    when 'Declined'    then 'Did not proceed with ' || v_title || ' at ' || v_employer || '.'
    else new.status || ' — ' || v_title || ' at ' || v_employer
  end;

  if new.notes <> '' then
    v_text := v_text || E'\n' || new.notes;
  end if;

  insert into public.notes (client_id, staff_id, staff_name, text, type, visible_roles)
  values (
    new.client_id,
    coalesce(new.created_by, v_actor),
    coalesce(v_name, ''),
    v_text,
    public.note_type_for_match(new.status),
    array['Admin', 'Job Search', 'Reports', 'Billing']
  );

  return new;
end;
$$;

create trigger lead_matches_note
  after insert or update of status on public.lead_matches
  for each row execute function public.log_lead_match();

-- ─────────────────────────────────────────────────────────────
-- Access
--
-- Job Search and Admin work the board; Intake & Reports and Billing can see it
-- but not change it. Everyone active can read, which is what "Billing read"
-- means in the brief.
-- ─────────────────────────────────────────────────────────────
do $$
declare t text;
begin
  foreach t in array array['employers', 'job_leads', 'lead_matches'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format(
      'create policy %I on public.%I for select to authenticated using (public.is_active_staff())',
      t || '_read', t);
    execute format(
      'create policy %I on public.%I for insert to authenticated
         with check (public.current_staff_role() in (''Admin'', ''Job Search''))',
      t || '_insert', t);
    execute format(
      'create policy %I on public.%I for update to authenticated
         using (public.current_staff_role() in (''Admin'', ''Job Search''))
         with check (public.current_staff_role() in (''Admin'', ''Job Search''))',
      t || '_update', t);
    execute format(
      'create policy %I on public.%I for delete to authenticated using (public.is_admin())',
      t || '_delete', t);
  end loop;
end $$;

-- ─────────────────────────────────────────────────────────────
-- Per-client history: the jobs we have tried for someone.
-- ─────────────────────────────────────────────────────────────
create or replace view public.client_job_history as
select m.id as match_id,
       m.client_id,
       m.status,
       m.applied_on,
       m.interview_on,
       m.decided_on,
       m.notes,
       m.placement_id,
       m.updated_at,
       l.id as lead_id,
       l.title,
       l.status as lead_status,
       e.id as employer_id,
       e.name as employer_name
  from public.lead_matches m
  join public.job_leads l on l.id = m.lead_id
  join public.employers e on e.id = l.employer_id;

alter view public.client_job_history set (security_invoker = true);
grant select on public.client_job_history to authenticated;
