-- Zion Vocational Rehab CRM — a date has to be one somebody meant
-- (stress test, finding 8, owner 16 Oct 2026)
--
-- Date validation across the app was `/^\d{4}-\d{2}-\d{2}$/`, which accepts
-- 0226-03-14 and 9999-12-31, and the schema had one range constraint in it:
-- staff_personal_dob. Authorization dates had none at all.
--
-- A slipped keystroke in the year therefore lands, and what it does depends
-- on which way it slipped:
--
--   Backwards - 2026 typed as 0226 - puts stale_date centuries past, so
--   authorization_attention reports the authorization blocked or expired for
--   ever and raises an alert that doing the work cannot clear.
--
--   Forwards - 2062 - means bill_by never arrives, so the authorization
--   never falls Due, never reaches the working list, and is never billed.
--   Nothing complains, which makes it the expensive one.
--
-- So a date has to be inside a window that a real one is: not before 1990,
-- and not more than five years ahead. Five years is far past any
-- authorization anybody writes and far short of a typed year.
--
-- In the database rather than in TypeScript, because the rule has to hold
-- however the row arrives - the intake cron reads dates off a PDF, the
-- filename rules read them off a file name, and neither goes through a form.
-- That is the lesson 0203 applied to document categories.
--
-- A trigger rather than a CHECK: the window moves with today, and a CHECK
-- cannot call current_date. 0001 learned the same thing about logging hours
-- in the future.
--
-- Only on the way in. A date already on file that is outside the window is
-- left alone unless somebody writes to it, so this refuses new mistakes
-- without making old rows unsaveable. Nothing on file is outside it today.

create or replace function public.dates_are_real()
returns trigger language plpgsql set search_path = public as $$
declare
  v_lo  date := date '1990-01-01';
  v_hi  date := (public.practice_today() + interval '5 years')::date;
  r     record;
begin
  for r in
    select * from (values
      ('The start date',     new.start_date,   case when tg_op = 'UPDATE' then old.start_date   end),
      ('The end date',       new.end_date,     case when tg_op = 'UPDATE' then old.end_date     end),
      ('The date received',  new.received_on,  case when tg_op = 'UPDATE' then old.received_on  end),
      ('The bill-by date',   new.bill_by,      case when tg_op = 'UPDATE' then old.bill_by      end),
      ('The end date',       new.stale_date,   case when tg_op = 'UPDATE' then old.stale_date   end),
      ('The date submitted', new.submitted_on, case when tg_op = 'UPDATE' then old.submitted_on end),
      ('The date paid',      new.paid_on,      case when tg_op = 'UPDATE' then old.paid_on      end),
      ('The follow-up date', new.followup_due, case when tg_op = 'UPDATE' then old.followup_due end),
      ('The month',          new.period,       case when tg_op = 'UPDATE' then old.period       end)
    ) as x(label, val, was)
  loop
    if r.val is not null
       and (r.val < v_lo or r.val > v_hi)
       and (tg_op = 'INSERT' or r.was is distinct from r.val) then
      raise exception '% is %. A date here is between % and % - check the year.',
        r.label, r.val, v_lo, v_hi using errcode = 'check_violation';
    end if;
  end loop;
  return new;
end;
$$;

drop trigger if exists authorizations_dates_are_real on public.authorizations;
create trigger authorizations_dates_are_real
  before insert or update on public.authorizations
  for each row execute function public.dates_are_real();

/**
 * The date on a document, which is the date on the paper rather than the day
 * it was uploaded (0202). The same window, and the same reason: a scan filed
 * under the year 0225 sorts to the top of a client's record for ever.
 */
create or replace function public.document_date_is_real()
returns trigger language plpgsql set search_path = public as $$
declare
  v_lo date := date '1990-01-01';
  v_hi date := (public.practice_today() + interval '5 years')::date;
begin
  if new.document_date is not null
     and (new.document_date < v_lo or new.document_date > v_hi)
     and (tg_op = 'INSERT' or old.document_date is distinct from new.document_date) then
    raise exception 'The date on the document is %. A date here is between % and % - check the year.',
      new.document_date, v_lo, v_hi using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

drop trigger if exists attachments_document_date_is_real on public.attachments;
create trigger attachments_document_date_is_real
  before insert or update on public.attachments
  for each row execute function public.document_date_is_real();

/**
 * And hours. The future was already refused (0001); the far past was not, so
 * an entry typed as 0226 would sit on a client's record and in every total
 * that reads by date.
 */
create or replace function public.entry_date_is_real()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.date < date '1990-01-01' then
    raise exception 'Service hours cannot be logged for % - check the year.', new.date
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

drop trigger if exists service_entries_date_is_real on public.service_entries;
create trigger service_entries_date_is_real
  before insert or update on public.service_entries
  for each row execute function public.entry_date_is_real();

do $$
declare v_n integer;
begin
  select count(*) into v_n from pg_trigger
   where tgname in ('authorizations_dates_are_real', 'attachments_document_date_is_real',
                    'service_entries_date_is_real');
  if v_n <> 3 then
    raise exception 'Expected three date triggers, found %.', v_n;
  end if;
  raise notice 'ok  a date on an authorization, a document or an hour has to be one somebody meant';
end $$;
