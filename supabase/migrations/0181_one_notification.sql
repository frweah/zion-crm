-- Zion Vocational Rehab CRM — one notification, three places
--
-- "One function builds all three (CRM notification, email, My day item) from
-- one message. Never three copies of the text." (Intake Automation Brief.)
--
-- The three places already existed and none of them knew about the others:
--
--   The CRM notification is a row in `notifications`, which the bell reads.
--   Until now every one of them was addressed to a *role* and written by
--   generate_notifications() from a rule. Addressing one to a person is what
--   `staff_id` is for, and nothing used it.
--
--   The My day item is a task. That is not a simplification - My day reads
--   `tasks` for the person, open, due today or earlier. So "raise the intake
--   task for Margaret" and "put an item on her My day" are the same sentence,
--   which is what Rule 5 says: "The intake task and this item are the same
--   item, not two."
--
--   The email is sent by whoever calls this, from the text it returns. It is
--   not sent from here because the database has no mail connection - but the
--   words are written once, here, and handed over. A caller that invents its
--   own wording is a caller that will drift.
--
-- So: one call, one text, and the recipient's address returned so the mail can
-- carry exactly what the bell and My day are showing.

-- The intake raises tasks, and a task says where it came from.
alter table public.tasks drop constraint if exists tasks_source_kind_check;
alter table public.tasks add constraint tasks_source_kind_check check (
  source_kind = any (array[
    'Interview prep', 'Interview day', 'Follow-up', 'billing_item', 'text_unanswered',
    -- Raised by the intake rules (Intake Automation Brief).
    'intake', 'authorization_received', 'authorization_missing', 'authorization_ending',
    'placement_authorization'
  ])
);

-- An earlier shape of this took no p_source and would be left behind as a
-- second overload, which makes every unqualified reference to the name
-- ambiguous. Dropped by its exact signature so nothing else is touched.
drop function if exists public.notify_person(uuid, text, text, text, text, uuid, text, date, text);

/**
 * Tell one person one thing, in all three places.
 *
 * Returns the address to email and the text to send, or no row when there was
 * nothing to do - which is how the caller knows not to send a second email for
 * a document that arrived twice.
 *
 * Idempotent on `p_ref`: the same reference and kind is one notification and
 * one task however many times this is called. That matters because the mailbox
 * is polled, and a poll that overlaps the last one must not notify twice.
 */
create or replace function public.notify_person(
  p_staff      uuid,
  p_kind       text,
  p_text       text,
  p_ref        text,
  p_href       text default null,
  p_client     uuid default null,
  p_task_title text default null,
  p_due        date default null,
  p_level      text default 'warn',
  -- What the task came from, which is a record and so a uuid. Separate from
  -- p_ref, which is the notification's key and is text because one document
  -- can be the reason for two different notifications to two people.
  p_source     uuid default null
)
returns table (staff_name text, email text, message text, task_id uuid, already boolean)
language plpgsql security definer set search_path = public as $$
declare
  st       public.staff;
  v_key    text := p_kind || ':' || p_ref;
  v_task   uuid;
  v_fresh  boolean := false;
begin
  select * into st from public.staff where id = p_staff and active;
  if not found then
    raise exception 'There is nobody active to notify (%).', p_staff
      using errcode = 'no_data_found';
  end if;
  if coalesce(btrim(p_text), '') = '' then
    raise exception 'A notification with no words in it says nothing.'
      using errcode = 'check_violation';
  end if;

  -- ── the bell ───────────────────────────────────────────────
  insert into public.notifications (dedupe_key, kind, level, text, roles, href, client_id, staff_id)
  values (v_key, p_kind, p_level, p_text, array[st.role], p_href, p_client, p_staff)
  on conflict (dedupe_key) do nothing;
  if found then
    v_fresh := true;
  end if;

  -- ── My day ─────────────────────────────────────────────────
  -- The same item, not a second one: looked for by where it came from before
  -- it is raised, so a re-send does not leave Margaret two identical lines.
  -- Keyed on the assignee as well as the source, because one document can
  -- raise an item for two people - a placement authorization is Margaret's to
  -- confirm and Rei's to act on - and those are two items, not a collision.
  if coalesce(btrim(p_task_title), '') <> '' then
    select id into v_task from public.tasks
     where source_kind = p_kind
       and source_ref is not distinct from p_source
       and assigned_staff_id = p_staff
       and status = 'Open';
    if v_task is null then
      insert into public.tasks
        (title, client_id, assigned_staff_id, due, status, system_generated, source_kind, source_ref)
      values (p_task_title, p_client, p_staff, coalesce(p_due, public.practice_today()),
              'Open', true, p_kind, p_source)
      returning id into v_task;
      v_fresh := true;
    end if;
  end if;

  -- ── and the words for the email ────────────────────────────
  -- Returned rather than sent: the words are written once, here. Nothing is
  -- returned when neither the bell nor My day had anything new, so a second
  -- poll over the same document sends no second email.
  if not v_fresh then
    return;
  end if;
  return query select st.name, st.email, p_text, v_task, false;
end;
$$;

comment on function public.notify_person(uuid, text, text, text, text, uuid, text, date, text, uuid) is
  'Tell one person one thing in all three places - the bell, My day, and the words for the email. Idempotent on its reference, so a repeated poll notifies once.';

revoke all on function public.notify_person(uuid, text, text, text, text, uuid, text, date, text, uuid)
  from anon, authenticated;

-- The bell shows a notification addressed to a person, to that person.
--
-- Until now every row was addressed to a role and the policy asked only about
-- roles, so Margaret's own intake notification would have been shown to
-- everybody who shares her role and to nobody else in particular. A row with
-- a staff_id is that person's.
do $$
declare v_qual text;
begin
  select qual into v_qual from pg_policies
   where schemaname = 'public' and tablename = 'notifications' and policyname = 'notifications_read';
  if v_qual is null then
    raise notice 'notifications_read is not there; the policy is left alone';
  elsif v_qual like '%staff_id%' then
    raise notice 'the policy already accounts for a notification addressed to a person';
  else
    execute 'drop policy notifications_read on public.notifications';
    execute format($f$
      create policy notifications_read on public.notifications
        for select using (
          (staff_id is null and (%s))
          or staff_id = (select public.current_staff_id())
        )
    $f$, v_qual);
    raise notice 'the policy now shows a person their own notifications, and role rows as before';
  end if;
end $$;
