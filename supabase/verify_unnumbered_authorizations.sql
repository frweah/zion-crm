-- Zion Vocational Rehab CRM — an authorization without a number says so (0252)
--
-- Four of the practice's authorizations are placeholders from the spreadsheet
-- import, called things like `coaching 1006`. Two more have no number at all.
-- None of the six has a USOR number, and every dropdown in the CRM was
-- showing `coaching 1006` in the place a USOR number goes - so a list of
-- authorizations read as though USOR had issued one called that (owner,
-- 26 Oct 2026).
--
-- The question is asked of the *shape* now, not of a list of the wrong
-- shapes: a USOR number is `V` and digits, and anything else is a filing
-- note. That is one definition, in one generated column, and this is what
-- holds it:
--
--   every real number on file is recognised as one;
--   every placeholder and every empty one is not;
--   and the thing that replaces a placeholder asks the same question, so the
--   action exists for the records it exists for.
--
-- Read-only against the practice's own rows, because the shapes that are
-- actually on file are the whole point. A fixture would only prove the
-- regular expression matches itself.

do $$
declare
  v_real     integer;
  v_missed   text;
  v_claimed  text;
  v_unnumber integer;
  failures   text[] := '{}';
begin
  -- ── a real number is recognised ───────────────────────────
  select count(*) into v_real from public.authorizations where number ~* '^V[0-9]+';
  if v_real = 0 then
    failures := failures || 'FAILED: no authorization has a USOR-shaped number, so this is checking nothing'::text;
  end if;

  select string_agg(number, ', ' order by number) into v_missed
    from public.authorizations
   where number ~* '^V[0-9]+' and not has_usor_number;
  if v_missed is not null then
    failures := failures ||
      format('FAILED: these have a USOR number and are not recognised as numbered: %s', v_missed)::text;
  else
    raise notice 'ok  all % USOR numbers on file are recognised as numbers', v_real;
  end if;

  -- ── and a filing note is not ──────────────────────────────
  select string_agg(format('%s (%s)', number, service_type), ', ' order by number) into v_claimed
    from public.authorizations
   where has_usor_number and number !~* '^V[0-9]+';
  if v_claimed is not null then
    failures := failures ||
      format('FAILED: these claim a USOR number and have not got one: %s', v_claimed)::text;
  else
    raise notice 'ok  and nothing without one claims to have one';
  end if;

  select count(*) into v_unnumber from public.authorizations where not has_usor_number;
  raise notice '--  % authorization(s) on file have no USOR number yet', v_unnumber;

  -- ── replacing is for exactly those ────────────────────────
  --
  -- `replace_placeholder_authorization` refused anything whose number did not
  -- begin with "(workbook)", a convention no row has used for months - so the
  -- action refused every record it exists for. It asks the column now, and
  -- this is the assertion that it still does.
  if not exists (
        select 1 from pg_proc
         where pronamespace = 'public'::regnamespace
           and proname = 'replace_placeholder_authorization'
           and pg_get_functiondef(oid) ~ 'if v_auth\.has_usor_number then') then
    failures := failures ||
      'FAILED: replacing a placeholder does not ask has_usor_number, so it is testing a convention instead of a fact'::text;
  elsif exists (
        select 1 from pg_proc
         where pronamespace = 'public'::regnamespace
           and proname = 'replace_placeholder_authorization'
           and pg_get_functiondef(oid) like '%(workbook)%') then
    failures := failures ||
      'FAILED: replacing a placeholder still mentions the "(workbook)" convention'::text;
  else
    raise notice 'ok  replacing a placeholder asks whether it has a number, not what it is called';
  end if;

  if array_length(failures, 1) > 0 then
    raise exception '%', array_to_string(failures, E'\n');
  end if;
  raise notice '--- UNNUMBERED AUTHORIZATIONS VERIFIED ---';
end $$;
