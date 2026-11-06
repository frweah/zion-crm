-- Zion Vocational Rehab CRM — mail that names somebody, offered for filing
--
-- Item E, source 2: "nightly, unfiled mail in a staff member's connected
-- mailbox that mentions an active client's name → filing suggestion.
-- Drag-and-drop stays; never auto-file from here."
--
-- ── no mailbox is read for this ──────────────────────────────
--
-- The sweep that reads mail already exists and already writes down what it
-- saw: one `mail_log` row per message, with its subject and no body, filed to
-- a client or not. So "unfiled mail that mentions a client" is a question
-- about rows the practice already has, and this is a SQL sweep rather than a
-- second thing holding a mail token. Which means it can be tried in a
-- transaction that is rolled back, and `check-mail`'s rules about who may
-- open a mailbox are untouched by it.
--
-- Unfiled means what 0242 made it mean: no client on the row, or a client
-- somebody has since taken off it.
--
-- ── and a name is a name, not a fragment ─────────────────────
--
-- The match is the client's whole name, a spelling on file for them (0303),
-- or their own email address - and never a string shorter than six
-- characters, because "Ann" is in "announcement" and an inbox full of
-- suggestions nobody wants is an inbox nobody clears. A client whose real
-- name is shorter than that is matched by their email address or not at all,
-- which is the honest answer rather than a guess.

begin;

create or replace function public.clients_named_in(p_text text)
returns table(client_id uuid, how text)
language sql
stable
security definer
set search_path to 'public'
as $$
  with said as (select lower(coalesce(p_text, '')) as text)
  select c.id, 'named'::text
    from public.clients c, said
   where c.status = 'Active' and c.merged_into is null
     and length(btrim(c.name)) >= 6
     and said.text like '%' || lower(btrim(c.name)) || '%'
  union
  select a.client_id, 'another spelling of this name'::text
    from public.client_aliases a
    join public.clients c on c.id = a.client_id, said
   where c.status = 'Active' and c.merged_into is null
     and length(btrim(a.name)) >= 6
     and said.text like '%' || lower(btrim(a.name)) || '%'
  union
  select c.id, 'their email address'::text
    from public.clients c, said
   where c.status = 'Active' and c.merged_into is null
     and coalesce(btrim(c.email), '') <> ''
     and said.text like '%' || lower(btrim(c.email)) || '%'
$$;

comment on function public.clients_named_in is
  'Active clients whose name, a spelling on file for them, or their email '
  'address appears in a piece of text. Nothing shorter than six characters is '
  'matched on, so a short name is found by address or not at all.';

revoke all on function public.clients_named_in(text) from public, anon;
grant execute on function public.clients_named_in(text) to authenticated, service_role;

-- ── the nightly sweep ───────────────────────────────────────
create or replace function public.to_file_from_mail(p_since date default null)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_from date := coalesce(p_since, public.practice_today() - 2);
  v_n    integer := 0;
  r      record;
begin
  if coalesce(auth.role(), '') <> 'service_role' then
    perform public.refuse_elevated('to_file_from_mail',
      'Only the nightly sweep offers mail for filing.');
  end if;

  for r in
    select m.id, m.staff_id, m.graph_message_id, m.subject, m.sent_at,
           m.counterpart_email, m.direction, n.client_id, n.how
      from public.mail_log m
      join lateral public.clients_named_in(
             coalesce(m.subject, '') || ' ' || coalesce(m.counterpart_email, '')) n on true
     where m.staff_id is not null
       and m.client_id is null
       and m.sent_at >= v_from::timestamptz
     order by m.sent_at
  loop
    -- One suggestion per message. Where two clients are named in one subject
    -- the first is offered with its reason and the person can reassign it:
    -- two rows about one email is two things to clear for one decision.
    if not exists (select 1 from public.to_file f
                    where f.staff_id = r.staff_id and f.source = 'Email'
                      and f.source_key = coalesce(nullif(r.graph_message_id, ''), r.id::text)) then
      perform public.to_file_offer(
        r.staff_id, 'Email',
        coalesce(nullif(r.graph_message_id, ''), r.id::text),
        coalesce(nullif(btrim(r.subject), ''), '(no subject)'),
        case when r.direction = 'Outgoing' then 'Sent to ' else 'From ' end
          || coalesce(nullif(r.counterpart_email, ''), 'somebody'),
        r.sent_at, r.client_id, r.how);
      v_n := v_n + 1;
    end if;
  end loop;

  return v_n;
end $$;

comment on function public.to_file_from_mail is
  'Offers unfiled mail that names an active client to the inbox of whoever '
  'the mail belongs to. Files nothing: a person confirms it or discards it.';

revoke all on function public.to_file_from_mail(date) from public, anon, authenticated;

commit;
