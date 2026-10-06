-- Zion Vocational Rehab CRM — Updates: what the practice tells everybody
-- (Design language, §3)
--
-- Things everybody needs to know have been going out as email and as text
-- messages, which means nobody can answer the only question that matters
-- about them: who has read this. An email read receipt is a setting people
-- turn off; a text to seven people is seven conversations.
--
-- So: a post, a list of who has read it, and - where it matters - a post that
-- says it must be acknowledged and stays pinned to the top of everybody's
-- Updates until they say they have read it. Reading is a deliberate act with
-- a button, not a scroll position: "it was on their screen" is not the same
-- as "they read it", and the difference is the entire point of the feature.
--
-- Who may post is Admin. Who may read is a role list, defaulting to everybody,
-- because a policy change for Billing is noise for everybody else.

create table if not exists public.updates (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  text text not null,
  link text,
  attachment_path text,
  attachment_name text,
  -- Empty means everybody, as it does for a work category (0134).
  audience text[] not null default '{}',
  pinned boolean not null default false,
  requires_ack boolean not null default false,
  active boolean not null default true,
  posted_by uuid references public.staff(id) on delete set null,
  posted_by_name text,
  posted_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint updates_title_said check (btrim(title) <> ''),
  constraint updates_body_said check (btrim(text) <> '')
);

comment on table public.updates is
  'What the practice tells everybody (0136). Posted by Admin, read by a role or by all, and - where it matters - acknowledged one person at a time.';

create index if not exists updates_posted_idx on public.updates (posted_at desc) where active;

create table if not exists public.update_reads (
  update_id uuid not null references public.updates(id) on delete cascade,
  staff_id uuid not null references public.staff(id) on delete cascade,
  read_at timestamptz not null default now(),
  primary key (update_id, staff_id)
);

comment on table public.update_reads is
  'Who has said they read an update (0136). A deliberate act, not a scroll position.';

-- ── who sees what ──────────────────────────────────────────
alter table public.updates enable row level security;
alter table public.update_reads enable row level security;

drop policy if exists updates_select on public.updates;
create policy updates_select on public.updates for select to authenticated
  using (
    active
    and (
      cardinality(audience) = 0
      or (select public.current_staff_role()) = any (audience)
      or (select public.current_staff_role()) = 'Admin'
    )
  );

drop policy if exists updates_write on public.updates;
create policy updates_write on public.updates for all to authenticated
  using ((select public.current_staff_role()) = 'Admin')
  with check ((select public.current_staff_role()) = 'Admin');

-- A person records their own reading, and nobody else's. Admin reads the
-- whole list, because "who has not read this" is the question Admin posts it
-- to be able to ask.
drop policy if exists update_reads_select on public.update_reads;
create policy update_reads_select on public.update_reads for select to authenticated
  using (
    staff_id = (select public.current_staff_id())
    or (select public.current_staff_role()) = 'Admin'
  );

drop policy if exists update_reads_insert on public.update_reads;
create policy update_reads_insert on public.update_reads for insert to authenticated
  with check (staff_id = (select public.current_staff_id()));

select public.apply_system_read_only('public.updates'::regclass);
select public.apply_system_read_only('public.update_reads'::regclass);

grant select, insert, update, delete on public.updates to authenticated;
grant select, insert on public.update_reads to authenticated;

/**
 * The updates one person should see, newest first, with whether they have
 * read it and - for the people who have to act on that - how many have.
 *
 * Pinned-and-unacknowledged sorts to the top, which is what "pinned until
 * read" means: it is pinned for the person who has not read it and ordinary
 * for everybody who has.
 */
create or replace view public.updates_for_me
with (security_invoker = true) as
  select u.id,
         u.title,
         u.text,
         u.link,
         u.attachment_path,
         u.attachment_name,
         u.audience,
         u.pinned,
         u.requires_ack,
         u.posted_by_name,
         u.posted_at,
         exists (
           select 1 from public.update_reads r
            where r.update_id = u.id and r.staff_id = public.current_staff_id()
         ) as read_by_me,
         (select count(*) from public.update_reads r where r.update_id = u.id) as read_count
    from public.updates u
   where u.active;

grant select on public.updates_for_me to authenticated;

comment on view public.updates_for_me is
  'An update as one person sees it (0136): whether they have read it, and how many have.';
