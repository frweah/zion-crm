-- Zion Vocational Rehab CRM — a person can upload their own papers
-- (Melanie, 14 Oct 2026: cannot upload her ID in onboarding)
--
-- Reproduced as her before anything was changed. Signed in as Melanie
-- (Billing, contractor), every part of the database path works: she can read
-- her own employment row, and she can insert her own staff_files row and read
-- it back. What fails is storage, and it fails in a way worth writing down
-- because the error names the wrong thing.
--
--   insert into storage.objects (bucket_id, name) values ('staff-files', ...)
--     -> allowed
--
--   insert into storage.objects (bucket_id, name) values ('staff-files', ...)
--     returning id
--     -> ERROR: new row violates row-level security policy for table "objects"
--
-- The only difference is RETURNING, and RETURNING makes Postgres apply the
-- *SELECT* policy to the row it is about to hand back. The select policy on
-- this bucket was `is_admin()`. So the insert was never the problem: reading
-- back what she had just written was, and the message blames the write.
--
-- The storage service inserts with RETURNING, because it answers with the
-- object it created. So this was not Melanie, or Billing, or onboarding - no
-- role but Admin could upload anything to staff-files at all, and every one
-- of them got an error about a policy violation on a row they were allowed to
-- write.
--
-- ── so: a person may read their own file ────────────────────
--
-- Which is the right rule on its own merits, quite apart from the upload. A
-- person should be able to see and open the ID they uploaded; being unable to
-- is how somebody uploads the wrong page twice.
--
-- Three path shapes are in the bucket, all of which name their owner:
--
--   <staff id>/<timestamp>-<filename>      the onboarding uploads
--   staff/<staff id>/<kind>-<id>.pdf       the generated forms
--   signatures/<staff id>.jpg              a signature
--
-- staff_file_owner() reads the owner out of any of them, so one expression
-- covers the lot and a fourth shape added later fails closed rather than
-- opening the bucket.
--
-- ── and two more faults found while in here ─────────────────
--
-- The insert policy was `is_active_staff()` and nothing else, so any member of
-- staff could write into anybody's folder. Narrowed to their own, or an
-- Admin's, which is also what the owner's fourth item needs.
--
-- The delete policy meant to refuse deleting the files of somebody no longer
-- active, and asked:
--
--   not exists (select 1 from staff s
--                where s.id::text = (storage.foldername(s.name))[1] ...)
--
-- `s.name` is the person's name. It took the folder name of "Melanie Morales"
-- and compared it with a uuid, which is never equal - so the subquery was
-- always empty, `not exists` was always true, and the freeze it was there to
-- enforce has never once applied. It should have been the object's name.

-- ─────────────────────────────────────────────────────────────
-- Whose file is this?
-- ─────────────────────────────────────────────────────────────
create or replace function public.staff_file_owner(p_name text)
returns uuid language sql immutable set search_path = public as $$
  with f as (select storage.foldername(coalesce(p_name, '')) as parts)
  select case
           -- <staff id>/...
           when (select parts[1] from f) ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
             then (select parts[1] from f)::uuid
           -- staff/<staff id>/...
           when (select parts[1] from f) = 'staff'
            and (select parts[2] from f) ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
             then (select parts[2] from f)::uuid
           -- signatures/<staff id>.<ext>
           when (select parts[1] from f) = 'signatures'
            and regexp_replace(coalesce(p_name, ''), '^signatures/([^/.]+).*$', '\1')
                ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
             then regexp_replace(coalesce(p_name, ''), '^signatures/([^/.]+).*$', '\1')::uuid
           else null
         end;
$$;

comment on function public.staff_file_owner is
  'The staff member a path in staff-files belongs to, for any of the three shapes the bucket holds, or null for a path that names nobody. Null is refused by the policies that read it, so a new shape fails closed rather than opening the bucket.';

revoke all on function public.staff_file_owner(text) from anon, authenticated;
grant execute on function public.staff_file_owner(text) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- Reading: an Admin, or the person it belongs to
--
-- This is the policy whose absence broke the upload. RETURNING applies it to
-- the row being written, so without it no non-Admin can write here either.
-- ─────────────────────────────────────────────────────────────
drop policy if exists "zion read staff files" on storage.objects;
create policy "zion read staff files" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'staff-files'
    and ((select public.is_admin()) or public.staff_file_owner(name) = (select public.current_staff_id()))
  );

-- ─────────────────────────────────────────────────────────────
-- Writing: into your own folder, or anybody's if you are an Admin
--
-- The owner's fourth item asks for an Admin to be able to upload a document
-- on somebody's behalf, which is the is_admin() half. The other half is the
-- narrowing: this used to let any active member of staff write into any
-- person's folder.
-- ─────────────────────────────────────────────────────────────
drop policy if exists "zion write staff files" on storage.objects;
create policy "zion write staff files" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'staff-files'
    and (select public.is_active_staff())
    and ((select public.is_admin()) or public.staff_file_owner(name) = (select public.current_staff_id()))
  );

-- ─────────────────────────────────────────────────────────────
-- Replacing: the same test
--
-- There was no update policy at all, so replacing a document was refused for
-- everybody including an Admin - the storage service upserts when asked to
-- overwrite. Needed by the owner's fourth item ("upload or replace any
-- document on their behalf").
-- ─────────────────────────────────────────────────────────────
drop policy if exists "zion replace staff files" on storage.objects;
create policy "zion replace staff files" on storage.objects
  for update to authenticated
  using (
    bucket_id = 'staff-files'
    and ((select public.is_admin()) or public.staff_file_owner(name) = (select public.current_staff_id()))
  )
  with check (
    bucket_id = 'staff-files'
    and ((select public.is_admin()) or public.staff_file_owner(name) = (select public.current_staff_id()))
  );

-- ─────────────────────────────────────────────────────────────
-- Deleting: an Admin, and never from a frozen record
--
-- Same policy as before with the one word corrected: the object's name rather
-- than the person's. The freeze now actually applies.
-- ─────────────────────────────────────────────────────────────
drop policy if exists "zion delete staff files" on storage.objects;
create policy "zion delete staff files" on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'staff-files'
    and (select public.is_admin())
    and not exists (
      select 1 from public.staff s
       where s.id = public.staff_file_owner(objects.name)
         and not s.active
    )
  );
