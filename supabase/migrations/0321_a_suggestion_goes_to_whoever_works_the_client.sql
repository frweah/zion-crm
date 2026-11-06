-- Zion Vocational Rehab CRM — a suggestion goes to whoever works the client
--
-- The owner, 6 Nov 2026, on the ninety-five unfiled emails waiting in the
-- log: "surface them as To file suggestions to the assigned staff member
-- (Margaret where none), never auto-filed."
--
-- 0318 offered mail to whoever owned the mailbox it came from, which is the
-- obvious reading of "one inbox per staff member" and the wrong one. The live
-- rows say why: of the ninety-five, fifty-seven are in the Admin mailbox and
-- forty-eight in the Reports one, and seventy-eight of them are about clients
-- worked by somebody who is neither. Routing by mailbox would have put
-- seventy-eight decisions in front of two people who cannot make them and
-- none in front of the person who can.
--
-- ── which means the item has two people on it, not one ───────
--
-- Whose inbox it is and whose thing it was are now different questions, and
-- the second one has a column. `staff_id` is the inbox - who has to decide.
-- `by_staff_id` is whose email it was, whose calendar, whose recording - and
-- that is the one that goes onto the contact log when the item is confirmed.
--
-- Without it, a job coach confirming an email the Admin desk sent would put a
-- contact-log entry on the client saying the job coach emailed them. That is
-- not a small inaccuracy: the contact log is what a monthly report reads, so
-- it would be in a document that goes to the state over somebody's signature.
--
-- For a calendar item the two are the same person and nothing changes.
--
-- ── and the fallback is a desk rather than a name ────────────
--
-- "Margaret where none" is a person today and a role for as long as the
-- practice exists, so what is written down is the role: the Reports desk,
-- which is already the one that sees every inbox in the read policy, because
-- somebody has to be able to answer "has anybody filed this" for the
-- practice. A client with nobody assigned is the practice's to work out, and
-- the Reports desk is where the practice keeps that sort of thing. Admin
-- second, if ever there is no Reports desk at all.

begin;

-- ─────────────────────────────────────────────────────────────
-- Whose thing it was
-- ─────────────────────────────────────────────────────────────
alter table public.to_file
  add column if not exists by_staff_id uuid references public.staff(id) on delete set null;

-- Everything offered so far was offered to the person it belonged to, which is
-- what the column now says out loud.
update public.to_file set by_staff_id = staff_id where by_staff_id is null;

alter table public.to_file alter column by_staff_id set not null;

comment on column public.to_file.by_staff_id is
  'Whose email, calendar or recording this was - which is who the contact log '
  'credits when it is confirmed. Usually the same person as staff_id; for '
  'mail it is the mailbox owner, while the inbox belongs to whoever works the '
  'client.';

-- ─────────────────────────────────────────────────────────────
-- The desk that takes what nobody else owns
-- ─────────────────────────────────────────────────────────────
create or replace function public.unassigned_filing_desk()
returns uuid
language sql
stable
security definer
set search_path to 'public'
as $$
  -- Longest-serving first, so the answer does not move about when somebody
  -- joins. A system account is never a person who can decide anything.
  select s.id
    from public.staff s
   where s.active and not s.is_system and s.role in ('Reports', 'Admin')
   order by case s.role when 'Reports' then 0 else 1 end, s.created_at
   limit 1
$$;

comment on function public.unassigned_filing_desk is
  'Whose inbox something about a client with nobody assigned goes to: the '
  'Reports desk, or Admin where there is no Reports desk.';

-- Nobody signed in may ask this. It is only ever called from inside
-- to_file_from_mail, which is security definer and so calls it with the
-- owner's rights - and granting it to `authenticated` would let anybody with
-- a session, a portal client included, learn which member of staff holds the
-- filing desk. verify_portal_rls caught exactly that, which is the second
-- time this week an elevated helper has been written one grant too wide.
revoke all on function public.unassigned_filing_desk() from public, anon, authenticated;
grant execute on function public.unassigned_filing_desk() to service_role;

-- ─────────────────────────────────────────────────────────────
-- Offering something says who it belonged to
--
-- A defaulted parameter does not change a function, it makes a second one -
-- and the second one starts life with execute granted to PUBLIC. So the old
-- signature goes first, by name.
-- ─────────────────────────────────────────────────────────────
drop function if exists public.to_file_offer(uuid, text, text, text, text, timestamptz, uuid, text);

create or replace function public.to_file_offer(
  p_staff      uuid,
  p_source     text,
  p_source_key text,
  p_title      text,
  p_detail     text default '',
  p_happened   timestamptz default null,
  p_client     uuid default null,
  p_guess_why  text default '',
  p_by_staff   uuid default null)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_id uuid;
begin
  -- The sweeps run with nobody signed in, behind the cron secret, as the
  -- service role. A signed-in person has no business putting things in
  -- somebody's inbox: there are screens for that.
  if coalesce(auth.role(), '') <> 'service_role' then
    perform public.refuse_elevated('to_file_offer',
      'Only the nightly sweep offers something to file.');
  end if;

  if coalesce(btrim(p_source_key), '') = '' then
    raise exception 'Something to file has to say what it is, or it cannot be offered once.'
      using errcode = 'check_violation';
  end if;

  -- Offered once. A second sighting of the same event updates what it says
  -- about itself and leaves the decision alone - so a sweep that looks back
  -- sixty days on Monday and a day on Tuesday does not undo Monday's work.
  insert into public.to_file
    (staff_id, source, source_key, title, detail, happened_at, client_id, guess_why, by_staff_id)
  values
    (p_staff, p_source, btrim(p_source_key), coalesce(p_title, ''), coalesce(p_detail, ''),
     p_happened, p_client, coalesce(p_guess_why, ''), coalesce(p_by_staff, p_staff))
  on conflict (staff_id, source, source_key) do update
     set title = excluded.title,
         detail = excluded.detail,
         happened_at = coalesce(excluded.happened_at, public.to_file.happened_at),
         -- The guess is only improved where there was none. A person who
         -- assigned it to somebody keeps that.
         client_id = case when public.to_file.state = 'Waiting' and public.to_file.decided_at is null
                               and public.to_file.client_id is null
                          then excluded.client_id else public.to_file.client_id end,
         guess_why = case when public.to_file.client_id is null
                          then excluded.guess_why else public.to_file.guess_why end
         -- by_staff_id is not touched: whose email it was is a fact about the
         -- message, and the first sighting read it from the same row the
         -- second one would.
   returning id into v_id;

  return v_id;
end $$;

comment on function public.to_file_offer is
  'Puts something in a member of staff inbox to decide about. Writes nothing '
  'onto a client. p_by_staff says whose thing it was, where that is not the '
  'person whose inbox it is.';

revoke all on function public.to_file_offer(uuid, text, text, text, text, timestamptz, uuid, text, uuid)
  from public, anon, authenticated;

-- ─────────────────────────────────────────────────────────────
-- Confirming it credits whoever did it
-- ─────────────────────────────────────────────────────────────
create or replace function public.to_file_confirm(
  p_item     uuid,
  p_outcome  text,
  p_note     text default '',
  p_category text default null)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_item  public.to_file%rowtype;
  v_staff uuid := public.current_staff_id();
  v_name  text;
  v_id    uuid;
begin
  if not public.to_file_is_mine(p_item) then
    raise exception 'That is not in your inbox.' using errcode = 'insufficient_privilege';
  end if;

  select * into v_item from public.to_file where id = p_item for update;
  if v_item.state <> 'Waiting' then
    raise exception 'That has been dealt with already.' using errcode = 'check_violation';
  end if;
  if p_outcome not in ('happened', 'did not happen', 'wrong client') then
    raise exception 'Say whether it happened, did not happen, or was the wrong client.'
      using errcode = 'check_violation';
  end if;

  select name into v_name from public.staff where id = v_staff;

  /**
   * The wrong client is not a decision about the item.
   *
   * It says the guess was wrong, so the guess goes and the item waits for
   * somebody to say whose it is. Marking it Confirmed would file a judgment
   * about a client it turned out not to be about.
   */
  if p_outcome = 'wrong client' then
    update public.to_file
       set client_id = null, guess_why = 'The guess was wrong', outcome = ''
     where id = p_item;
    return null;
  end if;

  if v_item.client_id is null then
    raise exception 'Say which client it was about first.'
      using hint = 'Assign it to a client, then confirm it.', errcode = 'check_violation';
  end if;

  -- It happened: the contact log gets the entry, and that entry is what a
  -- report reads. Nothing was on the record before this line ran.
  --
  -- Credited to whoever the contact was - the mailbox it was sent from, the
  -- calendar it was on - and not to whoever pressed the button. Those are the
  -- same person for everything except mail about somebody else's client, and
  -- for that one the difference would reach a signed monthly report.
  if p_outcome = 'happened' then
    insert into public.contact_log
      (client_id, date, method, topic, outcome, category, staff_id)
    values
      (v_item.client_id,
       coalesce(v_item.happened_at::date, public.practice_today()),
       case v_item.source when 'Calendar' then 'Appointment'
                          when 'Email' then 'Email'
                          else 'Recording' end,
       coalesce(nullif(btrim(v_item.title), ''), v_item.source),
       coalesce(nullif(btrim(p_note), ''), 'Happened'),
       p_category,
       coalesce(v_item.by_staff_id, v_staff, v_item.staff_id))
    returning id into v_id;
  end if;

  update public.to_file
     set state = 'Confirmed',
         outcome = p_outcome,
         note = btrim(coalesce(p_note, '')),
         category = p_category,
         contact_id = v_id,
         decided_by = v_staff,
         decided_by_name = coalesce(v_name, ''),
         decided_at = now()
   where id = p_item;

  return v_id;
end $$;

revoke all on function public.to_file_confirm(uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.to_file_confirm(uuid, text, text, text) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- The mail sweep, routed by the client rather than the mailbox
-- ─────────────────────────────────────────────────────────────
create or replace function public.to_file_from_mail(p_since date default null)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_from date := coalesce(p_since, public.practice_today() - 2);
  v_desk uuid := public.unassigned_filing_desk();
  v_n    integer := 0;
  r      record;
begin
  if coalesce(auth.role(), '') <> 'service_role' then
    perform public.refuse_elevated('to_file_from_mail',
      'Only the nightly sweep offers mail for filing.');
  end if;

  -- One suggestion per message, which is why the distinct is on the message
  -- and not on the pair. Twelve of the ninety-five name two clients, and two
  -- rows about one email is two things to clear for one decision - the person
  -- who gets it can reassign it to the other client in a press.
  --
  -- Where the client has nobody, the Reports desk. Where there is no Reports
  -- desk either, the mailbox owner, because an item nobody can see is worse
  -- than one in front of the wrong person.
  for r in
    select distinct on (m.id)
           m.id, m.staff_id, m.graph_message_id, m.subject, m.sent_at,
           m.counterpart_email, m.direction, n.client_id, n.how,
           coalesce(c.assigned_staff_id, v_desk, m.staff_id) as inbox,
           owner.name as mailbox_owner
      from public.mail_log m
      join lateral public.clients_named_in(
             coalesce(m.subject, '') || ' ' || coalesce(m.counterpart_email, '')) n on true
      join public.clients c on c.id = n.client_id
      join public.staff owner on owner.id = m.staff_id
     where m.staff_id is not null
       and m.client_id is null
       and m.sent_at >= v_from::timestamptz
     order by m.id, m.sent_at
  loop
    if not exists (select 1 from public.to_file f
                    where f.source = 'Email'
                      and f.source_key = coalesce(nullif(r.graph_message_id, ''), r.id::text)) then
      perform public.to_file_offer(
        r.inbox, 'Email',
        coalesce(nullif(r.graph_message_id, ''), r.id::text),
        coalesce(nullif(btrim(r.subject), ''), '(no subject)'),
        -- Whose mailbox, where that is not the person reading this. They did
        -- not send it and may need to ask the person who did.
        (case when r.direction = 'Outgoing' then 'Sent to ' else 'From ' end
          || coalesce(nullif(r.counterpart_email, ''), 'somebody'))
          || case when r.inbox is distinct from r.staff_id
                  then ', in ' || r.mailbox_owner || '''s mailbox' else '' end,
        r.sent_at, r.client_id, r.how, r.staff_id);
      v_n := v_n + 1;
    end if;
  end loop;

  return v_n;
end $$;

comment on function public.to_file_from_mail is
  'Offers unfiled mail that names an active client to the inbox of whoever '
  'works that client. Files nothing: a person confirms it or discards it.';

revoke all on function public.to_file_from_mail(date) from public, anon, authenticated;

commit;
