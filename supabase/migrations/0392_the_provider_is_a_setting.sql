/**
 * Which carrier the practice texts through, as a setting rather than a deploy
 * (owner, 27 November 2026).
 *
 * The Zion client line 385-406-3432 is leaving GoHighLevel for Twilio. The
 * two ways to do that are a deploy and a switch, and a deploy is the wrong
 * one: the day the number moves, somebody has to be able to put it back
 * inside a minute without waiting twenty for a build. So the provider lives
 * in `org_settings`, Admin sets it, and one file in the application reads it.
 *
 * It is named for texting because that is what the owner named it, and the
 * same switch governs voice: a practice half on one carrier and half on
 * another is a practice whose client line rings in two places.
 *
 * Three things here, and the third is the reason the other two are safe.
 *
 * 1. The setting, with only two values it will accept.
 * 2. `sms_provider()` - what the switch says - and `sms_provider_name()`,
 *    which is the same answer in the words `sms_messages.provider` has used
 *    since 0050. The second is the column's new default, so a message
 *    records which carrier carried it without one line of the sending code
 *    changing, and without `record_incoming_sms` having to be touched at all.
 * 3. `record_text_status` learns the two status words Twilio sends that
 *    GoHighLevel does not, and stops naming GoHighLevel in the two sentences
 *    a person can end up reading.
 *
 * Tolerates the old code: nothing deployed writes `org_settings.sms_provider`
 * or `sms_messages.provider`, so the constraint can refuse nothing that is
 * being sent today, and the new column default is what the old code gets
 * when it inserts a row exactly as it does now - 'GoHighLevel' until Admin
 * moves the switch.
 */

-- ── 1. the setting ───────────────────────────────────────────

-- Tolerates the old code: nothing deployed writes org_settings.sms_provider or
-- sms_messages.provider, so the constraint below can refuse nothing that is
-- being sent today, and the new column default is what the old code already
-- gets when it inserts a row - 'GoHighLevel', until Admin moves the switch.

alter table public.org_settings
  add column if not exists sms_provider text not null default 'ghl';

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.org_settings'::regclass and conname = 'org_settings_sms_provider'
  ) then
    alter table public.org_settings
      add constraint org_settings_sms_provider
      check (sms_provider in ('ghl', 'twilio'));
  end if;
end $$;

comment on column public.org_settings.sms_provider is
  'Which carrier the practice texts and calls through: ghl or twilio. Admin sets it on Admin → System; lib/text-provider.ts is the only code that reads it.';

/**
 * The column has to be granted by name.
 *
 * `org_settings` carries column grants rather than a table grant, so a column
 * added without this line is a column the application cannot read - and
 * `select` of the others goes on working, which is what makes it quiet
 * (the `select *` lesson, 0282).
 */
grant select (sms_provider) on public.org_settings to authenticated;
grant update (sms_provider) on public.org_settings to authenticated;

-- ── 2. what the switch says ──────────────────────────────────

/**
 * Read as the owner of this function, not as whoever is asking.
 *
 * The sweeps read it as the service role and a member of staff reads it from
 * a screen, and both have to get the same answer: a text that went through
 * one carrier while the record says the other is a text nobody can trace.
 * It is a setting and not client data, so there is nothing here RLS was
 * protecting.
 */
create or replace function public.sms_provider()
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce((select sms_provider from public.org_settings where id = true), 'ghl')
$$;

comment on function public.sms_provider() is
  'Which carrier is live: ghl or twilio. Falls back to ghl, because the carrier that has been sending for a year is the safer answer when the row cannot be read.';

/**
 * The same answer in the ledger's own words.
 *
 * `sms_messages.provider` has said 'GoHighLevel' on every one of its rows
 * since 0050, and a column that suddenly says 'ghl' would make the history
 * read as two different things. This is the column's default from here on, so
 * every message - sent from a screen, from a sweep, or arriving on the
 * webhook - records the carrier that carried it, and no sending code had to
 * be changed to make that true.
 */
create or replace function public.sms_provider_name()
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select case public.sms_provider() when 'twilio' then 'Twilio' else 'GoHighLevel' end
$$;

revoke all on function public.sms_provider() from anon, public;
revoke all on function public.sms_provider_name() from anon, public;
grant execute on function public.sms_provider() to authenticated, service_role;
grant execute on function public.sms_provider_name() to authenticated, service_role;

alter table public.sms_messages
  alter column provider set default public.sms_provider_name();

-- ── 3. the status words, and whose name is on them ───────────

/**
 * What the provider now says about a message it took (0287, amended).
 *
 * Two changes, both of them about the carrier moving.
 *
 * Twilio's outbound statuses include `sending` and `receiving`, which this
 * knew nothing about - and a word it does not know is deliberately not
 * guessed at, so a text mid-flight would have come back as "this does not
 * know" and sat on Sent for ever. They mean the same as `queued`: taken, not
 * yet delivered.
 *
 * And the two sentences a person can read named GoHighLevel. One of them is
 * returned to a webhook and the other is written onto the message as its
 * error, where staff see it. Neither should name a company the practice may
 * have left this morning, so both say "the provider" - which stays true
 * whichever carrier is live, and reads the same on a row from either.
 *
 * Nothing else about it moves: the mapping is still refused rather than
 * guessed, a status for a message nobody has a row for is still not an
 * error, and Delivered is still final.
 */
create or replace function public.record_text_status(
  p_provider_id text,
  p_status      text,
  p_error       text default null,
  p_payload     jsonb default null
)
returns table(matched boolean, status text)
language plpgsql security definer set search_path = public as $$
declare
  m        public.sms_messages;
  v_word   text := lower(btrim(coalesce(p_status, '')));
  v_status text;
begin
  if coalesce(btrim(coalesce(p_provider_id, '')), '') = '' then
    raise exception 'That status has no message id on it, so there is nothing to put it against.'
      using errcode = 'check_violation';
  end if;

  -- The provider's words, in ours. Anything unrecognised is not guessed at:
  -- a word nobody has seen before must not quietly read as a failure and
  -- tell somebody a text did not go.
  v_status := case
    when v_word in ('delivered', 'read') then 'Delivered'
    when v_word in ('sent', 'accepted', 'queued', 'pending', 'scheduled', 'sending', 'receiving')
      then 'Sent'
    when v_word in ('failed', 'undelivered', 'error', 'rejected', 'bounced') then 'Failed'
    else null
  end;

  if v_status is null then
    return query select false, format('the provider said %L, which this does not know', v_word)::text;
    return;
  end if;

  select * into m from public.sms_messages
   where provider_message_id = p_provider_id and direction = 'Outgoing'
   order by created_at desc limit 1;

  -- A status for a message the practice has no row for is not an error. It is
  -- a text sent from the provider's own screens, and a 400 here would have
  -- them retrying it for ever.
  if m.id is null then
    return query select false, 'no text on file carries that receipt'::text;
    return;
  end if;

  if m.status = 'Delivered' then
    return query select true, m.status;
    return;
  end if;

  update public.sms_messages
     set status = v_status,
         sent_at = coalesce(sent_at, now()),
         error = case when v_status = 'Failed'
                      then left(coalesce(nullif(btrim(coalesce(p_error, '')), ''),
                                         'The provider reported the message failed.'), 300)
                      else '' end,
         provider_payload = coalesce(p_payload, provider_payload)
   where id = m.id;

  return query select true, v_status;
end $$;

revoke all on function public.record_text_status(text, text, text, jsonb) from anon, authenticated;

-- ── and the rules asked of themselves ────────────────────────

do $$
declare v_n integer; v_text text;
begin
  -- One signature each, or a defaulted parameter has quietly made a second
  -- function that nobody revoked anything from (0366).
  for v_text in select unnest(array['sms_provider', 'sms_provider_name', 'record_text_status']) loop
    select count(*) into v_n from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = v_text;
    if v_n <> 1 then
      raise exception '% exists at % signatures, not one', v_text, v_n;
    end if;
  end loop;

  select count(*) into v_n from information_schema.routine_privileges
   where routine_schema = 'public'
     and routine_name in ('sms_provider', 'sms_provider_name', 'record_text_status')
     and grantee in ('anon', 'public');
  if v_n <> 0 then
    raise exception 'the provider switch or the status recorder can be called by anon';
  end if;

  if public.sms_provider() <> 'ghl' then
    raise exception 'the switch starts on %, and it has to start where the practice already is', public.sms_provider();
  end if;
  if public.sms_provider_name() <> 'GoHighLevel' then
    raise exception 'the ledger would stamp % on a message today', public.sms_provider_name();
  end if;

  select pg_get_functiondef(p.oid) into v_text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'record_text_status';
  if v_text like '%GoHighLevel%' then
    raise exception 'record_text_status still names GoHighLevel in a sentence somebody reads';
  end if;

  select count(*) into v_n from information_schema.column_privileges
   where table_schema = 'public' and table_name = 'org_settings'
     and column_name = 'sms_provider' and grantee = 'authenticated'
     and privilege_type in ('SELECT', 'UPDATE');
  if v_n <> 2 then
    raise exception 'authenticated has % of the two grants on sms_provider, so a screen cannot read or set it', v_n;
  end if;

  raise notice 'ok  the switch is a setting, it starts on GoHighLevel, and the status words cover both carriers';
end $$;
