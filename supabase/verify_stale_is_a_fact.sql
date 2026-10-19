-- Zion Vocational Rehab CRM — Stale is a fact, not a sentence (0221)
--
-- Billing → Authorizations has a Stale view, and the rows in it are the ones
-- past the grace: ended, and more than stale_grace_days ago, so USOR will not
-- take them and the only thing left to do is close them.
--
-- The screen could have found those rows by matching the attention line,
-- which already says "Cannot be submitted - ended <date>, more than 90 days
-- ago". It does not, and this is what stops anybody making it: the flag and
-- the sentence are asserted to agree, on the same rows, in both directions.
-- Rewrite the copy without rewriting the rule and this fails; change the rule
-- without changing the copy and this fails too.
--
-- The other half is the 90-day block itself, which the owner asked to keep.
-- A row one day inside the grace is not stale and can still be submitted; a
-- row one day past it is stale. Both are asserted, because "past its end
-- date" and "past saving" are different things and the filter is about the
-- second.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_client   uuid;
  v_grace    integer;
  v_today    date;
  v_past     uuid;
  v_inside   uuid;
  v_future   uuid;
  v_sent     uuid;
  v_blocked  boolean;
  v_att      text;
  v_n        integer;
  failures   text[] := '{}';
begin
  select stale_grace_days into v_grace from public.org_settings where id;
  v_today := public.practice_today();

  if v_grace is distinct from 90 then
    failures := failures || format(
      'FAILED: the grace is %s days, not the 90 the owner asked to keep. If that was deliberate, this assertion is the one to change.',
      v_grace)::text;
  else
    raise notice 'ok  the grace is still 90 days';
  end if;

  insert into public.clients (name) values ('ZZ Stale Fixture') returning id into v_client;

  -- Ended one day past the grace: stale.
  insert into public.authorizations
    (client_id, service_type, rate_type, number, status, rate, start_date, end_date, stale_date)
  values (v_client, 'Job Coaching', 'Flat Fee', 'VZZ900001', 'Due', 1.00,
          v_today - (v_grace + 400), v_today - (v_grace + 1), v_today - (v_grace + 1))
  returning id into v_past;

  -- Ended, but one day short of the grace: not stale, still submittable.
  insert into public.authorizations
    (client_id, service_type, rate_type, number, status, rate, start_date, end_date, stale_date)
  values (v_client, 'Job Coaching', 'Flat Fee', 'VZZ900002', 'Due', 1.00,
          v_today - (v_grace + 400), v_today - (v_grace - 1), v_today - (v_grace - 1))
  returning id into v_inside;

  -- Not ended at all.
  insert into public.authorizations
    (client_id, service_type, rate_type, number, status, rate, start_date, end_date, stale_date)
  values (v_client, 'Job Coaching', 'Flat Fee', 'VZZ900003', 'Due', 1.00,
          v_today - 10, v_today + 30, v_today + 30)
  returning id into v_future;

  -- Long past the grace, but already submitted: not the practice's problem.
  insert into public.authorizations
    (client_id, service_type, rate_type, number, status, rate, start_date, end_date, stale_date,
     submitted_on)
  values (v_client, 'Job Coaching', 'Flat Fee', 'VZZ900004', 'Submitted', 1.00,
          v_today - (v_grace + 400), v_today - (v_grace + 50), v_today - (v_grace + 50),
          v_today - 20)
  returning id into v_sent;

  -- ── past the grace is stale ───────────────────────────────
  select w.blocked, w.attention into v_blocked, v_att
    from public.billing_worklist() w where w.id = v_past;
  if v_blocked is not true then
    failures := failures ||
      'FAILED: an authorization a day past the grace is not marked stale, so the Stale view would miss it'::text;
  else
    raise notice 'ok  a day past the grace reads as stale';
  end if;

  -- ── and the sentence agrees with the flag ─────────────────
  if v_att not like 'Cannot be submitted%' then
    failures := failures || format(
      'FAILED: a stale row says "%s" rather than that it cannot be submitted - the flag and the words have come apart',
      v_att)::text;
  else
    raise notice 'ok  and it says so in words as well';
  end if;

  -- ── a day inside the grace is not ─────────────────────────
  select w.blocked, w.attention into v_blocked, v_att
    from public.billing_worklist() w where w.id = v_inside;
  if v_blocked is not false then
    failures := failures ||
      'FAILED: an authorization still inside the grace is marked stale, so a bulk close would sweep up work that can still be billed'::text;
  else
    raise notice 'ok  a day inside the grace is not stale';
  end if;
  if v_att not like 'Past its end date%can still be submitted%' then
    failures := failures || format(
      'FAILED: a row inside the grace says "%s" rather than that it can still be submitted', v_att)::text;
  else
    raise notice 'ok  and it still says it can be submitted';
  end if;

  -- ── one that has not ended is not ─────────────────────────
  select w.blocked into v_blocked from public.billing_worklist() w where w.id = v_future;
  if v_blocked is not false then
    failures := failures || 'FAILED: an authorization that has not ended is marked stale'::text;
  else
    raise notice 'ok  one that has not ended is not stale';
  end if;

  -- ── and one already submitted never is ────────────────────
  select w.blocked into v_blocked from public.billing_worklist() w where w.id = v_sent;
  if v_blocked is not false then
    failures := failures ||
      'FAILED: an authorization already submitted is marked stale, and it is with USOR rather than with us'::text;
  else
    raise notice 'ok  one already submitted is never stale, however old';
  end if;

  -- ── neither direction drifts, across the whole list ───────
  --
  -- The screen filters on the flag and a person reads the sentence. If those
  -- two ever disagree on any row, one of them is lying to somebody.
  select count(*) into v_n from public.billing_worklist() w
   where w.blocked <> (coalesce(w.attention, '') like 'Cannot be submitted%');
  if v_n > 0 then
    failures := failures || format(
      'FAILED: %s rows where the stale flag and the sentence disagree', v_n)::text;
  else
    raise notice 'ok  the flag and the sentence agree on every row in the list';
  end if;

  -- ── the Stale view is exactly the blocked rows ────────────
  select count(*) into v_n from public.billing_worklist() w where w.blocked;
  raise notice 'ok  the Stale view would show % of % rows', v_n,
    (select count(*) from public.billing_worklist());

  -- ── and anon cannot read any of it ────────────────────────
  if has_function_privilege('anon', 'public.billing_worklist(date, uuid)', 'execute')
     or has_function_privilege('anon', 'public.authorization_attention_for(uuid[], date)', 'execute') then
    failures := failures || 'FAILED: anon may read the working list'::text;
  else
    raise notice 'ok  anon cannot read the working list';
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- STALE IS A FACT VERIFIED ---';
end $$;

rollback;
