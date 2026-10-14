-- Zion Vocational Rehab CRM — next actions for many clients at once
--
-- The dashboard and My clients asked client_next_actions once per client,
-- inside Promise.all - so one page load opened sixty concurrent connections
-- and asked sixty questions. On the evening of 14 Oct 2026 that path was
-- called 1,278 times in five minutes, the database's p95 went from 800ms to
-- 58 seconds, and the middleware (which was awaiting an auth round trip with
-- no timeout) turned it into 504s on every request. The middleware is fixed
-- separately; this is the thing that started it.
--
-- One call, one connection, one question. The rules themselves are not copied:
-- this is a lateral join over the same client_next_actions, so what a client
-- owes is still decided in exactly one place and a change to it reaches both
-- the record's own strip and these two screens.
create or replace function public.client_next_actions_for(p_clients uuid[])
returns table (
  client_id uuid,
  kind      text,
  title     text,
  detail    text,
  href      text,
  urgency   integer
)
language sql stable security definer set search_path = public as $$
  select c.id, a.kind, a.title, a.detail, a.href, a.urgency
    from unnest(coalesce(p_clients, '{}'::uuid[])) as c(id)
    cross join lateral public.client_next_actions(c.id) a
$$;

comment on function public.client_next_actions_for is
  'What a list of clients owe, in one call. A lateral join over client_next_actions, so the rules live in one place and sixty clients cost one round trip rather than sixty connections.';

revoke all on function public.client_next_actions_for(uuid[]) from anon, authenticated;
grant execute on function public.client_next_actions_for(uuid[]) to authenticated;
