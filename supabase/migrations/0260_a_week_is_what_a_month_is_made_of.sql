-- Zion Vocational Rehab CRM — 0260 a week is what a month is made of
--
-- The report a counselor is owed is one document per client per calendar
-- month, a section per active service (Monthly Reports Brief, 26 Oct 2026).
-- The owner's amendment, two days later: build the week first and let the
-- month be made of weeks.
--
-- That is a better shape than a month assembled from nothing on the 1st, and
-- the reason has nothing to do with code. A month read off the record four
-- weeks after it happened is read by somebody who no longer remembers it, so
-- the reading is whatever the record says and the gaps are invisible. A week
-- read on the Monday after is read by the person who was there. They know
-- that Tuesday's appointment did happen and was logged as a no-show, and they
-- fix it while fixing it is still cheap. By the 1st the month is four
-- confirmations rather than one act of recall, which is also why the month
-- can be honest about what it does not have: it knows which weeks somebody
-- looked at and which nobody did.
--
-- So two tables, and the second reads the first.
--
--   `client_weekly_reports`  one per client per week. Generated Monday from
--                            the record, confirmed by the person who did the
--                            work. Draft or Confirmed, and that is all.
--   `client_monthly_reports` one per client per month, assembled from those
--                            weeks. Draft, Reviewed, Signed, Sent, and the
--                            order is enforced here rather than hoped for on
--                            a screen.
--
-- **Where the words come from.** Both hold `content` as structured sections
-- with dated lines rather than finished prose, because a month made of weeks
-- has to be able to take the lines dated inside it and leave the rest. A week
-- straddling two months then belongs to both, each taking its own days, and
-- nothing is double-counted or dropped at the boundary.
--
-- **Who may read one.** This is the part worth slowing down for. The existing
-- progress report (lib/report.ts) pastes note text into an activity log and is
-- safe because it runs as the person: row-level security has already removed
-- the notes they may not read. These are generated on a timer by the service
-- role, which no policy applies to, so a report could carry a note's words to
-- somebody the note itself refuses - every active staff member, if the read
-- policy said `is_active_staff()`.
--
-- So a report carries `visible_roles` the way a note does, and it is the
-- intersection of the notes whose words are in it. A report is exactly as
-- visible as the most closely held thing inside it, using the rule the
-- practice already has rather than a second one invented here. The owner is
-- added to that by name: ordinary notes do not include Job Coach or Case
-- Manager (notes.visible_roles defaults to four of the six roles), and a
-- report about a client that their own assigned worker cannot open would be a
-- rule protecting nobody from anything.

-- ── the week ──────────────────────────────────────────────────

create table if not exists public.client_weekly_reports (
  id            uuid primary key default gen_random_uuid(),
  client_id     uuid not null references public.clients(id) on delete cascade,

  -- The Monday. A week is Monday to Sunday in the practice's own zone, which
  -- is the week the staff day already runs on.
  week_start    date not null,

  -- Whose week it is: the client's assigned worker when the draft was made.
  -- Nullable, because a client with nobody assigned still gets a report - it
  -- then appears on the list with no owner, which is a thing somebody can
  -- see and fix.
  owner_id      uuid references public.staff(id) on delete set null,

  status        text not null default 'Draft',

  -- `{ sections: [{ service, code, lines: [{ on, kind, text }] }], withheld }`
  -- Sections in service order, lines in date order, and nothing in here that
  -- is not in the record.
  content       jsonb not null default '{}'::jsonb,

  -- The staff member's own words for the week. The one part of a report that
  -- was not read off the record, and the part a counselor actually reads.
  note          text not null default '',

  visible_roles text[] not null default array['Admin', 'Job Search', 'Reports', 'Billing'],

  due_on        date not null,
  generated_at  timestamptz not null default now(),
  confirmed_at  timestamptz,
  confirmed_by  uuid references public.staff(id) on delete set null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),

  unique (client_id, week_start),

  constraint client_weekly_reports_monday
    check (extract(isodow from week_start) = 1),
  constraint client_weekly_reports_status
    check (status in ('Draft', 'Confirmed')),
  -- Confirmed means somebody put their name to it, so the two arrive together
  -- or neither does.
  constraint client_weekly_reports_confirmed
    check ((status = 'Confirmed') = (confirmed_at is not null)),
  constraint client_weekly_reports_confirmed_by
    check ((confirmed_at is null) = (confirmed_by is null)),
  constraint client_weekly_reports_content
    check (jsonb_typeof(content) = 'object'),
  constraint client_weekly_reports_roles
    check (array_length(visible_roles, 1) > 0)
);

comment on table public.client_weekly_reports is
  'One report per client per week, generated from the record on Monday and confirmed by the person who did the work. The month is made of these (0260).';

create index if not exists client_weekly_reports_mine
  on public.client_weekly_reports (owner_id, status, week_start desc);
create index if not exists client_weekly_reports_by_client
  on public.client_weekly_reports (client_id, week_start desc);
create index if not exists client_weekly_reports_by_week
  on public.client_weekly_reports (week_start desc, status);

-- ── the month ─────────────────────────────────────────────────

create table if not exists public.client_monthly_reports (
  id            uuid primary key default gen_random_uuid(),
  client_id     uuid not null references public.clients(id) on delete cascade,

  -- The first of the month being reported on.
  month         date not null,
  owner_id      uuid references public.staff(id) on delete set null,

  status        text not null default 'Draft',

  -- The same shape as a week's, plus what it was built from: which weeks were
  -- confirmed, which were still drafts, and which days no week covered. That
  -- last list is why the month can say "no activity recorded" about a gap
  -- instead of being silent about it.
  content       jsonb not null default '{}'::jsonb,
  note          text not null default '',
  visible_roles text[] not null default array['Admin', 'Job Search', 'Reports', 'Billing'],

  -- The 5th of the month after the one reported on.
  due_on        date not null,
  generated_at  timestamptz not null default now(),

  reviewed_at   timestamptz,
  reviewed_by   uuid references public.staff(id) on delete set null,
  signed_at     timestamptz,
  signed_by     uuid references public.staff(id) on delete set null,
  sent_at       timestamptz,
  sent_by       uuid references public.staff(id) on delete set null,
  sent_to       text not null default '',

  -- The PDF that was signed, and the thing the counselor was sent. It stays
  -- on the client's record as an attachment in its own right, so reopening a
  -- month does not take away the version that went out.
  pdf_attachment_id uuid references public.attachments(id) on delete set null,

  reopened_at   timestamptz,
  reopened_by   uuid references public.staff(id) on delete set null,
  reopen_reason text not null default '',

  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),

  unique (client_id, month),

  constraint client_monthly_reports_first_of_month
    check (extract(day from month) = 1),
  constraint client_monthly_reports_status
    check (status in ('Draft', 'Reviewed', 'Signed', 'Sent')),
  -- A signature is what makes it signed. Nothing here can be Signed or Sent
  -- without one, which is half of "drafts are never sent unsigned" - the
  -- other half is the trigger below, which stops Sent arriving from Draft.
  constraint client_monthly_reports_signed
    check ((status in ('Signed', 'Sent')) = (signed_at is not null)),
  constraint client_monthly_reports_signed_by
    check ((signed_at is null) = (signed_by is null)),
  constraint client_monthly_reports_sent
    check ((status = 'Sent') = (sent_at is not null)),
  -- Sent means a named address got a PDF. A row saying it was sent with
  -- neither of those is a row that cannot be answered for.
  constraint client_monthly_reports_sent_to
    check (status <> 'Sent' or btrim(sent_to) <> ''),
  constraint client_monthly_reports_sent_pdf
    check (status <> 'Sent' or pdf_attachment_id is not null),
  constraint client_monthly_reports_content
    check (jsonb_typeof(content) = 'object'),
  constraint client_monthly_reports_roles
    check (array_length(visible_roles, 1) > 0)
);

comment on table public.client_monthly_reports is
  'One report per client per calendar month, assembled from that month''s weekly reports, signed and sent to the counselor on record (0260).';

create index if not exists client_monthly_reports_mine
  on public.client_monthly_reports (owner_id, status, month desc);
create index if not exists client_monthly_reports_by_client
  on public.client_monthly_reports (client_id, month desc);
create index if not exists client_monthly_reports_by_month
  on public.client_monthly_reports (month desc, status);
create index if not exists client_monthly_reports_overdue
  on public.client_monthly_reports (due_on)
  where status <> 'Sent';

-- ── what a month is due ───────────────────────────────────────

create or replace function public.monthly_report_due_on(p_month date)
returns date
language sql
immutable
as $$
  -- The 5th of the month after the one reported on: October's report is
  -- generated on 1 November and due on the 5th.
  select (date_trunc('month', p_month::timestamp) + interval '1 month' + interval '4 days')::date;
$$;

comment on function public.monthly_report_due_on(date) is
  'The 5th of the month after the one reported on (0260).';

revoke all on function public.monthly_report_due_on(date) from public, anon, authenticated;
grant execute on function public.monthly_report_due_on(date) to authenticated;

-- ── a signed month holds its weeks still ──────────────────────
--
-- Once a month has been signed, the weeks it was assembled from are the
-- record of what was signed. Editing one afterwards would leave the practice
-- holding a PDF that its own weeks no longer add up to, which is worse than
-- either version alone. So the week says no, and names the way round it:
-- reopen the month, which is an act somebody has to give a reason for.

create or replace function public.weekly_report_is_frozen(p_client uuid, p_week date)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select exists (
    select 1
      from public.client_monthly_reports m
     where m.client_id = p_client
       and m.status in ('Signed', 'Sent')
       -- The week overlaps the month: it starts before the month ends and
       -- ends on or after the month starts.
       and m.month <= p_week + 6
       and (date_trunc('month', m.month::timestamp) + interval '1 month')::date > p_week
  );
$$;

comment on function public.weekly_report_is_frozen(uuid, date) is
  'Whether a week overlaps a month this client has already had signed (0260).';

-- Not granted to anybody signed in, and the reason is the rule
-- `supabase/verify_portal_rls.sql` enforces: an elevated function that takes
-- a client id and answers a question about them has to check who is asking,
-- or it has to be unreachable. This one is unreachable. Its only caller is
-- the trigger below, which is itself security definer and so calls it with
-- the owner's rights whoever set it off. A screen wanting to say a week is
-- frozen reads the month's status, which row-level security already governs.
revoke all on function public.weekly_report_is_frozen(uuid, date) from public, anon, authenticated;

create or replace function public.weekly_report_stays_put()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if public.weekly_report_is_frozen(old.client_id, old.week_start) then
    raise exception 'That week is part of a signed monthly report — reopen the month to change it.'
      using errcode = 'check_violation';
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

drop trigger if exists weekly_report_stays_put on public.client_weekly_reports;
create trigger weekly_report_stays_put
  before update or delete on public.client_weekly_reports
  for each row execute function public.weekly_report_stays_put();

-- ── and a month moves one way ─────────────────────────────────
--
-- Draft, Reviewed, Signed, Sent. Sending needs a signature, a signed report
-- that turns out to be wrong is reopened rather than quietly rewritten, and
-- a report that has gone is finished - the record of what the counselor was
-- told does not change after they were told it.

create or replace function public.monthly_report_moves_forward()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if new.status = old.status then
    -- Not a status change, but the same two rules still hold: a sent report
    -- is done, and a signed one is reopened rather than edited.
    if old.status = 'Sent' then
      raise exception 'That report has been sent, so it cannot be changed.'
        using errcode = 'check_violation';
    end if;
    if old.status = 'Signed'
       and (new.content is distinct from old.content or new.note is distinct from old.note) then
      raise exception 'That report is signed — reopen it before changing what it says.'
        using errcode = 'check_violation';
    end if;
    return new;
  end if;

  if old.status = 'Sent' then
    raise exception 'That report has been sent, so its status cannot change.'
      using errcode = 'check_violation';
  end if;

  if new.status = 'Sent' and old.status <> 'Signed' then
    raise exception 'Sign the report before sending it.'
      using errcode = 'check_violation';
  end if;

  if new.status = 'Signed' and old.status not in ('Draft', 'Reviewed') then
    raise exception 'A report is signed from the draft or the review, not from %.', old.status
      using errcode = 'check_violation';
  end if;

  -- Going back is reopening, and reopening says why. "Say why it is being
  -- reopened" is the house wording for exactly this, and the reason is kept
  -- with the row rather than left in somebody's memory of the conversation.
  if old.status = 'Signed' and new.status in ('Draft', 'Reviewed') then
    if btrim(coalesce(new.reopen_reason, '')) = '' then
      raise exception 'Say why the signed report is being reopened.'
        using errcode = 'check_violation';
    end if;
    new.reopened_at := now();
    new.reopened_by := coalesce(new.reopened_by, public.current_staff_id());
  end if;

  return new;
end;
$$;

drop trigger if exists monthly_report_moves_forward on public.client_monthly_reports;
create trigger monthly_report_moves_forward
  before update on public.client_monthly_reports
  for each row execute function public.monthly_report_moves_forward();

-- ── keeping updated_at honest ─────────────────────────────────

drop trigger if exists client_weekly_reports_touch on public.client_weekly_reports;
create trigger client_weekly_reports_touch
  before update on public.client_weekly_reports
  for each row execute function public.set_updated_at();

drop trigger if exists client_monthly_reports_touch on public.client_monthly_reports;
create trigger client_monthly_reports_touch
  before update on public.client_monthly_reports
  for each row execute function public.set_updated_at();

-- ── who may read one, and who may change it ───────────────────

alter table public.client_weekly_reports enable row level security;
alter table public.client_monthly_reports enable row level security;

-- As visible as the most closely held note inside it, plus the person whose
-- client it is. See the note at the top of this file for why both halves are
-- needed rather than either alone.
drop policy if exists client_weekly_reports_read on public.client_weekly_reports;
create policy client_weekly_reports_read on public.client_weekly_reports
  for select using (
    (select public.is_admin())
    or (
      (select public.is_active_staff())
      and (
        owner_id = (select public.current_staff_id())
        or (select public.current_staff_role()) = any (visible_roles)
      )
    )
  );

drop policy if exists client_monthly_reports_read on public.client_monthly_reports;
create policy client_monthly_reports_read on public.client_monthly_reports
  for select using (
    (select public.is_admin())
    or (
      (select public.is_active_staff())
      and (
        owner_id = (select public.current_staff_id())
        or (select public.current_staff_role()) = any (visible_roles)
      )
    )
  );

-- A report is edited by the person whose client it is, or by Admin. Nobody
-- inserts one by hand: the drafts are made by the scheduler, which runs as the
-- service role, and a report that exists because somebody typed it is a report
-- not built from the record.
drop policy if exists client_weekly_reports_update on public.client_weekly_reports;
create policy client_weekly_reports_update on public.client_weekly_reports
  for update using (
    (select public.is_admin())
    or ((select public.is_active_staff()) and owner_id = (select public.current_staff_id()))
  ) with check (
    (select public.is_admin())
    or ((select public.is_active_staff()) and owner_id = (select public.current_staff_id()))
  );

drop policy if exists client_monthly_reports_update on public.client_monthly_reports;
create policy client_monthly_reports_update on public.client_monthly_reports
  for update using (
    (select public.is_admin())
    or ((select public.is_active_staff()) and owner_id = (select public.current_staff_id()))
  ) with check (
    (select public.is_admin())
    or ((select public.is_active_staff()) and owner_id = (select public.current_staff_id()))
  );

-- Deleting one is Admin's, and only while it is a draft. A signed or sent
-- report is what the practice told somebody, and that is not deletable.
drop policy if exists client_weekly_reports_delete on public.client_weekly_reports;
create policy client_weekly_reports_delete on public.client_weekly_reports
  for delete using ((select public.is_admin()) and status = 'Draft');

drop policy if exists client_monthly_reports_delete on public.client_monthly_reports;
create policy client_monthly_reports_delete on public.client_monthly_reports
  for delete using ((select public.is_admin()) and status = 'Draft');

select public.apply_system_read_only('public.client_weekly_reports'::regclass);
select public.apply_system_read_only('public.client_monthly_reports'::regclass);

-- Supabase's default privileges would hand `authenticated` INSERT, TRUNCATE,
-- REFERENCES and TRIGGER here along with the rest, and 0257 and 0259 are the
-- record of what that costs when nobody asks. Asked here: read, change and
-- delete are governed by the policies above, and inserting is not a thing
-- anybody signed in does.
revoke all on table public.client_weekly_reports from anon, authenticated;
revoke all on table public.client_monthly_reports from anon, authenticated;
grant select, update, delete on table public.client_weekly_reports to authenticated;
grant select, update, delete on table public.client_monthly_reports to authenticated;
