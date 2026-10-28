-- Zion Vocational Rehab CRM — 0262 a signed report is a document
--
-- A signed monthly report is a PDF on the client's record, and the record
-- files documents by category. There was no category for one, which would
-- have left every signed report filed as "Other" beside the things nobody
-- could name - and a counselor asking for last October's report would be
-- looking through a list of Others for it.
--
-- Not restricted by default. The document is what was sent to the counselor,
-- so anybody who may read the client's record may read what the practice told
-- them about it. What the report may contain is limited where that belongs -
-- the note gate in lib/report-period.ts, which keeps a note held back from
-- most of the practice out of a letter going to the state.

insert into public.client_file_categories (key, label, detail, restricted_by_default, sort_order, active)
values ('Monthly report', 'Monthly report',
        'The signed monthly report sent to the counselor', false, 115, true)
on conflict (key) do nothing;
