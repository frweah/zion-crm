-- Zion Vocational Rehab CRM — some documents are restricted before anybody
-- decides to restrict them
-- (owner, 15 Oct 2026: default Restricted on for ID, medical/psychological,
-- guardianship/legal and financial; the uploader can un-tick it; log when
-- they do)
--
-- ── three of the four did not exist ─────────────────────────
--
-- The client document types were: Signed USOR form, Work schedule,
-- Authorization, Signed intake, Employer verification, Invoice, Guardianship
-- document, Other. Of the four kinds the owner named, only guardianship was
-- among them. There was no way to say a document was somebody's ID, or
-- medical, or financial - so the instruction would have been inert for three
-- of its four cases. They are added here, or the rule has nothing to fire on.
--
-- ── and Invoice is not "financial" ──────────────────────────
--
-- The nearest existing type to "financial" is Invoice, and it is the wrong
-- one. There are 130 invoices on file and none of them is restricted: they
-- are what the practice bills USOR, not a client's bank statements. Defaulting
-- them to restricted would hide routine billing paperwork from Billing staff
-- who are not the assigned worker, which is most of them.
--
-- So "Financial document" is its own type, for the client's own money - a
-- benefits letter, a bank statement, a representative-payee record - and
-- Invoice stays open.
--
-- ── one list, in one place, at last ─────────────────────────
--
-- The types were written out three times before today and the three
-- disagreed; 0202 brought it to a constant and a check constraint. That is
-- still two, and now the database needs to know something the constant
-- cannot carry - which types are sensitive - because the log below has to
-- fire however the row arrives, not only when it comes from the form.
--
-- So the list becomes a table, like staff_file_categories already is for the
-- other side of the house, and the check constraint becomes a foreign key to
-- it. The screens read it, the form reads it, the trigger reads it. Adding a
-- type is a row rather than a deploy.
--
-- The keys are the strings already stored on 770 documents and are not
-- renamed. Only the label somebody reads changes: "Guardianship document"
-- shows as "Guardianship or legal document", because the owner's heading was
-- guardianship/legal and a court order about anything else belongs there too.

create table if not exists public.client_file_categories (
  key                   text primary key,
  label                 text not null,
  detail                text not null default '',
  /**
   * Whether the Restricted switch starts on for this type.
   *
   * A default, not a rule: the uploader can turn it off, and when they do it
   * is written down. Somebody who has the authority to decide a scan is not
   * sensitive keeps it; what they lose is doing it silently.
   */
  restricted_by_default boolean not null default false,
  sort_order            integer not null default 0,
  active                boolean not null default true
);

comment on table public.client_file_categories is
  'What a document on a client''s file can be, and which kinds start out restricted. One list: the screens, the upload form and the log trigger all read it, and adding a type is a row rather than a deploy.';

insert into public.client_file_categories (key, label, detail, restricted_by_default, sort_order)
values
  ('Signed USOR form',       'Signed USOR form',             'A USOR form signed by the client or the counselor.',        false,  10),
  ('Work schedule',          'Work schedule',                'Hours and shifts, from the employer or the job coach.',     false,  20),
  ('Authorization',          'Authorization',                'The authorization USOR issued.',                            false,  30),
  ('Signed intake',          'Signed intake',                'The intake paperwork the client signed.',                   false,  40),
  ('Employer verification',  'Employer verification',        'An employer confirming a placement or a wage.',              false,  50),
  ('Invoice',                'Invoice',                      'What the practice billed USOR. Not the client''s own money.', false, 60),
  ('Identity document',      'Identity document',            'A driving licence, a passport, a social security card.',    true,   70),
  ('Medical or psychological', 'Medical or psychological',   'A diagnosis, an assessment, a doctor''s letter.',            true,   80),
  ('Guardianship document',  'Guardianship or legal document', 'A guardianship order, a court paper, a legal notice.',    true,   90),
  ('Financial document',     'Financial document',           'The client''s own money: benefits, bank, representative payee.', true, 100),
  ('Other',                  'Other',                        'Anything else that belongs on the file.',                   false, 110)
on conflict (key) do update
   set label = excluded.label,
       detail = excluded.detail,
       restricted_by_default = excluded.restricted_by_default,
       sort_order = excluded.sort_order,
       active = true;

alter table public.client_file_categories enable row level security;

drop policy if exists client_file_categories_read on public.client_file_categories;
create policy client_file_categories_read on public.client_file_categories
  for select using ((select public.is_active_staff()));

drop policy if exists client_file_categories_write on public.client_file_categories;
create policy client_file_categories_write on public.client_file_categories
  for all using ((select public.is_admin())) with check ((select public.is_admin()));

revoke all on public.client_file_categories from anon, authenticated;
grant select, insert, update, delete on public.client_file_categories to authenticated;
select public.apply_system_read_only('client_file_categories');

-- ── the constraint becomes a key ────────────────────────────
-- Every value on the 770 rows already on file is one of the eleven above, so
-- this binds without touching any of them.
alter table public.attachments drop constraint if exists attachments_category_check;
alter table public.attachments drop constraint if exists attachments_category_fkey;
alter table public.attachments add constraint attachments_category_fkey
  foreign key (category) references public.client_file_categories(key);

-- ─────────────────────────────────────────────────────────────
-- Which clients this person may restrict a document for
--
-- The form needs it before it can tick the box: offering a switch that the
-- database will refuse is worse than not offering it. One query rather than
-- one per client, and it calls can_see_restricted() rather than restating
-- what that means.
-- ─────────────────────────────────────────────────────────────
create or replace function public.clients_i_can_restrict()
returns setof uuid language sql stable security definer set search_path = public as $$
  select c.id from public.clients c
   where public.is_active_staff() and public.can_see_restricted(c.id)
$$;

comment on function public.clients_i_can_restrict is
  'The clients the caller may put a restricted document on. Asked once by the upload form, so a switch is never offered where the database would refuse it.';

revoke all on function public.clients_i_can_restrict() from anon, authenticated;
grant execute on function public.clients_i_can_restrict() to authenticated;

-- ─────────────────────────────────────────────────────────────
-- And when somebody turns the default off, that is the record
--
-- 0202's trigger, with one addition. A document of a sensitive type filed
-- unrestricted is a decision somebody made, and the only place it can be
-- caught for certain is here - the form is one way a row arrives, and the
-- agent and the filing rules are others.
-- ─────────────────────────────────────────────────────────────
create or replace function public.client_document_log()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  k_watched constant text[] := array['filename', 'document_date', 'category', 'restricted', 'note'];
  v_old     jsonb := case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) else '{}'::jsonb end;
  v_new     jsonb := case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) else '{}'::jsonb end;
  v_changes jsonb := '{}'::jsonb;
  v_key     text;
  v_row     public.attachments;
  v_me      uuid := public.current_staff_id();
  v_name    text;
  v_default boolean;
begin
  v_row := case when tg_op = 'DELETE' then old else new end;

  if tg_op = 'UPDATE' then
    foreach v_key in array k_watched loop
      if (v_old -> v_key) is distinct from (v_new -> v_key) then
        v_changes := v_changes || jsonb_build_object(v_key,
          jsonb_build_object('from', v_old -> v_key, 'to', v_new -> v_key));
      end if;
    end loop;
    -- A save that moved none of the fields a person edits is not news.
    if v_changes = '{}'::jsonb then
      return null;
    end if;
  end if;

  /**
   * The default declined.
   *
   * On the way in, and on an edit that takes the restriction back off a
   * sensitive type. Written as its own key so it can be looked for, rather
   * than inferred later by joining the log to a category list that may have
   * changed its mind since.
   */
  if tg_op in ('INSERT', 'UPDATE') and not coalesce(v_row.restricted, false) then
    select restricted_by_default into v_default
      from public.client_file_categories where key = v_row.category;
    if coalesce(v_default, false) then
      v_changes := v_changes || jsonb_build_object('restricted_default_declined',
        jsonb_build_object('category', v_row.category, 'by', coalesce(v_me::text, 'the system')));
    end if;
  end if;

  select name into v_name from public.staff where id = v_me;

  insert into public.client_document_events
    (attachment_id, client_id, filename, category, restricted, action, changes, staff_id, staff_name)
  values (v_row.id, v_row.client_id, coalesce(v_row.filename, ''), coalesce(v_row.category, ''),
          coalesce(v_row.restricted, false),
          case tg_op when 'INSERT' then 'Added' when 'DELETE' then 'Removed' else 'Edited' end,
          v_changes, v_me, coalesce(v_name, 'the system'));
  return null;
end;
$$;

comment on function public.client_document_log is
  'Records a client document being added, edited or removed, with who did it - and, when a type that starts out restricted is filed without it, that somebody turned the default off. A trigger rather than a line in the upload screen, because the agent and the filing rules write this table too.';
