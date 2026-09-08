-- Zion Vocational Rehab CRM — Microsoft account connections
--
-- A refresh token is worth more than a taxpayer number. A TIN identifies a
-- person; a refresh token acts as them, unattended, until it is revoked. So
-- the rules are stricter than anywhere else in this system: the ciphertext is
-- unreadable to the application role, the plaintext is readable only by the
-- person it belongs to — not by Admin — and deactivating an account destroys
-- it rather than leaving it on file.
--
-- Runs inside a transaction that is rolled back. Nothing here is left behind.

begin;

do $$
declare
  v_admin    uuid;
  v_adm_uid  uuid;
  v_rei      uuid;
  v_rei_uid  uuid;
  v_marg     uuid;
  v_access   text;
  v_refresh  text;
  v_count    int;
  failures   text[] := '{}';
begin
  select id, user_id into v_admin, v_adm_uid from public.staff where legacy_id = 's1';
  select id, user_id into v_rei,  v_rei_uid  from public.staff where legacy_id = 's2';
  select id             into v_marg          from public.staff where legacy_id = 's3';

  -- ── the key is in Vault, not in the schema ─────────────────
  if not exists (select 1 from vault.secrets where name = 'zion_oauth_key') then
    failures := failures || 'FAILED: the OAuth encryption key is not in Vault'::text;
  else
    raise notice 'ok  the OAuth encryption key is held in Vault';
  end if;

  -- ── a person connects their own account ────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_rei_uid, 'role', 'authenticated')::text, true);

  perform public.set_microsoft_tokens(
    'ms-user-zz', 'zz@example.com', 'ZZ Verify', 'offline_access User.Read',
    'ZZ-ACCESS-TOKEN', 'ZZ-REFRESH-TOKEN', now() + interval '1 hour');

  if not exists (select 1 from public.microsoft_connections where staff_id = v_rei) then
    failures := failures || 'FAILED: the connection was not recorded'::text;
  else
    raise notice 'ok  a person can connect their own Microsoft account';
  end if;

  -- ── the tokens are ciphertext, not text ────────────────────
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  if exists (
    select 1 from public.microsoft_connections
     where staff_id = v_rei
       and (encode(refresh_encrypted, 'escape') like '%ZZ-REFRESH-TOKEN%'
            or encode(access_encrypted, 'escape') like '%ZZ-ACCESS-TOKEN%')
  ) then
    failures := failures || 'FAILED: a token is readable in the table'::text;
  else
    raise notice 'ok  the tokens are held as ciphertext';
  end if;

  -- ── the owner of the token can read it back ────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_rei_uid, 'role', 'authenticated')::text, true);

  select access_token, refresh_token into v_access, v_refresh
    from public.get_microsoft_tokens(v_rei);

  if v_access <> 'ZZ-ACCESS-TOKEN' or v_refresh <> 'ZZ-REFRESH-TOKEN' then
    failures := failures || 'FAILED: the person could not read their own token back'::text;
  else
    raise notice 'ok  the person the token belongs to can read it back';
  end if;

  -- A refresh that returns no new refresh token must not wipe the one held.
  perform public.set_microsoft_tokens(
    'ms-user-zz', 'zz@example.com', 'ZZ Verify', 'offline_access User.Read',
    'ZZ-ACCESS-2', null, now() + interval '1 hour');

  select access_token, refresh_token into v_access, v_refresh
    from public.get_microsoft_tokens(v_rei);
  if v_refresh <> 'ZZ-REFRESH-TOKEN' then
    failures := failures || 'FAILED: refreshing without a new refresh token wiped the old one'::text;
  else
    raise notice 'ok  a refresh with no new refresh token keeps the one on file';
  end if;
  if v_access <> 'ZZ-ACCESS-2' then
    failures := failures || 'FAILED: the new access token was not stored'::text;
  else
    raise notice 'ok  a refresh replaces the access token';
  end if;

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  -- ── not even Admin can read somebody's token ───────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', v_adm_uid, 'role', 'authenticated')::text, true);

  begin
    perform public.get_microsoft_tokens(v_rei);
    failures := failures || 'FAILED: Admin read somebody else''s Microsoft token'::text;
  exception when insufficient_privilege then
    raise notice 'ok  not even Admin can read another person''s token — that would be reading their mail';
  end;

  -- Admin can still see that a connection exists, which is what a sync needs.
  if not exists (select 1 from public.microsoft_connections where staff_id = v_rei) then
    failures := failures || 'FAILED: Admin cannot see who is connected'::text;
  else
    raise notice 'ok  Admin can see who is connected, without seeing their token';
  end if;

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  -- ── a colleague sees nothing at all ────────────────────────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', (select user_id from public.staff where id = v_marg),
                                       'role', 'authenticated')::text, true);

  select count(*) into v_count from public.microsoft_connections;
  if v_count <> 0 then
    failures := failures || format('FAILED: a colleague saw %s connections', v_count);
  else
    raise notice 'ok  a colleague cannot see that anybody else is connected';
  end if;

  begin
    perform public.get_microsoft_tokens(v_rei);
    failures := failures || 'FAILED: a colleague read somebody else''s token'::text;
  exception when insufficient_privilege then
    raise notice 'ok  a colleague cannot read somebody else''s token';
  end;

  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);

  -- ── offboarding destroys the token ─────────────────────────
  update public.staff set active = false where id = v_rei;

  if exists (select 1 from public.microsoft_connections where staff_id = v_rei) then
    failures := failures || 'FAILED: deactivating an account left the Microsoft token on file'::text;
  else
    raise notice 'ok  deactivating an account destroys the connection with it';
  end if;

  if failures = '{}' then
    raise notice '';
    raise notice '--- MICROSOFT CONNECTIONS VERIFIED ---';
  else
    raise notice '';
    raise notice '%  PROBLEM(S):', array_length(failures, 1);
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
