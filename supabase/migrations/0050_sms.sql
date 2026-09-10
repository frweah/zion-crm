-- ─────────────────────────────────────────────────────────────
-- 0050 — texting clients, and the consent that has to come first
--
-- Appointment reminders the day before, sent through the practice's
-- GoHighLevel sub-account from 385-406-3432, the client line.
--
-- The rules here are not conveniences. Texting somebody who has not agreed to
-- be texted is a federal matter, and "the screen would not let you" is worth
-- nothing next to "the database would not let you" — an API route, a cron
-- job, a future import and a person with the service key are four different
-- ways to reach the same table.
--
-- So: consent is a record with a history, not a checkbox. Withdrawing is
-- always allowed and never lost. An outgoing message to a client without
-- current consent cannot be written down at all, which means it cannot be
-- sent, because sending is what writing it down represents.
-- ─────────────────────────────────────────────────────────────

-- ─────────────────────────────────────────────────────────────
-- Phone numbers, in one shape
--
-- The workbook holds "(801) 674-5180" and a carrier wants "+18016745180".
-- Every comparison in this file goes through here, so a reply from a number
-- with a different amount of punctuation still finds its client.
-- ─────────────────────────────────────────────────────────────
create or replace function public.normalize_phone(p_raw text)
returns text language sql immutable as $$
  select case
    when p_raw is null then null
    when length(regexp_replace(p_raw, '\D', '', 'g')) = 10
      then '+1' || regexp_replace(p_raw, '\D', '', 'g')
    when length(regexp_replace(p_raw, '\D', '', 'g')) = 11
         and left(regexp_replace(p_raw, '\D', '', 'g'), 1) = '1'
      then '+' || regexp_replace(p_raw, '\D', '', 'g')
    when p_raw like '+%' and length(regexp_replace(p_raw, '\D', '', 'g')) between 8 and 15
      then '+' || regexp_replace(p_raw, '\D', '', 'g')
    else null
  end;
$$;

comment on function public.normalize_phone is
  'A US phone number as E.164, or null if it is not one. Every comparison between our numbers and a carrier''s goes through this.';

-- ─────────────────────────────────────────────────────────────
-- Consent, as a history
--
-- Append-only. The current state is the latest row, and a withdrawal can
-- never be edited away — which is the only version of this worth having when
-- somebody asks, two years later, what we were relying on.
-- ─────────────────────────────────────────────────────────────
create table if not exists public.sms_consent_events (
  id          uuid primary key default gen_random_uuid(),
  -- Which record came last, when two share a timestamp.
  --
  -- Two events can carry the same `at`: everything inside one transaction sees
  -- the same now(), and a grant followed immediately by a STOP is exactly the
  -- sequence that matters. Ordering by a uuid to break that tie is ordering by
  -- a coin toss, and the coin decides whether somebody who said stop is texted
  -- tomorrow. A sequence cannot tie.
  seq         bigserial not null,
  client_id   uuid not null references public.clients(id) on delete cascade,
  state       text not null check (state in ('Granted', 'Withdrawn')),
  -- The number consent was given for. Consent follows the number, not the
  -- person: a client who changes phones has not agreed to be texted there.
  phone       text not null,
  method      text not null check (method in ('Verbal', 'Written', 'Intake form', 'Text reply', 'Staff')),
  note        text not null default '',
  at          timestamptz not null default now(),
  staff_id    uuid references public.staff(id) on delete set null
);

create index if not exists sms_consent_client_idx
  on public.sms_consent_events (client_id, at desc, seq desc);

alter table public.sms_consent_events enable row level security;

drop policy if exists sms_consent_read on public.sms_consent_events;
drop policy if exists sms_consent_write on public.sms_consent_events;

create policy sms_consent_read on public.sms_consent_events
  for select to authenticated using (public.is_active_staff());

-- Recording consent is a client-record action, so it follows who may edit a
-- client record. A withdrawal arriving by text is written by the webhook
-- through a definer function, not by anybody signed in.
create policy sms_consent_write on public.sms_consent_events
  for insert to authenticated
  with check (
    public.current_staff_role() in ('Admin', 'Job Search', 'Reports')
    and staff_id is not distinct from public.current_staff_id()
  );

-- No update or delete policy, deliberately: a consent history that can be
-- rewritten is not a history.

create or replace function public.sms_consent_append_only()
returns trigger language plpgsql as $$
begin
  raise exception 'A consent record cannot be changed. Record the new state instead.'
    using errcode = 'check_violation';
end;
$$;

drop trigger if exists sms_consent_no_edit on public.sms_consent_events;
create trigger sms_consent_no_edit before update or delete on public.sms_consent_events
  for each row execute function public.sms_consent_append_only();

-- ─────────────────────────────────────────────────────────────
-- Where consent stands now
-- ─────────────────────────────────────────────────────────────
create or replace view public.client_sms_consent as
select c.id                                   as client_id,
       public.normalize_phone(c.phone)        as client_phone,
       e.state,
       e.phone                                as consented_phone,
       e.method,
       e.at                                   as since,
       e.staff_id,
       -- Consent is only good for the number it was given for. If the client
       -- record now holds a different number, we do not have consent to text
       -- it, and saying so beats discovering it in a complaint.
       (e.state = 'Granted'
        and e.phone = public.normalize_phone(c.phone)
        and public.normalize_phone(c.phone) is not null) as can_text
  from public.clients c
  left join lateral (
    select * from public.sms_consent_events x
     where x.client_id = c.id
     order by x.at desc, x.seq desc
     limit 1
  ) e on true;

alter view public.client_sms_consent set (security_invoker = true);
grant select on public.client_sms_consent to authenticated;

comment on view public.client_sms_consent is
  'Where texting consent stands for each client. can_text is false unless consent was granted for the number now on the record.';

-- ─────────────────────────────────────────────────────────────
-- The messages
-- ─────────────────────────────────────────────────────────────
create table if not exists public.sms_messages (
  id                  uuid primary key default gen_random_uuid(),
  client_id           uuid references public.clients(id) on delete set null,
  direction           text not null check (direction in ('Outgoing', 'Incoming')),
  phone               text not null,
  body                text not null,
  kind                text not null default 'Manual'
                        check (kind in ('Reminder', 'Reply', 'Manual', 'System')),
  -- Which appointment a reminder is for, so it is sent once and only once.
  event_id            uuid references public.calendar_events(id) on delete set null,
  provider            text not null default 'GoHighLevel',
  provider_message_id text,
  status              text not null default 'Queued'
                        check (status in ('Queued', 'Sent', 'Failed', 'Received')),
  error               text not null default '',
  sent_at             timestamptz,
  created_at          timestamptz not null default now(),
  created_by          uuid references public.staff(id) on delete set null
);

create index if not exists sms_messages_client_idx
  on public.sms_messages (client_id, created_at desc);
create index if not exists sms_messages_phone_idx
  on public.sms_messages (phone, created_at desc);

-- One reminder per appointment. A cron job that runs twice, or a person
-- pressing a button after it has run, does not text somebody the same
-- reminder again.
create unique index if not exists sms_reminder_once
  on public.sms_messages (event_id)
  where kind = 'Reminder' and direction = 'Outgoing' and status <> 'Failed';

alter table public.sms_messages enable row level security;

drop policy if exists sms_messages_read on public.sms_messages;
drop policy if exists sms_messages_write on public.sms_messages;

-- Visible to all active staff, the same decision the owner made about logged
-- mail: whoever picks up the phone should be able to see what was said.
create policy sms_messages_read on public.sms_messages
  for select to authenticated using (public.is_active_staff());

create policy sms_messages_write on public.sms_messages
  for insert to authenticated
  with check (
    public.current_staff_role() in ('Admin', 'Job Search', 'Reports')
    and direction = 'Outgoing'
  );

-- ─────────────────────────────────────────────────────────────
-- The gate
--
-- Everything above is arrangement. This is the rule.
-- ─────────────────────────────────────────────────────────────
-- ─────────────────────────────────────────────────────────────
-- When a text may go out
--
-- Eight in the morning to nine at night, the client's time. Taken as an
-- argument rather than read from the clock inside the trigger, so it can be
-- checked at eleven at night without waiting until then — a rule that can
-- only be tested by staying up is a rule that does not get tested.
-- ─────────────────────────────────────────────────────────────
create or replace function public.sms_within_sending_hours(p_at timestamptz)
returns boolean language sql immutable as $$
  select extract(hour from (p_at at time zone 'America/Denver')) >= 8
     and extract(hour from (p_at at time zone 'America/Denver')) < 21;
$$;

create or replace function public.sms_outgoing_requires_consent()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_ok    boolean;
  v_phone text;
begin
  if new.direction <> 'Outgoing' then
    return new;
  end if;

  if new.client_id is null then
    raise exception 'A text has to be to somebody: no client on this message.'
      using errcode = 'check_violation';
  end if;

  select can_text, consented_phone into v_ok, v_phone
    from public.client_sms_consent where client_id = new.client_id;

  if not coalesce(v_ok, false) then
    raise exception
      'This client has not agreed to be texted at the number on their record, so nothing can be sent to them. Record their consent first.'
      using errcode = 'check_violation';
  end if;

  -- Consent is for a number, so the message goes to that number.
  if public.normalize_phone(new.phone) is distinct from v_phone then
    raise exception
      'That is not the number this client agreed to be texted at.'
      using errcode = 'check_violation';
  end if;
  new.phone := v_phone;

  -- A reminder is not urgent enough to be worth waking somebody up for.
  if not public.sms_within_sending_hours(now()) then
    raise exception
      'It is % in Utah. Texts go out between 8am and 9pm.',
      to_char(now() at time zone 'America/Denver', 'HH12:MIam')
      using errcode = 'check_violation';
  end if;

  return new;
end;
$$;

drop trigger if exists sms_consent_gate on public.sms_messages;
create trigger sms_consent_gate before insert on public.sms_messages
  for each row execute function public.sms_outgoing_requires_consent();

-- ─────────────────────────────────────────────────────────────
-- A reply arriving
--
-- Definer, because the webhook has no signed-in person behind it. It resolves
-- the client by number, writes the message down, and — this is the part that
-- matters — acts on STOP itself rather than leaving it to whatever called it.
-- ─────────────────────────────────────────────────────────────
create or replace function public.record_incoming_sms(
  p_phone       text,
  p_body        text,
  p_provider_id text default null
)
returns table (client_id uuid, action text)
language plpgsql security definer set search_path = public as $$
declare
  v_phone  text := public.normalize_phone(p_phone);
  v_client uuid;
  v_word   text := upper(regexp_replace(coalesce(p_body, ''), '[^A-Za-z]', '', 'g'));
  v_action text := 'logged';
begin
  if v_phone is null then
    raise exception 'That is not a phone number we can match: %', p_phone
      using errcode = 'check_violation';
  end if;

  select c.id into v_client
    from public.clients c
   where public.normalize_phone(c.phone) = v_phone
   order by case when c.status = 'Active' then 0 else 1 end, c.created_at
   limit 1;

  -- The message is written down whether or not we know whose it is. A STOP
  -- from a number we cannot place still has to be honoured, and an unmatched
  -- reply is a thing somebody should see rather than lose.
  insert into public.sms_messages (client_id, direction, phone, body, kind,
                                   provider_message_id, status, sent_at)
  values (v_client, 'Incoming', v_phone, coalesce(p_body, ''), 'Reply',
          p_provider_id, 'Received', now());

  -- The keywords carriers require, plus the ones people actually send.
  if v_word in ('STOP', 'STOPALL', 'UNSUBSCRIBE', 'CANCEL', 'END', 'QUIT', 'REVOKE', 'OPTOUT') then
    if v_client is not null then
      insert into public.sms_consent_events (client_id, state, phone, method, note)
      values (v_client, 'Withdrawn', v_phone, 'Text reply',
              'Replied ' || v_word || ' — consent withdrawn automatically');
    end if;
    v_action := 'withdrawn';

  elsif v_word in ('START', 'UNSTOP', 'YES', 'OPTIN') then
    -- A person can put themselves back on, and only for the number they sent
    -- from. Anything less would mean a withdrawal that cannot be undone
    -- without ringing the office.
    if v_client is not null then
      insert into public.sms_consent_events (client_id, state, phone, method, note)
      values (v_client, 'Granted', v_phone, 'Text reply',
              'Replied ' || v_word || ' — consent given by text');
    end if;
    v_action := 'granted';
  end if;

  return query select v_client, v_action;
end;
$$;

-- Nobody signed in may call this: a person with a browser must not be able to
-- withdraw somebody else's consent, or fake a reply into their timeline. Only
-- the webhook, which runs as the service role behind a shared secret.
revoke execute on function public.record_incoming_sms(text, text, text) from public;
revoke execute on function public.record_incoming_sms(text, text, text) from authenticated;
revoke execute on function public.record_incoming_sms(text, text, text) from anon;
grant execute on function public.record_incoming_sms(text, text, text) to service_role;

-- ─────────────────────────────────────────────────────────────
-- Recording consent from inside the app
-- ─────────────────────────────────────────────────────────────
create or replace function public.set_sms_consent(
  p_client_id uuid,
  p_state     text,
  p_method    text,
  p_note      text default ''
)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_staff uuid := public.current_staff_id();
  v_phone text;
begin
  if v_staff is null then
    raise exception 'You are not signed in.' using errcode = 'insufficient_privilege';
  end if;
  if public.current_staff_role() not in ('Admin', 'Job Search', 'Reports') then
    raise exception 'Your role does not change client records.'
      using errcode = 'insufficient_privilege';
  end if;
  if p_state not in ('Granted', 'Withdrawn') then
    raise exception 'Consent is granted or withdrawn.' using errcode = 'check_violation';
  end if;

  select public.normalize_phone(phone) into v_phone from public.clients where id = p_client_id;
  if v_phone is null then
    raise exception
      'There is no usable phone number on this client, so there is nothing to consent to.'
      using errcode = 'check_violation';
  end if;

  -- Granting needs a note saying how it was given: "verbal, at intake, 3 March"
  -- is the whole evidence if anybody ever asks.
  if p_state = 'Granted' and coalesce(p_note, '') = '' then
    raise exception 'Say how consent was given — it is the only record of it.'
      using errcode = 'check_violation';
  end if;

  insert into public.sms_consent_events (client_id, state, phone, method, note, staff_id)
  values (p_client_id, p_state, v_phone, p_method, coalesce(p_note, ''), v_staff);
end;
$$;

revoke execute on function public.set_sms_consent(uuid, text, text, text) from public;
grant execute on function public.set_sms_consent(uuid, text, text, text) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- Which reminders are due
--
-- Tomorrow's appointments, in Utah's day rather than the server's, for
-- clients who have agreed to be texted and have not been reminded already.
-- ─────────────────────────────────────────────────────────────
create or replace view public.sms_due_reminders as
select e.id                                          as event_id,
       e.client_id,
       c.name                                        as client_name,
       k.consented_phone                             as phone,
       e.title,
       e.kind,
       e.starts_at,
       (e.starts_at at time zone 'America/Denver')::date as local_date,
       to_char(e.starts_at at time zone 'America/Denver', 'FMDay FMDD FMMonth') as local_day,
       to_char(e.starts_at at time zone 'America/Denver', 'FMHH12:MIam')        as local_time
  from public.calendar_events e
  join public.clients c on c.id = e.client_id
  join public.client_sms_consent k on k.client_id = c.id
 where e.client_id is not null
   and k.can_text
   and (e.starts_at at time zone 'America/Denver')::date
       = (public.practice_today() + 1)
   and not exists (
     select 1 from public.sms_messages m
      where m.event_id = e.id
        and m.kind = 'Reminder'
        and m.direction = 'Outgoing'
        and m.status <> 'Failed'
   );

alter view public.sms_due_reminders set (security_invoker = true);
grant select on public.sms_due_reminders to authenticated;

comment on view public.sms_due_reminders is
  'Appointments tomorrow, Utah time, for clients who have agreed to be texted and have not already been reminded about that appointment.';

-- ─────────────────────────────────────────────────────────────
-- The timeline learns about texting
--
-- Restated in full, as 0034 and 0035 did before it: this view is the one
-- definition of what has happened to a client, and a second view unioned onto
-- it would be a second definition waiting to disagree.
-- ─────────────────────────────────────────────────────────────
create or replace view public.client_activity as
select * from ( SELECT n.client_id,
            COALESCE(n.at::timestamp with time zone, n.created_at) AS at,
            'Note'::text AS kind,
            n.type AS title,
            n.text AS detail,
            n.staff_name AS who,
            'notes'::text AS tab,
            n.id AS ref_id
           FROM notes n
        UNION ALL
         SELECT h.client_id,
            COALESCE(h.at::timestamp with time zone, h.created_at) AS "coalesce",
            'Stage'::text,
            'Moved to '::text || h.stage,
            ''::text,
            s.name,
            'overview'::text,
            h.id
           FROM client_stage_history h
             LEFT JOIN staff s ON s.id = h.staff_id
        UNION ALL
         SELECT m.client_id,
            m.applied_on::timestamp with time zone AS applied_on,
            'Job'::text,
            'Applied — '::text || COALESCE(e.name, l.title, 'a job'::text),
            COALESCE(l.title, ''::text) AS "coalesce",
            s.name,
            'overview'::text,
            m.id
           FROM lead_matches m
             JOIN job_leads l ON l.id = m.lead_id
             LEFT JOIN employers e ON e.id = l.employer_id
             LEFT JOIN staff s ON s.id = m.created_by
          WHERE m.applied_on IS NOT NULL
        UNION ALL
         SELECT m.client_id,
            m.interview_on::timestamp with time zone AS interview_on,
            'Interview'::text,
            'Interview — '::text || COALESCE(e.name, l.title, 'a job'::text),
            COALESCE(l.title, ''::text) AS "coalesce",
            s.name,
            'overview'::text,
            m.id
           FROM lead_matches m
             JOIN job_leads l ON l.id = m.lead_id
             LEFT JOIN employers e ON e.id = l.employer_id
             LEFT JOIN staff s ON s.id = m.created_by
          WHERE m.interview_on IS NOT NULL
        UNION ALL
         SELECT m.client_id,
            m.follow_up_on::timestamp with time zone AS follow_up_on,
            'Follow-up'::text,
            'Follow up — '::text || COALESCE(e.name, l.title, 'a job'::text),
            COALESCE(l.title, ''::text) AS "coalesce",
            s.name,
            'overview'::text,
            m.id
           FROM lead_matches m
             JOIN job_leads l ON l.id = m.lead_id
             LEFT JOIN employers e ON e.id = l.employer_id
             LEFT JOIN staff s ON s.id = m.created_by
          WHERE m.follow_up_on IS NOT NULL
        UNION ALL
         SELECT m.client_id,
            m.decided_on::timestamp with time zone AS decided_on,
            'Job'::text,
            (m.status || ' — '::text) || COALESCE(e.name, l.title, 'a job'::text),
            COALESCE(NULLIF(m.outcome, ''::text), m.notes, ''::text) AS "coalesce",
            s.name,
            'overview'::text,
            m.id
           FROM lead_matches m
             JOIN job_leads l ON l.id = m.lead_id
             LEFT JOIN employers e ON e.id = l.employer_id
             LEFT JOIN staff s ON s.id = m.created_by
          WHERE m.decided_on IS NOT NULL
        UNION ALL
         SELECT t.client_id,
            t.done_at,
            'Task'::text,
            'Done — '::text || t.title,
            ''::text,
            s.name,
            'tasks'::text,
            t.id
           FROM tasks t
             LEFT JOIN staff s ON s.id = t.assigned_staff_id
          WHERE t.status = 'Done'::text AND t.done_at IS NOT NULL
        UNION ALL
         SELECT f.client_id,
            f.completed_at,
            'Form'::text,
            'Completed — '::text || COALESCE(ft.name, 'form'::text),
            ''::text,
            f.completed_by_name,
            'forms'::text,
            f.id
           FROM forms f
             LEFT JOIN form_templates ft ON ft.id = f.template_id
          WHERE f.completed_at IS NOT NULL
        UNION ALL
         SELECT f.client_id,
            f.sent_at,
            'Form'::text,
            'Sent — '::text || COALESCE(ft.name, 'form'::text),
            COALESCE(f.sent_to, ''::text) AS "coalesce",
            f.completed_by_name,
            'forms'::text,
            f.id
           FROM forms f
             LEFT JOIN form_templates ft ON ft.id = f.template_id
          WHERE f.sent_at IS NOT NULL
        UNION ALL
         SELECT cl.client_id,
            cl.date::timestamp with time zone AS date,
            'Counselor'::text,
            cl.method || COALESCE(' — '::text || NULLIF(cl.topic, ''::text), ''::text),
            COALESCE(cl.outcome, ''::text) AS "coalesce",
            s.name,
            'counselors'::text,
            cl.id
           FROM contact_log cl
             LEFT JOIN staff s ON s.id = cl.staff_id
          WHERE cl.client_id IS NOT NULL
        UNION ALL
         SELECT p.client_id,
            p.start_date::timestamp with time zone AS start_date,
            'Placement'::text,
            'Started — '::text || COALESCE(NULLIF(p.employer, ''::text), 'a placement'::text),
            COALESCE(p.title, ''::text) AS "coalesce",
            NULL::text,
            'placements'::text,
            p.id
           FROM placements p
          WHERE p.start_date IS NOT NULL
        UNION ALL
         SELECT p.client_id,
            c.at::timestamp with time zone AS at,
            'Retention'::text,
            (c.label || ' check — '::text) || COALESCE(NULLIF(p.employer, ''::text), 'placement'::text),
            ''::text,
            NULL::text,
            'placements'::text,
            p.id
           FROM placements p
             CROSS JOIN LATERAL ( VALUES (p.check30,'30 day'::text), (p.check60,'60 day'::text), (p.check90,'90 day'::text)) c(at, label)
          WHERE c.at IS NOT NULL
        UNION ALL
         SELECT a.client_id,
            se.date::timestamp with time zone AS date,
            'Hours'::text,
            (fmt_hours(se.hours) || ' logged'::text) ||
                CASE
                    WHEN se.non_billable THEN ' (non-billable)'::text
                    ELSE ''::text
                END,
            COALESCE(se.notes, ''::text) AS "coalesce",
            s.name,
            'authorizations'::text,
            se.id
           FROM service_entries se
             JOIN authorizations a ON a.id = se.auth_id
             LEFT JOIN staff s ON s.id = se.staff_id
        UNION ALL
         SELECT ce.client_id,
            ce.starts_at,
            'Appointment'::text,
            (ce.kind || ' — '::text) || ce.title,
            COALESCE(ce.location, ''::text) AS "coalesce",
            s.name,
            'calendar'::text,
            ce.id
           FROM calendar_events ce
             LEFT JOIN staff s ON s.id = ce.staff_id
          WHERE ce.client_id IS NOT NULL
        UNION ALL
         SELECT ml.client_id,
            ml.sent_at,
            'Mail'::text,
                CASE ml.direction
                    WHEN 'Incoming'::text THEN 'From '::text
                    ELSE 'To '::text
                END || ml.counterpart_email,
            ml.subject,
            NULL::text,
            'calendar'::text,
            ml.id
           FROM mail_log ml
          WHERE ml.client_id IS NOT NULL
        UNION ALL
         -- Texts, both directions. A reminder that went out and a reply that
         -- came back belong in the same timeline as a call or an email —
         -- otherwise "did anyone tell her?" is a question about four screens.
         SELECT sm.client_id,
            COALESCE(sm.sent_at, sm.created_at),
            'Text'::text,
                CASE sm.direction
                    WHEN 'Incoming'::text THEN 'From the client'::text
                    ELSE 'To the client'::text
                END ||
                CASE
                    WHEN sm.status = 'Failed'::text THEN ' — not delivered'::text
                    WHEN sm.kind = 'Reminder'::text THEN ' — appointment reminder'::text
                    ELSE ''::text
                END,
            sm.body,
            s.name,
            'calendar'::text,
            sm.id
           FROM sms_messages sm
             LEFT JOIN staff s ON s.id = sm.created_by
          WHERE sm.client_id IS NOT NULL) feed;

alter view public.client_activity set (security_invoker = true);
grant select on public.client_activity to authenticated;
