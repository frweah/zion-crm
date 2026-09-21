-- Zion Vocational Rehab CRM — work inside the dates, and a flat fee proved
--
-- Punch list #4 (review, 20 Sept 2026): four authorizations end on
-- 30 September with nothing earned against them - two flat fees with no
-- completion date, a job coaching authorization with no hours, and a WSA -
-- and "done" is every piece of billable work documented and invoiced inside
-- its authorized dates, with verified completion dates recorded before
-- billing goes ahead.
--
-- Four things, each a rule the database keeps rather than a habit:
--
--   Every open flat-fee authorization has a completion to record. Only two
--   ever had a row, so the other flat fees had nowhere for a completion date
--   to go and could never show as earned.
--
--   A completion date is inside the authorization's dates, not before the
--   work started, and not in the future. A date outside the dates is work
--   USOR did not authorize, and the answer is an extension, not a date.
--
--   Billable hours are logged inside the authorization's dates, for the
--   same reason.
--
--   A flat-fee invoice is not sent until its completion date is recorded.
--
-- And the client record says, a month out, when an authorization is about
-- to end with money on it - not only when hours have been logged, which is
-- the case the four above were all missing.

-- ── a completion for every open flat fee ─────────────────────
create or replace function public.ensure_completion_row()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.rate_type = 'Flat Fee'
     and not exists (select 1 from public.completions where auth_id = new.id) then
    insert into public.completions (auth_id, start_date, notes)
    values (new.id, new.start_date, '');
  end if;
  return new;
end;
$$;

drop trigger if exists authorizations_completion_row on public.authorizations;
create trigger authorizations_completion_row after insert or update of rate_type on public.authorizations
  for each row execute function public.ensure_completion_row();

insert into public.completions (auth_id, start_date, notes)
select a.id, a.start_date, ''
  from public.authorizations a
 where a.rate_type = 'Flat Fee' and a.status = 'Open'
   and not exists (select 1 from public.completions c where c.auth_id = a.id);

-- ── a completion inside the dates ──────────────────────────
create or replace function public.check_completion_dates()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  a public.authorizations%rowtype;
begin
  if new.completion is null then
    return new;
  end if;
  select * into a from public.authorizations where id = new.auth_id;

  if new.completion > public.practice_today() then
    raise exception 'A completion on % has not happened yet.', new.completion
      using errcode = 'check_violation';
  end if;
  if new.start_date is not null and new.completion < new.start_date then
    raise exception 'The completion (%) is before the work started (%).', new.completion, new.start_date
      using errcode = 'check_violation';
  end if;
  if (a.start_date is not null and new.completion < a.start_date)
     or (a.end_date is not null and new.completion > a.end_date) then
    raise exception '% runs % to %, and % is outside it. Work outside the dates was not authorized - ask the counselor to extend the authorization first.',
      coalesce(nullif(a.number, ''), a.service_type),
      coalesce(a.start_date::text, 'its start'), coalesce(a.end_date::text, 'its end'), new.completion
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

drop trigger if exists completions_dates on public.completions;
create trigger completions_dates before insert or update of completion, start_date on public.completions
  for each row execute function public.check_completion_dates();

-- ── billable hours inside the dates ────────────────────────
create or replace function public.check_entry_in_dates()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  a public.authorizations%rowtype;
begin
  if new.non_billable then
    return new;
  end if;
  select * into a from public.authorizations where id = new.auth_id;
  if (a.start_date is not null and new.date < a.start_date)
     or (a.end_date is not null and new.date > a.end_date) then
    raise exception '% runs % to %, and % is outside it. Log it as non-billable, or ask the counselor to extend the authorization.',
      coalesce(nullif(a.number, ''), a.service_type),
      coalesce(a.start_date::text, 'its start'), coalesce(a.end_date::text, 'its end'), new.date
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

drop trigger if exists service_entries_in_dates on public.service_entries;
create trigger service_entries_in_dates before insert or update of date, auth_id, non_billable on public.service_entries
  for each row execute function public.check_entry_in_dates();

-- ── a flat fee is not sent without its completion ──────────
create or replace function public.check_invoice_completion()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  a public.authorizations%rowtype;
begin
  if new.status <> 'Sent' or (tg_op = 'UPDATE' and old.status = 'Sent') then
    return new;
  end if;
  select * into a from public.authorizations where id = new.auth_id;
  if a.rate_type = 'Flat Fee'
     and not exists (select 1 from public.completions c where c.auth_id = a.id and c.completion is not null) then
    raise exception 'Invoice cannot be sent: % is a flat fee and no completion date is recorded. Record the verified completion on Billing -> Authorizations first.',
      coalesce(nullif(a.number, ''), a.service_type)
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

drop trigger if exists invoices_completion_guard on public.invoices;
create trigger invoices_completion_guard before insert or update of status on public.invoices
  for each row execute function public.check_invoice_completion();

revoke execute on function public.ensure_completion_row() from public, anon, authenticated;
revoke execute on function public.check_completion_dates() from public, anon, authenticated;
revoke execute on function public.check_entry_in_dates() from public, anon, authenticated;
revoke execute on function public.check_invoice_completion() from public, anon, authenticated;

-- ── what the client record says a month out ────────────────
CREATE OR REPLACE FUNCTION public.client_next_actions(p_client uuid)
 RETURNS TABLE(kind text, title text, detail text, href text, urgency integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with c as (select * from public.clients where id = p_client)
  -- The next appointment, from client_next_up rather than from the events
  -- table: that view already knows an appointment being withdrawn from
  -- Outlook is not one, and a second definition here would forget.
  (select 'appointment',
         'Appointment ' || to_char(n.at at time zone 'America/Denver', 'Dy DD Mon, FMHH12:MIam'),
         n.title,
         '/clients/' || p_client || '?tab=activity',
         case when n.at < now() + interval '24 hours' then 1 else 4 end
    from public.client_next_up n
   where n.client_id = p_client and n.kind = 'Appointment'
   order by n.at limit 1)

  union all
  -- A form that is blocking billing: hours logged against an authorization
  -- with no form for them.
  select 'form', p.usor || ' needed',
         p.form_name || coalesce(' · ' || p.month, '') || ' · ' || trim(to_char(p.hours_logged, 'FM999990.9')) || ' hours logged',
         '/billing/report?client=' || p_client,
         2
    from public.client_paperwork p
   where p.client_id = p_client and p.state = 'Missing'

  union all
  -- An authorization running out with money on it not yet invoiced (0116):
  -- hours logged and not billed, a flat fee with no completion recorded, or
  -- nothing done at all. After its end date none of it can be earned, so
  -- this is the last month to finish the work, record it, or ask the
  -- counselor to extend.
  select 'authorization', 'Authorization ' || a.number || ' ends ' || to_char(a.end_date, 'FMDD Mon'),
         case
           when a.rate_type = 'Flat Fee' and e.completed_on is null
             then 'No completion recorded - ' || trim(to_char(e.authorized - coalesce(e.invoiced, 0), 'FM$999,990.00'))
                  || ' not earned. Record it within the dates, or ask the counselor to extend'
           when coalesce(u.hours, 0) = 0
             then 'No hours logged - ' || trim(to_char(e.authorized - coalesce(e.invoiced, 0), 'FM$999,990.00'))
                  || ' not invoiced. Log the work within the dates, or ask the counselor to extend'
           else trim(to_char(coalesce(u.hours, 0), 'FM999990.9')) || ' hours logged on it, '
                || trim(to_char(greatest(e.unbilled, 0), 'FM$999,990.00')) || ' not yet invoiced'
         end,
         '/clients/' || p_client || '?tab=billing',
         case when a.end_date <= public.practice_today() + 14 then 1 else 3 end
    from public.authorizations a
    join public.authorization_economics e on e.auth_id = a.id
    left join lateral (
      select sum(se.hours) hours from public.service_entries se
       where se.auth_id = a.id and not se.non_billable) u on true
   where a.client_id = p_client and a.status = 'Open'
     and a.end_date is not null
     and a.end_date between public.practice_today() and public.practice_today() + 30
     and coalesce(e.authorized, 0) > coalesce(e.invoiced, 0)

  union all
  -- Five shifts kept: the placement may be billed, on USOR 92.
  select 'placement', 'Fifth shift reached',
         coalesce(nullif(pl.employer, ''), 'the placement') || ' · USOR 92 and the placement bill are due',
         '/billing/report?client=' || p_client, 2
    from public.placements pl
   where pl.client_id = p_client
     and pl.fifth_shift_on is not null
     and not exists (
       select 1 from public.forms f
        join public.authorizations a on a.id = f.auth_id
       where f.client_id = p_client and f.template_id = 'usor92'
         and f.status <> 'Draft' and a.service_type like 'Job Placement%')

  union all
  -- Thirty days of stability: the High Quality Indicators may be billed.
  select 'stability', 'Thirty days of stability',
         coalesce(nullif(pl.employer, ''), 'the placement')
           || coalesce(' · ' || nullif(pl.stability_basis, ''), '')
           || ' · High Quality Indicators may be billed',
         '/clients/' || p_client || '?tab=billing', 2
    from public.placements pl
   where pl.client_id = p_client
     and pl.stability_on is not null
     and pl.stability_on + 30 <= public.practice_today()
     and not exists (
       select 1 from public.authorizations a
        join public.invoices i on i.auth_id = a.id
       where a.client_id = p_client and a.service_type like '%HQ Indicator%')

  union all
  -- A text from them that nobody has answered.
  select 'text', 'Unanswered text', left(m.body, 80),
         '/clients/' || p_client || '?tab=messages', 1
    from public.conversations v
    join lateral (
      select body, sender_kind from public.messages
       where conversation_id = v.id order by seq desc limit 1) m on true
   where v.client_id = p_client and v.kind = 'sms' and m.sender_kind = 'client'

  union all
  -- Nobody has recorded whether they agreed to be texted.
  select 'consent', 'Texting consent not recorded',
         'They cannot be texted until it is', '/clients/' || p_client || '?tab=profile#texting', 3
    from c
   where not exists (select 1 from public.sms_consent_events e where e.client_id = p_client)

  union all
  -- A retention check that has come due on a placement.
  select 'retention', d.label || ' check due',
         coalesce(nullif(pl.employer, ''), 'a placement'),
         '/clients/' || p_client || '?tab=jobs', 2
    from public.placements pl
    cross join lateral (values
      (pl.check30, 30, '30 day'), (pl.check60, 60, '60 day'), (pl.check90, 90, '90 day')
    ) d(done, days, label)
   where pl.client_id = p_client and pl.start_date is not null
     and d.done is null and pl.start_date + d.days <= public.practice_today()

  order by 5, 1;
$function$;

revoke execute on function public.client_next_actions(uuid) from public, anon;
grant execute on function public.client_next_actions(uuid) to authenticated, service_role;
