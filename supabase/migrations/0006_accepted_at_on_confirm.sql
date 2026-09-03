-- Zion Vocational Rehab CRM — 0006 accurate invite status
--
-- 0004/0005 stamped staff.accepted_at when the auth user was created. But
-- inviting someone creates their auth user immediately — the email goes out
-- afterwards — so every invited person showed as "Active" on the Staff screen
-- before they had done anything. An Admin looking at that list could not tell
-- who still needs to accept, and would have no reason to resend a lost invite.
--
-- Creating the auth user now records the invite; accepted_at is stamped when
-- the person actually confirms.

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
         invited_at  = coalesce(invited_at, now()),
         -- Only count as accepted if this user arrived already confirmed,
         -- which is how an Admin-created account (rather than an invite) looks.
         accepted_at = case
                         when new.email_confirmed_at is not null then coalesce(accepted_at, now())
                         else accepted_at
                       end
   where id = v_staff.id;

  return new;
end;
$$;

-- The moment they confirm the emailed link, the account is genuinely accepted.
create or replace function public.mark_staff_accepted()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if new.email_confirmed_at is not null and old.email_confirmed_at is null then
    update public.staff
       set accepted_at = coalesce(accepted_at, now())
     where user_id = new.id;
  end if;
  return new;
end;
$$;

drop trigger if exists on_auth_user_confirmed on auth.users;
create trigger on_auth_user_confirmed
  after update of email_confirmed_at on auth.users
  for each row execute function public.mark_staff_accepted();

-- Correct anyone already marked accepted who has not actually confirmed.
update public.staff s
   set accepted_at = null
  from auth.users u
 where u.id = s.user_id
   and u.email_confirmed_at is null
   and s.accepted_at is not null;

-- The seeded rows from 0004 predate the invite flow; record that the ones with
-- a login attached were in fact invited.
update public.staff
   set invited_at = coalesce(invited_at, created_at)
 where user_id is not null
   and invited_at is null;
