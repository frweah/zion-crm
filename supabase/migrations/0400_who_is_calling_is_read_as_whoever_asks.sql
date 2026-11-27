/**
 * The two call-side readers are read as whoever asks (0394, amended).
 *
 * `verify_portal_rls` caught these the way it caught 0392's pair: a
 * SECURITY DEFINER function a signed-in session can call, with no check of
 * who is calling, reads with the practice's own authority on behalf of
 * somebody who may have none. `who_is_calling` is the serious one - it turns
 * a phone number into a client's name, which is the whole of what a client
 * record is for.
 *
 * The fix is the same one 0393 took, and for the same reason: the authority
 * goes instead of a guard being added. Both read as the caller now.
 *
 *   - `who_is_calling` joins `clients`, whose read policy is active staff. A
 *     session that is not staff gets no rows and therefore no name.
 *   - `staff_on_the_phones` reads `staff_voice_presence`, whose read policy is
 *     the same. A session that is not staff cannot find out who is at a desk.
 *
 * Neither loses anything it needs. The webhook routes call them through
 * `record_call_started` and the voice TwiML as the service role, which is
 * outside row level security; the token route calls
 * `staff_on_the_phones` as the member of staff asking about themselves.
 *
 * A guard that raised would have been the wrong shape here for the same
 * reason it was in 0393: `who_is_calling` is read inside `file_voicemail` and
 * `record_call_started`, and a raise there would turn "this number is not one
 * we hold" into "the call could not be recorded".
 *
 * Tolerates the old code: the signatures, the arguments and the returns are
 * unchanged, and every caller that exists runs as the owner or the service
 * role, neither of which row level security applies to.
 */

create or replace function public.who_is_calling(p_phone text)
returns table (client_id uuid, contact_id uuid, label text)
language sql
stable
security invoker
set search_path = public, pg_temp
as $$
  select n.client_id,
         n.contact_id,
         case
           when n.contact_id is null then coalesce(c.name, 'Unknown caller')
           else coalesce(n.whose_name, 'Somebody') ||
                coalesce(' (' || nullif(btrim(coalesce(n.relationship, '')), '') || ' of ' ||
                         coalesce(c.name, 'a client') || ')', ' for ' || coalesce(c.name, 'a client'))
         end as label
    from public.client_numbers n
    join public.clients c on c.id = n.client_id
   where n.phone = public.normalize_phone(p_phone)
   order by case when n.whose = 'Client' then 0 else 1 end,
            case when c.status = 'Active' then 0 else 1 end,
            c.created_at
   limit 1
$$;

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
     and s.role = any (array['Admin', 'Job Search', 'Reports'])
     and p.at > now() - make_interval(secs => public.voice_presence_seconds())
   order by p.since
$$;

revoke all on function public.who_is_calling(text) from anon, public;
revoke all on function public.staff_on_the_phones() from anon, public;
grant execute on function public.who_is_calling(text) to authenticated, service_role;
grant execute on function public.staff_on_the_phones() to authenticated, service_role;

do $$
declare v_n integer; v_name text;
begin
  for v_name in select unnest(array['who_is_calling', 'staff_on_the_phones']) loop
    select count(*) into v_n from pg_proc p
     where p.pronamespace = 'public'::regnamespace and p.proname = v_name and p.prosecdef;
    if v_n <> 0 then
      raise exception '% still reads with the practice''s own authority', v_name;
    end if;
    select count(*) into v_n from pg_proc p
     where p.pronamespace = 'public'::regnamespace and p.proname = v_name;
    if v_n <> 1 then
      raise exception '% exists at % signatures, not one', v_name, v_n;
    end if;
    select count(*) into v_n from information_schema.routine_privileges
     where routine_schema = 'public' and routine_name = v_name and grantee in ('anon', 'public');
    if v_n <> 0 then
      raise exception '% can be called by anon', v_name;
    end if;
  end loop;

  raise notice 'ok  a number becomes a name only for somebody who may read the record';
end $$;
