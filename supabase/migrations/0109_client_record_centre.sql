-- Zion Vocational Rehab CRM — the client record at the centre
--
-- The work of this practice happens against one client at a time, but the CRM
-- has been arranged by feature: to text somebody you went to Messages, to bill
-- for them you went to Billing, to log the visit you went to Hours. Every one
-- of those is a journey away from the record and back, and the way back is
-- where the client id gets lost and the note gets written later, or not.
--
-- So: get to a client from anywhere, and do the day's work without leaving
-- them. This migration is the database half of that -
--
--   getting there: what somebody has open lately, and one search across the
--   things a client is actually looked up by - name, number, phone, address.
--
--   what is next: the due things for one client, worked out in one place so
--   the strip on the record and anything else that asks cannot disagree.
--
--   signing: a signature image per staff member, uploaded once, stamped onto
--   what they sign. Kept in the restricted tier and readable only by its
--   owner - a signature is not a document about a client, it is the means of
--   signing as a person, and nobody else has any business holding it.

-- ── recently opened ─────────────────────────────────────────
-- Not history and not an audit: the handful of records this person has had
-- open, so the search box can offer them before anybody types. Old rows are
-- of no interest and are not kept.
create table if not exists public.client_recents (
  staff_id  uuid not null references public.staff(id) on delete cascade,
  client_id uuid not null references public.clients(id) on delete cascade,
  opened_at timestamptz not null default now(),
  primary key (staff_id, client_id)
);
create index if not exists client_recents_recent_idx on public.client_recents (staff_id, opened_at desc);

alter table public.client_recents enable row level security;

drop policy if exists client_recents_own on public.client_recents;
create policy client_recents_own on public.client_recents for select to authenticated
  using (staff_id = (select public.current_staff_id()));

revoke all on public.client_recents from anon;
revoke insert, update, delete on public.client_recents from authenticated;
grant select on public.client_recents to authenticated;
grant all on public.client_recents to service_role;

/** Opening a record puts it at the top of that person's recents. */
create or replace function public.note_client_opened(p_client uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := public.current_staff_id();
begin
  if v_me is null or not public.is_active_staff() then
    return;
  end if;
  insert into public.client_recents (staff_id, client_id, opened_at)
  values (v_me, p_client, now())
  on conflict (staff_id, client_id) do update set opened_at = now();

  -- Ten is what a person recognises in a list without reading it.
  delete from public.client_recents r
   where r.staff_id = v_me
     and r.opened_at < (select min(k.opened_at) from (
           select opened_at from public.client_recents
            where staff_id = v_me order by opened_at desc limit 10) k);
end;
$$;

/**
 * One search across what a client is actually looked up by.
 *
 * With nothing typed it is the recents, which is the common case: the person
 * you were just with. With something typed it is name, client number, USOR
 * id, phone and email - a phone number matched however it was written down,
 * because the number on a sticky note has dashes and the one on the record
 * does not.
 */
create or replace function public.search_clients(p_query text default '', p_limit integer default 12)
returns table (
  id uuid, name text, client_no integer, stage text, status text,
  assigned_name text, counselor_name text, recent boolean
)
language sql stable security definer set search_path = public as $$
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
             or ((select digits_only from digits) <> ''
                 and regexp_replace(coalesce(c.phone, ''), '[^0-9]', '', 'g') like '%' || (select digits_only from digits) || '%')
         end
   order by (r.staff_id is not null) desc, r.opened_at desc nulls last,
            -- A name that starts with what was typed before one that merely
            -- contains it: "Ann" should find Ann before Joanne.
            (c.name ilike (select text from q) || '%') desc,
            c.name
   limit least(coalesce(p_limit, 12), 50);
$$;

-- ── what is next for this client ────────────────────────────
/**
 * The due things for one client, in one place.
 *
 * Each row is something somebody can act on now, with where the action is.
 * Worked out here rather than on the screen so that the strip on the record,
 * the dashboard and anything else added later are reading the same answer -
 * two implementations of "what is due" eventually disagree, and the one
 * nobody is reading is the one that is wrong.
 *
 * Ordered by how soon it matters, not by kind.
 */
create or replace function public.client_next_actions(p_client uuid)
returns table (kind text, title text, detail text, href text, urgency integer)
language sql stable security definer set search_path = public as $$
  with c as (select * from public.clients where id = p_client)
  -- The next appointment, from client_next_up rather than from the events
  -- table: that view already knows an appointment being withdrawn from
  -- Outlook is not one, and a second definition here would forget.
  -- Parenthesised because a branch of a union may not carry its own order.
  (select 'appointment',
         'Appointment ' || to_char(n.at at time zone 'America/Denver', 'Dy DD Mon, FMHH12:MIam'),
         n.title,
         '/clients/' || p_client || '?tab=activity',
         case when n.at < now() + interval '24 hours' then 1 else 4 end
    from public.client_next_up n
   where n.client_id = p_client and n.kind = 'Appointment'
   order by n.at limit 1)

  union all
  -- A form that is blocking billing: hours logged against an authorization
  -- with no form for them.
  select 'form', p.usor || ' needed',
         p.form_name || coalesce(' · ' || p.month, '') || ' · ' || trim(to_char(p.hours_logged, 'FM999990.9')) || ' hours logged',
         '/clients/' || p_client || '?tab=billing&bill=' || p.auth_id || coalesce('&month=' || p.month, ''),
         2
    from public.client_paperwork p
   where p.client_id = p_client and p.state = 'Missing'

  union all
  -- An authorization running out, with hours on it nobody has billed for.
  select 'authorization', 'Authorization ' || a.number || ' ends ' || to_char(a.end_date, 'FMDD Mon'),
         trim(to_char(coalesce(u.hours, 0), 'FM999990.9')) || ' hours logged on it',
         '/clients/' || p_client || '?tab=billing',
         case when a.end_date <= public.practice_today() + 14 then 1 else 3 end
    from public.authorizations a
    left join lateral (
      select sum(se.hours) hours from public.service_entries se
       where se.auth_id = a.id and not se.non_billable) u on true
   where a.client_id = p_client and a.status = 'Open'
     and a.end_date is not null and a.end_date <= public.practice_today() + 30
     and coalesce(u.hours, 0) > 0

  union all
  -- A text from them that nobody has answered.
  select 'text', 'Unanswered text', left(m.body, 80),
         '/clients/' || p_client || '?tab=messages', 1
    from public.conversations v
    join lateral (
      select body, sender_kind from public.messages
       where conversation_id = v.id order by seq desc limit 1) m on true
   where v.client_id = p_client and v.kind = 'sms' and m.sender_kind = 'client'

  union all
  -- Nobody has recorded whether they agreed to be texted.
  select 'consent', 'Texting consent not recorded',
         'They cannot be texted until it is', '/clients/' || p_client || '?tab=profile#texting', 3
    from c
   where not exists (select 1 from public.sms_consent_events e where e.client_id = p_client)

  union all
  -- A retention check that has come due on a placement.
  select 'retention', d.label || ' check due',
         coalesce(nullif(pl.employer, ''), 'a placement'),
         '/clients/' || p_client || '?tab=jobs', 2
    from public.placements pl
    cross join lateral (values
      (pl.check30, 30, '30 day'), (pl.check60, 60, '60 day'), (pl.check90, 90, '90 day')
    ) d(done, days, label)
   where pl.client_id = p_client and pl.start_date is not null
     and d.done is null and pl.start_date + d.days <= public.practice_today()

  order by 5, 1;
$$;

-- ── a signature, per person ─────────────────────────────────
-- Uploaded once and stamped on what they sign. The path only: the image is in
-- the restricted bucket like anything else that identifies somebody.
create table if not exists public.staff_signatures (
  staff_id     uuid primary key references public.staff(id) on delete cascade,
  storage_path text not null,
  uploaded_at  timestamptz not null default now()
);

alter table public.staff_signatures enable row level security;

-- Their own, and nobody else's - not Admin's either. A signature is the means
-- of signing as a person; holding somebody else's is not an administrative
-- convenience, it is the ability to sign as them.
drop policy if exists staff_signatures_own on public.staff_signatures;
create policy staff_signatures_own on public.staff_signatures for select to authenticated
  using (staff_id = (select public.current_staff_id()));

revoke all on public.staff_signatures from anon;
revoke insert, update, delete on public.staff_signatures from authenticated;
grant select on public.staff_signatures to authenticated;
grant all on public.staff_signatures to service_role;

/** Where this person's signature lives, set when they upload one. */
create or replace function public.set_my_signature(p_path text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := public.current_staff_id();
begin
  if v_me is null or not public.is_active_staff() then
    raise exception 'Only staff have a signature here.' using errcode = 'insufficient_privilege';
  end if;
  if coalesce(btrim(p_path), '') = '' then
    raise exception 'There is no file to record.' using errcode = 'check_violation';
  end if;
  insert into public.staff_signatures (staff_id, storage_path, uploaded_at)
  values (v_me, btrim(p_path), now())
  on conflict (staff_id) do update set storage_path = excluded.storage_path, uploaded_at = now();
end;
$$;

create or replace function public.clear_my_signature()
returns void language sql security definer set search_path = public as $$
  delete from public.staff_signatures where staff_id = public.current_staff_id();
$$;

/** Whether somebody has one yet, for the prompt that asks them to add it. */
create or replace function public.have_my_signature()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.staff_signatures where staff_id = public.current_staff_id());
$$;

-- ── who may call what ───────────────────────────────────────
revoke execute on function public.note_client_opened(uuid) from public, anon;
revoke execute on function public.search_clients(text, integer) from public, anon;
revoke execute on function public.client_next_actions(uuid) from public, anon;
revoke execute on function public.set_my_signature(text) from public, anon;
revoke execute on function public.clear_my_signature() from public, anon;
revoke execute on function public.have_my_signature() from public, anon;
grant execute on function public.note_client_opened(uuid) to authenticated;
grant execute on function public.search_clients(text, integer) to authenticated;
grant execute on function public.client_next_actions(uuid) to authenticated;
grant execute on function public.set_my_signature(text) to authenticated;
grant execute on function public.clear_my_signature() to authenticated;
grant execute on function public.have_my_signature() to authenticated, service_role;
