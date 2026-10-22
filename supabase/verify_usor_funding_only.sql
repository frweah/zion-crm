-- Zion Vocational Rehab CRM — no Medicaid-funded record (0226)
--
-- The CRM is the USOR side of a hybrid entity. A client, an authorization or
-- a rate funded by HCBS Medicaid is refused, from a new row and from an edit.
--
-- Runs inside a transaction that is rolled back. Nothing here is left behind.

begin;

do $$
declare
  v_client uuid;
  failures text[] := '{}';
begin
  begin
    insert into public.clients (name, stage, status, funding_source) values ('ZZ Medicaid', 'Intake', 'Active', 'HCBS Medicaid');
    failures := failures || 'FAILED: a client funded by HCBS Medicaid was added'::text;
  exception when check_violation then null;
  end;

  insert into public.clients (name, stage, status) values ('ZZ USOR', 'Intake', 'Active') returning id into v_client;
  begin
    update public.clients set funding_source = 'HCBS Medicaid' where id = v_client;
    failures := failures || 'FAILED: a client was changed to HCBS Medicaid funding'::text;
  exception when check_violation then null;
  end;

  begin
    update public.authorizations set funding_source = 'HCBS Medicaid'
     where id = (select id from public.authorizations limit 1);
    if found then failures := failures || 'FAILED: an authorization was changed to HCBS Medicaid funding'::text; end if;
  exception when check_violation then null;
  end;

  begin
    update public.rate_schedule set funding_source = 'HCBS Medicaid'
     where id = (select id from public.rate_schedule limit 1);
    if found then failures := failures || 'FAILED: a rate was changed to HCBS Medicaid funding'::text; end if;
  exception when check_violation then null;
  end;

  if array_length(failures, 1) > 0 then
    raise exception E'\n%', array_to_string(failures, E'\n');
  end if;
  raise notice 'ok  nothing in the CRM can be funded by HCBS Medicaid';
  raise notice '--- USOR FUNDING VERIFIED ---';
end;
$$;

rollback;
