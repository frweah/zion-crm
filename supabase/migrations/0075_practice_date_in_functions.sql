-- ─────────────────────────────────────────────────────────────
-- 0075 — the practice's date in the six other places that used the server's
--
-- The same fault as 0074, smaller in each place. current_date is the database
-- server's date, UTC; between six in the evening and midnight in Utah it is
-- already tomorrow. So, in those hours:
--
--   a task marked done, an onboarding item ticked, e-delivery consent given
--   and an invoice sent were all stamped with tomorrow's date, and
--
--   the checks refusing service hours and 1099 deliveries "in the future"
--   let tomorrow's date through.
--
-- Each function below is its live pg_get_functiondef output from 2026-09-13
-- with every current_date replaced by public.practice_today() and nothing
-- else changed. CREATE OR REPLACE keeps each one's grants and the triggers
-- that call the two trigger functions.
--
-- Left alone on purpose: the client_next_up and staff_capacity views compare
-- timestamps against now(), which has no timezone problem - an instant is the
-- same instant in Utah.
-- ─────────────────────────────────────────────────────────────

-- ── answer_reminder(uuid,text,text): the day a task was marked done ──
CREATE OR REPLACE FUNCTION public.answer_reminder(p_task_id uuid, p_status text, p_outcome text DEFAULT ''::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_match uuid;
begin
  if public.current_staff_id() is null then
    raise exception 'You are not signed in.' using errcode = 'insufficient_privilege';
  end if;

  select source_match_id into v_match from public.tasks where id = p_task_id;
  if v_match is null then
    raise exception 'That task did not come from a job.' using errcode = 'check_violation';
  end if;

  if p_status is not null and p_status <> '' then
    update public.lead_matches
       set status  = p_status,
           outcome = case when coalesce(p_outcome, '') = '' then outcome else p_outcome end
     where id = v_match;

    -- Hired or Not selected is the end of this job. Whatever was still booked
    -- for it is not going to happen, and leaving it booked is how a calendar
    -- stops being believed.
    if p_status in ('Hired', 'Not selected') then
      update public.lead_matches
         set interview_on = null, follow_up_on = null
       where id = v_match
         and (interview_on is not null or follow_up_on is not null);
    end if;
  elsif coalesce(p_outcome, '') <> '' then
    update public.lead_matches set outcome = p_outcome where id = v_match;
  end if;

  update public.tasks
     set status = 'Done', done_at = public.practice_today()
   where id = p_task_id;
end;
$function$;

-- ── check_entry_hours(): refusing service hours dated in the future ──
CREATE OR REPLACE FUNCTION public.check_entry_hours()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  a          public.authorizations%rowtype;
  used_hours numeric;
begin
  if new.date > public.practice_today() then
    raise exception 'Service hours cannot be logged for % — that date has not happened yet.',
      new.date using errcode = 'check_violation';
  end if;

  if new.non_billable then
    return new;
  end if;

  select * into a from public.authorizations where id = new.auth_id;
  if a.total_hours is null then
    return new;                                   -- flat-fee authorization, no hour cap
  end if;

  select a.carried_used + coalesce(sum(e.hours), 0)
    into used_hours
    from public.service_entries e
   where e.auth_id = new.auth_id
     and e.non_billable = false
     and e.id is distinct from new.id;

  if used_hours + new.hours > a.total_hours then
    raise exception
      'Entry of % hrs exceeds the hours left on % (% authorized, % used). Request additional hours from the counselor first.',
      new.hours, coalesce(nullif(a.number, ''), a.service_type), a.total_hours, used_hours
      using errcode = 'check_violation';
  end if;

  return new;
end;
$function$;

-- ── check_invoice_forms(): the sent date an invoice gets when none is given ──
CREATE OR REPLACE FUNCTION public.check_invoice_forms()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  a       public.authorizations%rowtype;
  missing text;
begin
  if new.status <> 'Sent' then
    return new;
  end if;
  if tg_op = 'UPDATE' and old.status = 'Sent' then
    return new;
  end if;

  select * into a from public.authorizations where id = new.auth_id;

  select string_agg(t.usor, ' + ' order by t.sort_order)
    into missing
    from public.form_templates t
   where t.required_for_billing
     and a.service_type = any (t.services)
     and not exists (
       select 1 from public.forms f
        where f.auth_id = new.auth_id
          and f.template_id = t.id
          and f.status <> 'Draft'
     );

  if missing is not null then
    raise exception 'Invoice cannot be sent: % still outstanding for %.',
      missing, coalesce(nullif(a.number, ''), a.service_type)
      using errcode = 'check_violation';
  end if;

  new.sent_date := coalesce(new.sent_date, public.practice_today());
  return new;
end;
$function$;

-- ── record_1099_delivery(uuid,text,date): refusing a 1099 delivery dated in the future ──
CREATE OR REPLACE FUNCTION public.record_1099_delivery(p_recipient_id uuid, p_method text, p_delivered_on date)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  r record;
begin
  if not public.is_admin() then
    raise exception 'Only Admin can record delivery.' using errcode = 'insufficient_privilege';
  end if;

  select * into r from public.form_1099_recipients where id = p_recipient_id;
  if r is null then
    raise exception 'No such recipient.' using errcode = 'check_violation';
  end if;

  if p_method not in ('Secure download', 'Email', 'Post', 'In person') then
    raise exception 'Unknown delivery method.' using errcode = 'check_violation';
  end if;

  if p_method in ('Secure download', 'Email') and not r.consent_recorded then
    raise exception
      '% has not agreed to receive their 1099 electronically. Post it, or ask them to agree first.',
      r.legal_name using errcode = 'check_violation';
  end if;

  if p_delivered_on > public.practice_today() then
    raise exception 'A copy cannot be delivered in the future.' using errcode = 'check_violation';
  end if;

  update public.form_1099_recipients
     set delivered_on = p_delivered_on, delivery_method = p_method
   where id = p_recipient_id;
end;
$function$;

-- ── set_checklist_item(uuid,uuid,boolean,text): the day an onboarding item was ticked ──
CREATE OR REPLACE FUNCTION public.set_checklist_item(p_staff_id uuid, p_task_id uuid, p_done boolean, p_note text DEFAULT ''::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not public.is_admin() then
    raise exception 'Only Admin can tick these off.' using errcode = 'insufficient_privilege';
  end if;

  insert into public.staff_checklist_items (staff_id, task_id, done_on, done_by, note)
  values (p_staff_id, p_task_id,
          case when p_done then public.practice_today() end,
          case when p_done then public.current_staff_id() end,
          coalesce(p_note, ''))
  on conflict (staff_id, task_id) do update set
    done_on = excluded.done_on,
    done_by = excluded.done_by,
    note    = excluded.note;
end;
$function$;

-- ── set_e_delivery_consent(boolean): the day e-delivery consent was given ──
CREATE OR REPLACE FUNCTION public.set_e_delivery_consent(p_consent boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_staff uuid := public.current_staff_id();
begin
  if v_staff is null then
    raise exception 'You are not signed in.' using errcode = 'insufficient_privilege';
  end if;

  insert into public.contractor_profiles (staff_id, e_delivery_consent_on)
  values (v_staff, case when p_consent then public.practice_today() end)
  on conflict (staff_id) do update
    set e_delivery_consent_on = case when p_consent then public.practice_today() end;
end;
$function$;
