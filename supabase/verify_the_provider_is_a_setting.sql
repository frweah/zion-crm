-- Zion Vocational Rehab CRM — the provider is a setting (0392)
--
-- The client line 385-406-3432 is leaving GoHighLevel for Twilio, and the
-- practice decided the move should be a switch rather than a deploy: the day
-- the number moves, somebody has to be able to put it back inside a minute.
-- What has to hold for that to be safe:
--
--   the switch takes two values and nothing else, and it starts where the
--   practice already is;
--
--   every message records which carrier carried it, without any sending code
--   having to remember to say so - so a day that straddles the cutover can
--   be read message by message afterwards;
--
--   both carriers' status words map to the practice's three, and a word
--   neither of them has used is still refused rather than guessed at;
--
--   no sentence a person can read names a company the practice may have left
--   that morning;
--
--   and moving the switch loosens nothing. Consent, the sending hours and
--   the 'who may write an outgoing text' rule are the same on either
--   carrier, which is the half that would be quietest to get wrong.
--
-- Everything is rolled back.

begin;

do $$
declare
  failures text[] := array[]::text[];
  v_mark    integer;
  v_counsel uuid;
  v_client  uuid;
  v_sms     uuid;
  v_said    text;
  v_n       integer;
  v_matched boolean;
  v_def     text;
begin
  -- ── a client who may be texted, and one who may not ────────
  insert into public.counselors (name, email, office)
  values ('ZQ Switch Counselor', 'zq-switch@example.test', 'Salt Lake City') returning id into v_counsel;
  insert into public.clients (name, stage, status, counselor_id, phone)
  values ('ZZ Switch Client', 'Job Development', 'Active', v_counsel, '+13855550111')
  returning id into v_client;
  insert into public.sms_consent_events (client_id, state, phone, method, note)
  values (v_client, 'Granted', public.normalize_phone('+13855550111'), 'Intake form', 'ZZ fixture');

  -- ── 1. the switch takes two values, and starts on GoHighLevel ──
  v_mark := coalesce(array_length(failures, 1), 0);

  if public.sms_provider() <> 'ghl' then
    failures := failures || format(
      'FAILED: the switch reads %L, and it has to start where the practice already is',
      public.sms_provider())::text;
  end if;
  if public.sms_provider_name() <> 'GoHighLevel' then
    failures := failures || format(
      'FAILED: a message recorded now would be stamped %L', public.sms_provider_name())::text;
  end if;

  begin
    update public.org_settings set sms_provider = 'telnyx' where id = true;
    failures := failures ||
      'FAILED: the switch accepted a carrier nothing here can send through'::text;
  exception when check_violation then
    null;
  end;

  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  the switch starts on GoHighLevel and refuses a carrier nothing can send through';
  end if;

  -- ── 2. the ledger says which carrier carried each message ──
  --
  -- Asked of a real insert that names no provider at all, because that is
  -- what the sending code does: the column's default is the switch, so no
  -- caller has to remember. A test that passed `provider` explicitly would
  -- prove the column accepts a value and nothing about the rule.
  v_mark := coalesce(array_length(failures, 1), 0);

  insert into public.sms_messages (client_id, direction, phone, body, kind, status)
  values (v_client, 'Outgoing', public.normalize_phone('+13855550111'),
          'ZZ fixture, before the move', 'Manual', 'Queued')
  returning id into v_sms;
  select provider into v_said from public.sms_messages where id = v_sms;
  if v_said is distinct from 'GoHighLevel' then
    failures := failures || format(
      'FAILED: a text sent before the move is recorded as %L', coalesce(v_said, 'nothing'))::text;
  end if;

  update public.org_settings set sms_provider = 'twilio' where id = true;

  insert into public.sms_messages (client_id, direction, phone, body, kind, status)
  values (v_client, 'Outgoing', public.normalize_phone('+13855550111'),
          'ZZ fixture, after the move', 'Manual', 'Queued')
  returning id into v_sms;
  select provider into v_said from public.sms_messages where id = v_sms;
  if v_said is distinct from 'Twilio' then
    failures := failures || format(
      'FAILED: a text sent after the move is recorded as %L, so a day either side of a cutover ' ||
      'cannot be told apart', coalesce(v_said, 'nothing'))::text;
  end if;

  -- And a reply, which arrives through a function nobody edited for this.
  perform public.record_incoming_sms('+13855550111', 'thanks', 'SM-zz-fixture-1');
  select provider into v_said from public.sms_messages
   where direction = 'Incoming' and provider_message_id = 'SM-zz-fixture-1';
  if v_said is distinct from 'Twilio' then
    failures := failures || format(
      'FAILED: a reply arriving after the move is recorded as %L', coalesce(v_said, 'nothing'))::text;
  end if;

  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  every message records the carrier that carried it, on either side of the move';
  end if;

  -- ── 3. both carriers' status words, and a word from neither ──
  v_mark := coalesce(array_length(failures, 1), 0);

  insert into public.sms_messages (client_id, direction, phone, body, kind, status, provider_message_id)
  values (v_client, 'Outgoing', public.normalize_phone('+13855550111'),
          'ZZ fixture, in flight', 'Manual', 'Queued', 'SM-zz-fixture-2')
  returning id into v_sms;

  -- Twilio's two that GoHighLevel never sends. Before 0392 these came back
  -- as "this does not know" and the text sat on Sent until somebody looked.
  for v_said in select unnest(array['sending', 'receiving']) loop
    select status into v_def from public.record_text_status('SM-zz-fixture-2', v_said);
    if v_def is distinct from 'Sent' then
      failures := failures || format(
        'FAILED: a text Twilio says is %L reads as %L, so a message in flight has no status',
        v_said, coalesce(v_def, 'nothing'))::text;
    end if;
  end loop;

  -- The ones that were always understood, from either carrier.
  select status into v_def from public.record_text_status('SM-zz-fixture-2', 'undelivered', 'carrier dropped it');
  if v_def is distinct from 'Failed' then
    failures := failures || format('FAILED: an undelivered text reads as %L', coalesce(v_def, 'nothing'))::text;
  end if;
  select error into v_said from public.sms_messages where id = v_sms;
  if coalesce(v_said, '') = '' then
    failures := failures || 'FAILED: a failed text does not say why'::text;
  end if;

  select status into v_def from public.record_text_status('SM-zz-fixture-2', 'delivered');
  if v_def is distinct from 'Delivered' then
    failures := failures || format('FAILED: a delivered text reads as %L', coalesce(v_def, 'nothing'))::text;
  end if;

  -- And a word neither carrier has ever sent is still not guessed at. This
  -- is the half worth keeping: a status read as a failure because nobody
  -- recognised it would tell staff a text did not go when it did.
  select matched, status into v_matched, v_def
    from public.record_text_status('SM-zz-fixture-2', 'teleported');
  if v_matched is not false then
    failures := failures ||
      'FAILED: a status word nothing has ever sent was accepted and written onto a message'::text;
  end if;

  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  both carriers'' status words map, and a word from neither is refused';
  end if;

  -- ── 4. no sentence names a company we may have left ────────
  --
  -- Asked of the function's own definition rather than of this file, because
  -- the sentence is what somebody reads off a message on a screen, and a
  -- comment saying it was fixed is not evidence that it is.
  v_mark := coalesce(array_length(failures, 1), 0);

  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'record_text_status';
  if v_def ~* 'GoHighLevel' then
    failures := failures ||
      'FAILED: record_text_status names GoHighLevel in a sentence staff read off a message'::text;
  end if;

  select status into v_def from public.record_text_status('SM-nothing-on-file', 'teleported');
  if v_def ~* 'gohighlevel|twilio' then
    failures := failures || format(
      'FAILED: an unknown status is reported as %L, which names a carrier', v_def)::text;
  end if;

  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  nothing a person reads names the carrier we may have left';
  end if;

  -- ── 5. and the move loosens nothing ───────────────────────
  --
  -- The switch is on Twilio for all of this. A client with no consent is
  -- still refused, and a text outside the sending hours is still refused:
  -- if either of those were a per-provider rule, a cutover would quietly
  -- start texting people who had said no.
  v_mark := coalesce(array_length(failures, 1), 0);

  insert into public.clients (name, stage, status, counselor_id, phone)
  values ('ZZ Switch Nobody', 'Intake', 'Active', v_counsel, '+13855550222')
  returning id into v_client;

  begin
    insert into public.sms_messages (client_id, direction, phone, body, kind, status)
    values (v_client, 'Outgoing', public.normalize_phone('+13855550222'),
            'ZZ fixture, unconsented', 'Manual', 'Queued');
    failures := failures ||
      'FAILED: on Twilio an outgoing text was written for a client who never agreed to be texted'::text;
  exception when others then
    null;
  end;

  if not public.sms_within_sending_hours(
       (date_trunc('day', now() at time zone 'America/Denver') + interval '3 hours')
         at time zone 'America/Denver') then
    null;
  else
    failures := failures ||
      'FAILED: three in the morning is inside the sending hours, whichever carrier is live'::text;
  end if;

  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  consent and the sending hours are the same rules on either carrier';
  end if;

  -- ── 6. and the browser cannot ask or set ──────────────────
  v_mark := coalesce(array_length(failures, 1), 0);

  select count(*) into v_n from information_schema.routine_privileges
   where routine_schema = 'public'
     and routine_name in ('sms_provider', 'sms_provider_name', 'record_text_status')
     and grantee in ('anon', 'public');
  if v_n <> 0 then
    failures := failures || format(
      'FAILED: %s grant(s) on the switch or the status recorder reach anon or public', v_n)::text;
  end if;

  -- Admin sets it and the row rule says so. Asked of the policy rather than
  -- of a role name, because the policy is what would be edited.
  select count(*) into v_n from pg_policy
   where polrelid = 'public.org_settings'::regclass
     and polcmd in ('*', 'w') and polpermissive
     and pg_get_expr(polwithcheck, polrelid) ~* 'is_admin';
  if v_n = 0 then
    failures := failures ||
      'FAILED: nothing restricts writing org_settings to Admin, so anybody signed in could move the line'::text;
  end if;

  -- The new column has to be granted by name: org_settings carries column
  -- grants rather than a table grant, so a column added without them is a
  -- column no screen can read while `select` of the others goes on working.
  select count(*) into v_n from information_schema.column_privileges
   where table_schema = 'public' and table_name = 'org_settings'
     and column_name = 'sms_provider' and grantee = 'authenticated'
     and privilege_type in ('SELECT', 'UPDATE');
  if v_n <> 2 then
    failures := failures || format(
      'FAILED: authenticated holds %s of the two column grants on sms_provider, so Admin cannot read or set it',
      v_n)::text;
  end if;

  if coalesce(array_length(failures, 1), 0) = v_mark then
    raise notice '  ok  Admin sets the switch, and no browser can call it';
  end if;

  if array_length(failures, 1) > 0 then
    raise exception E'\n%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- THE PROVIDER IS A SETTING VERIFIED ---';
end $$;

rollback;
