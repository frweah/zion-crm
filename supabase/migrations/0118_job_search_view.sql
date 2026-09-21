-- Zion Vocational Rehab CRM — the job-search board, as a saved view
--
-- Job Search kept a Notion "Client Master Board": everyone looking for work,
-- who has them, their status and stage, when they can work and where. The
-- Clients list holds all of that now (0117 added availability, where they
-- will work, applications this week and the next interview), so the board is
-- one shared view of it rather than a second list to keep in step.

insert into public.saved_views (screen, name, owner_staff_id, params, sort_order)
select 'clients', 'Job search board', null,
       '{"status": ["Active"], "jobSearch": true, "sort": "nextInterview", "dir": "asc"}'::jsonb,
       coalesce((select max(sort_order) from public.saved_views where screen = 'clients'), 0) + 1
 where not exists (
   select 1 from public.saved_views where screen = 'clients' and name = 'Job search board' and owner_staff_id is null);
