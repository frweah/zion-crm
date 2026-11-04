-- A credential is required of the people who need it
--
-- ACRE is the employment-services training USOR expects of a job coach, and it
-- was marked `applies_to = 'everyone'`. So the practice's bookkeeper, its
-- reports writer and two automated accounts were all being chased for a job
-- coaching certificate, every day, on the same screen as the things that
-- genuinely are everybody's. Thirty-two alerts across eight names, of which
-- eight were for accounts that are not people.
--
-- An alert nobody can act on is worse than no alert: it teaches the people who
-- see it to stop reading the list, and the list is where a lapsed background
-- check is supposed to show up.
--
-- Three changes, in the shape the table already had. `applies_to` was never
-- "everybody or nobody" - 'drivers' has always meant "whoever the practice has
-- recorded as transporting clients", resolved per person through
-- `staff_employment.transports_clients`. This follows that exactly:
--
--   * **'direct_service'** joins 'everyone' and 'drivers' as an audience, and
--     ACRE and continuing education move onto it. Resolved per person through
--     `staff_employment.delivers_services` - whether they deliver job coaching
--     or supported employment - which is a property of the person and not of
--     their role, as transporting clients already is: a job coach who has
--     moved to intake stops needing it, and an Admin who coaches needs it.
--
--   * **`staff_credential_requirements`** is the exception to the audience: an
--     Admin saying that this person does or does not need this credential,
--     whatever the default says, with the reason and who decided. The brief
--     asked for the default to come from the role and for Admin to be able to
--     edit it; this is the editing half, and it is a record rather than a
--     setting - "Rispah does not need ACRE" is a decision somebody took and
--     the next person to wonder deserves to see who and why.
--
--   * **System accounts are not people.** `is_system` staff are excluded from
--     the credential list entirely. Nobody can hold a CPR card on behalf of an
--     automated check, and nothing on the roster of people should list one.
--
-- Nobody's credentials are deleted and nothing anybody holds is touched: what
-- changes is only which of them the practice asks for.

-- ─────────────────────────────────────────────────────────────
-- Who delivers the services the certificate is about

alter table public.staff_employment
  add column if not exists delivers_services boolean not null default false;

comment on column public.staff_employment.delivers_services is
  'Delivers job coaching or supported employment. A property of the person, not the role, the same way transports_clients is: it decides whether ACRE and continuing education are asked of them.';

alter table public.credential_types drop constraint if exists credential_types_applies_to_check;
alter table public.credential_types add constraint credential_types_applies_to_check
  check (applies_to in ('everyone', 'drivers', 'direct_service'));

update public.credential_types set applies_to = 'direct_service' where key in ('acre', 'ce');

-- ─────────────────────────────────────────────────────────────
-- The exception to the audience

create table if not exists public.staff_credential_requirements (
  staff_id    uuid not null references public.staff(id) on delete cascade,
  type_key    text not null references public.credential_types(key) on delete cascade,
  required    boolean not null,
  reason      text not null default '',
  decided_by  uuid references public.staff(id) on delete set null,
  decided_at  timestamptz not null default now(),
  primary key (staff_id, type_key)
);

comment on table public.staff_credential_requirements is
  'An Admin saying this person does or does not need this credential, whatever their audience says. A record of a decision, with who took it.';

-- Supabase grants everything on a new public table to `authenticated`,
-- TRUNCATE included, so the revoke is the work. Reading is for staff; the only
-- way to write is the function below, which is the house pattern and is what
-- keeps the reason and the decider from being optional.
alter table public.staff_credential_requirements enable row level security;
revoke all on table public.staff_credential_requirements from anon, authenticated;
grant select on table public.staff_credential_requirements to authenticated;

drop policy if exists staff_credential_requirements_read on public.staff_credential_requirements;
create policy staff_credential_requirements_read on public.staff_credential_requirements
  for select using ((select public.is_active_staff()));

-- The automated accounts read every screen and change nothing, which is a
-- restrictive policy per command and the same three on every table that has
-- them. `verify_system_account.sql` asks the catalogue rather than a list, and
-- it caught this one the first time the suite ran.
select public.apply_system_read_only('staff_credential_requirements');

create or replace function public.set_credential_requirement(
  p_staff    uuid,
  p_type     text,
  p_required boolean,
  p_reason   text default ''
)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_me    uuid := public.current_staff_id();
  v_role  text := public.current_staff_role();
  v_name  text;
  v_label text;
begin
  if v_role <> 'Admin' then
    raise exception 'Only Admin says which credentials somebody needs.'
      using errcode = 'insufficient_privilege';
  end if;

  select name into v_name from public.staff where id = p_staff and active and not is_system;
  if v_name is null then
    raise exception 'That is not somebody on the staff.' using errcode = 'no_data_found';
  end if;

  select label into v_label from public.credential_types where key = p_type and active;
  if v_label is null then
    raise exception 'That is not a credential the practice keeps.' using errcode = 'no_data_found';
  end if;

  -- Saying "do what the default says" is removing the exception, not recording
  -- a third state. Passing null for p_required is how a screen says that.
  if p_required is null then
    delete from public.staff_credential_requirements
     where staff_id = p_staff and type_key = p_type;
    return format('%s now follows the practice default for %s', v_name, v_label);
  end if;

  insert into public.staff_credential_requirements (staff_id, type_key, required, reason, decided_by, decided_at)
  values (p_staff, p_type, p_required, coalesce(btrim(p_reason), ''), v_me, now())
  on conflict (staff_id, type_key) do update
    set required = excluded.required,
        reason = excluded.reason,
        decided_by = excluded.decided_by,
        decided_at = excluded.decided_at;

  return format('%s %s %s', v_name, case when p_required then 'now needs' else 'does not need' end, v_label);
end $$;

revoke all on function public.set_credential_requirement(uuid, text, boolean, text) from anon, authenticated;
grant execute on function public.set_credential_requirement(uuid, text, boolean, text) to authenticated;
-- Restated rather than left to the replace: security_invoker is what makes
-- the view read as the person looking rather than as its owner, and a
-- `create or replace view` that does not say so is one Postgres release away
-- from quietly dropping it.
create or replace view public.staff_credential_status
  with (security_invoker = true) as
 WITH required AS (
         SELECT s.id AS staff_id,
            t.key AS type_key,
            t.label,
            t.kind,
            t.expires,
            t.warn_days,
            t.hours_target,
            t.applies_to,
            t.sort_order,
            -- The audience, then the exception. 'drivers' always meant
            -- "whoever the practice records as transporting clients";
            -- 'direct_service' means whoever delivers job coaching or
            -- supported employment, and an Admin can say otherwise about any
            -- one person (0288).
            COALESCE(req.required,
              CASE t.applies_to
                WHEN 'everyone' THEN true
                WHEN 'drivers' THEN COALESCE(e.transports_clients, false)
                WHEN 'direct_service' THEN COALESCE(e.delivers_services, false)
                ELSE false
              END) AS required
           FROM staff s
             CROSS JOIN credential_types t
             LEFT JOIN staff_employment e ON e.staff_id = s.id
             LEFT JOIN staff_credential_requirements req
                    ON req.staff_id = s.id AND req.type_key = t.key
          WHERE s.active AND NOT s.is_system AND t.active
        ), latest AS (
         SELECT DISTINCT ON (c_1.staff_id, c_1.type_key) c_1.staff_id,
            c_1.type_key,
            c_1.id AS credential_id,
            c_1.issued_on,
            c_1.expires_on,
            c_1.reference,
            c_1.file_id,
            c_1.verified_at,
            c_1.verified_by
           FROM staff_credentials c_1
          ORDER BY c_1.staff_id, c_1.type_key, c_1.expires_on DESC, c_1.created_at DESC
        ), ce AS (
         SELECT ce_entries.staff_id,
            sum(ce_entries.hours) FILTER (WHERE ce_entries.on_date >= date_trunc('year'::text, practice_today()::timestamp with time zone)::date) AS hours_this_year,
            max(ce_entries.on_date) AS last_entry_on
           FROM ce_entries
          GROUP BY ce_entries.staff_id
        )
 SELECT r.staff_id,
    r.type_key,
    r.label,
    r.kind,
    r.required,
    r.sort_order,
    l.credential_id,
    l.reference,
    l.issued_on,
    l.expires_on,
    l.file_id,
    l.verified_at,
    COALESCE(c.hours_this_year, 0::numeric) AS hours_this_year,
    r.hours_target,
    c.last_entry_on,
        CASE
            WHEN r.kind = 'hours'::text THEN
            CASE
                WHEN NOT r.required THEN 'Not required'::text
                WHEN COALESCE(c.hours_this_year, 0::numeric) >= COALESCE(r.hours_target, 0::numeric) THEN 'Met'::text
                ELSE 'Outstanding'::text
            END
            WHEN l.credential_id IS NULL THEN
            CASE
                WHEN r.required THEN 'Missing'::text
                ELSE 'Not held'::text
            END
            WHEN r.expires AND l.expires_on IS NOT NULL AND l.expires_on < practice_today() THEN 'Expired'::text
            WHEN l.verified_at IS NULL THEN 'Awaiting check'::text
            WHEN NOT r.expires OR l.expires_on IS NULL THEN 'Valid'::text
            WHEN l.expires_on <= (practice_today() + r.warn_days) THEN 'Expiring'::text
            ELSE 'Valid'::text
        END AS state,
        CASE
            WHEN l.expires_on IS NULL THEN NULL::integer
            ELSE l.expires_on - practice_today()
        END AS days_left
   FROM required r
     LEFT JOIN latest l ON l.staff_id = r.staff_id AND l.type_key = r.type_key
     LEFT JOIN ce c ON c.staff_id = r.staff_id AND r.kind = 'hours'::text
  WHERE r.required OR l.credential_id IS NOT NULL;

revoke all on table public.staff_credential_status from anon, authenticated;
grant select on table public.staff_credential_status to authenticated;

-- ─────────────────────────────────────────────────────────────
-- What the practice is now asking for, and of whom
--
-- The counts are printed rather than asserted at a number, because the roster
-- changes and a check written against "eight people" is a check that fails the
-- first time somebody is hired. What is asserted is the rule.

do $$
declare
  v_before integer; v_after integer; v_acre integer; v_system integer;
  r record;
begin
  select count(*) into v_after from public.credential_attention;
  -- Asked for, as opposed to held. A credential somebody has submitted and
  -- nobody has verified still shows as 'Awaiting check' whether or not it is
  -- required, and it should: somebody uploaded a document and an Admin has it
  -- to look at. What must stop is the practice chasing people for one they do
  -- not need.
  select count(*) into v_acre from public.credential_attention
   where type_key in ('acre', 'ce') and state in ('Missing', 'Outstanding', 'Expired', 'Expiring');
  select count(*) into v_system from public.credential_attention a
    join public.staff s on s.id = a.staff_id where s.is_system;

  if v_system <> 0 then
    raise exception 'an automated account is still being chased for % credential(s)', v_system;
  end if;

  -- Nobody has been marked as delivering job coaching yet, so ACRE and
  -- continuing education are asked of nobody. That is the state the practice
  -- asked for: the people who were being chased were all of them, and who
  -- actually coaches is a tick on their record rather than a guess here.
  if v_acre <> 0 then
    raise exception 'ACRE or continuing education is still being chased from % people before anybody is marked as delivering it', v_acre;
  end if;

  raise notice 'ok  % credential alert(s) remain, none of them for an automated account', v_after;
  for r in select type_key, count(*) c from public.credential_attention group by 1 order by 1
  loop raise notice '      % = %', r.type_key, r.c; end loop;
end $$;

-- The audience resolves per person, and an Admin can say otherwise. Asserted
-- against a made-up person inside a block that rolls itself back, because the
-- real roster is not a fixture.

do $$
declare
  v_staff uuid;
  v_required boolean;
begin
  begin
    insert into public.staff (name, email, role, active)
    values ('ZZ Credential Coach', 'zz-cred@example.test', 'Job Search', true) returning id into v_staff;

    if (select required from public.staff_credential_status
         where staff_id = v_staff and type_key = 'acre') then
      raise exception 'somebody with no services recorded is asked for ACRE'
        using errcode = 'raise_exception';
    end if;

    insert into public.staff_employment (staff_id, delivers_services)
    values (v_staff, true)
    on conflict (staff_id) do update set delivers_services = true;

    if not (select required from public.staff_credential_status
             where staff_id = v_staff and type_key = 'acre') then
      raise exception 'somebody who delivers job coaching is not asked for ACRE'
        using errcode = 'raise_exception';
    end if;
    if not (select required from public.staff_credential_status
             where staff_id = v_staff and type_key = 'ce') then
      raise exception 'somebody who delivers job coaching is not asked for continuing education'
        using errcode = 'raise_exception';
    end if;

    -- And the exception beats the audience, both ways.
    insert into public.staff_credential_requirements (staff_id, type_key, required, reason)
    values (v_staff, 'acre', false, 'ZQ qualified elsewhere');
    if (select required from public.staff_credential_status
         where staff_id = v_staff and type_key = 'acre') then
      raise exception 'an Admin saying somebody does not need ACRE was ignored'
        using errcode = 'raise_exception';
    end if;

    insert into public.staff_credential_requirements (staff_id, type_key, required, reason)
    values (v_staff, 'licence', true, 'ZQ drives occasionally')
    on conflict (staff_id, type_key) do update set required = true;
    if not (select required from public.staff_credential_status
             where staff_id = v_staff and type_key = 'licence') then
      raise exception 'an Admin saying somebody does need a licence was ignored'
        using errcode = 'raise_exception';
    end if;

    raise notice 'ok  the audience resolves per person, and an Admin saying otherwise wins either way';
    raise exception 'ZQ rolling the fixture back' using errcode = 'check_violation';
  exception
    when check_violation then null;
  end;

  if exists (select 1 from public.staff where email = 'zz-cred@example.test') then
    raise exception 'the fixture outlived the check';
  end if;
end $$;
