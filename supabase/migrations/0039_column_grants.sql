-- ─────────────────────────────────────────────────────────────
-- 0039 — the column revokes never worked.
--
-- Five times across this build I wrote a line like
--
--   revoke select (tin_encrypted) on public.contractor_profiles from authenticated;
--
-- and said in the commit that the column could not be read. It could. In
-- Postgres a table-level SELECT grant dominates a column-level revoke: the
-- revoke removes a privilege the role was not relying on, and the table grant
-- keeps letting it read everything. Every one of those five lines was a no-op.
--
-- The only way to restrict a column is to take away SELECT on the table and
-- grant it back column by column. That is done below.
--
-- What was actually exposed, stated plainly rather than minimised:
--
--   * org_settings.employer_ein — readable by every signed-in staff member.
--   * contractor_profiles.tin_encrypted — Admin, and each person their own.
--   * tax_form_submissions.sensitive_encrypted — same.
--   * microsoft_connections.access_encrypted / refresh_encrypted — Admin could
--     read anybody's, which contradicts the guarantee written in 0029 that not
--     even Admin can read another person's token.
--
-- All four are ciphertext under a key that lives in Vault and was never
-- reachable this way, so nothing was readable as plaintext. That is the reason
-- this is a defence-in-depth failure rather than a breach, and it is not a
-- reason to have left it: encryption at rest is worth having precisely for the
-- day something else goes wrong.
--
-- The verifications did not catch it because they tested the functions —
-- get_contractor_tin, get_microsoft_tokens, get_employer_details — and those
-- were correctly locked down. They asserted the door and never tried the wall
-- beside it.
--
-- Maintenance note, which matters more than the fix: from here on these four
-- tables have per-column grants, so a column added by a later migration is
-- readable by nobody until it is granted. verify_columns.sql asserts both
-- halves — that the sensitive columns are unreadable, and that every other
-- column is readable — so a forgotten grant fails loudly on the next run
-- instead of quietly breaking a screen.
-- ─────────────────────────────────────────────────────────────

do $$
declare
  t          text;
  hidden     text[];
  cols       text;
  targets    text[][] := array[
    array['org_settings',           'employer_ein'],
    array['contractor_profiles',    'tin_encrypted'],
    array['tax_form_submissions',   'sensitive_encrypted'],
    array['microsoft_connections',  'access_encrypted,refresh_encrypted']
  ];
  i int;
begin
  for i in 1 .. array_length(targets, 1) loop
    t      := targets[i][1];
    hidden := string_to_array(targets[i][2], ',');

    -- Built from the catalogue rather than typed out, so the list cannot drift
    -- from the table it describes.
    select string_agg(quote_ident(column_name), ', ' order by ordinal_position)
      into cols
      from information_schema.columns
     where table_schema = 'public' and table_name = t
       and not (column_name = any(hidden));

    execute format('revoke select on public.%I from authenticated', t);
    execute format('grant select (%s) on public.%I to authenticated', cols, t);

    raise notice 'public.% — % hidden, rest granted', t, array_to_string(hidden, ' and ');
  end loop;
end $$;

-- Writes are unchanged. They were already governed by RLS and, for the
-- sensitive columns, by revoking insert and update outright — those revokes
-- were table-level and did work.
