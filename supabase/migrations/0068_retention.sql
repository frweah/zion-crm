-- ─────────────────────────────────────────────────────────────
-- 10.3 — how long records are kept
--
-- Two questions an auditor asks that the CRM currently cannot answer: how
-- long do you keep a client's file, and how do you know you have not
-- destroyed something you were required to keep. This answers both, and
-- deliberately does not answer a third one — it destroys nothing.
--
-- That restraint is the whole design. A schedule that deletes on a timer is
-- the most dangerous thing that could be added to this system: the mistake is
-- silent, unrecoverable, and discovered years later by somebody asking for a
-- record. So this migration creates no job, no trigger and no cascade. What
-- it creates is knowledge — a written schedule, a list of what has passed it,
-- and a record of every decision taken.
--
-- Three safety rules, each enforced rather than described:
--
--   Nothing is due under a policy nobody has confirmed. Every period seeded
--   below is the practice's starting assumption, marked unconfirmed, and an
--   unconfirmed policy never makes a single record due. The numbers came from
--   the commonly cited rules; they are not legal advice and USOR and the
--   practice's accountant have not seen them.
--
--   A legal hold outranks the schedule absolutely. Not "warns" — a client
--   under hold is not due, cannot be disposed of, and says why.
--
--   Every disposal is recorded, and the record cannot be edited or deleted.
--   A retention schedule with a deletable audit trail proves nothing.
-- ─────────────────────────────────────────────────────────────

create table if not exists public.retention_policies (
  key          text primary key,
  label        text not null,
  -- What it covers, in the words somebody would use to ask about it.
  what         text not null,

  keep_years   numeric(4,1) not null check (keep_years > 0),

  clock_starts text not null check (clock_starts in (
                 'Case closed', 'Record created', 'Last activity',
                 'End of the tax year', 'Employment ended', 'Never destroyed')),

  -- Why this number. An empty one is a number somebody typed.
  authority    text not null default '',

  -- Has a person actually checked this against the rule it cites? Until they
  -- have, nothing under this policy is ever reported as due. This is the
  -- single most important column in the migration.
  confirmed    boolean not null default false,
  confirmed_by uuid references public.staff(id) on delete set null,
  confirmed_at timestamptz,

  active       boolean not null default true,
  sort_order   integer not null default 100,
  updated_by   uuid references public.staff(id) on delete set null,
  updated_at   timestamptz not null default now()
);

alter table public.retention_policies enable row level security;

drop policy if exists retention_policies_read on public.retention_policies;
drop policy if exists retention_policies_write on public.retention_policies;

-- The schedule is not a secret; it is the sort of thing a counselor should be
-- able to look up when a client asks how long their file is kept.
create policy retention_policies_read on public.retention_policies
  for select to authenticated using (public.is_active_staff());

create policy retention_policies_write on public.retention_policies
  for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

drop trigger if exists retention_policies_updated_at on public.retention_policies;
create trigger retention_policies_updated_at before update on public.retention_policies
  for each row execute function public.set_updated_at();

-- ─────────────────────────────────────────────────────────────
-- The starting schedule
--
-- Every row is unconfirmed. The periods below are what the commonly cited
-- rules say, written down so there is something concrete to check rather than
-- a blank page — not so they can be relied on. Nothing becomes due until
-- somebody opens each one, checks it against the rule named in `authority`,
-- and confirms it.
-- ─────────────────────────────────────────────────────────────
insert into public.retention_policies
  (key, label, what, keep_years, clock_starts, authority, sort_order) values

  ('client-record', 'Client case record',
   'Everything on a client: notes, stage history, jobs, placements, forms, files and the restricted details.',
   5, 'Case closed',
   'Federal grant records run three years from the final expenditure report (2 CFR 200.334). USOR and Utah records rules may require longer, and five is the common practice figure. CHECK WITH USOR BEFORE ANYTHING IS DESTROYED.',
   10),

  ('invoices', 'Invoices, authorizations and warrants',
   'What was authorized, what was billed, and what USOR paid.',
   7, 'End of the tax year',
   'Financial records supporting a filed return. Seven years is the usual advice for supporting documents; the practice''s accountant should say.',
   20),

  ('tax-forms', 'Signed tax forms',
   'W-4s, W-9s, W-8BENs and issued 1099s.',
   4, 'End of the tax year',
   'IRS employment tax records: four years after the tax is due or paid, whichever is later (IRC §6001, Pub 15).',
   30),

  ('staff-file', 'Staff and contractor files',
   'Personnel records, credentials, pay rates and offboarding.',
   3, 'Employment ended',
   'FLSA payroll records run three years. I-9s follow their own rule (three years from hire or one year from termination, whichever is later) and are not held in this system.',
   40),

  ('sms-consent', 'Texting consent',
   'Who agreed to be texted, when, and every withdrawal.',
   5, 'Last activity',
   'Proof of consent is the defence to a TCPA claim, and the limitation period is four years. Kept five so the proof outlives the claim.',
   50),

  ('access-log', 'The read-access log',
   'Who opened a client''s restricted details, an intake, a tax number or a filed tax form.',
   5, 'Never destroyed',
   'The log is the proof that the records were handled properly, so it outlives what it describes. It is append-only in the database and nothing can delete an entry, including this schedule.',
   60)

on conflict (key) do nothing;

-- ─────────────────────────────────────────────────────────────
-- Legal holds
--
-- A dispute, an audit, a records request, an open complaint. While a hold
-- stands, that client's record is not due for anything, whatever the schedule
-- says — destroying records that are under hold is the one retention mistake
-- that turns a paperwork problem into a legal one.
--
-- Lifted, not deleted, and the reason survives both ways.
-- ─────────────────────────────────────────────────────────────
create table if not exists public.legal_holds (
  id            uuid primary key default gen_random_uuid(),
  client_id     uuid not null references public.clients(id) on delete cascade,
  reason        text not null check (btrim(reason) <> ''),
  placed_by     uuid references public.staff(id) on delete set null,
  placed_by_name text not null default '',
  placed_at     timestamptz not null default now(),
  lifted_by     uuid references public.staff(id) on delete set null,
  lifted_by_name text not null default '',
  lifted_at     timestamptz,
  lifted_reason text not null default ''
);

create index if not exists legal_holds_client_idx
  on public.legal_holds (client_id) where lifted_at is null;

alter table public.legal_holds enable row level security;

drop policy if exists legal_holds_read on public.legal_holds;
drop policy if exists legal_holds_write on public.legal_holds;

create policy legal_holds_read on public.legal_holds
  for select to authenticated using (public.is_active_staff());

-- Placing and lifting are both Admin. No delete policy: a hold that was
-- placed happened, and lifting it is the way to end it.
create policy legal_holds_write on public.legal_holds
  for insert to authenticated with check (public.is_admin());

drop policy if exists legal_holds_lift on public.legal_holds;
create policy legal_holds_lift on public.legal_holds
  for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- ─────────────────────────────────────────────────────────────
-- What was decided, and by whom
--
-- Append-only, like the access log. A retention schedule whose record of
-- disposals can be edited proves nothing at all.
--
-- Note what this table is not: it is not a deletion. Recording a disposal
-- says a person decided and acted; the acting itself is deliberately a
-- separate, explicit step that this migration does not automate.
-- ─────────────────────────────────────────────────────────────
create table if not exists public.retention_dispositions (
  id           bigserial primary key,
  client_id    uuid references public.clients(id) on delete set null,
  client_name  text not null default '',
  policy_key   text not null default 'client-record',

  action       text not null check (action in ('Destroyed', 'Kept longer', 'Reviewed — no change')),
  reason       text not null check (btrim(reason) <> ''),

  decided_by   uuid references public.staff(id) on delete set null,
  -- Kept beside the id: whoever authorised a destruction must still be
  -- nameable after they have left and their row is gone.
  decided_by_name text not null default '',
  disposed_at  timestamptz not null default now()
);

create index if not exists retention_dispositions_client_idx
  on public.retention_dispositions (client_id, disposed_at desc);

alter table public.retention_dispositions enable row level security;

drop policy if exists retention_dispositions_read on public.retention_dispositions;
drop policy if exists retention_dispositions_write on public.retention_dispositions;

create policy retention_dispositions_read on public.retention_dispositions
  for select to authenticated using (public.is_active_staff());

create policy retention_dispositions_write on public.retention_dispositions
  for insert to authenticated with check (public.is_admin());

-- No update policy and no delete policy, on purpose.

-- ─────────────────────────────────────────────────────────────
-- What has passed its period
--
-- One row per closed client. Open clients are not here at all — a record in
-- use is not a retention question, and listing them would bury the ones that
-- are.
--
-- `due` is the only column anybody should act on, and it is false unless
-- every one of the safety conditions holds.
-- ─────────────────────────────────────────────────────────────
create or replace view public.client_retention as
with closed as (
  select c.id,
         c.name,
         c.client_no,
         c.status,
         c.stage,
         -- When the case closed. The stage history is the truthful answer;
         -- clients imported from the workbook may have no such entry, and for
         -- those the clock has not demonstrably started, so it is null and
         -- they are never due. A guessed closure date is a guessed
         -- destruction date.
         (select max(h.at) from public.client_stage_history h
           where h.client_id = c.id and h.stage = 'Closed') as closed_on
    from public.clients c
   where c.status = 'Closed' or c.stage = 'Closed'
),
policy as (
  select keep_years, confirmed from public.retention_policies
   where key = 'client-record' and active
)
select cl.id                       as client_id,
       cl.name,
       cl.client_no,
       cl.status,
       cl.stage,
       cl.closed_on,
       (select keep_years from policy)                        as keep_years,
       (select confirmed  from policy)                        as policy_confirmed,
       case when cl.closed_on is not null
            then (cl.closed_on + ((select keep_years from policy) * 12)::int * interval '1 month')::date
       end                                                    as keep_until,
       h.id                        as hold_id,
       h.reason                    as hold_reason,
       (h.id is not null)          as on_hold,

       -- Due means: the case closed on a known date, the period has passed,
       -- somebody has confirmed the period is right, and no hold stands. Any
       -- one of those failing makes it not due, and the columns above say
       -- which.
       (cl.closed_on is not null
        and (select confirmed from policy)
        and h.id is null
        and (cl.closed_on + ((select keep_years from policy) * 12)::int * interval '1 month')::date
            <= public.practice_today())                       as due,

       d.disposed_at,
       d.action                    as disposed_action
  from closed cl
  left join lateral (
    select id, reason from public.legal_holds
     where client_id = cl.id and lifted_at is null
     order by placed_at desc limit 1
  ) h on true
  left join lateral (
    select disposed_at, action from public.retention_dispositions
     where client_id = cl.id order by disposed_at desc limit 1
  ) d on true;

alter view public.client_retention set (security_invoker = true);
grant select on public.client_retention to authenticated;

comment on view public.client_retention is
  'Closed client records against the retention schedule. "due" is false unless the closure date is known, the period has passed, the policy is confirmed, and no legal hold stands.';

-- ─────────────────────────────────────────────────────────────
-- Recording a decision
--
-- Definer, so the refusals are the database''s and not a screen''s. It writes
-- one row and changes nothing else — in particular it deletes nothing.
-- ─────────────────────────────────────────────────────────────
create or replace function public.record_disposition(
  p_client uuid,
  p_action text,
  p_reason text
) returns bigint
language plpgsql security definer set search_path = public as $$
declare
  v_id     bigint;
  v_staff  uuid := public.current_staff_id();
  v_name   text;
  v_client text;
  v_due    boolean;
  v_hold   text;
begin
  if not public.is_admin() then
    raise exception 'Only Admin records a retention decision.'
      using errcode = 'insufficient_privilege';
  end if;

  select name into v_name from public.staff where id = v_staff;
  select name into v_client from public.clients where id = p_client;
  if v_client is null then
    raise exception 'That client does not exist.' using errcode = 'no_data_found';
  end if;

  select due, hold_reason into v_due, v_hold
    from public.client_retention where client_id = p_client;

  -- A hold is absolute. Recording a destruction against a held record is the
  -- exact thing a hold exists to prevent, so it is refused here rather than
  -- discouraged on a screen.
  if p_action = 'Destroyed' and v_hold is not null then
    raise exception 'That record is under legal hold: %', v_hold
      using errcode = 'check_violation';
  end if;

  if p_action = 'Destroyed' and not coalesce(v_due, false) then
    raise exception 'That record is not past its retention period, or the period has not been confirmed.'
      using errcode = 'check_violation';
  end if;

  insert into public.retention_dispositions
    (client_id, client_name, action, reason, decided_by, decided_by_name)
  values (p_client, coalesce(v_client, ''), p_action, p_reason, v_staff, coalesce(v_name, ''))
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.record_disposition(uuid, text, text) from public;
grant execute on function public.record_disposition(uuid, text, text) to authenticated;

comment on function public.record_disposition(uuid, text, text) is
  'Records what was decided about a record that has passed its retention period. Refuses a destruction under legal hold or before the period has passed. Deletes nothing itself.';
