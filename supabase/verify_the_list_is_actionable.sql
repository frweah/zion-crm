-- Zion Vocational Rehab CRM — what leaves the working list (0177)
--
-- §9: "if a row needs no action from the person looking at it, it doesn't
-- show." What has to hold, each tried from the direction that would break it:
--
--   An authorization leaves the list the moment it is Paid, and the moment it
--   is Closed - not overnight, not when something is recalculated.
--
--   Every authorization of a closed client leaves it, whatever their own
--   status, because nobody is working with that person and the rows can
--   neither be billed nor cleared.
--
--   Closing the client does not rewrite the authorizations. They keep their
--   own status and stay readable on the client's record, so the history still
--   reads true - they are simply not work any more.
--
--   And reopening the client brings its live work back, because the decision
--   that took them off the list is the only thing that put them there.
--
-- Everything is rolled back.

begin;

do $$
declare
  v_client uuid;
  v_flat   uuid;
  v_hourly uuid;
  v_on     int;
  failures text[] := '{}';
  on_list  boolean;
begin
  insert into public.clients (name, stage, status) values ('ZZ List Client', 'Placement', 'Active')
  returning id into v_client;

  insert into public.authorizations
    (client_id, number, service_type, rate_type, rate, status, start_date, end_date, bill_by)
  values (v_client, 'ZZ-L-1', 'Job Development', 'Flat Fee', 560, 'Due',
          public.practice_today() - 30, public.practice_today() + 30, public.practice_today() - 1)
  returning id into v_flat;
  insert into public.authorizations
    (client_id, number, service_type, rate_type, rate, total_hours, status, start_date, end_date, bill_by)
  values (v_client, 'ZZ-L-2', 'WSA Tier 1', 'Flat Fee', 270, null, 'Authorized',
          public.practice_today() - 30, public.practice_today() + 30, public.practice_today() + 5)
  returning id into v_hourly;

  select count(*) into v_on from public.billing_worklist() where client_id = v_client;
  if v_on <> 2 then
    failures := failures || format('FAILED: two live authorizations put %s rows on the list', v_on);
  else
    raise notice 'ok  live work is on the list';
  end if;

  -- ── Paid leaves at once ────────────────────────────────────
  update public.authorizations set status = 'Closed', closed_reason = 'ZZ no longer needed'
   where id = v_flat;
  select exists (select 1 from public.billing_worklist() where id = v_flat) into on_list;
  if on_list then
    failures := failures || 'FAILED: a Closed authorization is still on the list'::text;
  else
    raise notice 'ok  Closed leaves the list the moment it is closed';
  end if;

  -- ── and a closed client takes the rest with it ─────────────
  select count(*) into v_on from public.billing_worklist() where client_id = v_client;
  if v_on <> 1 then
    failures := failures || format('FAILED: one live authorization left, and the list shows %s', v_on);
  end if;

  update public.clients set status = 'Closed' where id = v_client;
  select count(*) into v_on from public.billing_worklist() where client_id = v_client;
  if v_on <> 0 then
    failures := failures || format('FAILED: a closed client still has %s row(s) on the list', v_on);
  else
    raise notice 'ok  closing the client takes all of their work off the list';
  end if;

  -- ── without rewriting what happened ────────────────────────
  if (select status from public.authorizations where id = v_hourly) <> 'Authorized' then
    failures := failures || 'FAILED: closing the client rewrote the authorization''s own status'::text;
  elsif not exists (select 1 from public.authorization_record where id = v_hourly) then
    failures := failures || 'FAILED: a closed client''s authorization cannot be read any more'::text;
  else
    raise notice 'ok  the authorizations keep their own status and stay readable as history';
  end if;

  -- ── and the dashboard's one number agrees with the list ────
  if public.billing_needs_action() <> (select count(*) from public.billing_worklist()
                                        where coalesce(attention, '') <> '') then
    failures := failures || 'FAILED: the dashboard count and the list disagree'::text;
  else
    raise notice 'ok  the one number on the dashboard counts the same rows';
  end if;

  -- ── reopening the client brings the work back ──────────────
  update public.clients set status = 'Active' where id = v_client;
  select count(*) into v_on from public.billing_worklist() where client_id = v_client;
  if v_on <> 1 then
    failures := failures || format('FAILED: reopening the client brought back %s row(s), not 1', v_on);
  else
    raise notice 'ok  reopening the client brings their live work back';
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;

rollback;
