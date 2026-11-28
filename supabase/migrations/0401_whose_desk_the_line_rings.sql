/**
 * Whose desk the client line rings (owner, 27 November 2026).
 *
 * The switch gains a second column. `sms_provider` says which carrier, and
 * `voice_mode` says who hears it:
 *
 *   off    nobody. No desk rings and no browser is handed a telephone, which
 *          is where it starts.
 *   admin  Admin seats only. The owner's setting for running the proofs on a
 *          test number without the team watching a line ring that nothing is
 *          connected to yet.
 *   all    every seat that may text a client, which is the cutover setting.
 *
 * It is one function and one `case`, in `staff_on_the_phones` - the one place
 * that already decides whose browser to ring. Nothing else needs to know:
 * the token route refuses a token to anybody that function does not list, so
 * a seat outside the mode is handed no telephone and the panel draws nothing.
 * A second place deciding would be a seat that gets a token and never rings,
 * which looks like a broken telephone.
 *
 * **An unreadable mode is 'off', and that is not the same reasoning as the
 * carrier switch.** There, a failed read refuses the send, because a default
 * would text a client from whichever number the practice is not using. Here
 * the harm runs one way only: a desk ringing when it should not is a client
 * call answered by somebody who should not have it, and a desk not ringing is
 * a voicemail. So this one falls back to silence, on purpose, and says so.
 *
 * Tolerates the old code: a new column nothing deployed writes, and a
 * function that keeps its name, arguments and return type. The default is
 * 'off', so what is live the moment this is applied is a telephone that rings
 * nobody - which is the state the owner asked to deploy into.
 */

-- Tolerates the old code: nothing deployed writes org_settings.voice_mode, so
-- the constraint below can refuse nothing that is being sent today, and the
-- default makes the live behaviour "no desk rings" rather than anything new.

alter table public.org_settings
  add column if not exists voice_mode text not null default 'off';

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.org_settings'::regclass and conname = 'org_settings_voice_mode'
  ) then
    alter table public.org_settings
      add constraint org_settings_voice_mode
      check (voice_mode in ('off', 'admin', 'all'));
  end if;
end $$;

comment on column public.org_settings.voice_mode is
  'Whose desk the client line rings: off, admin or all. Admin sets it on Admin → System; staff_on_the_phones is the only code that reads it.';

/**
 * Granted by name, because `org_settings` carries column grants rather than a
 * table grant - a column added without this is one no screen can read while
 * `select` of the others goes on working (the `select *` lesson, 0282).
 */
grant select (voice_mode) on public.org_settings to authenticated;
grant update (voice_mode) on public.org_settings to authenticated;

/**
 * Read as whoever is asking, like the carrier switch after 0393 and the two
 * call readers after 0400: the authority rather than a guard, so the read
 * policy on `org_settings` is the check of who may ask.
 */
create or replace function public.voice_mode()
returns text
language sql
stable
security invoker
set search_path = public, pg_temp
as $$
  select coalesce((select voice_mode from public.org_settings where id = true), 'off')
$$;

comment on function public.voice_mode() is
  'Whose desk the client line rings: off, admin or all. Falls back to off, because a desk ringing when it should not is worse than a voicemail.';

revoke all on function public.voice_mode() from anon, public;
grant execute on function public.voice_mode() to authenticated, service_role;

/**
 * Whose browser to ring, now that the practice can say who.
 *
 * The freshness window and the roles are unchanged; the mode is one `case`
 * on top. 'off' lists nobody, which is why the whole thing can be deployed
 * before anybody wants a telephone.
 */
create or replace function public.staff_on_the_phones()
returns table (staff_id uuid, name text)
language sql
stable
security invoker
set search_path = public, pg_temp
as $$
  select s.id, s.name
    from public.staff_voice_presence p
    join public.staff s on s.id = p.staff_id
   where s.active
     and not s.is_system
     and p.at > now() - make_interval(secs => public.voice_presence_seconds())
     and case public.voice_mode()
           when 'all' then s.role = any (array['Admin', 'Job Search', 'Reports'])
           when 'admin' then s.role = 'Admin'
           else false
         end
   order by p.since
$$;

revoke all on function public.staff_on_the_phones() from anon, public;
grant execute on function public.staff_on_the_phones() to authenticated, service_role;

do $$
declare v_n integer; v_def text;
begin
  select count(*) into v_n from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'voice_mode';
  if v_n <> 1 then
    raise exception 'voice_mode exists at % signatures, not one', v_n;
  end if;

  select count(*) into v_n from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname in ('voice_mode', 'staff_on_the_phones') and p.prosecdef;
  if v_n <> 0 then
    raise exception '% of the two still read with the practice''s own authority', v_n;
  end if;

  select count(*) into v_n from information_schema.routine_privileges
   where routine_schema = 'public' and routine_name = 'voice_mode'
     and grantee in ('anon', 'public');
  if v_n <> 0 then
    raise exception 'voice_mode can be called by anon';
  end if;

  if public.voice_mode() <> 'off' then
    raise exception 'the line starts ringing % desks, and it has to start silent', public.voice_mode();
  end if;

  select count(*) into v_n from public.staff_on_the_phones();
  if v_n <> 0 then
    raise exception 'the mode is off and % desk(s) would still ring', v_n;
  end if;

  select pg_get_functiondef(p.oid) into v_def from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'staff_on_the_phones';
  if strpos(v_def, 'public.voice_mode()') = 0 then
    raise exception 'whose desk rings does not read the mode';
  end if;

  select count(*) into v_n from information_schema.column_privileges
   where table_schema = 'public' and table_name = 'org_settings'
     and column_name = 'voice_mode' and grantee = 'authenticated'
     and privilege_type in ('SELECT', 'UPDATE');
  if v_n <> 2 then
    raise exception 'authenticated holds % of the two column grants on voice_mode', v_n;
  end if;

  raise notice 'ok  the line starts silent, and whose desk rings is one case in one function';
end $$;
