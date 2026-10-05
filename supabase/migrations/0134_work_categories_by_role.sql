-- Zion Vocational Rehab CRM — Client development, and categories that belong
-- to a role (Rei, Oct 2026)
--
-- Two things, both about the list of categories somebody picks from when they
-- log an hour:
--
--   "Client development" is missing. Employer development is there - the work
--   of finding employers - and the work of developing a client, which is a
--   different thing and a large part of some days, had nowhere to go but
--   Other. An hour in Other is an hour nobody can report on.
--
--   The list is the same for everybody, so a Billing seat scrolls past
--   categories for work it never does, and the longer the list the more often
--   somebody picks the nearest thing rather than the right one. A category can
--   now name the roles it is for. Naming none means everybody, which is what
--   every category already in the list means.
--
-- Admin sees all of them whatever they say, because Admin logs hours against
-- any part of the practice and is the one who has to make the figures add up.

alter table public.work_categories
  add column if not exists roles text[] not null default '{}';

comment on column public.work_categories.roles is
  'The roles this category is offered to (0134). Empty means everybody. Admin is offered every category regardless.';

insert into public.work_categories (key, label, detail, billable, sort_order, active, roles)
values ('client_development',
        'Client development',
        'Building a client''s readiness for work: skills, confidence, materials, and the plan behind them.',
        true,
        (select coalesce(max(sort_order), 0) + 1 from public.work_categories where key = 'direct'),
        true,
        array['Admin', 'Job Search', 'Reports'])
on conflict (key) do update
  set label = excluded.label,
      detail = excluded.detail,
      active = true;

-- The ones that are nobody's in particular stay everybody's; the two that are
-- plainly job-search work say so, which is what makes the shorter list
-- shorter for the people who asked for it.
update public.work_categories set roles = array['Admin', 'Job Search', 'Reports']
 where key in ('employer', 'direct') and cardinality(roles) = 0;

/**
 * The categories a role is offered, in order. Admin is offered all of them.
 *
 * A function rather than a view because the answer depends on who is asking,
 * and the screens that ask are several.
 */
create or replace function public.work_categories_for(p_role text)
returns table (key text, label text, detail text, billable boolean, sort_order integer)
language sql stable security definer set search_path = public as $$
  select c.key, c.label, c.detail, c.billable, c.sort_order
    from public.work_categories c
   where c.active
     and (p_role = 'Admin' or cardinality(c.roles) = 0 or p_role = any (c.roles))
   order by c.sort_order, c.label;
$$;
revoke execute on function public.work_categories_for(text) from public, anon;
grant execute on function public.work_categories_for(text) to authenticated;
