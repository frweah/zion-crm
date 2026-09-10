-- Zion Vocational Rehab CRM — the document inbox
--
-- This is the one place in the system where something arrives without a
-- person having done it, so the claims worth checking are all about what
-- arrival is *not* allowed to do.
--
--   A document arriving changes nothing. Not the client's record, not an
--   authorization, not an invoice. It becomes a proposal and waits.
--
--   A file is known by its hash. Not its path, not its name — the owner
--   renames things, and a file edited in place is a different document.
--
--   A folder matches a client exactly or not at all. "J Smith" reaching
--   "Jane Smith" is how one client's authorization lands on another's file.
--
--   Nobody signed in can put a row in this table or take one out. The agent
--   writes; people decide.
--
-- Runs inside a transaction that is rolled back. Nothing here is left behind,
-- and no real document is touched.

begin;

do $$
declare
  v_admin    uuid;
  v_adm_uid  uuid;
  v_other    uuid;
  v_oth_uid  uuid;
  v_client   uuid;
  v_doc      uuid;
  v_second   uuid;
  v_count    int;
  v_state    text;
  v_decided  uuid;
  v_outcome  text;
  v_known    boolean;
  v_waiting  boolean;
  v_activity int;
  failures   text[] := '{}';
begin
  select id, user_id into v_admin, v_adm_uid from public.staff
   where role = 'Admin' and active order by created_at limit 1;
  select id, user_id into v_other, v_oth_uid from public.staff
   where active and id <> v_admin order by created_at limit 1;

  -- A client with a name nobody else has, so the matching rules below are
  -- answering about this row and not about somebody real.
  insert into public.clients (name, stage, status, assigned_staff_id)
  values ('ZZ Inbox Testperson', 'Referral', 'Active', v_admin)
  returning id into v_client;

  -- Creating the client is itself an event — it enters at Referral, and the
  -- feed says so. Taken now, so that what is compared later is what the
  -- document did, not what making a client does.
  select count(*) into v_activity from public.client_activity where client_id = v_client;

  -- ── a folder matches exactly, or not at all ────────────────
  if public.match_inbox_folder('ZZ Inbox Testperson') is distinct from v_client then
    failures := failures || 'FAILED: a folder named exactly after a client did not match'::text;
  else
    raise notice 'ok  a folder named exactly after a client matches';
  end if;

  if public.match_inbox_folder('zz-inbox_testperson  ') is distinct from v_client then
    failures := failures || 'FAILED: case and punctuation stopped an otherwise exact match'::text;
  else
    raise notice 'ok  case, spacing and punctuation do not stop it';
  end if;

  if public.match_inbox_folder('Testperson, ZZ Inbox') is distinct from v_client then
    failures := failures || 'FAILED: "Surname, First" did not match'::text;
  else
    raise notice 'ok  "Surname, First" matches, because that is how the folders are named';
  end if;

  -- The refusals. Each of these is a real folder shape in the watched
  -- directory, and each would be a plausible guess.
  if public.match_inbox_folder('ZZ Inbox') is not null then
    failures := failures || 'FAILED: a first name alone matched a client'::text;
  elsif public.match_inbox_folder('ZZ Inbox Testperson Jr') is not null then
    failures := failures || 'FAILED: a longer name matched a shorter client'::text;
  elsif public.match_inbox_folder('Z Testperson') is not null then
    failures := failures || 'FAILED: an initial matched a full first name'::text;
  elsif public.match_inbox_folder('') is not null then
    failures := failures || 'FAILED: an empty folder name matched something'::text;
  else
    raise notice 'ok  a partial name, an initial and an empty name match nothing at all';
  end if;

  -- ── what somebody has decided outranks any matching ────────
  insert into public.inbox_folder_map (folder_name, client_id, mapped_by)
  values ('Brienne', v_client, v_admin);

  if public.match_inbox_folder('brienne') is distinct from v_client then
    failures := failures || 'FAILED: a folder somebody has already mapped did not match'::text;
  else
    raise notice 'ok  a folder somebody has mapped by hand matches from then on';
  end if;

  -- And "this is not a client" has to stop the matching, not fall through to
  -- it — otherwise marking a folder as an archive would do nothing whenever
  -- its name happened to resemble somebody.
  insert into public.inbox_folder_map (folder_name, client_id, not_a_client, mapped_by)
  values ('ZZ Inbox Testperson (old)', null, true, v_admin);
  update public.inbox_folder_map
     set folder_name = 'ZZ Inbox Testperson'
   where folder_name = 'ZZ Inbox Testperson (old)';

  if public.match_inbox_folder('ZZ Inbox Testperson') is not null then
    failures := failures || 'FAILED: a folder marked "not a client" still matched by name'::text;
  else
    raise notice 'ok  a folder marked "not a client" stops matching, name or no name';
  end if;

  delete from public.inbox_folder_map where folder_name = 'ZZ Inbox Testperson';

  -- ── a document arrives, and nothing happens ────────────────
  insert into public.inbox_documents
    (sha256, folder_name, relative_path, filename, size_bytes, client_id, kind, proposal)
  values ('aa' || repeat('0', 62), 'ZZ Inbox Testperson',
          'ZZ Inbox Testperson\auth.pdf', 'auth.pdf', 12345, v_client, 'Authorization',
          '{"action":"Create an authorization","needs":"confirmation"}'::jsonb)
  returning id into v_doc;

  select state, decided_by, outcome into v_state, v_decided, v_outcome
    from public.inbox_documents where id = v_doc;

  if v_state <> 'Pending' or v_decided is not null or v_outcome <> '' then
    failures := failures || format('FAILED: a document arrived as %s, decided by %s', v_state, v_decided);
  else
    raise notice 'ok  a document arrives Pending, decided by nobody';
  end if;

  -- The claim that matters. An authorization was read and understood, and the
  -- client's file is exactly as it was.
  select count(*) into v_count from public.attachments where client_id = v_client;
  if v_count <> 0 then
    failures := failures || format('FAILED: arrival put %s file(s) on the client record', v_count);
  end if;

  select count(*) into v_count from public.authorizations where client_id = v_client;
  if v_count <> 0 then
    failures := failures || format('FAILED: arrival created %s authorization(s)', v_count);
  end if;

  select count(*) into v_count from public.client_activity where client_id = v_client;
  if v_count <> v_activity then
    failures := failures || format('FAILED: arrival added %s entries to the client Activity feed',
                                   v_count - v_activity);
  end if;

  if failures = '{}' then
    raise notice 'ok  and it changes nothing — no file, no authorization, nothing on the feed';
  end if;

  -- ── the hash is the identity, not the path ─────────────────
  begin
    insert into public.inbox_documents (sha256, folder_name, relative_path, filename)
    values ('aa' || repeat('0', 62), 'Somebody Else',
            'Somebody Else\a copy with another name.pdf', 'a copy with another name.pdf');
    failures := failures || 'FAILED: the same file was accepted twice under a different name'::text;
  exception when unique_violation then
    raise notice 'ok  the same file in two folders is one document, whatever it is called';
  end;

  -- The other direction: the same path with different contents is a different
  -- document. The owner overwrites a form in place and the new one must not
  -- be mistaken for the one already dealt with.
  insert into public.inbox_documents (sha256, folder_name, relative_path, filename, client_id)
  values ('bb' || repeat('0', 62), 'ZZ Inbox Testperson',
          'ZZ Inbox Testperson\auth.pdf', 'auth.pdf', v_client)
  returning id into v_second;
  raise notice 'ok  a file edited in place is a new document, not the old one again';

  -- ── what the agent is told to send ─────────────────────────
  perform set_config('role', 'service_role', true);

  select known into v_known from public.inbox_seen(array['aa' || repeat('0', 62)]);
  if not coalesce(v_known, false) then
    failures := failures || 'FAILED: a document already held was reported as new'::text;
  end if;

  select known into v_known from public.inbox_seen(array['cc' || repeat('0', 62)]);
  if coalesce(v_known, true) then
    failures := failures || 'FAILED: a document never seen was reported as known, so it would never be sent'::text;
  else
    raise notice 'ok  the manifest tells new from known, which is what makes a 758-file backfill one request';
  end if;

  -- ── who may do what ────────────────────────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);

  begin
    perform 1 from public.inbox_seen(array['aa' || repeat('0', 62)]);
    failures := failures || 'FAILED: somebody signed in can ask what the inbox already holds'::text;
  exception when insufficient_privilege then
    raise notice 'ok  the manifest function is the agent''s alone — nobody signed in may call it';
  end;

  -- Inventing a document. There is no insert policy, so this is refused
  -- outright rather than quietly doing nothing.
  begin
    insert into public.inbox_documents (sha256, folder_name, relative_path, filename)
    values ('dd' || repeat('0', 62), 'Made Up', 'Made Up\x.pdf', 'x.pdf');
    failures := failures || 'FAILED: Admin can put a document into the inbox by hand'::text;
  exception when insufficient_privilege then
    raise notice 'ok  nobody signed in invents a document — the agent writes, people decide';
  end;

  -- Removing one. There is no delete policy either, and RLS with no policy is
  -- silent: the statement succeeds and affects nothing. So this counts rows
  -- rather than waiting for an error that never comes.
  delete from public.inbox_documents where id = v_doc;
  get diagnostics v_count = row_count;
  if v_count <> 0 then
    failures := failures || 'FAILED: a document was deleted from the inbox'::text;
  else
    raise notice 'ok  and nobody deletes one — a decision is recorded, not erased';
  end if;

  -- Deciding, though, is exactly what a reviewer does, and it has to work —
  -- this is the same door the folder mapping uses to catch up documents that
  -- were already waiting when somebody named the folder.
  update public.inbox_documents
     set client_id = v_client
   where folder_name = 'ZZ Inbox Testperson' and client_id is null;

  update public.inbox_documents
     set state = 'Filed', decided_by = v_admin, decided_at = now(), outcome = 'Filed as Authorization'
   where id = v_doc;
  get diagnostics v_count = row_count;
  if v_count <> 1 then
    failures := failures || 'FAILED: a reviewer cannot record a decision'::text;
  else
    raise notice 'ok  a reviewer can record a decision, which is how a folder mapping catches up';
  end if;

  -- ── what is still waiting ──────────────────────────────────
  if exists (select 1 from public.inbox_pending where id = v_doc) then
    failures := failures || 'FAILED: a document that was dealt with is still in the pending list'::text;
  else
    raise notice 'ok  a document dealt with leaves the list';
  end if;

  -- A document from a folder nobody has claimed says so, rather than being
  -- filed against a guess.
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  insert into public.inbox_documents (sha256, folder_name, relative_path, filename, kind)
  values ('ee' || repeat('0', 62), 'Krisite Collins',
          'Krisite Collins\form.pdf', 'form.pdf', 'USOR form');

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);

  select needs_a_client into v_waiting from public.inbox_pending
   where sha256 = 'ee' || repeat('0', 62);
  if not coalesce(v_waiting, false) then
    failures := failures || 'FAILED: a document from an unrecognised folder does not say it needs a client'::text;
  else
    raise notice 'ok  a document from a folder nobody has claimed waits, and says what it is waiting for';
  end if;

  -- ── an account that has been switched off ──────────────────
  -- The standing rule for every table: deactivating somebody removes access
  -- now, not at their next sign-in.
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
  update public.staff set active = false where id = v_other;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_oth_uid, 'role', 'authenticated')::text, true);

  select count(*) into v_count from public.inbox_documents;
  if v_count <> 0 then
    failures := failures || format('FAILED: a deactivated account still reads %s documents', v_count);
  else
    raise notice 'ok  a deactivated account sees nothing here either';
  end if;

  select count(*) into v_count from public.inbox_runs;
  if v_count <> 0 then
    failures := failures || 'FAILED: a deactivated account can still see whether the agent is running'::text;
  else
    raise notice 'ok  including whether the agent is running';
  end if;

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  if failures = '{}' then
    raise notice '';
    raise notice '--- DOCUMENT INBOX VERIFIED ---';
  else
    raise notice '';
    raise notice '%  PROBLEM(S):', array_length(failures, 1);
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
