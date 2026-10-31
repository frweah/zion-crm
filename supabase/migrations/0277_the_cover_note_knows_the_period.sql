-- The cover note knows the period
--
-- 0276 gave `mail_template_for` the period so the progress report cover note
-- could say which month it covers. The screen that offers the templates calls
-- `mail_templates_for`, which passes through to it - and that one had no
-- period to pass, so every cover note on the Compose screen read "covering
-- ——" however the report was opened.
--
-- Found by reading what calls what rather than by sending one, which is the
-- only way to find it: the sentence is grammatical either way and the gap is
-- two em dashes.
--
-- Dropped and recreated rather than given a third defaulted parameter, for
-- the reason 0276 gives about the same thing: a defaulted parameter makes a
-- second function and leaves the two-argument calls ambiguous between them.

drop function if exists public.mail_templates_for(uuid, uuid);

create or replace function public.mail_templates_for(
  p_client        uuid default null,
  p_authorization uuid default null,
  p_period        date default null
)
returns table(key text, label text, subject text, body text)
language sql stable security definer set search_path = public as $$
  select t.key, t.label, f.subject, f.body
    from public.mail_templates t
    cross join lateral public.mail_template_for(t.key, p_client, p_authorization, p_period) f
   where t.active
   order by t.sort_order, t.key;
$$;

revoke all on function public.mail_templates_for(uuid, uuid, date) from anon, authenticated;
grant execute on function public.mail_templates_for(uuid, uuid, date) to authenticated;

do $$
begin
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'mail_templates_for') <> 1 then
    raise exception 'mail_templates_for exists at more than one signature';
  end if;

  -- The period reaches the cover note through both functions. Asserted here
  -- by the shape - that the pass-through takes a date and the template has
  -- the field in it - because mail_template_for refuses anybody who is not
  -- staff, and this file runs as postgres. The behaviour is asserted in
  -- verify_client_reports.sql, where impersonating somebody is the norm.
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'mail_templates_for'
       and pg_get_functiondef(p.oid) like '%p_period%'
  ) then
    raise exception 'mail_templates_for does not pass a period through';
  end if;
  if not exists (
    select 1 from public.mail_templates
     where key = 'progress_report' and body like '%{month}%'
  ) then
    raise exception 'the progress report cover note does not say which period it covers';
  end if;
  raise notice 'ok  the cover note carries the period, through both functions';
end $$;
