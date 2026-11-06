-- Zion Vocational Rehab CRM — the other spellings of a name
--
-- Ruling 6 of 6 November 2026: the name on the signed authorization document
-- is the record's name, and the other spellings become aliases so warrants
-- and emails match.
--
-- ── why this is worth a table ─────────────────────────────────
--
-- Phase 1B found six invoices that could not be matched to anything, and the
-- reason for three of them was a vowel. An invoice went out under one spelling
-- of a surname, the warrant came back under a second, and the CRM holds a
-- third - so a search finds nothing, intake_find_client finds nothing, and the
-- email sits in the inbox as though it were about a stranger. One of those
-- three was $900 the state had already paid.
--
-- A spelling is not a correction. The authorization document decides what the
-- record is called, and everything else somebody might type or receive is a
-- way in to the same person rather than a mistake to be fixed. So the
-- alternatives live beside the record instead of replacing it.
--
-- ── and why no names are in this file ────────────────────────
--
-- The practice's rule is that no client data goes into the codebase or into
-- git history. The aliases themselves are client names, so this file builds
-- the table and teaches the two matchers to read it, and the rows went in
-- against the database directly. The schema is in the repository; the names
-- are not.
--
-- ── one spelling, one person ──────────────────────────────────
--
-- The unique index is on the spelling alone rather than on the pair, because
-- a matcher that gets two answers has no answer. Two clients who really do
-- share a spelling make this refuse, which is the owner's own rule for the
-- reconciliation - "fits two or more, report and wait" - enforced rather than
-- remembered. The same goes for an alias that collides with somebody's real
-- name: the trigger below refuses it, because the record's own name has to
-- win and a second answer would make it a coin toss.

begin;

create table if not exists public.client_aliases (
  id            uuid primary key default gen_random_uuid(),
  client_id     uuid not null references public.clients(id) on delete cascade,
  name          text not null,
  -- Where this spelling was seen, so somebody can judge it: a warrant, a USOR
  -- form, an email, or somebody typing it.
  source        text not null default 'Other',
  note          text not null default '',
  added_by      uuid references public.staff(id) on delete set null,
  added_by_name text not null default '',
  at            timestamptz not null default now(),
  constraint client_aliases_name_said check (btrim(name) <> ''),
  constraint client_aliases_source_check
    check (source in ('Warrant', 'USOR form', 'Email', 'Staff', 'Other'))
);

create unique index if not exists client_aliases_one_person_per_spelling
  on public.client_aliases (lower(btrim(name)));

create index if not exists client_aliases_client_idx
  on public.client_aliases (client_id);

comment on table public.client_aliases is
  'Other spellings of a client''s name, so a warrant or an email under one of '
  'them finds the record. The record''s own name is what the signed '
  'authorization says; these are ways in, not corrections.';

-- ── an alias cannot be somebody else's name ──────────────────
create or replace function public.client_alias_is_not_a_name()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_other uuid;
begin
  select c.id into v_other
    from public.clients c
   where lower(btrim(c.name)) = lower(btrim(new.name))
     and c.merged_into is null
   limit 1;

  if v_other = new.client_id then
    raise exception 'That is already this client''s name.'
      using hint = 'A spelling is for what somebody else writes, not for what the record already says.',
            errcode = 'unique_violation';
  end if;
  if v_other is not null then
    raise exception 'That spelling is another client''s own name.'
      using hint = 'Two records answering to one spelling leaves nothing to match on. Merge them, or use a different spelling.',
            errcode = 'unique_violation';
  end if;
  return new;
end $$;

drop trigger if exists client_aliases_not_a_name on public.client_aliases;
create trigger client_aliases_not_a_name
  before insert or update on public.client_aliases
  for each row execute function public.client_alias_is_not_a_name();

-- ── who may read and change them ─────────────────────────────
alter table public.client_aliases enable row level security;

drop policy if exists client_aliases_read on public.client_aliases;
create policy client_aliases_read on public.client_aliases
  for select using ((select public.is_active_staff()));

drop policy if exists client_aliases_write on public.client_aliases;
create policy client_aliases_write on public.client_aliases
  for all using ((select public.billing_hands())) with check ((select public.billing_hands()));

revoke all on public.client_aliases from anon, authenticated;
grant select on public.client_aliases to authenticated;
grant insert, update, delete on public.client_aliases to authenticated;
revoke execute on function public.client_alias_is_not_a_name() from anon, authenticated;

-- ── the two places a name is looked up ───────────────────────
--
-- intake_find_client is what files an arriving document or email against a
-- client. It matched the record's own name and the name a merged-away record
-- used to have; now it also matches a spelling on file, and says which it was,
-- because "how" is shown to the person deciding whether the filing is right.
create or replace function public.intake_find_client(p_name text)
 returns table(client_id uuid, client_name text, how text)
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  with wanted as (select lower(btrim(coalesce(p_name, ''))) as n)
  select c.id, c.name, 'name'::text
    from public.clients c, wanted w
   where w.n <> '' and lower(btrim(c.name)) = w.n and c.merged_into is null
  union
  select public.client_merged_into(c.id), c.name, 'a name this record was merged under'::text
    from public.clients c, wanted w
   where w.n <> '' and lower(btrim(c.name)) = w.n and c.merged_into is not null
     and public.client_merged_into(c.id) is not null
  union
  select coalesce(public.client_merged_into(c.id), c.id), c.name,
         'another spelling of this name'::text
    from public.client_aliases a
    join public.clients c on c.id = a.client_id, wanted w
   where w.n <> '' and lower(btrim(a.name)) = w.n
     and coalesce(public.client_merged_into(c.id), c.id) is not null
$function$;

-- And the search box, so somebody who types the spelling they were sent finds
-- the person. The alias is matched the way the name is - anywhere in it - and
-- a record is still listed once however many of its spellings match.
create or replace function public.search_clients(p_query text default ''::text, p_limit integer default 12)
 returns table(id uuid, name text, client_no integer, stage text, status text,
               assigned_name text, counselor_name text, recent boolean)
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  with me as (select public.current_staff_id() as staff_id),
  q as (select btrim(coalesce(p_query, '')) as text),
  digits as (select regexp_replace((select text from q), '[^0-9]', '', 'g') as digits_only)
  select c.id, c.name, c.client_no, c.stage, c.status,
         s.name, co.name,
         r.staff_id is not null
    from public.clients c
    left join public.staff s on s.id = c.assigned_staff_id
    left join public.counselors co on co.id = c.counselor_id
    left join public.client_recents r on r.client_id = c.id and r.staff_id = (select staff_id from me)
   where public.is_active_staff()
     and case
           when (select text from q) = '' then r.staff_id is not null
           else c.name ilike '%' || (select text from q) || '%'
             or c.client_no::text = (select text from q)
             or c.agency_id ilike '%' || (select text from q) || '%'
             or lower(c.email) like '%' || lower((select text from q)) || '%'
             or exists (select 1 from public.client_aliases a
                         where a.client_id = c.id
                           and a.name ilike '%' || (select text from q) || '%')
             or ((select digits_only from digits) <> ''
                 and regexp_replace(coalesce(c.phone, ''), '[^0-9]', '', 'g') like '%' || (select digits_only from digits) || '%')
         end
   order by (r.staff_id is not null) desc, r.opened_at desc nulls last,
            -- A name that starts with what was typed before one that merely
            -- contains it: "Ann" should find Ann before Joanne.
            (c.name ilike (select text from q) || '%') desc,
            c.name
   limit least(coalesce(p_limit, 12), 50);
$function$;

commit;
