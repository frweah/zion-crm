-- Two changes the owner approved on 24 November 2026, run once.
--
--   1. The sentence "Paid on warrant F15691618." comes out of V1044403's
--      note, and nothing else in it. A warrant number on a Billing-readable
--      field is the one thing the ruling of 14 November does not allow, and
--      prose is the one route no column grant or policy can close. The
--      payment and its warrant are still recorded where they belong, in
--      `payments.warrant_no`, which Admin reads.
--
--      Logged as a correction, like every other change to an authorization,
--      so the record says what was taken out and why. The correction itself
--      carries the old text - which means it carries the warrant number - and
--      that is why `authorization_corrections` already hides a row whose
--      field is 'Warrant' from everybody but Admin. This one's field is
--      'Note', so it would be readable by Billing: the old value is written
--      with the number removed, and the reason says where the number went.
--
--   2. ZZ Smoke Board, the practice's one permanent fixture client, which
--      `verify_zz_no_fixtures.sql` permits by name and the deploy check needs
--      to exist. Inactive, so it is on nobody's board and in no active list,
--      and with no phone number at all, so no deploy check can ever text it
--      (ruling 7, 23 November).
--
--      Made here rather than on the Add client form because that form has no
--      status field: everything it writes is Active. It also refuses an empty
--      phone unless "No phone" is ticked with a reason, which is the step my
--      own instructions left out.
--
-- Run:  node --env-file=.env.local scripts/run-sql.mjs supabase/once_2026-11-24_the_warrant_out_of_a_note.sql

begin;

-- ── 1. the warrant number out of the note ────────────────────
do $$
declare
  v_id    uuid;
  v_was   text;
  v_now   text;
  v_staff uuid;
begin
  select id, note into v_id, v_was from public.authorizations where number = 'V1044403';
  if v_id is null then
    raise exception 'V1044403 is not on file, so there is no note to change.';
  end if;
  if position('F15691618' in coalesce(v_was, '')) = 0 then
    raise notice 'The note does not mention that warrant; nothing to do.';
    return;
  end if;

  -- Exactly the one sentence, and the space before it. Not a regex over
  -- anything F-shaped: this is a change to a record somebody will read, and
  -- the only safe edit is the one that was approved.
  v_now := replace(v_was, ' Paid on warrant F15691618.', '');
  if v_now = v_was then
    v_now := replace(v_was, 'Paid on warrant F15691618.', '');
  end if;
  if v_now = v_was then
    raise exception 'The sentence is not written the way it was approved; nothing changed.';
  end if;
  if position('F15691618' in v_now) > 0 then
    raise exception 'The warrant number is still in the note after the edit.';
  end if;

  select id into v_staff from public.staff where role = 'Admin' and active order by created_at limit 1;

  update public.authorizations set note = btrim(v_now) where id = v_id;

  insert into public.authorization_corrections
    (auth_id, auth_number, field, was_value, new_value, reason, staff_id, staff_name)
  values (
    v_id, 'V1044403', 'Note',
    -- The old text with the number taken out, because this row is readable by
    -- Billing and the whole point is that the number is not.
    btrim(replace(v_was, 'F15691618', '(warrant number removed)')),
    btrim(v_now),
    'A warrant number was written into the note, which Billing can read. Warrants are Admin''s (owner, 14 Nov 2026); the payment and its warrant stay on the payment. Approved by the owner, 24 Nov 2026.',
    v_staff,
    'Francis Weah (recorded by Claude)'
  );

  raise notice 'V1044403: the warrant number is out of the note, and the correction says so.';
end $$;

-- ── 2. the fixture client ────────────────────────────────────
do $$
declare
  v_n integer;
begin
  select count(*) into v_n from public.clients where name = 'ZZ Smoke Board';
  if v_n > 0 then
    raise notice 'ZZ Smoke Board is already on file % time(s); nothing created.', v_n;
    return;
  end if;

  insert into public.clients (name, funding_source, status, stage, no_phone_reason)
  values ('ZZ Smoke Board', 'Utah VR', 'Inactive', 'Intake',
          'Deploy check fixture - never texted, never called');

  raise notice 'ZZ Smoke Board created: Inactive, Intake, no phone number.';
end $$;

commit;
