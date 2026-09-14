-- Zion Vocational Rehab CRM — a warrant stub is never settled from the inbox
--
-- A USOR warrant stub saved in a client's folder arrives with that client's
-- documents and is read as a warrant. Until now the inbox offered to mark an
-- invoice paid from it, by amount, without the checks every stub in the
-- _Warrants folder goes through: both copies of the V-number agree, the lines
-- add up to the page total, the V-number is an authorization on file.
--
-- Now the agent reads such a stub page by page into the warrant pipeline
-- (/api/agent/warrants), and the inbox entry is closed by that pipeline once
-- every page is in - or handed back as an ordinary document when no page of it
-- is a warrant. Staff cannot file it, set it aside, or call it something else
-- to get it past those checks. Saying whose folder it came from is still
-- allowed.

create or replace function public.inbox_warrant_guard()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if old.kind = 'Warrant'
     and coalesce(public.filing_caller_role(), '') <> 'service_role'
     and (new.kind is distinct from old.kind or new.state is distinct from old.state) then
    raise exception 'A warrant stub is read on Billing → Warrants, where every line is checked. It is not settled from the document inbox.'
      using errcode = 'insufficient_privilege';
  end if;
  return new;
end;
$$;

revoke execute on function public.inbox_warrant_guard() from public, anon, authenticated;

drop trigger if exists inbox_documents_warrant_guard on public.inbox_documents;
create trigger inbox_documents_warrant_guard
  before update on public.inbox_documents
  for each row execute function public.inbox_warrant_guard();

comment on function public.inbox_warrant_guard() is
  'A document read as a warrant leaves the inbox only through the warrant pipeline (service role), never by a person filing, setting aside or reclassifying it.';
