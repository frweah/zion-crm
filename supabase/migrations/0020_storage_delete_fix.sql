-- ─────────────────────────────────────────────────────────────
-- 0020 — remove the file-deletion triggers, which never worked.
--
-- 0009 and 0015 each deleted the stored object from a trigger on the metadata
-- row, so that removing a record removed the file with it. That reasoning was
-- right and the mechanism was wrong: Supabase guards storage.objects with its
-- own protect_delete() trigger, which refuses any direct DELETE and tells you
-- to use the Storage API. It fires at statement level, so it raises even when
-- the statement would match no rows.
--
-- The effect in production was worse than a file left behind: because the
-- trigger raised, deleting an attachment or a staff file failed outright.
-- Nobody could remove a document at all.
--
-- Object removal now happens in the server action, through the Storage API,
-- after the row delete has passed RLS. The row delete is the authorization
-- check; the object removal is the second half of the same operation.
-- ─────────────────────────────────────────────────────────────

drop trigger if exists attachments_delete_object on public.attachments;
drop function if exists public.delete_attachment_object();

drop trigger if exists staff_files_delete_object on public.staff_files;
drop function if exists public.delete_staff_file_object();
