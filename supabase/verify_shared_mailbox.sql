-- Zion Vocational Rehab CRM — the shared mailbox
--
-- A shared mailbox is the practice's, not a person's, so the rules that were
-- about "your own mailbox" have to hold in a different shape: the same
-- match-first logging, the same absence of anywhere to put a body, and a
-- message that belongs to a mailbox rather than to whoever happened to read
-- it.
--
-- Runs inside a transaction that is rolled back. Nothing here is left behind.

begin;

do $$
declare
  v_admin    uuid;
  v_adm_uid  uuid;
  v_rei      uuid;
  v_rei_uid  uuid;
  v_client   uuid;
  v_counsel  uuid;
  v_logged   boolean;
  v_count    int;
  v_box      text := 'zz-shared@example.com';
  failures   text[] := '{}';
begin
  select id, user_id into v_admin, v_adm_uid from public.staff where legacy_id = 's1';
  select id, user_id into v_rei,  v_rei_uid  from public.staff where legacy_id = 's2';
  select id into v_client  from public.clients order by created_at limit 1;
  select id into v_counsel from public.counselors order by created_at limit 1;

  -- ── only Admin sets one up ─────────────────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_rei_uid, 'role', 'authenticated')::text, true);
  begin
    insert into public.shared_mailboxes (address, connected_by) values (v_box, v_rei);
    failures := failures || 'FAILED: a contractor added a shared mailbox'::text;
  exception when insufficient_privilege then
    raise notice 'ok  only Admin can set up a shared mailbox';
  end;
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  insert into public.shared_mailboxes (address, label, connected_by)
  values (v_box, 'ZZ verify', v_admin);

  -- ── logging against a mailbox nobody reads is refused ──────
  begin
    perform public.log_shared_mail_message(
      'zz-not-ours@example.com', v_client, null, 'sm-0', 'st-0', 'Not our mailbox',
      now(), 'Incoming', 'someone@example.com', '');
    failures := failures || 'FAILED: mail was logged for a mailbox this practice does not read'::text;
  exception when check_violation then
    raise notice 'ok  a mailbox the practice does not read cannot be logged against';
  end;

  -- ── a counselor message lands on the counselor ─────────────
  v_logged := public.log_shared_mail_message(
    v_box, null, v_counsel, 'sm-1', 'st-1', 'About a client', now(), 'Incoming',
    'counselor@example.com', 'https://outlook/sm1');

  if not v_logged then
    failures := failures || 'FAILED: a counselor message was not logged'::text;
  else
    raise notice 'ok  a counselor message from the shared mailbox is logged';
  end if;

  if not exists (select 1 from public.mail_log
                  where graph_message_id = 'sm-1'
                    and mailbox_address = v_box and staff_id is null
                    and counselor_id = v_counsel) then
    failures := failures || 'FAILED: the row is not attributed to the shared mailbox'::text;
  else
    raise notice 'ok  the row belongs to the mailbox, not to whoever read it';
  end if;

  -- ── the same message twice is one record ───────────────────
  v_logged := public.log_shared_mail_message(
    v_box, null, v_counsel, 'sm-1', 'st-1', 'About a client', now(), 'Incoming',
    'counselor@example.com', '');
  select count(*) into v_count from public.mail_log where graph_message_id = 'sm-1';
  if v_count <> 1 or v_logged then
    failures := failures || format('FAILED: the shared sweep logged a message twice (%s rows)', v_count);
  else
    raise notice 'ok  a second sweep of the shared mailbox does not duplicate';
  end if;

  -- ── the same id in two mailboxes is two records ────────────
  -- Graph message ids are per mailbox, so the same string can legitimately
  -- appear in a personal mailbox and the shared one and mean two things.
  v_logged := public.log_mail_message_for_sync(
    v_rei, v_client, null, 'sm-1', 'st-9', 'Same id, other mailbox', now(),
    'Incoming', 'someone@example.com', '');
  select count(*) into v_count from public.mail_log where graph_message_id = 'sm-1';
  if v_count <> 2 then
    failures := failures || format('FAILED: the same id in two mailboxes collapsed to %s row(s)', v_count);
  else
    raise notice 'ok  the same message id in two mailboxes is two records, not one';
  end if;

  -- ── match-first still holds ────────────────────────────────
  begin
    perform public.log_shared_mail_message(
      v_box, null, null, 'sm-2', 'st-2', 'Matches nobody', now(), 'Incoming',
      'stranger@example.com', '');
    failures := failures || 'FAILED: shared mail matching nobody was logged'::text;
  exception when check_violation then
    raise notice 'ok  shared mail matching nobody is refused, as everywhere else';
  end;

  -- ── exclusion holds across both kinds of mailbox ───────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);
  perform public.exclude_mail_thread('st-1', 'not relevant');
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  if exists (select 1 from public.mail_log where conversation_id = 'st-1') then
    failures := failures || 'FAILED: excluding a thread left the shared mailbox copy'::text;
  else
    raise notice 'ok  excluding a thread clears it from the shared mailbox too';
  end if;

  v_logged := public.log_shared_mail_message(
    v_box, null, v_counsel, 'sm-3', 'st-1', 'A reply', now(), 'Incoming',
    'counselor@example.com', '');
  if v_logged then
    failures := failures || 'FAILED: an excluded thread was logged again from the shared mailbox'::text;
  else
    raise notice 'ok  an excluded thread stays excluded in the shared mailbox';
  end if;

  -- ── still nowhere to put a body ────────────────────────────
  if exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'mail_log'
       and column_name in ('body', 'body_preview', 'content', 'body_content')
  ) then
    failures := failures || 'FAILED: mail_log has somewhere to put a message body'::text;
  else
    raise notice 'ok  mail_log still has no column a body could be written to';
  end if;

  -- ── a signed-in person cannot write as the shared mailbox ──
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);
  begin
    perform public.log_shared_mail_message(
      v_box, null, v_counsel, 'sm-4', 'st-4', 'By hand', now(), 'Incoming',
      'counselor@example.com', '');
    failures := failures || 'FAILED: Admin logged shared mail by hand'::text;
  exception when insufficient_privilege then
    raise notice 'ok  not even Admin can write a shared-mailbox record by hand';
  end;

  -- Everyone can see that the practice reads a shared mailbox.
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_rei_uid, 'role', 'authenticated')::text, true);
  if not exists (select 1 from public.shared_mailboxes where address = v_box) then
    failures := failures || 'FAILED: staff cannot see which mailboxes are read'::text;
  else
    raise notice 'ok  staff can see which shared mailboxes the practice reads';
  end if;

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  if failures = '{}' then
    raise notice '';
    raise notice '--- SHARED MAILBOX VERIFIED ---';
  else
    raise notice '';
    raise notice '%  PROBLEM(S):', array_length(failures, 1);
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
