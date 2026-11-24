-- Approved by the owner, 24 November 2026. Run once.
--
-- `verify_no_warrant_in_prose` found two task comments from 6 November 2026,
-- both written by an Admin, each naming a warrant number that is on file -
-- one of them a voucher number as well. A Billing seat can read both, because
-- `task_comments` admits anybody who can read the task.
--
-- Each warrant or voucher number becomes "(on the payment)", which is where
-- the number is and where Admin can read it. Nothing else in either comment
-- changes, and no other row is touched.
--
-- Logged as a correction on the client's record, which is where a change to
-- something a person wrote about a client goes: `client_corrections`, field
-- `task_comments.said`, beside the two `tasks.title` corrections already
-- there. That table is read by any active staff member, so the old value is
-- written with the number taken out and the reason says where it went - the
-- same way the authorization note was logged this evening, and for the same
-- reason: a correction that quotes the number is the leak, moved.
--
-- Run:
--   node --env-file=.env.local scripts/run-sql.mjs supabase/once_2026-11-24_the_warrant_out_of_two_task_comments.sql

begin;

do $$
declare
  v_ids   uuid[] := array[
    'e52fe791-350d-4ca6-a64c-24e263b2a424'::uuid,
    '9961bfe8-df56-43af-97df-5c14f4d6d236'::uuid
  ];
  v_id    uuid;
  v_was   text;
  v_now   text;
  v_client uuid;
  v_name  text;
  v_staff uuid;
  v_n     integer := 0;
begin
  select id into v_staff from public.staff where role = 'Admin' and active order by created_at limit 1;

  foreach v_id in array v_ids loop
    select tc.said, t.client_id, c.name
      into v_was, v_client, v_name
      from public.task_comments tc
      join public.tasks t on t.id = tc.task_id
      join public.clients c on c.id = t.client_id
     where tc.id = v_id;

    if v_was is null then
      raise exception 'Task comment % is not on file, so there is nothing to change.', v_id;
    end if;
    if not public.warrant_shaped(v_was) then
      raise notice 'Task comment % holds no warrant or voucher number; left alone.', v_id;
      continue;
    end if;

    v_now := regexp_replace(
               regexp_replace(v_was, '\yF[0-9]{8}\y', '(on the payment)', 'gi'),
               '\y[0-9]{2}[A-Za-z]{2}[0-9]{11}\y', '(on the payment)', 'gi');
    if v_now = v_was then
      raise exception 'The number in task comment % is not either shape; nothing changed.', v_id;
    end if;
    if public.warrant_shaped(v_now) then
      raise exception 'A number is still in task comment % after the edit.', v_id;
    end if;

    update public.task_comments set said = v_now where id = v_id;

    insert into public.client_corrections
      (client_id, client_name, field, was_value, new_value, reason, staff_id, staff_name)
    values (
      v_client, v_name, 'task_comments.said',
      -- The old text with the numbers taken out, because this row is read by
      -- any active staff member and the point is that the number is not.
      regexp_replace(
        regexp_replace(v_was, '\yF[0-9]{8}\y', '(warrant number removed)', 'gi'),
        '\y[0-9]{2}[A-Za-z]{2}[0-9]{11}\y', '(voucher number removed)', 'gi'),
      v_now,
      'A warrant number was written into a task comment, which Billing can read. Warrants are Admin''s (owner, 14 Nov 2026); the number stays on the payment. Found by verify_no_warrant_in_prose and approved by the owner, 24 Nov 2026.',
      v_staff,
      'Francis Weah (recorded by Claude)'
    );

    v_n := v_n + 1;
  end loop;

  if exists (select 1 from public.task_comments where id = any(v_ids) and public.warrant_shaped(said)) then
    raise exception 'A number is still in one of the two comments.';
  end if;

  raise notice '% of 2 task comment(s) changed, each logged as a correction.', v_n;
end $$;

commit;
