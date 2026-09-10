-- ─────────────────────────────────────────────────────────────
-- 8.9 — the document inbox
--
-- The owner keeps a folder per client on his own machine, and everything
-- USOR sends lands in it. Reading that folder from the cloud would have meant
-- granting an application write access to an entire OneDrive, and Graph has
-- no permission narrower than that. So nothing is granted: a small agent runs
-- on the machine that already has the files, and posts them here.
--
-- Which makes this the one place in the system where something arrives
-- without a person having done it, and that shapes every rule below.
--
--   Nothing is filed on arrival. A document becomes a proposal, and a person
--   confirms it. An authorization read wrongly and applied silently is a rate
--   on a client's record that nobody typed and nobody checked.
--
--   Nothing is ever moved, renamed or deleted on the machine. The folder is
--   the owner's, not ours. What stops a file being handled twice is its hash,
--   held here.
--
--   A folder that matches no client is not a guess. It waits in a list with
--   the name it had, until somebody says who it belongs to.
-- ─────────────────────────────────────────────────────────────

create table if not exists public.inbox_documents (
  id            uuid primary key default gen_random_uuid(),

  -- The identity of the file, and the only thing that stops it being
  -- processed twice. Not the path: a file renamed on the machine is the same
  -- document, and one edited in place is a different one.
  sha256        text not null unique,

  folder_name   text not null,
  relative_path text not null,
  filename      text not null,
  size_bytes    bigint not null default 0,
  file_modified timestamptz,

  client_id     uuid references public.clients(id) on delete set null,

  kind          text not null default 'Unread'
                  check (kind in ('Unread', 'Authorization', 'USOR form', 'Warrant', 'Other', 'Unreadable')),

  state         text not null default 'Pending'
                  check (state in ('Pending', 'Filed', 'Ignored')),

  -- What was read out of it, and what is proposed as a result. Kept as it was
  -- read so a wrong proposal leads back to the text it came from.
  parsed        jsonb,
  proposal      jsonb,

  storage_path  text,

  -- Set when somebody acted on it, never by the agent.
  decided_by    uuid references public.staff(id) on delete set null,
  decided_at    timestamptz,
  outcome       text not null default '',

  first_seen    timestamptz not null default now()
);

create index if not exists inbox_documents_state_idx
  on public.inbox_documents (state, first_seen desc);
create index if not exists inbox_documents_client_idx
  on public.inbox_documents (client_id, first_seen desc);

alter table public.inbox_documents enable row level security;

drop policy if exists inbox_documents_read on public.inbox_documents;
drop policy if exists inbox_documents_write on public.inbox_documents;

-- Whoever can act on one can see it: an authorization is Billing's, a USOR
-- form is casework's. Not everybody, because a document nobody has read yet
-- may hold anything.
create policy inbox_documents_read on public.inbox_documents
  for select to authenticated
  using (public.current_staff_role() in ('Admin', 'Billing', 'Job Search', 'Reports'));

create policy inbox_documents_write on public.inbox_documents
  for update to authenticated
  using (public.current_staff_role() in ('Admin', 'Billing', 'Job Search', 'Reports'))
  with check (public.current_staff_role() in ('Admin', 'Billing', 'Job Search', 'Reports'));

-- No insert policy: rows arrive from the agent, which authenticates with a
-- shared secret and runs as the service role. Nobody signed in invents one.

-- ─────────────────────────────────────────────────────────────
-- Folders whose name is not a client
--
-- A folder called "Smith, John (closed)" belongs to a client whose name is
-- "John Smith", and no amount of string-matching should be trusted to say so.
-- Somebody says it once and it is remembered.
-- ─────────────────────────────────────────────────────────────
create table if not exists public.inbox_folder_map (
  folder_name text primary key,
  client_id   uuid references public.clients(id) on delete cascade,
  -- True when somebody has looked and decided this folder is not a client at
  -- all — an archive, a template folder, something of the owner's.
  not_a_client boolean not null default false,
  mapped_by   uuid references public.staff(id) on delete set null,
  mapped_at   timestamptz not null default now()
);

alter table public.inbox_folder_map enable row level security;

drop policy if exists inbox_folder_map_read on public.inbox_folder_map;
drop policy if exists inbox_folder_map_write on public.inbox_folder_map;

create policy inbox_folder_map_read on public.inbox_folder_map
  for select to authenticated using (public.is_active_staff());
create policy inbox_folder_map_write on public.inbox_folder_map
  for all to authenticated
  using (public.current_staff_role() in ('Admin', 'Job Search', 'Reports'))
  with check (public.current_staff_role() in ('Admin', 'Job Search', 'Reports'));

-- ─────────────────────────────────────────────────────────────
-- Matching a folder to a client
--
-- Exact, then exact-ignoring-case-and-punctuation, then the remembered map.
-- Nothing fuzzier: "J Smith" matching "Jane Smith" is how a client's
-- authorization ends up on somebody else's record, and the cost of asking is
-- one click.
-- ─────────────────────────────────────────────────────────────
create or replace function public.match_inbox_folder(p_folder text)
returns uuid language plpgsql stable as $$
declare
  v_client uuid;
  v_norm   text := lower(regexp_replace(coalesce(p_folder, ''), '[^a-zA-Z0-9]', '', 'g'));
begin
  if v_norm = '' then return null; end if;

  -- A decision somebody has already made wins over any matching.
  select client_id into v_client from public.inbox_folder_map
   where lower(folder_name) = lower(p_folder);
  if found then return v_client; end if;

  select id into v_client from public.clients
   where lower(regexp_replace(name, '[^a-zA-Z0-9]', '', 'g')) = v_norm
   limit 1;
  if found then return v_client; end if;

  -- "Smith, John" for "John Smith". Only where the folder is exactly two
  -- comma-separated parts, and only where reversing them matches exactly.
  if position(',' in p_folder) > 0 and array_length(string_to_array(p_folder, ','), 1) = 2 then
    select id into v_client from public.clients
     where lower(regexp_replace(name, '[^a-zA-Z0-9]', '', 'g')) =
           lower(regexp_replace(
             trim(split_part(p_folder, ',', 2)) || trim(split_part(p_folder, ',', 1)),
             '[^a-zA-Z0-9]', '', 'g'))
     limit 1;
    if found then return v_client; end if;
  end if;

  return null;
end;
$$;

-- ─────────────────────────────────────────────────────────────
-- Recording what the agent found
--
-- Definer, called by the endpoint as the service role. Returns whether this
-- is new, so the agent knows whether to send the file itself — the manifest
-- is cheap and the upload is not.
-- ─────────────────────────────────────────────────────────────
create or replace function public.inbox_seen(p_hashes text[])
returns table (sha256 text, known boolean)
language sql stable security definer set search_path = public as $$
  select h                                     as sha256,
         exists (select 1 from public.inbox_documents d where d.sha256 = h) as known
    from unnest(p_hashes) h;
$$;

revoke execute on function public.inbox_seen(text[]) from public;
revoke execute on function public.inbox_seen(text[]) from authenticated;
grant execute on function public.inbox_seen(text[]) to service_role;

-- ─────────────────────────────────────────────────────────────
-- What is waiting, and what it is waiting for
-- ─────────────────────────────────────────────────────────────
create or replace view public.inbox_pending as
select d.id,
       d.sha256,
       d.folder_name,
       d.relative_path,
       d.filename,
       d.size_bytes,
       d.file_modified,
       d.first_seen,
       d.kind,
       d.state,
       d.parsed,
       d.proposal,
       d.storage_path,
       d.client_id,
       c.name                                   as client_name,
       -- Three reasons a document cannot simply be filed, named separately
       -- because they need different people to fix them.
       (d.client_id is null)                    as needs_a_client,
       (d.kind = 'Unreadable')                  as needs_typing_in,
       (d.kind = 'Authorization')               as needs_confirming
  from public.inbox_documents d
  left join public.clients c on c.id = d.client_id
 where d.state = 'Pending';

alter view public.inbox_pending set (security_invoker = true);
grant select on public.inbox_pending to authenticated;

comment on view public.inbox_pending is
  'Documents the agent has posted that nobody has acted on yet, with why each one is still waiting.';

-- ─────────────────────────────────────────────────────────────
-- How the agent is doing
--
-- Read by a screen so somebody can answer "is it running?" without going to
-- the machine. A run that finds nothing still says it ran.
-- ─────────────────────────────────────────────────────────────
create table if not exists public.inbox_runs (
  id           bigserial primary key,
  ran_at       timestamptz not null default now(),
  machine      text not null default '',
  agent_version text not null default '',
  files_seen   integer not null default 0,
  files_new    integer not null default 0,
  folders_seen integer not null default 0,
  error        text not null default ''
);

create index if not exists inbox_runs_at_idx on public.inbox_runs (ran_at desc);

alter table public.inbox_runs enable row level security;

drop policy if exists inbox_runs_read on public.inbox_runs;

create policy inbox_runs_read on public.inbox_runs
  for select to authenticated using (public.is_active_staff());

-- Written by the endpoint as the service role, like the documents.
