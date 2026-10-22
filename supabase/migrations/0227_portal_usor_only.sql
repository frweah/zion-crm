-- 0227 — The client portal is for USOR clients only (owner, 21 Oct 2026).
--
-- The portal runs where the CRM runs, outside the HIPAA covered component of
-- the hybrid entity (0226). So the same line holds here: a portal account can
-- only be made for a client funded by Utah VR, and a client whose funding
-- changes away from Utah VR loses portal access at once - sessions ended,
-- account turned off, the reason recorded where staff read the portal's
-- history.

create or replace function public.portal_usor_only()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if (select funding_source from public.clients where id = new.client_id) is distinct from 'Utah VR' then
    raise exception 'The client portal is for USOR clients only, and this client is not funded by Utah VR.'
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

drop trigger if exists portal_accounts_usor_only on public.portal_accounts;
create trigger portal_accounts_usor_only
  before insert or update of client_id on public.portal_accounts
  for each row execute function public.portal_usor_only();

create or replace function public.portal_close_when_not_usor()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  a record;
begin
  if new.funding_source is distinct from 'Utah VR' and old.funding_source = 'Utah VR' then
    for a in select id from public.portal_accounts where client_id = new.id and disabled_at is null loop
      update public.portal_accounts
         set disabled_at = now(), disabled_reason = 'No longer funded by Utah VR'
       where id = a.id;
      perform public.portal_end_sessions(a.id, 'Account disabled');
      insert into public.portal_activity (account_id, client_id, action, detail, acting_as, actor_name)
      values (a.id, new.id, 'Account disabled', 'No longer funded by Utah VR', 'System', '');
    end loop;
  end if;
  return new;
end;
$$;

drop trigger if exists clients_portal_usor_only on public.clients;
create trigger clients_portal_usor_only
  after update of funding_source on public.clients
  for each row execute function public.portal_close_when_not_usor();

revoke execute on function public.portal_usor_only(), public.portal_close_when_not_usor()
  from public, anon, authenticated;
