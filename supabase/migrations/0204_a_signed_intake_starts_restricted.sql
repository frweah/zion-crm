-- Zion Vocational Rehab CRM — a signed intake starts restricted
-- (owner, 16 Oct 2026)
--
-- 0203 defaulted four types to restricted: an ID, anything medical, a
-- guardianship or legal paper, and the client's own financial documents.
-- Signed intake was left out because it was not one of the four the owner
-- named, and flagged as a candidate rather than decided unilaterally.
--
-- The owner has said yes, which closes the gap the upload screen itself had
-- been pointing at all along: its guidance has always read "tick restricted
-- for anything carrying disability, medical or intake detail - a signed
-- intake or a USOR 94", and a signed intake was the example it gave while
-- being the one type the default did not cover.
--
-- One row. Nothing retrospective: the single signed intake already on file
-- keeps whatever it has, and this decides what the next one starts as.

update public.client_file_categories
   set restricted_by_default = true
 where key = 'Signed intake';

do $$
declare
  v_set text;
begin
  select string_agg(key, ', ' order by key) into v_set
    from public.client_file_categories where restricted_by_default;
  raise notice 'ok  the types that start restricted: %', v_set;
  if position('Signed intake' in v_set) = 0 then
    raise exception 'Signed intake did not take the default.';
  end if;
end $$;
