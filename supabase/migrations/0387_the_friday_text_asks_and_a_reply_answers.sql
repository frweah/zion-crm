/**
 * The Friday text lists the week and a reply answers it (owner, 24 Nov 2026).
 *
 * The weekly update has said "You applied for 3 jobs this week" since it was
 * built, deliberately: `weekly_update_facts` carries a count and not a list,
 * and its comment says why - "a text listing five employers is a text that
 * reads as a report". The owner has reversed that for the client's own copy.
 * It stands for a contact's copy, which still gets the count: listing where
 * somebody else's client applied is the thing that ruling was protecting, and
 * nothing in the new one asks for it.
 *
 * So a client's Friday text now numbers the places, and a reply of
 * "3 NO" is that client's answer about the third one.
 *
 * ── the collision this had to clear ──
 *
 * `record_incoming_sms` reduced an incoming body to its letters -
 * `regexp_replace(body, '[^A-Za-z]', '')` - and then matched opt-in keywords
 * against it. "3 YES" reduced to "YES", which is in that list, so the reply
 * this text asks for would have been recorded as *consent granted by text*
 * and never as a rating. It now strips punctuation and whitespace only, so a
 * digit cannot vanish, and the rating is parsed before the keywords are
 * considered at all. One behaviour changes with it: a message like "YES 3"
 * no longer grants consent, because it is no longer the word YES. A bare
 * YES, which is what the carrier rules are about, is untouched.
 *
 * ── the numbers have to mean something a week later ──
 *
 * "3" is only answerable if the practice knows what 3 was, so the list is
 * written down as it is sent, in `weekly_update_items`, rather than
 * recomputed when the reply arrives. A recomputed list would renumber itself
 * the moment anybody logged another application, and the client's answer
 * would land on the wrong employer - which then warns staff off an employer
 * the client never rejected.
 *
 * ── and it has to stay one text ──
 *
 * Today's body is 146 to 164 characters and pure GSM-7. One employer on file
 * is written with a typographic apostrophe (U+2019), and one job title is 342
 * characters long. Either one would wreck the arithmetic: the apostrophe
 * turns the whole message into UCS-2 at 67 characters a part, and the title
 * would add three parts by itself. `sms_plain` folds the punctuation and
 * `cut_to` caps the label, so a five-application week is three parts and the
 * worst week on file - seven - is also three.
 *
 * Tolerates the old code: the new tables are written by the drafting function
 * and by the inbound parser, both of which arrive with this migration; the
 * body is composed in the database, so the Friday screen sends whatever it is
 * given, as it did before. An older deployment drafts the old wording, which
 * is a shorter text, not a broken one.
 */

-- ── what a text can carry ───────────────────────────────────

/**
 * GSM-7, or as near as a name gets.
 *
 * Only the punctuation that actually turns up - typographic quotes, dashes,
 * an ellipsis, a non-breaking space - and then anything still outside
 * printable ASCII is dropped rather than left to triple the cost of every
 * message in the practice.
 */
create or replace function public.sms_plain(p_text text)
returns text
language sql
immutable
set search_path = public, pg_temp
as $$
  select regexp_replace(
           replace(replace(replace(replace(replace(replace(replace(replace(
             coalesce(p_text, ''),
             U&'\2018', ''''), U&'\2019', ''''),
             U&'\201C', '"'),  U&'\201D', '"'),
             U&'\2013', '-'),  U&'\2014', '-'),
             U&'\2026', '...'), U&'\00A0', ' '),
           '[^ -~\u000A]', '', 'g')
$$;

comment on function public.sms_plain(text) is
  'The same words in characters a text can carry without turning into UCS-2.';

/**
 * How many characters a text costs.
 *
 * The seven characters GSM-7 keeps in its extension table - [ ] { } \ ^ ~ |
 * and the euro sign - take two units each, which is how a 160-character
 * message becomes two parts without looking any longer.
 */
create or replace function public.sms_units(p_text text)
returns integer
language sql
immutable
set search_path = public, pg_temp
as $$
  select length(coalesce(p_text, ''))
       + (length(coalesce(p_text, '')) - length(regexp_replace(coalesce(p_text, ''), '[\[\]{}\\^~|€]', '', 'g')))
$$;

create or replace function public.sms_segments(p_text text)
returns integer
language sql
immutable
set search_path = public, pg_temp
as $$
  -- One text up to 160 units; after that the parts carry a header and hold
  -- 153 each. Assumes GSM-7, which `sms_plain` is what guarantees.
  select case when public.sms_units(p_text) <= 160 then 1
              else ceil(public.sms_units(p_text)::numeric / 153)::integer end
$$;

comment on function public.sms_segments(text) is
  'How many parts a GSM-7 text would be sent in. Feed it sms_plain output.';

/** A label that cannot run away with the message. */
create or replace function public.cut_to(p_text text, p_max integer)
returns text
language sql
immutable
set search_path = public, pg_temp
as $$
  select case
    when length(btrim(coalesce(p_text, ''))) <= p_max then btrim(coalesce(p_text, ''))
    else rtrim(left(btrim(p_text), greatest(p_max - 3, 1))) || '...'
  end
$$;

revoke all on function public.sms_plain(text) from anon, public;
revoke all on function public.sms_units(text) from anon, public;
revoke all on function public.sms_segments(text) from anon, public;
revoke all on function public.cut_to(text, integer) from anon, public;
grant execute on function public.sms_plain(text) to authenticated;
grant execute on function public.sms_units(text) to authenticated;
grant execute on function public.sms_segments(text) to authenticated;
grant execute on function public.cut_to(text, integer) to authenticated;

-- ── the list, as it was sent ─────────────────────────────────

create table if not exists public.weekly_update_items (
  id         uuid primary key default gen_random_uuid(),
  update_id  uuid not null references public.weekly_updates(id) on delete cascade,
  item_no    integer not null check (item_no between 1 and 20),
  match_id   uuid not null references public.lead_matches(id) on delete cascade,
  label      text not null default '',
  created_at timestamptz not null default now(),
  unique (update_id, item_no),
  unique (update_id, match_id)
);

comment on table public.weekly_update_items is
  'The numbered list a weekly update carried, kept so a reply of "3 NO" still means the third place a week later.';

alter table public.weekly_update_items enable row level security;

create policy weekly_update_items_read on public.weekly_update_items
  for select using ((select public.is_active_staff()));

-- Written by the drafting function, which is what sends the numbers out.
create policy weekly_update_items_no_insert on public.weekly_update_items
  as restrictive for insert with check (false);
create policy weekly_update_items_no_edit on public.weekly_update_items
  as restrictive for update using (false);
create policy weekly_update_items_no_delete on public.weekly_update_items
  as restrictive for delete using (false);

revoke all on public.weekly_update_items from anon, public;
grant select on public.weekly_update_items to authenticated;
select public.apply_system_read_only('public.weekly_update_items'::regclass);

-- ── the client's answer ──────────────────────────────────────

create table if not exists public.application_feedback (
  id        uuid primary key default gen_random_uuid(),
  match_id  uuid not null references public.lead_matches(id) on delete cascade,
  client_id uuid not null references public.clients(id) on delete cascade,
  update_id uuid references public.weekly_updates(id) on delete set null,
  answer    text not null check (answer in ('Yes', 'No')),
  -- The whole message, as they wrote it. The screens show the answer and
  -- these words, because "too far by bus" is the part staff can act on and
  -- paraphrasing somebody's own sentence is how it stops being theirs.
  said      text not null default '',
  sms_id    uuid references public.sms_messages(id) on delete set null,
  at        timestamptz not null default now(),
  source    text not null default 'Text' check (source in ('Text')),
  unique (sms_id, match_id)
);

comment on table public.application_feedback is
  'Whether a client would want to work somewhere they applied, in their own words, as they replied to the Friday text.';

create index if not exists application_feedback_by_match
  on public.application_feedback (match_id, at desc);
create index if not exists application_feedback_by_client
  on public.application_feedback (client_id, at desc);

alter table public.application_feedback enable row level security;

create policy application_feedback_read on public.application_feedback
  for select using ((select public.is_active_staff()));

/**
 * Append-only, and never by a staff member.
 *
 * It is the client's own sentence about where they would work. A row staff
 * could write would make "the client said this" a thing nobody can rely on,
 * and a row staff could edit would make it worse.
 */
create policy application_feedback_no_insert on public.application_feedback
  as restrictive for insert with check (false);
create policy application_feedback_no_edit on public.application_feedback
  as restrictive for update using (false);
create policy application_feedback_no_delete on public.application_feedback
  as restrictive for delete using (false);

revoke all on public.application_feedback from anon, public;
grant select on public.application_feedback to authenticated;
select public.apply_system_read_only('public.application_feedback'::regclass);

-- ── the list the text prints ─────────────────────────────────

/**
 * This week's applications, numbered.
 *
 * The employer, not the role: the client knows which place they applied to by
 * its name, the rating is about the place, and the warning staff get later is
 * per employer. The role is added only when the same employer appears twice
 * in one week, because then the name alone does not say which is which.
 *
 * `reader_may_answer()` for the same reason the facts function has it: a
 * definer function that answers "where did this client apply" would answer it
 * to anybody holding a session.
 */
create or replace function public.weekly_update_list(p_client uuid, p_from date, p_to date)
returns table (item_no integer, match_id uuid, label text)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  with applied as (
    select m.id,
           e.name as employer,
           l.title,
           count(*) over (partition by e.id) as same_employer,
           row_number() over (order by m.applied_on, e.name, m.id) as pos
      from public.lead_matches m
      join public.job_leads l on l.id = m.lead_id
      join public.employers e on e.id = l.employer_id
     where m.client_id = p_client
       and m.applied_on between p_from and p_to
  )
  select a.pos::integer,
         a.id,
         public.sms_plain(
           case when a.same_employer > 1 and coalesce(btrim(a.title), '') <> ''
                then public.cut_to(a.employer, 20) || ' - ' || public.cut_to(a.title, 14)
                else public.cut_to(a.employer, 30) end)
    from applied a
   where public.reader_may_answer()
     and a.pos <= 20
   order by a.pos
$$;

revoke all on function public.weekly_update_list(uuid, date, date) from anon, public;
grant execute on function public.weekly_update_list(uuid, date, date) to authenticated;

-- ── the one line that asks ───────────────────────────────────

create or replace function public.weekly_update_invitation()
returns text
language sql
immutable
set search_path = public, pg_temp
as $$
  select 'Reply with the number and YES or NO to tell us if you''d want to work there, or text us a place you''d like us to try.'
$$;

comment on function public.weekly_update_invitation() is
  'The line the client''s Friday text ends with. One place, so the text and the parser cannot drift apart.';

revoke all on function public.weekly_update_invitation() from anon, public;
grant execute on function public.weekly_update_invitation() to authenticated;
