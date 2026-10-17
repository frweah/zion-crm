-- Zion Vocational Rehab CRM — the hours used, counted once
-- (stress test, findings 2 and 3, owner 16 Oct 2026)
--
-- Three places answer "how many hours has this authorization used", and all
-- three count differently:
--
--   check_entry_hours (0171) counts across the coaching family - the parent
--   and every month under it - plus carried_used, which is the rule the
--   database actually enforces.
--
--   authorization_attention (0170) counts the same family, but reaches it
--   through an OR across a join, once per authorization on the working list.
--
--   The Billing screen counts in TypeScript, per authorization and its own
--   entries only, which misses every hour logged on a coaching month. So the
--   form offers hours the database then refuses.
--
-- This is the single answer. One aggregate over the whole set asked for,
-- rather than one query per authorization, and the trigger reads it too, so
-- what the form shows and what the database enforces cannot drift apart.
--
-- p_excluding is for the trigger: when it asks, the row it is checking is
-- either not in the table yet or is the old version of itself, and either way
-- it must not be counted twice.
--
-- Not security definer. service_entries_read (0003) is
-- `using (is_active_staff())`, so every active staff member already reads
-- every entry; a definer here would buy nothing and would hide the next
-- change to that policy.

create or replace function public.authorization_hours_used(
  p_auths     uuid[],
  p_excluding uuid default null
)
returns table (auth_id uuid, used numeric)
language sql stable set search_path = public as $$
  with asked as (
    select a.id, coalesce(a.parent_id, a.id) as root
      from public.authorizations a
     where a.id = any(p_auths)
  ),
  -- Every authorization whose hours count towards each root: the root itself
  -- and its months. One join, for the whole set.
  family as (
    select distinct r.root, c.id as member
      from (select distinct root from asked) r
      join public.authorizations c
        on c.id = r.root or c.parent_id = r.root
  ),
  logged as (
    select f.root, coalesce(sum(e.hours), 0) as hours
      from family f
      left join public.service_entries e
        on e.auth_id = f.member
       and e.non_billable = false
       and (p_excluding is null or e.id is distinct from p_excluding)
     group by f.root
  )
  select a.id,
         -- carried_used belongs to the root, as check_entry_hours reads it.
         coalesce(root.carried_used, 0) + coalesce(l.hours, 0)
    from asked a
    join public.authorizations root on root.id = a.root
    left join logged l on l.root = a.root;
$$;

comment on function public.authorization_hours_used(uuid[], uuid) is
  'Hours used per authorization, counted across the coaching family and including carried_used - the one definition, read by check_entry_hours, by the working list and by the Billing screen (0205).';

revoke all on function public.authorization_hours_used(uuid[], uuid) from anon, authenticated;
grant execute on function public.authorization_hours_used(uuid[], uuid) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- And the trigger reads it, instead of keeping its own copy of the sum.
--
-- Unchanged in every other respect: the future-date refusal, the non-billable
-- pass, the flat-fee pass, and the wording of the refusal are 0171's.
-- ─────────────────────────────────────────────────────────────
create or replace function public.check_entry_hours()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  a          public.authorizations%rowtype;
  v_root     uuid;
  v_total    numeric;
  used_hours numeric;
begin
  if new.date > public.practice_today() then
    raise exception 'Service hours cannot be logged for % — that date has not happened yet.',
      new.date using errcode = 'check_violation';
  end if;

  if new.non_billable then
    return new;
  end if;

  select * into a from public.authorizations where id = new.auth_id;
  if not found then
    return new;
  end if;

  v_root := coalesce(a.parent_id, a.id);
  select total_hours into v_total from public.authorizations where id = v_root;

  if v_total is null then
    return new;                                   -- flat fee, no hour cap
  end if;

  select u.used into used_hours
    from public.authorization_hours_used(array[v_root], new.id) u;

  if used_hours + new.hours > v_total then
    raise exception
      'Entry of % hrs exceeds the hours left on % (% authorized, % used). Request additional hours from the counselor first.',
      new.hours,
      coalesce(nullif((select number from public.authorizations where id = v_root), ''), a.service_type),
      v_total, used_hours
      using errcode = 'check_violation';
  end if;

  return new;
end;
$$;

do $$
declare
  v_auth uuid;
  v_used numeric;
begin
  select id into v_auth from public.authorizations
   where total_hours is not null and parent_id is null order by created_at limit 1;
  if v_auth is null then
    raise notice 'ok  no hourly authorization on file to read; the function is in place';
  else
    select used into v_used from public.authorization_hours_used(array[v_auth]) u;
    raise notice 'ok  hours used reads for one authorization: %', v_used;
  end if;
end $$;
