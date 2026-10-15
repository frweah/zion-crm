-- Zion Vocational Rehab CRM — the mailbox you connect is one of your addresses
-- (owner, 14 Oct 2026, item 2)
--
-- Rispah signs in as rispah@zionpersonalcareagency.com, and
-- Rispah@zionvocrehab.com is an alias of that same Exchange mailbox. The owner
-- asked that mail to either be attributed to her once she connects Outlook.
--
-- ── what already holds, and is worth saying before changing anything ──
--
-- Mail is attributed by mailbox, not by address. syncStaffMember sweeps one
-- person's mailbox with that person's own token and writes their staff_id on
-- every row it keeps, and the matching it does is against clients and
-- counselors - staff addresses are not matched at all. Two addresses on one
-- mailbox are therefore already one person's mail, whichever of them a
-- message was sent to. Nothing needed changing for that.
--
-- ── what did not hold ──
--
-- Which address Microsoft reports as the mailbox's own is Exchange's business,
-- not ours: Graph answers /me with whatever is configured as primary, and that
-- can be either of hers. The CRM stored it and never compared it with
-- anything, so if Graph had reported the Voc Rehab address, the practice would
-- have had a connection under an address nobody had recorded as hers - and
-- staff_by_email() would have said that address reaches nobody.
--
-- So connecting a mailbox now records its address as one of the connecting
-- person's, if it is not already known. The CRM learns the alias from Exchange
-- rather than waiting for somebody to type it.
--
-- And if that address is already somebody *else's*, it refuses and says so.
-- That is the case worth catching: it means a person has connected a mailbox
-- that is not theirs, and every message swept out of it would be filed under
-- the wrong name.

create or replace function public.record_my_mailbox_address(p_address text)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_me      uuid := public.current_staff_id();
  v_address text := btrim(coalesce(p_address, ''));
  v_owner   uuid;
begin
  if v_me is null or not public.is_active_staff() then
    raise exception 'Only a member of staff connects a mailbox.' using errcode = 'insufficient_privilege';
  end if;
  if v_address = '' then
    return 'Microsoft gave no address for that mailbox.';
  end if;

  v_owner := public.staff_by_email(v_address);

  if v_owner = v_me then
    return 'Already on your record.';
  end if;

  if v_owner is not null then
    raise exception 'That mailbox belongs to %. Mail swept out of it would be filed under their name.',
      (select name from public.staff where id = v_owner)
      using errcode = 'unique_violation',
            hint = 'Disconnect and connect your own mailbox.';
  end if;

  -- Nobody has it. It is the mailbox this person just proved they can open,
  -- so it is one of their addresses.
  insert into public.staff_emails (staff_id, address, note, added_by)
  values (v_me, v_address, 'The Outlook mailbox connected on ' || public.practice_today(), v_me);

  return format('%s added to your record, so mail to it is yours.', v_address);
end;
$$;

comment on function public.record_my_mailbox_address is
  'Records the address of the mailbox the caller has just connected as one of theirs, unless it is already known. Refuses an address that belongs to somebody else - that means a mailbox was connected by the wrong person, and every message swept from it would be filed under the wrong name.';

revoke all on function public.record_my_mailbox_address(text) from anon, authenticated;
grant execute on function public.record_my_mailbox_address(text) to authenticated;

-- ── and Rispah's record says what the owner says it says ────
--
-- Both were already right - staff.email is the PCA address and the Voc Rehab
-- one went on as an alias in 0199 - so this asserts rather than changes.
-- A migration that silently does nothing is worth less than one that says so.
do $$
declare
  v_id uuid;
begin
  select id into v_id from public.staff where lower(email) = 'rispah@zionpersonalcareagency.com';
  if v_id is null then
    raise notice 'note  no staff record signs in as rispah@zionpersonalcareagency.com; nothing asserted';
    return;
  end if;
  if public.staff_by_email('Rispah@zionvocrehab.com') is distinct from v_id then
    raise exception 'The Voc Rehab address does not reach the person who signs in as the PCA one.';
  end if;
  raise notice 'ok  % signs in as the PCA address, and the Voc Rehab one reaches her',
    (select name from public.staff where id = v_id);
end $$;
