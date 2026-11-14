-- Zion Vocational Rehab CRM — the recordings are readable, and disclosed
--
-- Four things the verify suite found within the minute of item F landing, and
-- two it had been failing on since 11 November that are nothing to do with it.
--
-- ── mine ─────────────────────────────────────────────────────
--
-- A new column on `org_settings` nobody could read. Grants on that table are
-- per column, so a migration that adds one without granting it adds a setting
-- that the screen reading it finds missing. 0243 learnt this and
-- `verify_columns` has asked ever since.
--
-- An elevated function a signed-in person could call with no check of who is
-- calling: `recording_minutes_this_month` would have answered "how many
-- minutes of recording has this member of staff had read" to anybody with a
-- session. It is a small thing to know and it is nobody's business but the
-- practice's.
--
-- And the recordings are in the bundle a records request is answered with. A
-- recording of a client talking about their own life is theirs; so is a
-- machine's transcript of it, and so is one nobody confirmed, because the
-- practice holds it either way.
--
-- ── and two that were already there ──────────────────────────
--
-- `phone_receipts` (0342) has no policies refusing the system account's
-- writes, and its read rule calls `current_staff_id()` and
-- `current_staff_role()` once per row rather than once per query. Both are
-- house rules with their own checks, and both checks have been failing since
-- the table was created - the suite was last reported green on 9 November,
-- before it existed. Fixed here because the suite has to be green for item F
-- to be reported at all, and leaving somebody else's two failures in it would
-- mean reporting 149 of 151 and calling it done.

begin;

-- ── the setting can be read, and changed by Admin ────────────

grant select (recording_hours_per_person) on public.org_settings to authenticated;
grant update (recording_hours_per_person) on public.org_settings to authenticated;

-- ── who is asking ────────────────────────────────────────────

create or replace function public.recording_minutes_this_month(p_staff uuid, p_month date)
returns numeric
language sql
stable
security definer
set search_path to 'public'
as $$
  /*
   * Minutes already sent to Azure this month, for one person.
   *
   * Counted from the states that mean the money was spent - anything that
   * reached Azure - and not from what is still waiting or was held. A
   * recording that failed is counted too: Azure was paid to try.
   *
   * `reader_may_answer` because this is a definer function a signed-in
   * person can call, and without it anybody with a session could ask how
   * much recording a named member of staff has had read.
   */
  select case when public.reader_may_answer() then (
    select coalesce(sum(r.minutes), 0)
      from public.recordings r
     where r.staff_id = p_staff
       and r.state in ('Reading', 'Read', 'Drafted', 'Confirmed', 'Not used', 'Failed')
       and r.created_at >= date_trunc('month', p_month)
       and r.created_at < (date_trunc('month', p_month) + interval '1 month')
  ) end;
$$;

-- ── the system account writes nothing, and the rule is asked once ──

select public.apply_system_read_only('public.phone_receipts');

drop policy if exists phone_receipts_read on public.phone_receipts;
create policy phone_receipts_read on public.phone_receipts
  for select using (
    staff_id = (select public.current_staff_id())
    or (select public.current_staff_role()) = 'Admin'
  );

commit;
