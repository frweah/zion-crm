-- ─────────────────────────────────────────────────────────────
-- 10.4 — a records request
--
-- A client asks for their file. Or their attorney does, or USOR, or a
-- guardian. Today the answer would be somebody opening eight tabs and copying
-- things out, which is slow, and — worse — leaves nobody able to say
-- afterwards what was handed over.
--
-- So: one act that gathers everything held about one person, records that it
-- happened, and produces something a person reviews before it leaves the
-- building.
--
-- Three things shape it.
--
--   Everything means everything. A records request answered with the tidy
--   parts is not answered. Notes marked visible to one role are in it, and so
--   is the access log — "who has looked at my file" is one of the commonest
--   things actually being asked.
--
--   It is a draft, not a despatch. Nothing is sent from here. A case note can
--   name somebody else's client, an employer's private remark, a family
--   member — and deciding what may be disclosed is a judgement, not a query.
--   So every entry says who could see it, and a person reads it before it
--   goes.
--
--   Producing one is itself a read of the most restricted data in the system,
--   so it goes in the access log like any other. A records request that left
--   no trace would be the one hole in 10.1.
-- ─────────────────────────────────────────────────────────────

-- 'Records request' is a new kind of read. The constraint is widened rather
-- than dropped: the point of listing the subjects is that a new one is a
-- deliberate act.
--
-- All five are restated because the constraint has to be replaced whole.
-- 'Staff document' arrived in 0059 and the first version of this migration
-- rebuilt the list from the original four, silently dropping it — the schema
-- accepted that happily and verify_documents caught it on the next run. When
-- adding a sixth, copy this list, not 0054's.
alter table public.access_log drop constraint if exists access_log_subject_check;
alter table public.access_log add constraint access_log_subject_check
  check (subject in (
    'Client restricted details',
    'Client intake',
    'Contractor tax number',
    'Signed tax form',
    'Staff document',
    'Records request'
  ));

-- ─────────────────────────────────────────────────────────────
-- The request itself
--
-- Who asked, when, and what was produced. Kept whether or not anything was
-- ever handed over, because "we received a request and did nothing" is a fact
-- somebody may need, and it is the sort of fact that disappears if the only
-- record of a request is the bundle it produced.
-- ─────────────────────────────────────────────────────────────
create table if not exists public.records_requests (
  id            uuid primary key default gen_random_uuid(),
  client_id     uuid not null references public.clients(id) on delete restrict,
  client_name   text not null default '',

  -- In their own words: "the client", "Dana Reeves, attorney", "USOR audit".
  requested_by  text not null check (btrim(requested_by) <> ''),
  requested_on  date not null default public.practice_today(),
  note          text not null default '',

  -- Filled when a bundle was actually produced. Null means received and not
  -- yet answered, which is a state worth being able to see.
  produced_at   timestamptz,
  produced_by   uuid references public.staff(id) on delete set null,
  produced_by_name text not null default '',
  -- What was in it, by section, so what was handed over can be described
  -- later without producing it again.
  contents      jsonb,

  created_by    uuid references public.staff(id) on delete set null,
  created_at    timestamptz not null default now()
);

create index if not exists records_requests_client_idx
  on public.records_requests (client_id, requested_on desc);

alter table public.records_requests enable row level security;

drop policy if exists records_requests_read on public.records_requests;
drop policy if exists records_requests_write on public.records_requests;
drop policy if exists records_requests_update on public.records_requests;

-- Admin only, throughout. Answering a records request is a disclosure
-- decision, and this is a practice where one person makes those.
create policy records_requests_read on public.records_requests
  for select to authenticated using (public.is_admin());
create policy records_requests_write on public.records_requests
  for insert to authenticated with check (public.is_admin());
create policy records_requests_update on public.records_requests
  for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- No delete policy: a request that arrived, arrived.

-- ─────────────────────────────────────────────────────────────
-- Everything held about one person
--
-- One call, one document. Definer, because it reaches into client_private and
-- intakes, which nobody signed in can read directly — and it logs the read
-- before returning a single field, so a bundle cannot be produced without a
-- trace.
--
-- Attachments are listed but not embedded: the files are handed over
-- alongside, and a base64 blob in a jsonb column would make this unreadable
-- for the one thing it is for.
-- ─────────────────────────────────────────────────────────────
create or replace function public.records_request_bundle(
  p_client  uuid,
  p_purpose text default 'Records request'
) returns jsonb
language plpgsql security definer set search_path = public, vault, extensions as $$
declare
  v_out    jsonb;
  v_client jsonb;
begin
  if not public.is_admin() then
    raise exception 'Only Admin produces a records request.'
      using errcode = 'insufficient_privilege';
  end if;

  select to_jsonb(c) - 'legacy_id' - 'ghl_id' - 'import_review'
    into v_client
    from public.clients c where c.id = p_client;

  if v_client is null then
    raise exception 'That client does not exist.' using errcode = 'no_data_found';
  end if;

  -- Logged before anything is returned. If the rest of this function fails,
  -- the attempt is still on the record, which is the way round it should be.
  perform public.log_access('Records request', p_client, null, p_purpose);

  select jsonb_build_object(
    'produced_at', now(),
    'client', v_client,

    'restricted_details', (
      select to_jsonb(p) from public.client_private p where p.client_id = p_client
    ),

    'intake', (
      select to_jsonb(i) - 'id' from public.intakes i where i.client_id = p_client
    ),

    'stage_history', (
      select coalesce(jsonb_agg(to_jsonb(h) - 'id' order by h.at), '[]'::jsonb)
        from public.client_stage_history h where h.client_id = p_client
    ),

    -- visible_roles rides along on purpose. It is what tells the person
    -- reviewing this which notes were never meant for general circulation,
    -- and those are exactly the ones to read twice before disclosing.
    'notes', (
      select coalesce(jsonb_agg(to_jsonb(n) - 'id' - 'legacy_id' order by n.ts), '[]'::jsonb)
        from public.notes n where n.client_id = p_client
    ),

    'counselor_contacts', (
      select coalesce(jsonb_agg(to_jsonb(cl) - 'id' - 'legacy_id' order by cl.date), '[]'::jsonb)
        from public.contact_log cl where cl.client_id = p_client
    ),

    'tasks', (
      select coalesce(jsonb_agg(to_jsonb(t) - 'id' - 'legacy_id' order by t.created_at), '[]'::jsonb)
        from public.tasks t where t.client_id = p_client
    ),

    'authorizations', (
      select coalesce(jsonb_agg(to_jsonb(a) - 'legacy_id' order by a.start_date), '[]'::jsonb)
        from public.authorizations a where a.client_id = p_client
    ),

    'invoices', (
      select coalesce(jsonb_agg(to_jsonb(inv) - 'legacy_id' order by inv.date), '[]'::jsonb)
        from public.invoices inv
        join public.authorizations a on a.id = inv.auth_id
       where a.client_id = p_client
    ),

    'service_hours', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'worked_on', w.worked_on, 'hours', w.hours,
               'description', w.description, 'category', w.category,
               'voided', w.voided) order by w.worked_on), '[]'::jsonb)
        from public.work_sessions w where w.client_id = p_client
    ),

    'forms', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'template_id', f.template_id, 'month', f.month, 'status', f.status,
               'completed_at', f.completed_at, 'sent_at', f.sent_at, 'sent_to', f.sent_to,
               'data', f.data) order by f.created_at), '[]'::jsonb)
        from public.forms f where f.client_id = p_client
    ),

    'placements', (
      select coalesce(jsonb_agg(to_jsonb(pl) - 'id' - 'legacy_id' order by pl.start_date), '[]'::jsonb)
        from public.placements pl where pl.client_id = p_client
    ),

    'jobs_applied_for', (
      select coalesce(jsonb_agg(to_jsonb(m) - 'id' order by m.created_at), '[]'::jsonb)
        from public.lead_matches m where m.client_id = p_client
    ),

    'appointments', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'kind', e.kind, 'title', e.title, 'starts_at', e.starts_at,
               'ends_at', e.ends_at, 'location', e.location, 'note', e.note)
               order by e.starts_at), '[]'::jsonb)
        from public.calendar_events e where e.client_id = p_client
    ),

    'texts', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'direction', m.direction, 'phone', m.phone, 'body', m.body,
               'kind', m.kind, 'status', m.status,
               'at', coalesce(m.sent_at, m.created_at)) order by m.created_at), '[]'::jsonb)
        from public.sms_messages m where m.client_id = p_client
    ),

    'texting_consent', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'state', ev.state, 'method', ev.method, 'note', ev.note, 'at', ev.at)
               order by ev.seq), '[]'::jsonb)
        from public.sms_consent_events ev where ev.client_id = p_client
    ),

    'email', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'subject', ml.subject, 'direction', ml.direction,
               'counterpart', ml.counterpart_email, 'sent_at', ml.sent_at)
               order by ml.sent_at), '[]'::jsonb)
        from public.mail_log ml where ml.client_id = p_client
    ),

    -- Named, not embedded. The files go with the bundle; what belongs here is
    -- the list, so the person handing it over knows what to attach and the
    -- person receiving it knows what they should have.
    'files', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'filename', at2.filename, 'category', at2.category,
               'note', at2.note, 'size_bytes', at2.size_bytes,
               'restricted', at2.restricted, 'added', at2.created_at)
               order by at2.created_at), '[]'::jsonb)
        from public.attachments at2 where at2.client_id = p_client
    ),

    -- Who has opened this person's restricted details, and when. Often the
    -- actual question behind a records request.
    'who_read_this_record', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'at', l.at, 'who', l.staff_name, 'role', l.staff_role,
               'what', l.subject, 'why', l.purpose) order by l.at), '[]'::jsonb)
        from public.access_log l where l.client_id = p_client
    )
  ) into v_out;

  return v_out;
end;
$$;

revoke execute on function public.records_request_bundle(uuid, text) from public;
grant execute on function public.records_request_bundle(uuid, text) to authenticated;

comment on function public.records_request_bundle(uuid, text) is
  'Everything held about one client, for answering a records request. Admin only, and logs the read before returning anything. Produces a draft for review — nothing is sent from here.';
