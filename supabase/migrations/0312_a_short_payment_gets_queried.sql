-- Zion Vocational Rehab CRM — what came of querying an invoice
--
-- Phase 3 raised a short payment the day it happened, with the difference on
-- it, and then had nothing to say about what anybody did next. The chase
-- repeated itself every night for ever, because nothing could tell it the
-- conversation had happened. The owner asked for the missing half, 6 November
-- 2026: who was asked, when, what they said, and whether that settled it.
--
-- ── a note is one exchange, and it is not edited ─────────────
--
-- One row is one note: on this day I asked this person and this is what they
-- said. A second call is a second note. Nothing here is updated or deleted,
-- the way nothing in the correction log is, because a record of what somebody
-- said that can be rewritten afterwards is not a record of what they said.
--
-- So an unanswered call is a note with nobody's answer on it yet, rather than
-- a row waiting to be filled in - and when they ring back, that is the next
-- note. `said` may be empty; `asked_of` may not, because a note that does not
-- say who was asked answers nothing.
--
-- ── resolved settles the shortfall, not the debt ─────────────
--
-- A note may be marked as having settled it, and that stops the short-paid
-- chase. It does not stop the thirty-day chase on an invoice that is simply
-- unpaid, and the difference matters: a short payment is an answer that can
-- be accepted, and silence is not. Money still owed is still owed however
-- good the conversation was.
--
-- Notes are allowed on any invoice, not only a short-paid one. "Called
-- Downtown, it is in the next batch" is the same kind of record and the same
-- person writes it; only the suppressing is particular to a short payment.
-- And `resolved` defaults to false, because the dull case is the common one:
-- recording a call is not the same as closing the question.

begin;

create table if not exists public.invoice_queries (
  id               uuid primary key default gen_random_uuid(),
  invoice_id       uuid not null references public.invoices(id) on delete cascade,
  asked_on         date not null,
  -- Who was asked. A name, an office, an email address - whatever the person
  -- writing it would use to say who they spoke to.
  asked_of         text not null,
  -- What they said. Empty where nobody has said anything yet.
  said             text not null default '',
  resolved         boolean not null default false,
  recorded_by      uuid references public.staff(id) on delete set null,
  recorded_by_name text not null default '',
  at               timestamptz not null default now(),
  constraint invoice_queries_asked_of_said check (btrim(asked_of) <> ''),
  -- A note that settles it has to say what settled it.
  constraint invoice_queries_resolved_says_why check (not resolved or btrim(said) <> '')
);

create index if not exists invoice_queries_invoice_idx
  on public.invoice_queries (invoice_id, asked_on desc);

comment on table public.invoice_queries is
  'What came of querying an invoice: who was asked, when, what they said, and '
  'whether that settled it. One row per exchange, never changed or removed.';

-- ── never changed or removed ─────────────────────────────────
create or replace function public.invoice_query_append_only()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  raise exception 'A note about querying an invoice is not changed or removed. Write the next note.'
    using errcode = 'check_violation';
end $$;

drop trigger if exists invoice_queries_append_only on public.invoice_queries;
create trigger invoice_queries_append_only
  before update or delete on public.invoice_queries
  for each row execute function public.invoice_query_append_only();

-- ── who may read it, and how it is written ───────────────────
alter table public.invoice_queries enable row level security;

drop policy if exists invoice_queries_read on public.invoice_queries;
create policy invoice_queries_read on public.invoice_queries
  for select using ((select public.is_active_staff()));

-- No write policy, the same way invoices and payments have none: the note
-- goes in through a function that says who wrote it.
revoke all on public.invoice_queries from anon, authenticated;
grant select on public.invoice_queries to authenticated;
revoke execute on function public.invoice_query_append_only() from anon, authenticated;

select public.apply_system_read_only('invoice_queries');

-- ── writing one ──────────────────────────────────────────────
create or replace function public.record_invoice_query(
  p_invoice  uuid,
  p_asked_of text,
  p_said     text default null,
  p_resolved boolean default false,
  p_asked_on date default null)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_inv   public.invoices%rowtype;
  v_when  date := coalesce(p_asked_on, public.practice_today());
  v_staff uuid := public.current_staff_id();
  v_name  text;
  v_id    uuid;
begin
  if not public.billing_hands() then
    raise exception 'Recording what came of a query is Billing''s, or an Admin''s.'
      using errcode = 'insufficient_privilege';
  end if;

  select * into v_inv from public.invoices where id = p_invoice;
  if not found then
    raise exception 'That invoice does not exist.' using errcode = 'no_data_found';
  end if;

  if btrim(coalesce(p_asked_of, '')) = '' then
    raise exception 'Say who was asked.' using errcode = 'check_violation';
  end if;

  if v_when > public.practice_today() then
    raise exception 'A query cannot have happened on %, which has not happened yet.', v_when
      using errcode = 'invalid_parameter_value';
  end if;

  if coalesce(p_resolved, false) and btrim(coalesce(p_said, '')) = '' then
    raise exception 'Say what settled it.'
      using hint = 'A note that closes the question has to carry the answer.',
            errcode = 'check_violation';
  end if;

  select name into v_name from public.staff where id = v_staff;

  insert into public.invoice_queries
    (invoice_id, asked_on, asked_of, said, resolved, recorded_by, recorded_by_name)
  values
    (p_invoice, v_when, btrim(p_asked_of), btrim(coalesce(p_said, '')),
     coalesce(p_resolved, false), v_staff, coalesce(v_name, ''))
  returning id into v_id;

  /**
   * And the item it was raised as comes off My day.
   *
   * The chase above stops raising a settled short payment, but the item it
   * raised yesterday is already on somebody's list, and a rule that stops
   * telling you while leaving the old telling in place has not finished. The
   * bell goes with it, by the key notify_person deduplicates on - which is
   * also what lets a later short payment on the same invoice ring again.
   *
   * Only the short-paid item. The thirty-day item is about money that has not
   * arrived and settling a conversation does not make it arrive.
   */
  if coalesce(p_resolved, false) then
    update public.tasks
       set status = 'Done', done_at = public.practice_today(), updated_at = now()
     where source_kind = 'invoice_short_paid' and source_ref = p_invoice and status = 'Open';
    delete from public.notifications
     where dedupe_key = 'invoice_short_paid:' || p_invoice::text;
  end if;

  return v_id;
end $$;

comment on function public.record_invoice_query is
  'Records one exchange about an invoice: who was asked, when, what they said. '
  'Marked as resolved, it stops the short-paid chase; it never stops the chase '
  'on money still owed.';

revoke all on function public.record_invoice_query(uuid, text, text, boolean, date) from public, anon, authenticated;
grant execute on function public.record_invoice_query(uuid, text, text, boolean, date) to authenticated;

-- ── the chase stops asking what it has been told ─────────────
--
-- Replaced from 0309 with one branch changed: a short-paid invoice whose
-- query has been settled is left alone. Everything else - thirty days, then
-- forty-five, counted from the day the invoice was sent - is as it was.
create or replace function public.chase_invoices(p_today date default null)
returns table(staff_name text, email text, message text, task_id uuid)
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_day      date := coalesce(p_today, public.practice_today());
  v_intake   uuid;
  v_owner    uuid;
  r          record;
begin
  select intake_staff_id into v_intake from public.org_settings limit 1;
  select id into v_owner from public.staff
   where role = 'Admin' and active and not is_system order by created_at limit 1;

  for r in
    select i.id, i.number, i.amount, i.amount_paid, i.status, i.client_id, i.submitted_on,
           (v_day - i.submitted_on) as days,
           coalesce(nullif(a.number, ''), a.service_type) as about,
           coalesce(b.name, nullif(i.sent_to, ''), 'USOR') as office,
           exists (select 1 from public.invoice_queries q
                    where q.invoice_id = i.id and q.resolved) as settled
      from public.invoices i
      left join public.authorizations a on a.id = i.auth_id
      left join public.billing_offices b on b.id = i.office_id
     where i.status in ('Submitted', 'Short-paid')
       and i.submitted_on is not null
     order by i.submitted_on, i.number
  loop
    -- ── short-paid, which is an answer rather than a silence ──
    --
    -- And an answer that has been queried and settled is not raised again.
    -- The money is not back, and that is deliberate: the shortfall was asked
    -- about and somebody wrote down what came of it, which is the whole point
    -- of the note.
    if r.status = 'Short-paid' then
      if v_intake is not null and not r.settled then
        return query
          select n.staff_name, n.email, n.message, n.task_id from public.notify_person(
            v_intake, 'invoice_short_paid',
            format('Invoice %s to %s was paid $%s of $%s - $%s short. %s.',
                   r.number, r.office,
                   to_char(coalesce(r.amount_paid, 0), 'FM999999.00'),
                   to_char(coalesce(r.amount, 0), 'FM999999.00'),
                   to_char(coalesce(r.amount, 0) - coalesce(r.amount_paid, 0), 'FM999999.00'),
                   r.about),
            r.id::text, '/billing/invoices?invoice=' || r.id::text, r.client_id,
            format('Invoice %s short by $%s', r.number,
                   to_char(coalesce(r.amount, 0) - coalesce(r.amount_paid, 0), 'FM999999.00')),
            v_day, 'bad', r.id) n;
      end if;
      continue;
    end if;

    -- ── thirty days, then forty-five ─────────────────────────
    if r.days >= 30 and v_intake is not null then
      return query
        select n.staff_name, n.email, n.message, n.task_id from public.notify_person(
          v_intake, 'invoice_unpaid',
          format('Invoice %s to %s has been unpaid %s days - $%s for %s, sent %s.',
                 r.number, r.office, r.days,
                 to_char(coalesce(r.amount, 0), 'FM999999.00'), r.about,
                 to_char(r.submitted_on, 'FMDD FMMonth')),
          r.id::text, '/billing/invoices?invoice=' || r.id::text, r.client_id,
          format('Chase %s for invoice %s, $%s', r.office, r.number,
                 to_char(coalesce(r.amount, 0), 'FM999999.00')),
          v_day, 'warn', r.id) n;
    end if;

    if r.days >= 45 and v_owner is not null then
      return query
        select n.staff_name, n.email, n.message, n.task_id from public.notify_person(
          v_owner, 'invoice_unpaid_45',
          format('Invoice %s to %s is %s days unpaid - $%s for %s. The intake desk has had it since day thirty.',
                 r.number, r.office, r.days,
                 to_char(coalesce(r.amount, 0), 'FM999999.00'), r.about),
          r.id::text, '/billing/invoices?invoice=' || r.id::text, r.client_id,
          format('%s has not paid invoice %s in %s days', r.office, r.number, r.days),
          v_day, 'bad', r.id) n;
    end if;
  end loop;
end $$;

revoke execute on function public.chase_invoices(date) from anon, authenticated;

commit;
