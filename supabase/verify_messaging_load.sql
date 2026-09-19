-- Zion Vocational Rehab CRM — messaging under load (Messaging brief: "50
-- concurrent conversations without lag")
--
-- One member of staff in fifty busy conversations - fifty messages each, most
-- of them unread - and the queries every screen asks as them: the sidebar's
-- unread count, the conversation list, and one conversation opened. Each has
-- to come back well inside the time a person would notice (250 ms here, in
-- the database, before the network).
--
-- Made-up staff (ZZ). Runs inside a transaction that is rolled back.

begin;

do $$
declare
  v_me uuid; v_me_uid uuid := gen_random_uuid();
  v_other uuid; v_other_uid uuid := gen_random_uuid();
  v_conv uuid;
  v_first uuid;
  v_t timestamptz;
  v_ms numeric;
  v_n integer;
  i integer;
  failures text[] := '{}';
begin
  insert into public.staff (name, email, role, active) values ('ZZ Load Me', 'zz-load-me@example.test', 'Job Search', true) returning id into v_me;
  insert into public.staff (name, email, role, active) values ('ZZ Load Other', 'zz-load-other@example.test', 'Job Search', true) returning id into v_other;
  insert into auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (v_me_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-load-me@example.test', '{}', '{}', now(), now()),
         (v_other_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz-load-other@example.test', '{}', '{}', now(), now());

  for i in 1..50 loop
    insert into public.conversations (kind, title, created_by) values ('internal', 'ZZ load ' || i, v_me) returning id into v_conv;
    if i = 1 then v_first := v_conv; end if;
    insert into public.conversation_participants (conversation_id, staff_id) values (v_conv, v_me), (v_conv, v_other);
    insert into public.messages (conversation_id, sender_kind, sender_staff_id, sender_label, body)
    select v_conv, 'staff', case when g % 5 = 0 then v_me else v_other end, 'ZZ', 'ZZ load message ' || g
      from generate_series(1, 50) g;
    update public.conversations set last_message_at = now(), last_seq = (select max(seq) from public.messages where conversation_id = v_conv)
     where id = v_conv;
  end loop;
  analyze public.messages;
  analyze public.conversations;
  analyze public.conversation_participants;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_me_uid, 'role', 'authenticated')::text, true);

  v_t := clock_timestamp();
  select sum(unread) into v_n from public.my_unread();
  v_ms := extract(epoch from clock_timestamp() - v_t) * 1000;
  if v_n <> 2000 then
    failures := failures || format('FAILED: the unread count was %s, not 2000', v_n)::text;
  end if;
  if v_ms > 250 then
    failures := failures || format('FAILED: the unread count took %s ms', round(v_ms))::text;
  end if;
  raise notice 'ok  unread across 50 conversations: % in % ms', v_n, round(v_ms, 1);

  v_t := clock_timestamp();
  select count(*) into v_n
    from public.conversation_participants p
    join public.conversations c on c.id = p.conversation_id
   where p.staff_id = v_me and p.left_at is null;
  v_ms := extract(epoch from clock_timestamp() - v_t) * 1000;
  if v_n <> 50 or v_ms > 250 then
    failures := failures || format('FAILED: the conversation list gave %s in %s ms', v_n, round(v_ms))::text;
  end if;
  raise notice 'ok  the conversation list: % in % ms', v_n, round(v_ms, 1);

  v_t := clock_timestamp();
  select count(*) into v_n from (
    select * from public.messages where conversation_id = v_first order by seq desc limit 200) m;
  v_ms := extract(epoch from clock_timestamp() - v_t) * 1000;
  if v_n <> 50 or v_ms > 250 then
    failures := failures || format('FAILED: opening a conversation gave %s in %s ms', v_n, round(v_ms))::text;
  end if;
  raise notice 'ok  one conversation opened: % messages in % ms', v_n, round(v_ms, 1);

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- MESSAGING LOAD VERIFIED ---';
end $$;

rollback;
