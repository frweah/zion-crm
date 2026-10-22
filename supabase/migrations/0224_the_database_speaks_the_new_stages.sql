-- Zion Vocational Rehab CRM — 0224 the database speaks the new stages
--
-- 0223 renamed the columns of the board and remapped every row. Four
-- functions still said the old words, which is the quiet half of a rename:
-- the data moves, the constraint moves, and the code that reads it goes on
-- asking for a stage nobody is in any more.
--
-- Found by the verification suite rather than by a person. Three scripts with
-- nothing to do with the board - texting, the intake and the web chat -
-- failed on clients_stage_check, and all three got there through a function.
--
-- Each body below is the live definition with one phrase changed and nothing
-- else. 'Job Placement' in correct_authorization is a service type rather
-- than a stage, and intake_referral only says the word in a sentence; both
-- are left alone.

-- ── referral_from_conversation ──
-- It inserted a client at 'Referral', which the new constraint refuses - so a referral arriving from a text or the website would have failed outright.
CREATE OR REPLACE FUNCTION public.referral_from_conversation(p_conversation uuid, p_name text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_who    text;
  v_kind   text;
  v_email  text;
  v_phone  text;
  v_client uuid;
  v_me     uuid := public.current_staff_id();
begin
  if (select public.current_staff_role()) not in ('Admin', 'Job Search', 'Reports') then
    raise exception 'Your role does not take referrals.' using errcode = 'insufficient_privilege';
  end if;
  if coalesce(btrim(p_name), '') = '' then
    raise exception 'A referral needs a name.' using errcode = 'check_violation';
  end if;
  select c.external_address, c.kind into v_who, v_kind
    from public.conversations c where c.id = p_conversation and c.kind in ('sms', 'web') and c.client_id is null;
  if v_who is null then
    raise exception 'That conversation is already somebody''s.' using errcode = 'check_violation';
  end if;

  if (select contact_kind from public.web_chats where conversation_id = p_conversation) = 'email' then
    v_email := v_who;
  else
    v_phone := v_who;
  end if;

  insert into public.clients (name, phone, email, stage, status, assigned_staff_id)
  values (btrim(p_name), coalesce(v_phone, ''), coalesce(v_email, ''), 'Intake', 'Active', v_me)
  returning id into v_client;

  -- Writing to them still needs their consent: arriving is not it.
  perform public.match_conversation(p_conversation, v_client);
  insert into public.tasks (client_id, title, assigned_staff_id, status, due)
  values (v_client,
          case when v_kind = 'web' then 'Intake call - asked on the website' else 'Intake call - texted in' end,
          v_me, 'Open', public.practice_today() + 1);
  return v_client;
end;
$function$;

-- ── intake_referral ──
-- It files a referral from a scanned form and created the client at 'Referral'. The sentence about a name matching two clients also says the word, and is left alone.
CREATE OR REPLACE FUNCTION public.intake_referral(p_doc uuid, p_name text, p_counselor text DEFAULT ''::text, p_office text DEFAULT ''::text, p_date date DEFAULT NULL::date, p_phone text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  cfg        public.org_settings;
  v_client   uuid;
  v_found    int;
  v_names    text;
  v_counsel  uuid;
  v_doc      public.inbox_documents;
  v_resend   boolean := false;
  v_due      date := public.next_business_day(public.practice_today());
  v_text     text;
  v_notify   jsonb := '[]'::jsonb;
  r          record;
begin
  select * into cfg from public.org_settings limit 1;
  if cfg.intake_staff_id is null then
    raise exception 'Nobody is set to receive intake (org_settings.intake_staff_id).'
      using errcode = 'no_data_found';
  end if;
  select * into v_doc from public.inbox_documents where id = p_doc;
  if not found then
    raise exception 'That document is not on file (%).', p_doc using errcode = 'no_data_found';
  end if;
  if coalesce(btrim(p_name), '') = '' then
    raise exception 'A referral with no client name on it cannot be filed.'
      using errcode = 'check_violation';
  end if;

  select count(*), string_agg(client_name, ' and '), (array_agg(client_id))[1]
    into v_found, v_names, v_client
    from public.intake_find_client(p_name);

  -- ── two candidates: create nothing, ask ────────────────────
  if v_found > 1 then
    v_text := format('Referral for %s matches more than one client on file (%s). The form is attached; it has not been filed.',
                     btrim(p_name), v_names);
    for r in select * from public.notify_person(
      cfg.intake_staff_id, 'intake', v_text, p_doc::text,
      '/admin/documents', null,
      format('Decide which client the referral for %s belongs to', btrim(p_name)), v_due, 'bad', p_doc)
    loop
      v_notify := v_notify || jsonb_build_object('name', r.staff_name, 'email', r.email, 'message', r.message);
    end loop;
    return jsonb_build_object('action', 'ambiguous name', 'client_id', null,
                              'candidates', v_names, 'notify', v_notify, 'reply', false);
  end if;

  select id into v_counsel from public.counselors
   where lower(btrim(name)) = lower(btrim(coalesce(p_counselor, ''))) limit 1;

  -- ── nobody on file: create them ────────────────────────────
  if v_found = 0 then
    insert into public.clients
      (name, stage, status, counselor_id, referring_office, phone,
       assigned_staff_id, billing_staff_id)
    values (btrim(p_name), 'Intake', 'Active', v_counsel, btrim(coalesce(p_office, '')),
            btrim(coalesce(p_phone, '')),
            (select id from public.staff where id = cfg.placement_staff_id and active),
            cfg.intake_staff_id)
    returning id into v_client;
  else
    v_resend := true;
    -- The counselor and the office as the form has them, where the record has
    -- nothing. Never overwritten: what is on the record was put there by
    -- somebody, and a form is not a correction.
    update public.clients set
      counselor_id = coalesce(counselor_id, v_counsel),
      referring_office = case when btrim(coalesce(referring_office, '')) = ''
                              then btrim(coalesce(p_office, '')) else referring_office end,
      phone = case when btrim(coalesce(phone, '')) = ''
                   then btrim(coalesce(p_phone, '')) else phone end
     where id = v_client;
  end if;

  -- ── the PDF, on the client, once ───────────────────────────
  -- One object: the attachment points at what the inbox already stored. The
  -- fingerprint made it one document however many times it arrived.
  insert into public.attachments
    (client_id, storage_path, filename, mime_type, size_bytes, category, note, uploaded_by_name)
  select v_client, v_doc.storage_path, v_doc.filename, 'application/pdf', v_doc.size_bytes,
         'Signed USOR form',
         'Received by email from ' || coalesce(nullif(btrim(p_counselor), ''), 'the counselor') || '.',
         'Intake'
   where not exists (
     select 1 from public.attachments a
      where a.client_id = v_client and a.storage_path = v_doc.storage_path
   );

  update public.inbox_documents set client_id = v_client where id = p_doc;

  -- ── the contact log ───────────────────────────────────────
  insert into public.contact_log (client_id, counselor_id, date, method, topic, outcome, staff_id)
  values (v_client, v_counsel, coalesce(p_date, public.practice_today()), 'Email',
          'Referral received',
          'Referral received by email from ' || coalesce(nullif(btrim(p_counselor), ''), 'the counselor') || '.',
          cfg.intake_staff_id);

  -- ── one notification, three places (Rules 1.4, 5) ──────────
  -- Rule 5: the intake task and the My day item are the same item, so there is
  -- one call and one task, titled as Rule 5 words it.
  if v_resend then
    v_text := format('Referral re-sent for %s — form attached.', btrim(p_name));
  else
    v_text := format('New referral: %s, from %s, %s. Intake call due %s.',
                     btrim(p_name),
                     coalesce(nullif(btrim(p_counselor), ''), 'an unnamed counselor'),
                     coalesce(nullif(btrim(p_office), ''), 'no office given'),
                     to_char(v_due, 'FMDay FMDD FMMonth'));
  end if;

  for r in select * from public.notify_person(
    cfg.intake_staff_id, 'intake', v_text, p_doc::text,
    '/clients/' || v_client::text, v_client,
    format('Initiate contact with %s%s — referred by %s',
           btrim(p_name),
           case when btrim(coalesce(p_phone, '')) <> '' then ' — ' || btrim(p_phone) else '' end,
           coalesce(nullif(btrim(p_counselor), ''), 'an unnamed counselor')),
    v_due, 'warn', p_doc)
  loop
    v_notify := v_notify || jsonb_build_object('name', r.staff_name, 'email', r.email, 'message', r.message);
  end loop;

  return jsonb_build_object(
    'action', case when v_resend then 'referral re-sent' else 'referral' end,
    'client_id', v_client, 'notify', v_notify, 'reply', true);
end;
$function$;

-- ── referral_received_on ──
-- It looked in the stage history for the day somebody reached 'Referral'. Nobody reaches it now, so every referral read as arriving the day the record was made.
CREATE OR REPLACE FUNCTION public.referral_received_on(p_client uuid)
 RETURNS date
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select least(
    coalesce((select min(l.date) from public.contact_log l
               where l.client_id = p_client and l.topic = 'Referral received'), 'infinity'::date),
    coalesce((select min(h.at)::date from public.client_stage_history h
               where h.client_id = p_client and h.stage = 'Intake'), 'infinity'::date),
    coalesce((select c.created_at::date from public.clients c where c.id = p_client), 'infinity'::date)
  )
$function$;

-- ── referrals_without_authorization ──
-- The counselor nudge chased clients at 'Referral'. There are none, so it would have chased nobody and said nothing was waiting.
CREATE OR REPLACE FUNCTION public.referrals_without_authorization(p_today date DEFAULT NULL::date)
 RETURNS TABLE(client_id uuid, client_name text, counselor_id uuid, counselor_name text, counselor_email text, received_on date, days_waiting integer, nth integer, send boolean, body text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with today as (select coalesce(p_today, public.practice_today()) as d),
  waiting as (
    select c.id, c.name, c.counselor_id, co.name as counselor_name, co.email as counselor_email,
           public.referral_received_on(c.id) as received_on,
           (select d from today) - public.referral_received_on(c.id) as days_waiting
      from public.clients c
      left join public.counselors co on co.id = c.counselor_id
     where c.stage = 'Intake'
       and c.status = 'Active'
       and c.merged_into is null
       and not exists (
         select 1 from public.authorizations a
          where a.client_id = c.id and a.parent_id is null
       )
  )
  select w.id, w.name, w.counselor_id, coalesce(w.counselor_name, ''), coalesce(w.counselor_email, ''),
         w.received_on, w.days_waiting,
         case when w.days_waiting >= 14 then 2 else 1 end as nth,
         -- Sent on the seventh and the fourteenth day only, and only once each.
         (w.days_waiting in (7, 14)
          and coalesce(w.counselor_email, '') <> ''
          and not exists (
            select 1 from public.chase_sent s
             where s.rule = 'referral nudge' and s.client_id = w.id
               and s.nth = case when w.days_waiting >= 14 then 2 else 1 end
          )) as send,
         format(
           'Hi %s — we received %s''s referral on %s and wanted to check whether an authorization is on its way. Thank you.',
           coalesce(nullif(split_part(btrim(coalesce(w.counselor_name, '')), ' ', 1), ''), 'there'),
           w.name,
           to_char(w.received_on, 'FMDD FMMonth YYYY')
         ) as body
    from waiting w
   where w.days_waiting >= 7
   order by w.days_waiting desc, w.name
$function$;

-- ── ledger_revenue_forecast ──
-- The forecast counted clients at 'Referral' or 'Intake' with nothing authorized. The two are one column now.
CREATE OR REPLACE FUNCTION public.ledger_revenue_forecast(p_months integer DEFAULT 3)
 RETURNS TABLE(month date, band text, amount numeric, note text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  with horizon as (
    select date_trunc('month', public.practice_today())::date as first_month,
           (date_trunc('month', public.practice_today()) + (p_months || ' months')::interval)::date as last_month
  ),
  /**
   * Committed: an authorization that exists and has not been billed.
   *
   * The month it is expected in is its own bill-by, which is now a column
   * rather than a rule to re-derive - §3 put it on the record, so the
   * forecast reads it instead of recomputing what the screen already shows.
   */
  committed as (
    select greatest(date_trunc('month', coalesce(a.bill_by, public.practice_today()))::date,
                    (select first_month from horizon)) as month,
           public.authorization_amount(a.id) as amount,
           a.id
      from public.authorizations a
     where a.status in ('Authorized', 'Due')
       and a.id not in (select parent_id from public.authorizations where parent_id is not null)
  ),
  /**
   * Authorized and not yet earned: the hours a coaching parent still has,
   * and flat-fee work not yet billed. Spread to the stale date, because
   * nothing in the record says which month it will actually be worked.
   */
  uncovered as (
    select a.id,
           greatest(
             coalesce(a.total_hours, 0) * coalesce(a.rate, 0)
               - coalesce((select sum(e.hours) from public.service_entries e
                            join public.authorizations c on c.id = e.auth_id
                           where (c.id = a.id or c.parent_id = a.id) and not e.non_billable), 0)
                 * coalesce(a.rate, 0),
             0) as amount,
           greatest(1, least(p_months + 1,
             case when a.stale_date is null then 3
                  else greatest(1, (extract(year from a.stale_date) * 12 + extract(month from a.stale_date))::int
                                   - (extract(year from public.practice_today()) * 12
                                      + extract(month from public.practice_today()))::int + 1)
             end))::int as spread
      from public.authorizations a
     where a.status in ('Authorized', 'Due')
       and a.rate_type = 'Hourly'
       and coalesce(a.total_hours, 0) > 0
  ),
  per_client as (
    select coalesce(avg(total), 0) as amount
      from (
        select a.client_id, sum(public.authorization_amount(a.id)) as total
          from public.authorizations a
         where a.created_at >= public.practice_today() - 180
         group by a.client_id
      ) t
  ),
  referred as (
    select count(*)::numeric as clients
      from public.clients c
     where c.status = 'Active'
       and c.stage = 'Intake'
       and not exists (select 1 from public.authorizations a where a.client_id = c.id)
  )
  select c.month, 'Committed', sum(c.amount),
         'Authorizations not yet billed, in the month their bill-by falls'
    from committed c
   where c.month <= (select last_month from horizon) and c.amount > 0
   group by c.month

  union all

  select m.month, 'Authorized', sum(round(u.amount / u.spread, 2)),
         'Hours authorized and not yet worked, spread to the stale date'
    from uncovered u
    cross join lateral (
      select (date_trunc('month', public.practice_today()) + (n || ' months')::interval)::date as month
        from generate_series(0, u.spread - 1) n
    ) m
   where u.amount > 0
     and m.month <= (select last_month from horizon)
   group by m.month

  union all

  select (date_trunc('month', public.practice_today()) + interval '2 months')::date, 'From the trend',
         round((select clients from referred) * (select amount from per_client), 2),
         (select clients from referred)::text || ' referred and not yet authorized, at the average of the last six months'
   where (select clients from referred) > 0
     and (select amount from per_client) > 0
     and (date_trunc('month', public.practice_today()) + interval '2 months')::date
         <= (select last_month from horizon)

   order by 1, 2;
$function$;
