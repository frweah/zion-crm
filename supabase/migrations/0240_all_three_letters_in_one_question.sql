-- Zion Vocational Rehab CRM — 0240 all three letters in one question
--
-- The Compose screen offers every template with the facts already merged in,
-- which it did by calling `mail_template_for` once per template. Three
-- templates is three round trips, and `scripts/check-screens.mjs` says a
-- screen asks one question per record - a rule that exists because the fourth
-- template would have made it four without anybody noticing.
--
-- One function over the table, answering for all of them. `mail_template_for`
-- stays: it is the single-template answer and the one the merge lives in, and
-- this calls it rather than keeping a second copy of the merge.

create or replace function public.mail_templates_for(
  p_client        uuid default null,
  p_authorization uuid default null
)
returns table (key text, label text, subject text, body text)
language sql stable security definer set search_path = public as $$
  select t.key, t.label, f.subject, f.body
    from public.mail_templates t
    cross join lateral public.mail_template_for(t.key, p_client, p_authorization) f
   where t.active
   order by t.sort_order, t.key;
$$;

comment on function public.mail_templates_for is
  'Every active template with this client''s facts merged in, in one question (0240).';

revoke all on function public.mail_templates_for(uuid, uuid) from anon, authenticated;
grant execute on function public.mail_templates_for(uuid, uuid) to authenticated;
