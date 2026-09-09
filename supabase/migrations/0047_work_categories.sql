-- ─────────────────────────────────────────────────────────────
-- 0047 — what the hours were spent on
--
-- A work session records how long somebody worked and a sentence about it.
-- That is enough to pay them and not enough to answer the question the owner
-- actually has: of what we pay for, how much reaches a client?
--
-- Free text cannot answer it. "Drove to Tooele and did a follow-up" is one
-- session covering two categories, and nobody is going to read four hundred
-- of those. So a session carries a category as well as its sentence.
--
-- The categories are data, not code: the practice will find its own splits,
-- and adding one should not need a deploy.
-- ─────────────────────────────────────────────────────────────
create table if not exists public.work_categories (
  key         text primary key,
  label       text not null,
  detail      text not null default '',
  -- Whether this kind of time is normally billable to USOR. Not a rule about
  -- what may be invoiced — that is the authorization's business — but the
  -- expectation, so a capacity view can say what share of paid time is meant
  -- to reach a client at all.
  billable    boolean not null default false,
  sort_order  integer not null default 100,
  active      boolean not null default true
);

alter table public.work_categories enable row level security;

drop policy if exists work_categories_read on public.work_categories;
drop policy if exists work_categories_write on public.work_categories;

create policy work_categories_read on public.work_categories
  for select to authenticated using (public.is_active_staff());
create policy work_categories_write on public.work_categories
  for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

insert into public.work_categories (key, label, detail, billable, sort_order) values
  ('direct',        'Direct client service',
   'Coaching, placement work, assessment — time with the client or on their job site.', true, 10),
  ('employer',      'Employer development',
   'Finding and keeping employers: cold calls, site visits, negotiating a placement.', true, 20),
  ('documentation', 'Notes and USOR forms',
   'Writing it up: case notes, USOR forms, progress reports, invoicing paperwork.', true, 30),
  ('travel',        'Travel',
   'Driving to a client, a job site or an employer.', false, 40),
  ('meetings',      'Meetings and supervision',
   'Staff meetings, supervision, case conferences.', false, 50),
  ('training',      'Training',
   'Courses, certification, learning the system.', false, 60),
  ('admin',         'Admin',
   'Scheduling, email, filing, anything that is not any of the above.', false, 70),
  ('other',         'Other',
   'Say what it was in the description.', false, 999)
on conflict (key) do update set
  label = excluded.label, detail = excluded.detail,
  billable = excluded.billable, sort_order = excluded.sort_order;

-- ─────────────────────────────────────────────────────────────
-- The column
--
-- Nullable, because 0047 does not get to invent a category for work that was
-- logged before anybody was asked. Those sessions read as "not categorised"
-- and the screens say how many there are rather than guessing.
-- ─────────────────────────────────────────────────────────────
alter table public.work_sessions
  add column if not exists category text references public.work_categories(key);

create index if not exists work_sessions_category_idx
  on public.work_sessions (category) where category is not null;

-- ─────────────────────────────────────────────────────────────
-- Append-only, with one door left open
--
-- A category is a claim about the work, so it is as immutable as the hours.
-- But a session logged before this existed has no category at all, and
-- refusing to let anybody fill that in would leave the record permanently
-- unanswerable for no gain. So: blank may become a value. A value may never
-- become a different value — that needs a correction, like everything else
-- here.
-- ─────────────────────────────────────────────────────────────
create or replace function public.work_sessions_append_only()
returns trigger language plpgsql as $$
begin
  if new.staff_id      is distinct from old.staff_id
  or new.worked_on     is distinct from old.worked_on
  or new.hours         is distinct from old.hours
  or new.description   is distinct from old.description
  or new.client_id     is distinct from old.client_id
  or new.corrects_id   is distinct from old.corrects_id
  or new.created_by    is distinct from old.created_by then
    raise exception
      'A time record cannot be edited. Add a correction referencing this entry and say why.'
      using errcode = 'check_violation';
  end if;

  if old.category is not null and new.category is distinct from old.category then
    raise exception
      'The category on a time record cannot be changed. Add a correction referencing this entry and say why.'
      using errcode = 'check_violation';
  end if;

  return new;
end;
$$;

-- ─────────────────────────────────────────────────────────────
-- The one update anybody may make
--
-- work_sessions has had no update policy since 0014 — deliberately, because
-- time records are evidence. That means the door the trigger leaves open is
-- not actually a door: row-level security would refuse the update before the
-- trigger ever saw it, silently, because an update that matches no rows is
-- not an error.
--
-- So the door needs cutting here too, and no wider than it has to be: your
-- own session, one that has no category yet, one that is not already on a
-- statement, and the result must have a category. Everything else the trigger
-- refuses.
-- ─────────────────────────────────────────────────────────────
drop policy if exists work_sessions_fill_category on public.work_sessions;
create policy work_sessions_fill_category on public.work_sessions
  for update to authenticated
  using (
    staff_id = public.current_staff_id()
    and category is null
    and statement_id is null
    and not voided
  )
  with check (
    staff_id = public.current_staff_id()
    and category is not null
  );

-- ─────────────────────────────────────────────────────────────
-- What each session is worth, now with what it was for
-- ─────────────────────────────────────────────────────────────
-- Dropped rather than replaced: the new columns land in the middle, and a
-- replace can only add them at the end.
drop view if exists public.work_session_values cascade;
create view public.work_session_values as
select w.id,
       w.staff_id,
       w.worked_on,
       w.hours,
       w.description,
       w.client_id,
       w.statement_id,
       w.category,
       c.label                                      as category_label,
       coalesce(c.billable, false)                  as category_billable,
       r.pay_rate,
       r.rate_unit,
       case when r.rate_unit = 'Hourly' then round(w.hours * r.pay_rate, 2) end as amount
  from public.work_sessions w
  left join public.work_categories c on c.key = w.category
  left join lateral public.pay_rate_on(w.staff_id, w.worked_on) r on true
 where not w.voided;

alter view public.work_session_values set (security_invoker = true);
grant select on public.work_session_values to authenticated;

-- ─────────────────────────────────────────────────────────────
-- Rebuilt, because the drop above took it with it
--
-- Unchanged from 0027. It reads work_session_values, so dropping that view
-- cascaded to this one — and a statement total is not something to leave
-- missing between two migrations.
-- ─────────────────────────────────────────────────────────────
create or replace view public.contractor_statement_totals as
select st.id                                   as statement_id,
       st.staff_id,
       st.period_start,
       st.period_end,
       st.status,
       st.adjustment,
       st.adjustment_note,
       coalesce(sum(v.hours), 0)               as hours,
       coalesce(sum(v.hours) filter (where v.amount is null), 0) as unpriced_hours,
       pr.rate_unit,
       pr.pay_rate                             as period_rate,
       -- What it comes to now, before any snapshot is considered.
       case
         when pr.rate_unit = 'Flat' then coalesce(pr.pay_rate, 0)
         else coalesce(sum(v.amount), 0)
       end + st.adjustment                     as computed_amount,
       st.approved_hours,
       st.approved_amount,
       -- What to show. An approved statement shows what it was approved with.
       coalesce(st.approved_hours, coalesce(sum(v.hours), 0))    as total_hours,
       coalesce(st.approved_amount,
                case
                  when pr.rate_unit = 'Flat' then coalesce(pr.pay_rate, 0)
                  else coalesce(sum(v.amount), 0)
                end + st.adjustment)                             as total_amount
  from public.contractor_statements st
  left join public.work_session_values v on v.statement_id = st.id
  left join lateral public.pay_rate_on(st.staff_id, st.period_end) pr on true
 group by st.id, st.staff_id, st.period_start, st.period_end, st.status,
          st.adjustment, st.adjustment_note, st.approved_hours, st.approved_amount,
          pr.rate_unit, pr.pay_rate;

alter view public.contractor_statement_totals set (security_invoker = true);
grant select on public.contractor_statement_totals to authenticated;

-- ─────────────────────────────────────────────────────────────
-- Hours by category, by person, by month
--
-- The roll-up both the Hours screen and the capacity view read, so the two
-- can never disagree about what a month contained.
-- ─────────────────────────────────────────────────────────────
create or replace view public.work_hours_by_category as
select v.staff_id,
       to_char(v.worked_on, 'YYYY-MM')              as month,
       coalesce(v.category, 'uncategorised')        as category,
       coalesce(v.category_label, 'Not categorised') as label,
       coalesce(v.category_billable, false)         as billable,
       sum(v.hours)                                 as hours,
       sum(v.amount)                                as amount,
       count(*)                                     as sessions
  from public.work_session_values v
 group by v.staff_id, to_char(v.worked_on, 'YYYY-MM'),
          v.category, v.category_label, v.category_billable;

alter view public.work_hours_by_category set (security_invoker = true);
grant select on public.work_hours_by_category to authenticated;

comment on view public.work_hours_by_category is
  'Hours and pay by staff member, month and category. Sessions with no category are grouped as uncategorised rather than dropped.';
