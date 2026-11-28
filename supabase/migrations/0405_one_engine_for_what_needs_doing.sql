-- One engine for what needs doing.
--
-- Tolerates the old code: nothing deployed calls next_steps yet, and
-- clients_board_rows keeps every column it already returned - the four new
-- ones are additions. The removals are 0406, after the code that reads these
-- is live.
--
-- ─────────────────────────────────────────────────────────────
--
-- Six things answered "what needs doing" before this, and none of them asked
-- another. Measured on 27 November 2026, over twenty active clients:
--
--   * eleven clients had an open task, every one of them overdue. The Clients
--     board named it in its Next step column. The client's own record never
--     mentions tasks at all, and for four of those eleven the record said
--     "Nothing is due for this client".
--   * twenty-five overdue tasks on active clients. The bell raised each one.
--     client_next_up excludes anything overdue, so My day showed none of them.
--   * three clients quiet for a fortnight. The threads board said three,
--     Home's "Inactive clients" tile said none, because one counts fourteen
--     days and the other thirty.
--   * "Follow-ups due" meant contact_log.follow_up in the nightly alerts and
--     lead_matches.follow_up_on on Home. Two columns, two tables, one name.
--   * an authorization ending soon was one rule on the board and the bell
--     (authorization_attention) and a second, differently worded rule on the
--     record.
--   * whose work something is had four answers, and severity had four scales.
--
-- The owner's ruling (27 November 2026): one engine, it returns the union,
-- the board's single cell shows the highest-severity item, the record lists
-- all of them, and no consumer suppresses a kind to keep its screen looking
-- the way it looked. A screen changing is the bug becoming visible.
--
-- ── What this does not re-implement ─────────────────────────
--
-- Four rules already existed in one place each, and this delegates rather
-- than restating them. That is the whole point of the exercise; a seventh
-- definition written inside the function meant to end them would be the
-- joke writing itself.
--
--   authorization_attention_for  the authorization sentence, which the board
--                                and the bell already shared
--   client_paperwork             what counts as a form missing
--   client_threads_board         a reply, quiet 14+ days, consent missing -
--                                the rule CLAUDE.md names, with the ruling
--                                that a reply is a reply on any channel
--   client_next_up               the next appointment, which knows that an
--                                appointment withdrawn from Outlook is not one
--
-- client_threads_board computes the whole practice on every call and this
-- calls it once per question, including for a single client. At twenty active
-- clients that is cheaper than the four separate round trips the record page
-- made before. If the practice grows into it, the answer is an index or a
-- materialised board, not a second quiet rule.
--
-- Known gap, recorded rather than worked around: client_next_up is
-- `distinct on (client_id)`, so it holds each client's soonest item of any
-- kind. An appointment sitting behind a sooner task is therefore not listed
-- as its own line. The task is listed, so nothing disappears from a screen,
-- and the owner settled the appointment source. Fixing the view changes My
-- day, the phone home screen and the counselor record, none of which is in
-- this brief.
--
-- ── Severity ────────────────────────────────────────────────
--
-- One scale, 1 to 4, replacing four:
--
--   1  overdue, today, or stopping the work
--   2  this week, or holding up billing
--   3  dated and further off
--   4  undated
--
-- authorization_attention's 0-10 is mapped onto it rather than passed
-- through, so a screen comparing two kinds compares like with like.

begin;

create or replace function public.next_steps(
  p_scope text,
  p_person uuid,
  p_client uuid
)
 returns table (
   client_id uuid,
   "when" timestamptz,
   what text,
   who text,
   kind text,
   action_href text,
   severity integer
 )
 language sql
 stable
 security definer
 set search_path to 'public'
as $function$
  select * from (
    with day as (select public.practice_today() as today),
    /*
     * Whose work this question is about.
     *
     * Four scopes and no else-branch that means "everybody": an unknown word
     * returns nothing, because a scope nobody recognised answering with the
     * whole practice is how a Job Coach ends up reading Billing's list.
     *
     *   client  one record's strip
     *   person  the clients one member of staff is on, by either assignment -
     *           job search or billing, which is how tasks already work
     *   board   every active client, for the Clients board
     *   owner   the same, for the practice-wide view and the nightly alerts
     */
    scope_clients as (
      select c.id, c.name,
             coalesce(sa.name, sb.name) as owner_name,
             sb.name as billing_name,
             sa.name as search_name
        from public.clients c
        left join public.staff sa on sa.id = c.assigned_staff_id
        left join public.staff sb on sb.id = c.billing_staff_id
       where c.merged_into is null
         and case p_scope
               when 'client' then p_client is not null and c.id = p_client
               when 'person' then p_person is not null
                                  and c.status = 'Active'
                                  and (c.assigned_staff_id = p_person
                                       or c.billing_staff_id = p_person)
               when 'board' then c.status = 'Active'
               when 'owner' then c.status = 'Active'
               else false
             end
    ),
    threads as (
      select t.client_id,
             max(t.waiting_hours) as waiting_hours,
             min(t.quiet_days) as quiet_days,
             bool_or(coalesce(t.consent_missing, false)) as consent_missing
        from public.client_threads_board() t
        join scope_clients s on s.id = t.client_id
       group by t.client_id
    ),
    live_auths as (
      select a.id, a.client_id, coalesce(nullif(a.number, ''), a.service_type) as label
        from public.authorizations a
        join scope_clients s on s.id = a.client_id
       where a.status in ('Authorized', 'Due', 'Submitted')
         and not a.is_placeholder
    )

    -- They spoke last and nobody has answered, on any channel.
    select s.id, now(), 'Unanswered - they spoke ' || t.waiting_hours || ' hours ago',
           s.owner_name, 'reply',
           '/clients/' || s.id || '?tab=messages', 1
      from scope_clients s
      join threads t on t.client_id = s.id
     where t.waiting_hours is not null

    union all
    -- An open task. The board used to show the next one whatever its date,
    -- the bell only an overdue one, and Home one due today or earlier. One
    -- rule now, and the date decides how loud it is rather than whether it
    -- exists at all.
    select s.id,
           (k.due::timestamp at time zone 'America/Denver'),
           case when k.due is null then 'Task: ' || k.title
                when k.due < (select today from day) then 'Overdue task: ' || k.title
                else 'Task: ' || k.title end,
           coalesce(ts.name, s.owner_name), 'task',
           '/clients/' || s.id || '?tab=dashboard',
           case
             when k.due is null then 4
             when k.due <= (select today from day) then 1
             when k.due <= (select today from day) + 7 then 2
             else 3
           end
      from scope_clients s
      join public.tasks k on k.client_id = s.id and k.status = 'Open'
      left join public.staff ts on ts.id = k.assigned_staff_id
     where p_scope <> 'person' or k.assigned_staff_id is null or k.assigned_staff_id = p_person

    union all
    -- A task on nobody's client, which only the practice-wide view can see.
    select null::uuid,
           (k.due::timestamp at time zone 'America/Denver'),
           case when k.due is not null and k.due < (select today from day)
                  then 'Overdue task: ' || k.title else 'Task: ' || k.title end,
           ts.name, 'task', '/tasks',
           case
             when k.due is null then 4
             when k.due <= (select today from day) then 1
             when k.due <= (select today from day) + 7 then 2
             else 3
           end
      from public.tasks k
      left join public.staff ts on ts.id = k.assigned_staff_id
     where k.status = 'Open' and k.client_id is null
       and (p_scope = 'owner'
            or (p_scope = 'person' and k.assigned_staff_id = p_person))

    union all
    -- The authorization sentence, as the board and the bell already said it.
    select s.id, null::timestamptz,
           a.label || ' - ' || t.attention,
           s.billing_name, 'authorization',
           '/billing/authorizations/' || a.id,
           case
             when t.urgency <= 1 then 1
             when t.urgency <= 3 then 2
             when t.urgency <= 6 then 3
             else 4
           end
      from scope_clients s
      join live_auths a on a.client_id = s.id
      join public.authorization_attention_for(
             array(select id from live_auths), (select today from day)) t on t.auth_id = a.id
     where coalesce(t.attention, '') <> ''

    union all
    -- A form that is holding up billing.
    select s.id, null::timestamptz,
           p.usor || ' needed - ' || p.form_name
             || coalesce(' for ' || p.month, '')
             || ' - ' || trim(to_char(p.hours_logged, 'FM999990.9')) || ' hours logged',
           s.billing_name, 'form',
           '/billing/report?client=' || s.id, 2
      from scope_clients s
      join public.client_paperwork p on p.client_id = s.id
     where p.state = 'Missing'

    union all
    -- The next appointment.
    select s.id, n.at,
           'Appointment - ' || n.title, s.owner_name, 'appointment',
           '/clients/' || s.id || '?tab=dashboard',
           case when n.at < now() + interval '24 hours' then 1 else 3 end
      from scope_clients s
      join public.client_next_up n on n.client_id = s.id and n.kind = 'Appointment'

    union all
    -- A counselor follow-up the practice said it would do.
    select s.id, (g.follow_up::timestamp at time zone 'America/Denver'),
           'Counselor follow-up due: ' || coalesce(nullif(g.topic, ''), 'no topic recorded'),
           coalesce(gs.name, s.owner_name), 'followup',
           '/clients/' || s.id || '?tab=notes', 1
      from scope_clients s
      join public.contact_log g on g.client_id = s.id
      left join public.staff gs on gs.id = g.staff_id
     where g.follow_up is not null and not g.follow_up_done
       and g.follow_up <= (select today from day)

    union all
    -- An interview this week.
    select s.id, (m.interview_on::timestamp at time zone 'America/Denver'),
           'Interview - ' || coalesce(e.name, l.title, 'a job'),
           s.search_name, 'interview',
           '/clients/' || s.id || '?tab=jobs', 2
      from scope_clients s
      join public.lead_matches m on m.client_id = s.id
      join public.job_leads l on l.id = m.lead_id
      left join public.employers e on e.id = l.employer_id
     where m.interview_on between (select today from day) and (select today from day) + 7

    union all
    -- Five shifts kept: the placement may be billed, on USOR 92.
    select s.id, null::timestamptz,
           'Fifth shift reached - '
             || coalesce(nullif(pl.employer, ''), 'the placement')
             || ' - USOR 92 and the placement bill are due',
           s.billing_name, 'placement',
           '/billing/report?client=' || s.id, 2
      from scope_clients s
      join public.placements pl on pl.client_id = s.id
     where pl.fifth_shift_on is not null
       and not exists (
         select 1 from public.forms f
          join public.authorizations a on a.id = f.auth_id
         where f.client_id = s.id and f.template_id = 'usor92'
           and f.status <> 'Draft' and a.service_type like 'Job Placement%')

    union all
    -- Thirty days of stability: the High Quality Indicators may be billed.
    select s.id, null::timestamptz,
           'Thirty days of stability - '
             || coalesce(nullif(pl.employer, ''), 'the placement')
             || coalesce(' - ' || nullif(pl.stability_basis, ''), '')
             || ' - High Quality Indicators may be billed',
           s.billing_name, 'stability',
           '/clients/' || s.id || '?tab=billing', 2
      from scope_clients s
      join public.placements pl on pl.client_id = s.id
     where pl.stability_on is not null
       and pl.stability_on + 30 <= (select today from day)
       and not exists (
         select 1 from public.authorizations a
         where a.client_id = s.id
           and a.service_type like '%HQ Indicator%'
           and a.status in ('Submitted', 'Paid'))

    union all
    -- A retention check that has come due.
    select s.id, ((pl.start_date + d.days)::timestamp at time zone 'America/Denver'),
           d.label || ' check due - ' || coalesce(nullif(pl.employer, ''), 'a placement'),
           s.search_name, 'retention',
           '/clients/' || s.id || '?tab=jobs', 2
      from scope_clients s
      join public.placements pl on pl.client_id = s.id
      cross join lateral (values
        (pl.check30, 30, '30 day'), (pl.check60, 60, '60 day'), (pl.check90, 90, '90 day')
      ) d(done, days, label)
     where pl.start_date is not null and d.done is null
       and pl.start_date + d.days <= (select today from day)

    union all
    -- Nobody has recorded whether they agreed to be texted.
    select s.id, null::timestamptz,
           'Texting consent not recorded - they cannot be texted until it is',
           s.owner_name, 'consent',
           '/clients/' || s.id || '?tab=profile#texting', 3
      from scope_clients s
      join threads t on t.client_id = s.id
     where t.consent_missing

    union all
    -- Nobody has reached them in a fortnight, on any channel.
    select s.id, null::timestamptz,
           case when t.quiet_days is null then 'Nothing recorded with them at all'
                else 'Quiet ' || t.quiet_days || ' days' end,
           s.owner_name, 'quiet',
           '/clients/' || s.id || '?tab=dashboard', 3
      from scope_clients s
      join threads t on t.client_id = s.id
     where t.quiet_days is null or t.quiet_days >= 14
  ) as rows_for_staff
   where public.reader_may_answer();
$function$;

comment on function public.next_steps(text, uuid, uuid) is
  'What needs doing, for one client, one person, the board or the practice. '
  'The only answer: every screen reads this one and none computes its own.';

revoke all on function public.next_steps(text, uuid, uuid) from public;
revoke all on function public.next_steps(text, uuid, uuid) from anon;
grant execute on function public.next_steps(text, uuid, uuid) to authenticated;

commit;
