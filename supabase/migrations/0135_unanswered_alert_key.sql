-- Zion Vocational Rehab CRM — one alert per episode of waiting, not one per
-- client for ever
--
-- The alert for a client waiting five business days used the client as its
-- whole dedupe key (0130). An alert's key is unique across the whole table
-- for all time, resolved or not - so the second time a client waited, the
-- insert hit the unique constraint and the nightly job fell over. It would
-- have happened the first time anybody was answered late twice.
--
-- The key now names the episode as well: the client, and the day their
-- unanswered message arrived. A client who waits, is answered, and later
-- waits again raises a new alert, which is the right behaviour; the same
-- episode raises one, which was the point of the key.
--
-- And the insert says what to do on a collision rather than failing, because
-- an alert nobody can raise is worse than an alert raised twice, and this
-- runs where nobody is watching.

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
      insert into public.notifications (dedupe_key, kind, level, text, roles, href, client_id)
      values ('text_unanswered:' || r.client_id || ':' || to_char(r.waiting_since, 'YYYY-MM-DD'),
              'text_unanswered', 'bad',
              r.client_name || ' has been waiting ' || r.business_days || ' business days for an answer to a text',
              array['Admin'],
              '/clients/' || r.client_id || '?tab=messages',
              r.client_id)
      on conflict (dedupe_key) do nothing;
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
