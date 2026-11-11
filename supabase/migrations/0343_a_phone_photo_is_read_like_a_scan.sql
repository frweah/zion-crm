-- Zion Vocational Rehab CRM — a phone photo is read like a scan
--
-- "The document agent on my computer also fetches phone photos from the
-- client record and reads them, same rules as scans. Until it does, a phone
-- photo shows 'not read yet' on the document." (owner, 11 Nov 2026)
--
-- A scan is read by the agent from that computer's own copy, matched by hash.
-- A photo taken on a phone is never on that computer, so the agent asks for
-- it: /api/agent/ocr-wanted lists the photos waiting with a link that works
-- for ten minutes, the agent reads each with the same Tesseract it reads
-- scans with, and /api/agent/photo-ocr records the reading on the document.
--
-- The same rules as a scan:
--
--   An empty reading - the photo was read and nothing is on it - is a
--   reading, recorded as "nothing readable", and the agent stops asking.
--   A failure is never recorded: the photo stays "not read yet" and is asked
--   for again on the next run (the agent waits a week on one that keeps
--   failing, as it does for scans).
--   The reading is a proposal and files nothing. What the text says the
--   document is, is kept beside it for a person to act on.
--
-- Only photos sent from the phone are marked. A document added on a desk is
-- not asked about, so nothing already on a record suddenly reads "not read
-- yet".

begin;

alter table public.attachments
  add column if not exists ocr_state text
    check (ocr_state is null or ocr_state in ('not read yet', 'read', 'nothing readable')),
  add column if not exists ocr_text text,
  add column if not exists ocr_confidence numeric,
  add column if not exists ocr_kind text,
  add column if not exists ocr_at timestamptz;

create index if not exists attachments_not_read_yet
  on public.attachments (created_at)
  where ocr_state = 'not read yet';

-- The documents list says "not read yet" from the view it already reads.
-- Every column as it was, in the same order (0202), and the state added at
-- the end. The state is not redacted: that a restricted photo has not been
-- read tells nobody what it is.
create or replace view public.client_documents as
select
  a.id,
  a.client_id,
  a.document_date,
  a.created_at,
  case when (not a.restricted) or public.can_see_restricted(a.client_id)
       then a.category else '' end as category,
  a.restricted,
  a.uploaded_by,
  a.uploaded_by_name,
  ((not a.restricted) or public.can_see_restricted(a.client_id)) as can_open,
  case when (not a.restricted) or public.can_see_restricted(a.client_id)
       then a.filename else '' end as filename,
  case when (not a.restricted) or public.can_see_restricted(a.client_id)
       then a.note else '' end as note,
  case when (not a.restricted) or public.can_see_restricted(a.client_id)
       then a.storage_path else '' end as storage_path,
  case when (not a.restricted) or public.can_see_restricted(a.client_id)
       then a.mime_type else '' end as mime_type,
  case when (not a.restricted) or public.can_see_restricted(a.client_id)
       then a.size_bytes else null end as size_bytes,
  a.auth_id,
  a.form_id,
  a.ocr_state
from public.attachments a
where (select public.is_active_staff());

revoke all on public.client_documents from anon, authenticated;
grant select on public.client_documents to authenticated;

commit;
