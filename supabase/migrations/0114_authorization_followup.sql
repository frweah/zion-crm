-- Zion Vocational Rehab CRM — who is getting each authorization invoiced
--
-- Punch list #5 (review, 20 Sept 2026): tens of thousands of dollars are
-- authorized and not invoiced, and nothing on the record says, for any one
-- authorization, who is moving it or what they are doing next. "Done" is
-- each uninvoiced authorization carrying a documented next action and an
-- owner.
--
-- So an authorization gets three things somebody writes: the person who owns
-- getting it invoiced, what happens next, and by when. Nothing here decides
-- them or bills anything - an unsupported charge is worse than a late one -
-- it only makes the decision visible, on Insights -> Money.
--
-- Written under the authorization's existing write rule (0092): Admin and
-- Billing, or anybody granted billing edit. When and by whom it was last set
-- are stamped here, not taken from the screen.

alter table public.authorizations
  add column if not exists followup_owner uuid references public.staff(id) on delete set null,
  add column if not exists followup_action text not null default '',
  add column if not exists followup_due date,
  add column if not exists followup_set_at timestamptz,
  add column if not exists followup_set_by uuid references public.staff(id) on delete set null;

alter table public.authorizations drop constraint if exists authorizations_followup_action_length;
alter table public.authorizations add constraint authorizations_followup_action_length
  check (char_length(followup_action) <= 500);

comment on column public.authorizations.followup_owner is
  'Who owns getting this authorization invoiced (punch list #5).';
comment on column public.authorizations.followup_action is
  'The next thing that has to happen for it to be invoiced, in words.';
comment on column public.authorizations.followup_due is
  'When that next thing is due.';

create or replace function public.stamp_authorization_followup()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.followup_owner is distinct from old.followup_owner
     or new.followup_action is distinct from old.followup_action
     or new.followup_due is distinct from old.followup_due then
    new.followup_set_at := now();
    new.followup_set_by := public.current_staff_id();
  else
    -- Not writable on their own: they record the change above, nothing else.
    new.followup_set_at := old.followup_set_at;
    new.followup_set_by := old.followup_set_by;
  end if;
  return new;
end;
$$;

drop trigger if exists authorizations_followup_stamp on public.authorizations;
create trigger authorizations_followup_stamp before update on public.authorizations
  for each row execute function public.stamp_authorization_followup();

revoke execute on function public.stamp_authorization_followup() from public, anon, authenticated;
