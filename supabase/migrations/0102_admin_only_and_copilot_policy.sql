-- Zion Vocational Rehab CRM — Admin is Admin's alone; Copilot in the policy
--
-- The owner, 19 Sept 2026:
--
--   The Admin group is Admin-only. The monthly export and the rate schedule
--   move to Billing → Export, and the screen hint follows them. (The document
--   inbox stays in Admin → Documents; see 0103.)
--
--   Microsoft 365 Copilot Chat is linked from the sidebar, and the
--   data-handling policy says it is the only AI tool client information may be
--   entered into. A signed policy's text never changes (0100), so this is
--   version 2, and version 2 is what is signed from now on.

-- ── the hints follow the screens ────────────────────────────
update public.tour_hints set screen = '/billing/export' where key = 'exports' and screen = '/admin/system';

-- ── the data-handling policy, version 2 ─────────────────────
-- Version 1 with one rule added, second, straight after "Client data lives in
-- the CRM only" - the rule it is an exception to.
do $$
declare
  v_body jsonb;
begin
  if exists (select 1 from public.staff_policies where key = 'data-handling' and version = 2) then
    return;
  end if;
  select body into v_body from public.staff_policies where key = 'data-handling' and version = 1;
  if v_body is null or v_body -> 5 ->> 'text' not like 'Client data lives in the CRM only.%' then
    raise exception 'Version 1 of the data-handling policy is not as expected; not publishing version 2.';
  end if;

  v_body := jsonb_insert(v_body, '{5}', jsonb_build_object(
    'type', 'li',
    'text', 'Microsoft 365 Copilot Chat is the only AI tool client information may be entered into - signed in with your Zion work account, from the Copilot link in the CRM''s sidebar. Not ChatGPT, not Gemini, not Copilot under a personal Microsoft account, and no other AI service, on any device.'
  ), true);

  update public.staff_policies set is_current = false where key = 'data-handling' and is_current;
  insert into public.staff_policies (key, version, title, body, text_sha256, is_current)
  values ('data-handling', 2, 'Data-handling policy', v_body,
          encode(extensions.digest(v_body::text, 'sha256'), 'hex'), true);
end $$;
