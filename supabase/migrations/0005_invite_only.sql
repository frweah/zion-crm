-- Zion Vocational Rehab CRM — 0005 invite-only accounts
--
-- The dashboard's "allow new users to sign up" switch is a setting, and a
-- setting can be flipped back by anyone with dashboard access, or reset by a
-- project restore. This makes invite-only a property of the database instead:
-- an auth user can only come into existence for an email address that already
-- has an active staff row, which only an Admin can create.
--
-- Replaces the linking trigger from 0004.

create or replace function public.link_staff_account()
returns trigger language plpgsql security definer set search_path = public
as $$
declare
  v_staff public.staff%rowtype;
begin
  select * into v_staff
    from public.staff
   where lower(email) = lower(new.email)
   limit 1;

  if v_staff.id is null then
    raise exception 'No staff account exists for %. Accounts are created by the administrator.',
      new.email using errcode = 'insufficient_privilege';
  end if;

  if not v_staff.active then
    raise exception 'The staff account for % is closed.', new.email
      using errcode = 'insufficient_privilege';
  end if;

  if v_staff.user_id is not null and v_staff.user_id <> new.id then
    raise exception 'The staff account for % is already linked to a login.', new.email
      using errcode = 'insufficient_privilege';
  end if;

  update public.staff
     set user_id     = new.id,
         accepted_at = coalesce(accepted_at, now())
   where id = v_staff.id;

  return new;
end;
$$;

-- The trigger itself is unchanged; 0004 created it. Recreate it defensively so
-- this migration is safe to run on its own.
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.link_staff_account();
