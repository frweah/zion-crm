-- Zion Vocational Rehab CRM — the columns the app role may not read
--
-- This file exists because five migrations claimed a column was unreadable and
-- none of them made it so. `revoke select (col) on t from authenticated` is a
-- no-op while the role holds table-level SELECT, which it did. The encrypted
-- TINs, the encrypted tax payloads, the Microsoft refresh tokens and the
-- practice EIN were all readable by any signed-in staff member for as long as
-- they had existed.
--
-- The older verifications missed it because they tested the functions —
-- get_contractor_tin, get_microsoft_tokens, get_employer_details — which were
-- correctly locked down. They asserted the door and never tried the wall.
--
-- So this asks the catalogue directly, and asks it both ways round:
--
--   * the sensitive columns are unreadable, and
--   * every other column on those tables is readable.
--
-- The second half matters as much as the first. Restricting a column means
-- granting the rest one by one, so a column added by a later migration is
-- readable by nobody until somebody grants it — and a screen quietly losing a
-- field is the kind of breakage that gets blamed on anything but permissions.
--
-- Nothing here writes, so there is nothing to roll back.

do $$
declare
  v_table   text;
  v_hidden  text[];
  v_col     text;
  v_missing text;
  targets   text[][] := array[
    array['org_settings',           'employer_ein'],
    array['contractor_profiles',    'tin_encrypted'],
    array['tax_form_submissions',   'sensitive_encrypted'],
    array['microsoft_connections',  'access_encrypted,refresh_encrypted']
  ];
  i int;
  failures text[] := '{}';
begin
  for i in 1 .. array_length(targets, 1) loop
    v_table  := targets[i][1];
    v_hidden := string_to_array(targets[i][2], ',');

    -- ── the ones that must stay shut ─────────────────────────
    foreach v_col in array v_hidden loop
      if has_column_privilege('authenticated', 'public.' || v_table, v_col, 'select') then
        failures := failures || format('FAILED: authenticated can read %s.%s', v_table, v_col);
      else
        raise notice 'ok  %.% is not readable by the application role', v_table, v_col;
      end if;
    end loop;

    -- ── and the ones that must stay open ─────────────────────
    select string_agg(column_name, ', ' order by ordinal_position)
      into v_missing
      from information_schema.columns
     where table_schema = 'public' and table_name = v_table
       and not (column_name = any(v_hidden))
       and not has_column_privilege('authenticated', 'public.' || v_table, column_name, 'select');

    if v_missing is not null then
      failures := failures || format(
        'FAILED: %s has columns nobody can read — %s. A migration added them without a grant.',
        v_table, v_missing);
    else
      raise notice 'ok  every other column on % is still readable', v_table;
    end if;
  end loop;

  -- ── the table grant is gone, which is what makes it work ──
  for i in 1 .. array_length(targets, 1) loop
    v_table := targets[i][1];
    if has_table_privilege('authenticated', 'public.' || v_table, 'select') then
      failures := failures || format(
        'FAILED: authenticated holds table-level SELECT on %s, which overrides every column grant',
        v_table);
    else
      raise notice 'ok  % has no table-level SELECT to override the column grants', v_table;
    end if;
  end loop;

  if failures = '{}' then
    raise notice '';
    raise notice '--- COLUMN PERMISSIONS VERIFIED ---';
  else
    raise notice '';
    raise notice '%  PROBLEM(S):', array_length(failures, 1);
    raise exception '%', array_to_string(failures, E'\n');
  end if;
end $$;
