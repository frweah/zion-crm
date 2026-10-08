-- Zion Vocational Rehab CRM — the 1099 tie-out follows the reversals
-- (ERP brief, Controls: "1099 tie-out equals payables")
--
-- The tie-out compares three things for a year: what the operational records
-- say was paid, what the ledger posted, and what was filed on the 1099. Its
-- whole value is that a difference means something.
--
-- It counted the ledger side by naming the payment kinds - 'Contractor payment'
-- and 'Vendor bill' with a 'Paid' event - and a reversal is neither of those.
-- reverse_journal() files it as source_kind 'Reversal' against the journal it
-- reverses, so the reversing credit was invisible to this report.
--
-- Measured: pay a vendor bill of 500 and undo it the way the books undo things,
-- and the tie-out reads recorded 0, posted 500, difference -500. A phantom, in
-- the one report somebody has to be able to trust in January.
--
-- It also decides which year a reversal belongs to, and the answer is the year
-- of the payment it undoes. The operational side already works that way - it
-- reads the bill's own paid_on, which goes back with the payment - and a
-- tie-out whose two sides answer for different years cannot balance.
--
-- This is the live definition with that one CTE widened.

create or replace function public.ledger_1099_tie_out(p_year integer)
 RETURNS TABLE(staff_id uuid, person text, recorded numeric, posted numeric, on_the_1099 numeric, difference numeric)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  with recorded as (
    select p.staff_id as payee, null::uuid as vendor, sum(p.amount) as amount
      from public.contractor_payments p
     where extract(year from p.paid_on) = p_year
     group by p.staff_id
    union all
    select null::uuid, b.vendor_id, sum(b.amount)
      from public.vendor_bills b
     where b.status = 'Paid' and extract(year from b.paid_on) = p_year
     group by b.vendor_id
  ),
  /**
   * What the ledger posted for the year, net of anything taken back.
   *
   * A reversal is not filed against the payment: reverse_journal() files it as
   * source_kind 'Reversal' against the journal it reverses, so a clause that
   * names the payment kinds excludes it. The effect was a tie-out that showed a
   * difference nobody could find - the operational record dropped the payment
   * and the ledger kept it.
   *
   * A reversal counts in the year of the payment it undoes, not the year
   * somebody got round to undoing it. The operational side works that way
   * (`recorded` reads the bill's own paid_on, which goes with the payment), and
   * a tie-out whose two sides answer for different years cannot balance.
   */
  posted as (
    select l.staff_id as payee, l.vendor_id as vendor, sum(l.debit) - sum(l.credit) as amount
      from public.journals j
      left join public.journals src on src.id = j.reverses_id
      join public.journal_lines l on l.journal_id = j.id
      join public.ledger_accounts a on a.id = l.account_id
       and a.role in ('contractor_payable', 'ap')
     where extract(year from coalesce(src.entry_date, j.entry_date)) = p_year
       and (
         (j.source_kind in ('Contractor payment', 'Vendor bill') and j.source_event like 'Paid%')
         or (j.source_kind = 'Reversal'
             and src.source_kind in ('Contractor payment', 'Vendor bill')
             and src.source_event like 'Paid%')
       )
     group by l.staff_id, l.vendor_id
  ),
  filed as (
    select r.staff_id as payee, r.vendor_id as vendor, r.nonemployee_comp as amount
      from public.form_1099_recipients r
      join public.form_1099_runs u on u.id = r.run_id
     where u.year = p_year
       and r.id = (
         select r2.id from public.form_1099_recipients r2
           join public.form_1099_runs u2 on u2.id = r2.run_id
          where u2.year = p_year
            and r2.staff_id is not distinct from r.staff_id
            and r2.vendor_id is not distinct from r.vendor_id
          order by r2.created_at desc limit 1)
  ),
  everybody as (
    select payee, vendor from recorded
    union select payee, vendor from posted
    union select payee, vendor from filed
  )
  select e.payee,
         coalesce(s.name, v.name, 'Unknown'),
         coalesce((select amount from recorded r where r.payee is not distinct from e.payee
                                                  and r.vendor is not distinct from e.vendor), 0),
         coalesce((select amount from posted p where p.payee is not distinct from e.payee
                                                 and p.vendor is not distinct from e.vendor), 0),
         coalesce((select amount from filed f where f.payee is not distinct from e.payee
                                                and f.vendor is not distinct from e.vendor), 0),
         coalesce((select amount from recorded r where r.payee is not distinct from e.payee
                                                  and r.vendor is not distinct from e.vendor), 0)
           - coalesce((select amount from posted p where p.payee is not distinct from e.payee
                                                     and p.vendor is not distinct from e.vendor), 0)
    from everybody e
    left join public.staff s on s.id = e.payee
    left join public.vendors v on v.id = e.vendor
   order by 2;
$function$;

revoke all on function public.ledger_1099_tie_out(integer) from anon, authenticated;
grant execute on function public.ledger_1099_tie_out(integer) to authenticated;
