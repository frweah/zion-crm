-- Zion Vocational Rehab CRM — two people logging hours at once
-- (stress test, finding 5, owner 16 Oct 2026)
--
-- check_entry_hours reads how many hours have been used and then decides
-- whether one more entry fits. Between the reading and the deciding there was
-- nothing holding the authorization still, and the default isolation level is
-- read committed, so two people logging against the same authorization in the
-- same moment both read the same figure, both find room, and both insert.
-- Fifty-eight hours of sixty used, two entries of ninety minutes, and the
-- authorization ends at sixty-one.
--
-- That matters more here than a lost update usually would. Hours past the
-- authorized total are hours the practice cannot bill USOR for, and it finds
-- out at submission - by which time the work has been done.
--
-- So the root authorization is locked before its hours are counted. It
-- serialises only entries against the same authorization family, which is
-- exactly the contention that has to be serialised; two coaches logging
-- against different clients never wait for each other.
--
-- Everything else about the trigger is 0205's, which is 0171's: the
-- future-date refusal, the non-billable pass, the flat-fee pass, the single
-- counter it shares with the screen and the working list, and the wording.

create or replace function public.check_entry_hours()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  a          public.authorizations%rowtype;
  v_root     uuid;
  v_total    numeric;
  used_hours numeric;
begin
  if new.date > public.practice_today() then
    raise exception 'Service hours cannot be logged for % — that date has not happened yet.',
      new.date using errcode = 'check_violation';
  end if;

  if new.non_billable then
    return new;
  end if;

  select * into a from public.authorizations where id = new.auth_id;
  if not found then
    return new;
  end if;

  v_root := coalesce(a.parent_id, a.id);

  /*
   * Held until this entry is committed or abandoned.
   *
   * Anybody else logging hours against this authorization or any of its
   * months waits here, and then counts a total that includes this entry
   * rather than the one that was true a moment ago.
   */
  select total_hours into v_total
    from public.authorizations where id = v_root for update;

  if v_total is null then
    return new;                                   -- flat fee, no hour cap
  end if;

  select u.used into used_hours
    from public.authorization_hours_used(array[v_root], new.id) u;

  if used_hours + new.hours > v_total then
    raise exception
      'Entry of % hrs exceeds the hours left on % (% authorized, % used). Request additional hours from the counselor first.',
      new.hours,
      coalesce(nullif((select number from public.authorizations where id = v_root), ''), a.service_type),
      v_total, used_hours
      using errcode = 'check_violation';
  end if;

  return new;
end;
$$;

do $$
begin
  if position('for update' in lower(pg_get_functiondef(
       'public.check_entry_hours()'::regprocedure))) = 0 then
    raise exception 'check_entry_hours does not hold the authorization while it counts.';
  end if;
  raise notice 'ok  the authorization is held while its hours are counted';
end $$;
