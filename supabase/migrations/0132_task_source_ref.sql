-- Zion Vocational Rehab CRM — what a task points back at
--
-- A task could name what raised it (source_kind) and point at it
-- (source_match_id), and that column is a foreign key to lead_matches -
-- because when it was added, every automatic task came from a job
-- application. Two do not any more: the billing follow-up points at an item,
-- and the unanswered text points at a conversation.
--
-- Pointing either of those at source_match_id is not a near miss, it is a
-- different table, and the database said so. So they get a column that means
-- what they need: source_ref, the thing named by source_kind. It carries no
-- foreign key of its own precisely because it points at different tables -
-- which is the honest shape for "whatever raised this" and the reason it is
-- separate from the job-application link rather than replacing it.
--
-- Nothing is migrated: neither function had ever managed to raise a task.

alter table public.tasks
  add column if not exists source_ref uuid;

comment on column public.tasks.source_ref is
  'What raised this task, where that is not a job application (0132): a billing item, a conversation. Read with source_kind, which says which.';

create index if not exists tasks_source_ref_idx on public.tasks (source_kind, source_ref) where source_ref is not null;

-- ── the billing follow-up, pointing at the item ────────────
create or replace function public.billing_followups_on(p_today date)
returns integer language plpgsql security definer set search_path = public as $$
declare r record; v_made integer := 0;
begin
  for r in
    select i.id, i.client_id, i.service, i.period, i.assigned_staff_id, c.name as client_name,
           i.submitted_at::date as sent_on
      from public.billing_items i
      join public.clients c on c.id = i.client_id
     where i.status in ('Submitted', 'Pending')
       and i.submitted_at is not null
       and coalesce(i.followup_due, i.submitted_at::date + 14) <= p_today
  loop
    if not exists (
      select 1 from public.tasks t
       where t.source_kind = 'billing_item' and t.source_ref = r.id and t.status = 'Open'
    ) then
      insert into public.tasks (client_id, assigned_staff_id, title, due, status, system_generated, source_kind, source_ref)
      values (r.client_id,
              r.assigned_staff_id,
              'No answer yet on ' || r.service || coalesce(' for ' || to_char(r.period, 'FMMonth'), '')
                || ' - sent ' || to_char(r.sent_on, 'FMDD Mon') || '. Chase it.',
              p_today,
              'Open', true, 'billing_item', r.id);
      v_made := v_made + 1;
    end if;
    update public.billing_items set followup_due = p_today + 14 where id = r.id;
  end loop;
  return v_made;
end;
$$;
revoke execute on function public.billing_followups_on(date) from public, anon, authenticated;
grant execute on function public.billing_followups_on(date) to service_role;

-- ── the unanswered text, pointing at the conversation ──────
create or replace function public.escalate_unanswered_texts(p_today date)
returns integer language plpgsql security definer set search_path = public as $$
declare r record; v_made integer := 0;
begin
  for r in select * from public.texts_unanswered where business_days >= 2 loop
    if r.owed_by is not null and not exists (
      select 1 from public.tasks t
       where t.source_kind = 'text_unanswered' and t.source_ref = r.conversation_id and t.status = 'Open'
    ) then
      insert into public.tasks (client_id, assigned_staff_id, title, due, status, system_generated, source_kind, source_ref)
      values (r.client_id, r.owed_by,
              r.client_name || ' texted ' || r.business_days || ' business days ago and has had no answer',
              p_today, 'Open', true, 'text_unanswered', r.conversation_id);
      v_made := v_made + 1;
    end if;

    if r.business_days >= 5 and not exists (
      select 1 from public.notifications n
       where n.kind = 'text_unanswered' and n.client_id = r.client_id and n.resolved_at is null
    ) then
      -- Every alert carries the key that stops it being raised twice; this
      -- one is per client, because a client waiting on two conversations is
      -- one situation, not two alerts.
      insert into public.notifications (dedupe_key, kind, level, text, roles, href, client_id)
      values ('text_unanswered:' || r.client_id, 'text_unanswered', 'bad',
              r.client_name || ' has been waiting ' || r.business_days || ' business days for an answer to a text',
              array['Admin'],
              '/clients/' || r.client_id || '?tab=messages',
              r.client_id);
      v_made := v_made + 1;
    end if;
  end loop;

  update public.notifications n
     set resolved_at = now()
   where n.kind = 'text_unanswered' and n.resolved_at is null
     and not exists (select 1 from public.texts_unanswered u where u.client_id = n.client_id and u.business_days >= 5);

  update public.tasks t
     set status = 'Done', done_at = now()
   where t.source_kind = 'text_unanswered' and t.status = 'Open'
     and not exists (select 1 from public.texts_unanswered u where u.conversation_id = t.source_ref);

  return v_made;
end;
$$;
revoke execute on function public.escalate_unanswered_texts(date) from public, anon, authenticated;
grant execute on function public.escalate_unanswered_texts(date) to service_role;
