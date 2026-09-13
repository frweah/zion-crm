-- ─────────────────────────────────────────────────────────────
-- 0073 — client-files takes files up to 50 MB
--
-- The first real backfill found a 27.3 MB client PDF, over the 25 MB cap set
-- in 0009. Raised at the owner's request on 2026-09-13; applied directly that
-- day and recorded here so the repository says what the database does.
--
-- staff-files (0015) stays at 25 MB: nothing larger has been asked for there.
-- The application's own checks read the same number - lib/inbox-storage.ts,
-- the agent's $StorageLimit, and the client Files tab.
-- ─────────────────────────────────────────────────────────────
update storage.buckets
   set file_size_limit = 52428800
 where id = 'client-files';
