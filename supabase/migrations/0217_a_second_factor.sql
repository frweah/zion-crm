-- Zion Vocational Rehab CRM — a second factor
-- (owner, 18 Oct 2026)
--
-- The CRM holds every client's disability information, their identity
-- documents, the practice's bank reconciliation and its payroll. It has been
-- protected by a password and nothing else.
--
-- Supabase Auth does the cryptography; what is here is the practice's side of
-- the question:
--
--   Whether it is required at all, which is a setting rather than a constant,
--   because turning it on is an operational decision with a date attached and
--   not a deploy.
--
--   Whether the person in front of us has set one up, which the app has to
--   know on every request to decide whether to let them past.
--
--   Who has and who has not, which is the thing Admin needs in order to turn
--   it on without locking anybody out.
--
-- It arrives switched **off**, deliberately. Enrolment cannot be rehearsed on
-- somebody else's phone, so the first person through the enrolment screen is
-- the first real test of it - and if that screen were wrong with the setting
-- already on, nobody could get in to fix it, including whoever would have to.
-- Admin turns it on from Settings once the roster below shows everybody
-- enrolled. The screen says exactly that.

alter table public.org_settings
  add column if not exists require_two_factor boolean not null default false;

comment on column public.org_settings.require_two_factor is
  'Whether every member of staff must have a second factor to use the CRM (0217). Off until everybody has enrolled.';

/**
 * What this request needs to know about second factors.
 *
 * One answer, because the layout asks on every page: whether the practice
 * requires one, and whether the person asking has one. Security definer
 * because auth.mfa_factors is not a table anybody is granted.
 *
 * "Enrolled" means verified. A factor that was started and never confirmed is
 * somebody who closed the tab halfway, and letting that count would be a
 * second factor that does not exist.
 */
create or replace function public.two_factor_state()
returns table (required boolean, enrolled boolean)
language sql stable security definer set search_path = public, auth as $$
  select coalesce((select o.require_two_factor from public.org_settings o limit 1), false),
         exists (
           select 1 from auth.mfa_factors f
            where f.user_id = auth.uid()
              and f.status = 'verified'
         );
$$;

revoke all on function public.two_factor_state() from anon, authenticated;
grant execute on function public.two_factor_state() to authenticated;

/**
 * Who has one and who has not.
 *
 * Admin's, and only Admin's: who is protected and who is not is exactly the
 * list somebody attacking the practice would want. It names no secrets - only
 * whether a factor exists and when it was confirmed.
 */
create or replace function public.two_factor_roster()
returns table (staff_id uuid, name text, role text, enrolled boolean, enrolled_at timestamptz)
language sql stable security definer set search_path = public, auth as $$
  select s.id, s.name, s.role,
         f.id is not null,
         f.updated_at
    from public.staff s
    left join auth.mfa_factors f
      on f.user_id = s.user_id and f.status = 'verified'
   where s.active and not s.is_system
     and public.is_admin()
   order by (f.id is not null), s.name;
$$;

revoke all on function public.two_factor_roster() from anon, authenticated;
grant execute on function public.two_factor_roster() to authenticated;

do $$
declare v_required boolean; v_n integer;
begin
  select required into v_required from public.two_factor_state();
  if v_required is distinct from false then
    raise exception 'A second factor is already required, and nobody has enrolled yet.';
  end if;
  select count(*) into v_n from public.staff where active and not is_system;
  raise notice 'ok  second factors are off, with % people to enrol before they go on', v_n;
end $$;
