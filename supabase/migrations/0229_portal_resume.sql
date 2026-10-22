-- 0229 — Client portal, step 4: the resume builder (portal brief, section 4).
--
-- A client with no resume builds one in the portal, a step at a time, most
-- recent job first. What they type is saved after every step, so leaving and
-- coming back carries on where they were. Finishing produces a PDF and a
-- Word file, filed in the client's documents as category Resume, waiting for
-- review, with a task for the assigned staff member: "Review resume for
-- <client>". Approving marks both files accepted and answers any open Resume
-- request; sending it back returns it to the client with a note, to edit and
-- finish again.
--
-- Nothing the client did not type is added: the files are drawn on the
-- server from the saved draft and nothing else.
--
-- Applied in parts (0229a-c) on 21 Oct 2026; this file is their sum.

create table if not exists public.portal_resumes (
  id            uuid primary key default gen_random_uuid(),
  client_id     uuid not null references public.clients(id) on delete cascade,
  account_id    uuid references public.portal_accounts(id) on delete set null,
  data          jsonb not null default '{}'::jsonb check (pg_column_size(data) < 60000),
  step          integer not null default 0 check (step between 0 and 20),
  status        text not null default 'Draft' check (status in ('Draft', 'Submitted', 'Approved', 'Returned')),
  return_note   text not null default '',
  pdf_id        uuid references public.attachments(id) on delete set null,
  docx_id       uuid references public.attachments(id) on delete set null,
  submitted_at  timestamptz,
  reviewed_by   uuid references public.staff(id) on delete set null,
  reviewed_at   timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
-- One resume in progress per client at a time: a draft, one sent back, or one
-- waiting for review. An approved one is finished; the next starts fresh from
-- it.
create unique index if not exists portal_resumes_one_open
  on public.portal_resumes (client_id) where status in ('Draft', 'Returned', 'Submitted');

alter table public.portal_resumes enable row level security;
create policy portal_resumes_read on public.portal_resumes for select to authenticated
  using ((select public.is_active_staff()));
revoke all on public.portal_resumes from anon, authenticated;
grant select on public.portal_resumes to authenticated;

alter table public.tasks drop constraint if exists tasks_source_kind_check;
alter table public.tasks add constraint tasks_source_kind_check check (source_kind = any (array[
  'Interview prep', 'Interview day', 'Follow-up', 'billing_item', 'text_unanswered', 'intake',
  'authorization_received', 'authorization_missing', 'authorization_ending', 'placement_authorization',
  'portal_upload', 'portal_resume']));

-- ── the client's side ───────────────────────────────────────
-- The resume in progress, or the last approved one to start again from, and
-- what the record already knows for the contact step.
create or replace function public.portal_my_resume()
returns table (id uuid, data jsonb, step integer, status text, return_note text,
               record_name text, record_phone text, record_email text, record_city text)
language sql stable security definer set search_path = public as $$
  select r.id, coalesce(r.data, '{}'::jsonb), coalesce(r.step, 0), coalesce(r.status, 'None'), coalesce(r.return_note, ''),
         c.name, c.phone, c.email, ''::text
    from public.clients c
    left join lateral (
      select * from public.portal_resumes x
       where x.client_id = c.id
       order by (x.status in ('Draft', 'Returned', 'Submitted')) desc, x.updated_at desc
       limit 1) r on true
   where c.id = public.portal_client_id();
$$;

create or replace function public.portal_save_resume(p_data jsonb, p_step integer)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_client  uuid := public.portal_client_id();
  v_account uuid := public.portal_session_account_id();
  v_id      uuid;
  v_status  text;
begin
  if v_client is null then
    raise exception 'Sign in and agree to the portal terms first.' using errcode = 'insufficient_privilege';
  end if;
  if jsonb_typeof(p_data) is distinct from 'object' then
    raise exception 'That could not be saved. Refresh the page and try again.' using errcode = 'check_violation';
  end if;

  select id, status into v_id, v_status from public.portal_resumes
   where client_id = v_client and status in ('Draft', 'Returned', 'Submitted');
  if v_status = 'Submitted' then
    raise exception 'Your resume is with Zion for review. You can change it once they send it back.' using errcode = 'check_violation';
  end if;

  if v_id is null then
    insert into public.portal_resumes (client_id, account_id, data, step)
    values (v_client, v_account, p_data, greatest(0, least(coalesce(p_step, 0), 20)))
    returning id into v_id;
  else
    update public.portal_resumes
       set data = p_data, step = greatest(0, least(coalesce(p_step, 0), 20)), account_id = v_account, updated_at = now()
     where id = v_id;
  end if;
  return v_id;
end;
$$;

-- Where the server puts the two files for this resume.
create or replace function public.portal_resume_folder()
returns text language plpgsql security definer set search_path = public as $$
declare
  v_client uuid := public.portal_client_id();
  v_id     uuid;
begin
  if v_client is null then
    raise exception 'Sign in and agree to the portal terms first.' using errcode = 'insufficient_privilege';
  end if;
  select id into v_id from public.portal_resumes where client_id = v_client and status in ('Draft', 'Returned');
  if v_id is null then
    raise exception 'There is no resume to finish. Start one first.' using errcode = 'check_violation';
  end if;
  return 'portal/' || v_client || '/resume/' || v_id || '/';
end;
$$;

create or replace function public.portal_submit_resume(
  p_pdf_path text, p_pdf_size bigint, p_pdf_sha text,
  p_docx_path text, p_docx_size bigint, p_docx_sha text)
returns uuid language plpgsql security definer set search_path = public, storage as $$
declare
  v_client  uuid := public.portal_client_id();
  v_account uuid := public.portal_session_account_id();
  v_r       public.portal_resumes%rowtype;
  v_name    text;
  v_first   text;
  v_label   text;
  v_pdf     uuid;
  v_docx    uuid;
  v_staff   uuid;
  v_folder  text;
begin
  if v_client is null then
    raise exception 'Sign in and agree to the portal terms first.' using errcode = 'insufficient_privilege';
  end if;
  select * into v_r from public.portal_resumes where client_id = v_client and status in ('Draft', 'Returned');
  if v_r.id is null then
    raise exception 'There is no resume to finish. Start one first.' using errcode = 'check_violation';
  end if;
  v_folder := 'portal/' || v_client || '/resume/' || v_r.id || '/';
  if p_pdf_path not like v_folder || '%' or p_docx_path not like v_folder || '%'
     or not exists (select 1 from storage.objects where bucket_id = 'client-files' and name = p_pdf_path)
     or not exists (select 1 from storage.objects where bucket_id = 'client-files' and name = p_docx_path) then
    raise exception 'Your resume files were not saved. Try finishing again.' using errcode = 'check_violation';
  end if;

  select c.name, c.assigned_staff_id into v_name, v_staff from public.clients c where c.id = v_client;
  select name into v_label from public.portal_accounts where id = v_account;
  v_first := regexp_replace(coalesce(nullif(btrim(v_name), ''), 'Client'), '[^A-Za-z0-9]+', '-', 'g');

  insert into public.attachments (client_id, storage_path, filename, mime_type, size_bytes, category, restricted, note,
                                  uploaded_by, uploaded_by_name, sha256, source, portal_account_id, review_status)
  values (v_client, p_pdf_path, v_first || '-Resume.pdf', 'application/pdf', coalesce(p_pdf_size, 0), 'Resume', false,
          'Built in the client portal resume builder.', null, coalesce(v_label, '') || ' (portal)',
          nullif(p_pdf_sha, ''), 'Portal', v_account, 'Waiting')
  returning id into v_pdf;
  insert into public.attachments (client_id, storage_path, filename, mime_type, size_bytes, category, restricted, note,
                                  uploaded_by, uploaded_by_name, sha256, source, portal_account_id, review_status)
  values (v_client, p_docx_path, v_first || '-Resume.docx',
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document', coalesce(p_docx_size, 0), 'Resume', false,
          'Built in the client portal resume builder. The Word copy, for editing.', null, coalesce(v_label, '') || ' (portal)',
          nullif(p_docx_sha, ''), 'Portal', v_account, 'Waiting')
  returning id into v_docx;

  update public.portal_resumes
     set status = 'Submitted', pdf_id = v_pdf, docx_id = v_docx, submitted_at = now(), return_note = '', updated_at = now()
   where id = v_r.id;

  insert into public.tasks (client_id, assigned_staff_id, title, due, system_generated, source_kind, source_ref)
  values (v_client, v_staff, 'Review resume for ' || coalesce(v_name, 'client'),
          (now() at time zone 'America/Denver')::date, true, 'portal_resume', v_r.id);
  return v_r.id;
end;
$$;

-- ── the staff side ──────────────────────────────────────────
create or replace function public.portal_review_resume(p_resume uuid, p_approve boolean, p_note text default '')
returns uuid[] language plpgsql security definer set search_path = public as $$
declare
  v_r  public.portal_resumes%rowtype;
  v_me uuid := public.current_staff_id();
begin
  select * into v_r from public.portal_resumes where id = p_resume;
  if v_r.id is null or not public.can_manage_portal(v_r.client_id) then
    raise exception 'Only Admin, Reports or the assigned staff member reviews this client''s resume.' using errcode = 'insufficient_privilege';
  end if;
  if v_r.status <> 'Submitted' then
    raise exception 'That resume is not waiting for review.' using errcode = 'check_violation';
  end if;
  if not p_approve and coalesce(btrim(p_note), '') = '' then
    raise exception 'Say what to change, so the client knows what to fix.' using errcode = 'check_violation';
  end if;

  update public.portal_resumes
     set status = case when p_approve then 'Approved' else 'Returned' end,
         return_note = case when p_approve then '' else btrim(p_note) end,
         reviewed_by = v_me, reviewed_at = now(), updated_at = now()
   where id = p_resume;
  update public.attachments
     set review_status = case when p_approve then 'Accepted' else 'Returned' end,
         review_note = case when p_approve then review_note else btrim(p_note) end
   where id in (v_r.pdf_id, v_r.docx_id);
  update public.tasks set status = 'Done', done_at = (now() at time zone 'America/Denver')::date, updated_at = now()
   where source_kind = 'portal_resume' and source_ref = p_resume and status = 'Open';

  if p_approve then
    -- It counts as received only now: any Resume request still waiting is
    -- answered by it.
    update public.portal_requests
       set status = 'Accepted', attachment_id = v_r.pdf_id, answered_at = coalesce(answered_at, now()),
           reviewed_by = v_me, reviewed_at = now(), return_reason = ''
     where client_id = v_r.client_id and item = 'Resume' and status in ('Open', 'Returned');
    return '{}';
  end if;
  return public.portal_post_system_line(v_r.client_id,
    'Zion has looked at your resume and asked for a change: ' || btrim(p_note) || ' Open Resume to edit it.');
end;
$$;

revoke execute on function public.portal_my_resume(), public.portal_save_resume(jsonb, integer), public.portal_resume_folder(),
  public.portal_submit_resume(text, bigint, text, text, bigint, text), public.portal_review_resume(uuid, boolean, text)
  from public, anon;
grant execute on function public.portal_my_resume(), public.portal_save_resume(jsonb, integer), public.portal_resume_folder(),
  public.portal_submit_resume(text, bigint, text, text, bigint, text) to authenticated, portal_client;
grant execute on function public.portal_review_resume(uuid, boolean, text) to authenticated;
