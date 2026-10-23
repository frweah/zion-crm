-- Zion Vocational Rehab CRM — 0238 three letters the practice keeps writing
--
-- An authorization request, a cover note on a progress report, and a chase on
-- a renewal. The practice writes all three several times a week, and writes
-- them slightly differently each time, which is how a counselor ends up with
-- two emails that ask the same question in two voices.
--
-- A template is not a form letter. It is the opening that nobody should have
-- to retype and the facts nobody should have to look up twice: the client,
-- their counselor, the authorization number, its dates and its service. The
-- merge happens here rather than in the screen so that the fields come from
-- one place and a name is spelt the way the record spells it.
--
-- Three rows, not an enum: Admin edits the words, and the practice may want a
-- fourth. The key is what the screen asks for and does not change.

create table if not exists public.mail_templates (
  key        text primary key,
  label      text not null,
  subject    text not null default '',
  body       text not null default '',
  sort_order integer not null default 100,
  active     boolean not null default true,
  updated_by uuid references public.staff(id) on delete set null,
  updated_at timestamptz not null default now()
);

comment on table public.mail_templates is
  'The letters the practice keeps writing, with merge fields. Admin edits them on Admin → Templates (0238).';

alter table public.mail_templates enable row level security;

drop policy if exists mail_templates_read on public.mail_templates;
create policy mail_templates_read on public.mail_templates
  for select using ((select public.is_active_staff()));

drop policy if exists mail_templates_admin_write on public.mail_templates;
create policy mail_templates_admin_write on public.mail_templates
  for all using ((select public.is_admin())) with check ((select public.is_admin()));

-- The system accounts smoke signs in as read and never write.
drop policy if exists system_read_only_insert on public.mail_templates;
create policy system_read_only_insert on public.mail_templates
  as restrictive for insert
  with check (not (select public.current_staff_is_system()));
drop policy if exists system_read_only_update on public.mail_templates;
create policy system_read_only_update on public.mail_templates
  as restrictive for update
  using (not (select public.current_staff_is_system()));
drop policy if exists system_read_only_delete on public.mail_templates;
create policy system_read_only_delete on public.mail_templates
  as restrictive for delete
  using (not (select public.current_staff_is_system()));

-- The three, seeded once. `on conflict do nothing`, because after the first
-- deploy the words belong to Admin and a migration that re-ran would take
-- their edits back.
insert into public.mail_templates (key, label, subject, body, sort_order) values
  ('authorization_request', 'Authorization request',
   'Authorization request — {client} {client_no}',
   E'{counselor},\n\nWe are asking for an authorization for {client} for {service}.\n\nThey are ready to start and we can begin the week it is issued. If there is anything else you need from us for it, say so and we will send it the same day.\n\n{me}\n{signature}',
   10),
  ('progress_report', 'Progress report cover note',
   'Progress report — {client} {client_no}',
   E'{counselor},\n\nThe progress report for {client} is attached, covering {authorization} from {issued} to {ends}.\n\nIt is a summary of the work and where they are. Anything in it you want to go through, say so and we will.\n\n{me}\n{signature}',
   20),
  ('renewal_chase', 'Renewal chase',
   'Renewal — {authorization} for {client}',
   E'{counselor},\n\n{authorization} for {client} ends on {ends} and the work is continuing.\n\nWe are asking for the renewal now so there is no gap. If it is already with you, say where it is and we will wait rather than ask again.\n\n{me}\n{signature}',
   30)
on conflict (key) do nothing;

-- ─────────────────────────────────────────────────────────────
-- What the practice signs with
-- ─────────────────────────────────────────────────────────────
alter table public.org_settings
  add column if not exists mail_signature text not null default '';

comment on column public.org_settings.mail_signature is
  'The lines under every message sent from the CRM. Admin edits it on Admin → Settings → Organization (0238).';

update public.org_settings
   set mail_signature = concat_ws(E'\n',
         nullif(employer_legal_name, ''),
         nullif(employer_address, ''))
 where mail_signature = '';

-- ─────────────────────────────────────────────────────────────
-- Filling one in
-- ─────────────────────────────────────────────────────────────
/**
 * A template with the facts in it.
 *
 * The fields are the ones the owner named - client, counselor, authorization
 * number, dates, service - plus the signature and the name of whoever is
 * writing. A field with nothing behind it is left as a visible gap rather than
 * silently blanked: "ends on ——" tells somebody to go and look, and a sentence
 * that reads perfectly with a date missing is a sentence that will be sent
 * with a date missing.
 *
 * Nothing restricted is merged in. These are the facts a counselor already
 * has, which is why the screen can offer them to anybody who may write to
 * that counselor.
 */
create or replace function public.mail_template_for(
  p_key           text,
  p_client        uuid default null,
  p_authorization uuid default null
)
returns table (subject text, body text)
language plpgsql stable security definer set search_path = public as $$
declare
  t    public.mail_templates;
  c    public.clients;
  k    public.counselors;
  a    public.authorizations;
  v_me text;
  v_sig  text;
  fill   text;
  fields jsonb;
  field  text;
  value  text;
begin
  if not (select public.is_active_staff()) then
    raise exception 'Only a member of staff reads the templates.' using errcode = 'insufficient_privilege';
  end if;

  select * into t from public.mail_templates where key = p_key and active;
  if not found then
    raise exception 'There is no template called %.', p_key using errcode = 'no_data_found';
  end if;

  if p_client is not null then
    select * into c from public.clients where id = p_client;
    if c.counselor_id is not null then
      select * into k from public.counselors where id = c.counselor_id;
    end if;
  end if;

  -- The authorization asked for, or the client's latest if the screen did not
  -- say which.
  if p_authorization is not null then
    select * into a from public.authorizations where id = p_authorization;
  elsif p_client is not null then
    select * into a from public.authorizations
     where client_id = p_client and status in ('Authorized', 'Due')
     order by coalesce(end_date, start_date) desc nulls last
     limit 1;
  end if;

  select s.name into v_me from public.staff s where s.id = public.current_staff_id();
  select o.mail_signature into v_sig from public.org_settings o limit 1;

  -- A gap somebody can see. A sentence that reads perfectly with the date
  -- missing is a sentence that gets sent with the date missing.
  fill := '——';

  fields := jsonb_build_object(
    '{client}',        coalesce(nullif(c.name, ''), fill),
    '{client_no}',     coalesce('#' || c.client_no::text, ''),
    '{counselor}',     coalesce(nullif(k.name, ''), 'Hello'),
    '{authorization}', coalesce(nullif(a.number, ''), fill),
    '{service}',       coalesce(nullif(a.service_type, ''), fill),
    '{issued}',        coalesce(to_char(a.start_date, 'FMMon FMDD, YYYY'), fill),
    '{ends}',          coalesce(to_char(a.end_date, 'FMMon FMDD, YYYY'), fill),
    '{me}',            coalesce(nullif(v_me, ''), ''),
    '{signature}',     coalesce(nullif(v_sig, ''), '')
  );

  subject := t.subject;
  body    := t.body;
  for field, value in select * from jsonb_each_text(fields)
  loop
    subject := replace(subject, field, value);
    body    := replace(body, field, value);
  end loop;

  subject := btrim(regexp_replace(subject, '\s+', ' ', 'g'));
  return next;
end;
$$;

revoke all on function public.mail_template_for(text, uuid, uuid) from anon, authenticated;
grant execute on function public.mail_template_for(text, uuid, uuid) to authenticated;
