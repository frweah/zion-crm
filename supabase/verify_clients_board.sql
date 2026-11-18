-- Zion Vocational Rehab CRM — the stage board (0371)
--
-- Clients › Board became one row per client grouped by stage (owner, 17
-- November 2026), reading `clients_board_rows`. What has to hold is what the
-- brief said, asked of the database rather than of the screen:
--
--   every active client is on it exactly once, and nobody else is;
--   it is staff only, and says so in the body as well as in the grant;
--   each of the four things the tiles count is a fact about the row, so a
--     tile and the rows it filters to cannot disagree;
--   last contact means somebody was reached - not that a note was written;
--   and there is no money on it at all.
--
-- Everything is rolled back.

begin;

do $$
declare
  failures text[] := '{}';
  v_staff  record;
  v_client uuid;
  v_note   uuid;
  v_task   uuid;
  n integer;
  v_text text;
  r record;
begin
  select s.id, s.user_id, s.name into v_staff
    from public.staff s
   where s.active and s.user_id is not null and not coalesce(s.is_system, false)
     and s.role = 'Job Search'
   order by s.created_at limit 1;
  if v_staff.user_id is null then
    raise exception 'This needs a signed-in member of staff to ask as.';
  end if;

  -- ── 1. no money on it, by name ─────────────────────────────
  -- Asked of the signature rather than of a row, so a column added in six
  -- months fails here rather than appearing on a screen the whole team reads.
  select coalesce(string_agg(a.attname, ', ' order by a.i), '') into v_text
    from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
    cross join lateral unnest(p.proargnames) with ordinality as a(attname, i)
   where ns.nspname = 'public' and p.proname = 'clients_board_rows'
     and a.attname ~* 'warrant|voucher|invoice|amount|paid|rate|transcript|personal';
  if v_text <> '' then
    failures := failures || format('FAILED: the stage board returns %s, and this screen is the whole team''s', v_text)::text;
  else
    raise notice 'ok  the stage board carries no money, no warrant and no transcript';
  end if;

  -- ── 2. staff only ──────────────────────────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
  select count(*) into n from public.clients_board_rows();
  if n <> 0 then
    failures := failures || format('FAILED: a signed-in account that is not staff read %s clients off the board', n)::text;
  else
    raise notice 'ok  a signed-in account that is not staff gets nothing from it';
  end if;

  perform set_config('role', 'anon', true);
  begin
    perform public.clients_board_rows();
    failures := failures || 'FAILED: anon can call the board'::text;
  exception when insufficient_privilege then
    raise notice 'ok  anon cannot call it at all';
  when others then
    raise notice 'ok  anon cannot call it (%)', sqlerrm;
  end;

  -- ── as a member of staff, for the rest ─────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_staff.user_id, 'role', 'authenticated')::text, true);

  -- ── 3. everybody active, once, and nobody else ─────────────
  select count(*) into n
    from public.clients c
   where c.status = 'Active' and c.merged_into is null
     and not exists (select 1 from public.clients_board_rows() b where b.client_id = c.id);
  if n <> 0 then
    failures := failures || format('FAILED: %s active client(s) are on no row of the board', n)::text;
  else
    raise notice 'ok  every active client is on the board';
  end if;

  select count(*) into n
    from public.clients_board_rows() b
    join public.clients c on c.id = b.client_id
   where c.status <> 'Active' or c.merged_into is not null;
  if n <> 0 then
    failures := failures || format('FAILED: %s closed, inactive or merged client(s) are on the board', n)::text;
  else
    raise notice 'ok  a client who is not active is not on it';
  end if;

  select count(*) into n from (
    select b.client_id from public.clients_board_rows() b
     group by b.client_id having count(*) > 1
  ) x;
  if n <> 0 then
    failures := failures || format('FAILED: %s client(s) are on the board twice', n)::text;
  else
    raise notice 'ok  one row per client';
  end if;

  -- ── 4. what the tiles count is true of the row ─────────────
  select count(*) into n
    from public.clients_board_rows() b
   where b.authorization_ends_on is not null
     and (b.authorization_ends_on < public.practice_today()
       or b.authorization_ends_on > public.practice_today() + 30);
  if n <> 0 then
    failures := failures || format('FAILED: %s row(s) say an authorization ends within 30 days and it does not', n)::text;
  else
    raise notice 'ok  "authorization ends within 30 days" means exactly that';
  end if;

  select count(*) into n
    from public.clients_board_rows() b
   where b.authorization_ends_on is not null
     and not exists (
       select 1 from public.authorizations a
        where a.client_id = b.client_id and a.end_date = b.authorization_ends_on
          and a.status not in ('Paid', 'Closed'));
  if n <> 0 then
    failures := failures || format('FAILED: %s row(s) count an authorization that is already settled', n)::text;
  else
    raise notice 'ok  a settled authorization does not light the tile';
  end if;

  select count(*) into n
    from public.clients_board_rows() b
    join public.clients c on c.id = b.client_id
   where (b.assigned_staff_id is null) <> (c.assigned_staff_id is null);
  if n <> 0 then
    failures := failures || format('FAILED: %s row(s) disagree with the client about who is assigned', n)::text;
  else
    raise notice 'ok  "no assigned staff" is the client''s own answer';
  end if;

  -- ── 5. last contact means somebody was reached ─────────────
  select coalesce(string_agg(distinct b.last_contact_kind, ', '), '') into v_text
    from public.clients_board_rows() b
   where b.last_contact_kind is not null
     and b.last_contact_kind not in ('Text', 'Mail', 'Counselor', 'Appointment');
  if v_text <> '' then
    failures := failures || format('FAILED: last contact counted %s, which is not somebody being reached', v_text)::text;
  else
    raise notice 'ok  last contact is a text, an email, a counselor contact or an appointment';
  end if;

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  -- A note written today does not become "last contact": writing a meeting
  -- up a week later would otherwise move every client to today.
  select b.client_id into v_client from public.clients_board_rows() b limit 1;
  if v_client is null then
    select id into v_client from public.clients where status = 'Active' limit 1;
  end if;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_staff.user_id, 'role', 'authenticated')::text, true);
  select b.last_contact_at into r from public.clients_board_rows() b where b.client_id = v_client;
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  insert into public.notes (client_id, staff_id, staff_name, text, type, at, visible_roles)
  values (v_client, v_staff.id, 'ZZ Verify', 'ZZ a note written up afterwards', 'General', now(),
          array['Admin', 'Job Search', 'Reports', 'Billing', 'Case Manager', 'Job Coach'])
  returning id into v_note;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_staff.user_id, 'role', 'authenticated')::text, true);
  select count(*) into n from public.clients_board_rows() b
   where b.client_id = v_client and b.last_contact_at > now() - interval '1 minute';
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
  delete from public.notes where id = v_note;

  if n <> 0 then
    failures := failures || 'FAILED: writing a note moved "last contact" to today'::text;
  else
    raise notice 'ok  a note is not contact';
  end if;

  -- The control for the assertion above. A logged counselor contact *is*
  -- contact, so it has to move the date. If neither a note nor a contact
  -- moves it, the assertion above is passing on a query that answers
  -- nothing.
  insert into public.contact_log (client_id, staff_id, date, method, topic, outcome)
  values (v_client, v_staff.id, public.practice_today(), 'Email', 'ZZ verify', 'ZZ reached them');

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_staff.user_id, 'role', 'authenticated')::text, true);
  select count(*) into n from public.clients_board_rows() b
   where b.client_id = v_client
     and b.last_contact_at::date = public.practice_today()
     and b.last_contact_kind = 'Counselor';
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  if n <> 1 then
    failures := failures || 'FAILED: a logged counselor contact did not move "last contact" either, so the check above asks the wrong question'::text;
  else
    raise notice 'ok  a counselor contact does move it, which is what makes the line above mean something';
  end if;

  -- ── 6. the next task is the soonest open one ───────────────
  insert into public.tasks (client_id, title, status, due, assigned_staff_id)
  values (v_client, 'ZZ the soonest task', 'Open', public.practice_today() - 30, v_staff.id)
  returning id into v_task;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_staff.user_id, 'role', 'authenticated')::text, true);
  select count(*) into n from public.clients_board_rows() b
   where b.client_id = v_client and b.next_task_id = v_task;
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
  delete from public.tasks where id = v_task;

  if n <> 1 then
    failures := failures || 'FAILED: the row did not take the task due soonest as the next one'::text;
  else
    raise notice 'ok  the next task is the open one due soonest, with whose it is';
  end if;

  if failures = '{}' then
    raise notice '';
    raise notice '--- THE STAGE BOARD VERIFIED ---';
  else
    raise notice '';
    raise notice '%  PROBLEM(S):', array_length(failures, 1);
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
