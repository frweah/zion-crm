-- Zion Vocational Rehab CRM — Needs review asks the record, not the reader
--
-- Owner, 19 November 2026, on Admin → Warrants › Needs review:
--
--   "(1) collapse repeated scans of the same stub to one line; (2) a line
--   whose authorization and amount match a recorded payment exactly is
--   auto-accepted as 'matches payment on record' and leaves the queue -
--   nothing new is written, the line is just no longer a question; (3) a claim
--   letter (V1002111A-D) matches against its base authorization's payments;
--   (4) what remains is the real queue, with the reason each line is there."
--
-- What the queue was, and why it read 102 lines for $129,505 when $2,835 was
-- in question:
--
--   `reconcile_warrant_line` decides a page's problems before it looks for
--   the money. A page whose lines do not add up to its printed total, or whose
--   total was never read, stops every line on it with the page's reason - and
--   the matching that would have recognised the payment already on record sits
--   below that gate and never runs. So 95 of the 102 were money the practice
--   had written down months earlier, waiting to be asked about.
--
--   And the same stub arrives more than once: a standalone PDF named for one
--   client, then the same page inside a multi-page scan. Each copy is read
--   again and each copy's lines queue again. 102 readings were 62 stub lines.
--
-- So the queue is a question, and a question is asked of the records rather
-- than carried on a flag somebody has to clear. `warrant_review_queue` asks
-- it: one row per stub line however many scans read it, with whether a
-- payment on file already accounts for it, and if not, the one thing that is
-- unknown about it.
--
-- Nothing is written. A line whose money is on the record keeps its own
-- status - the reader's record of what it concluded - and simply is not a
-- question any more. Take that payment back and the line is a question again,
-- which a cleared flag could never manage.

-- ── the queue ────────────────────────────────────────────────

-- Dropped rather than replaced: adding a column to what a function returns
-- changes its return type, and `create or replace` refuses that. The grant
-- below goes with it, because a drop takes the grants with it.
drop function if exists public.warrant_review_queue();

create or replace function public.warrant_review_queue()
returns table(
  key          text,
  warrant_no   text,
  warrant_date date,
  page_id      uuid,
  image_path   text,
  line_id      uuid,
  line_ids     uuid[],
  line_no      integer,
  raw          text,
  client_name  text,
  voucher      text,
  service_date date,
  readings     integer,
  scans        text[],
  ref          text,
  base_ref     text,
  claim        text,
  auth_id      uuid,
  auth_number  text,
  amount       numeric,
  read_as      numeric[],
  settled      boolean,
  payment_id   uuid,
  why          text,
  page_why     text
)
language sql
stable
security definer
set search_path to 'public'
as $$
  with reading as (
    select l.id, l.page_id, l.line_no, l.amount, l.described_amount, l.problem,
           l.raw, l.client_name, l.voucher as voucher_text, l.service_date,
           p.warrant_no, p.warrant_date, p.image_path, p.ocr_confidence,
           d.filename,
           /*
            * The line's V-number, normalised. The stub prints it twice - once
            * before the slash and once inside the description - and either
            * copy can be the one OCR got. The copy before the slash is
            * preferred because it carries the claim letter.
            */
           public.normalize_auth_number(
             coalesce(nullif(btrim(l.invoice_ref), ''), l.described_ref)) as ref,
           public.normalize_auth_number(l.voucher) as voucher_key
      from public.warrant_lines l
      join public.warrant_pages p on p.id = l.page_id
      join public.warrant_documents d on d.id = p.document_id
     where l.status = 'Needs review'
       and p.status <> 'Not a warrant'
  ),
  keyed as (
    /*
     * One stub line, however many scans read it.
     *
     * The warrant number's digits and the V-number read off the line. Not the
     * page, not the document, not the line number: the same stub inside two
     * scans lands on different page rows at different line numbers, and that
     * is exactly the duplication this collapses.
     *
     * The voucher is the fallback where no V-number could be read at all, and
     * the line's own id where even that is blank - a line nothing identifies
     * cannot be proved to be another line, so it stands alone.
     *
     * And the copy number, because two lines on one page for the same
     * authorization are two lines. The state bills a repeat claim against the
     * same authorization and prints each claim on its own line, so one stub
     * can carry two of them for the same money; collapsing those would make
     * half a warrant disappear. The nth such line on one page pairs with the
     * nth on another.
     */
    select r.*,
           coalesce(nullif(regexp_replace(r.warrant_no, '[^0-9]', '', 'g'), ''), '?')
             || '/'
             || case when r.ref <> '' then r.ref
                     when r.voucher_key <> '' then 'voucher:' || r.voucher_key
                     else 'line:' || r.id::text end
             || '#'
             || row_number() over (
                  partition by r.page_id,
                               case when r.ref <> '' then r.ref
                                    when r.voucher_key <> '' then 'voucher:' || r.voucher_key
                                    else 'line:' || r.id::text end
                  order by r.line_no) as key
      from reading r
  ),
  figure as (
    /*
     * Every figure any scan read for this line - the amount column and the
     * amount written in the description, from each copy.
     *
     * One figure and the line's amount is known. Two and it is not, and that
     * is the line's question: F15390381's second line was read as 27,250.00
     * on one scan, 2,290.00 on another, and 2,250.00 in both descriptions.
     * Taking the description over the column, or the column over the
     * description, would have settled six lines against a figure nobody had
     * checked - including the 900.00 on F15617525, which is money that
     * belongs to no authorization and must not quietly become 2,250.00.
     */
    select k.key, array_agg(distinct f order by f) as read_as
      from keyed k, unnest(array[k.amount, k.described_amount]) as f
     where f is not null
     group by k.key
  ),
  grp as (
    select k.key,
           max(k.warrant_no)   as warrant_no,
           max(k.warrant_date) as warrant_date,
           max(k.ref)          as ref,
           count(*)::int       as readings,
           array_agg(distinct k.filename) as scans,
           -- The clearest reading is the one shown and the one acted on: its
           -- page image is the one worth looking at.
           (array_agg(k.page_id    order by k.ocr_confidence desc nulls last, k.line_no))[1] as page_id,
           (array_agg(k.image_path order by k.ocr_confidence desc nulls last, k.line_no))[1] as image_path,
           (array_agg(k.id         order by k.ocr_confidence desc nulls last, k.line_no))[1] as line_id,
           (array_agg(k.problem    order by k.ocr_confidence desc nulls last, k.line_no))[1] as page_why,
           (array_agg(k.line_no    order by k.ocr_confidence desc nulls last, k.line_no))[1] as line_no,
           (array_agg(k.raw        order by k.ocr_confidence desc nulls last, k.line_no))[1] as raw,
           (array_agg(k.client_name  order by k.ocr_confidence desc nulls last, k.line_no))[1] as client_name,
           (array_agg(k.voucher_text order by k.ocr_confidence desc nulls last, k.line_no))[1] as voucher_text,
           (array_agg(k.service_date order by k.ocr_confidence desc nulls last, k.line_no))[1] as service_date,
           array_agg(k.id order by k.ocr_confidence desc nulls last, k.line_no) as line_ids
      from keyed k
     group by k.key
  ),
  named as (
    /*
     * The claim letter is the state's claim sequence, not part of the
     * authorization number (0299). V1002111A-D are four claims billed against
     * V1002111, and the payments sit on V1002111 carrying their letter - so a
     * line reading V1002111C is matched against V1002111's payments.
     *
     * The letter is not required to match. The stub prints it before the
     * slash and not in the description, so a scan that lost the first copy
     * reads the base number for a claim line; and a payment entered from a
     * remittance may carry no letter at all. Four of the lines settled here
     * are one of those two shapes, and comparing letters would have asked
     * about all four.
     */
    select g.*,
           f.read_as,
           case when array_length(f.read_as, 1) = 1 then f.read_as[1] end as amount,
           case when g.ref ~ '^V[0-9]+[A-Z]$' then left(g.ref, length(g.ref) - 1)
                else g.ref end as base_ref,
           case when g.ref ~ '^V[0-9]+[A-Z]$' then right(g.ref, 1) end as claim
      from grp g
      left join figure f on f.key = g.key
  ),
  placed as (
    select n.*, a.id as auth_id, a.number as auth_number
      from named n
      left join public.authorizations a
        on public.normalize_auth_number(a.number) = n.base_ref
  ),
  want as (
    select p.key, p.auth_id, p.amount, p.warrant_date,
           row_number() over (partition by p.auth_id, p.amount
                              order by p.warrant_date nulls last, p.key) as nth
      from placed p
     where p.auth_id is not null and p.amount is not null
  ),
  have as (
    select pay.id, pay.auth_id, pay.amount,
           row_number() over (partition by pay.auth_id, pay.amount
                              order by pay.warrant_date nulls last, pay.created_at) as nth
      from public.payments pay
  ),
  vouched as (
    /*
     * A payment accounts for one line, not for every line that reads the same
     * figure.
     *
     * Two claims against one authorization for the same money are two
     * payments and two lines, and "a payment exists for this amount" would
     * let one of them answer for both - which is how a warrant comes to look
     * accounted for while half of it is unrecorded. So the lines wanting a
     * figure are numbered, the payments holding it are numbered, and they are
     * matched one to one. A third line with no third payment stays a
     * question.
     */
    select w.key, h.id as payment_id
      from want w
      join have h
        on h.auth_id = w.auth_id and h.amount = w.amount and h.nth = w.nth
  )
  select p.key, p.warrant_no, p.warrant_date, p.page_id, p.image_path,
         p.line_id, p.line_ids, p.line_no, p.raw, p.client_name,
         p.voucher_text, p.service_date, p.readings, p.scans,
         p.ref, p.base_ref, p.claim, p.auth_id, p.auth_number,
         p.amount, p.read_as,
         v.payment_id is not null as settled,
         v.payment_id,
         /*
          * And what is unknown about it, in the order it has to be answered:
          * the amount, then whose it is, then whether the record agrees.
          * One of them, not the page's reason - a page whose total does not
          * add up is a question about the page, and it is asked on "Does not
          * add up" where it belongs.
          */
         case
           when v.payment_id is not null then ''
           when p.read_as is null then
             'No amount was read on this line - take it off the page image.'
           when p.amount is null then
             format('Read as %s - say which off the page image.',
                    array_to_string(
                      array(select '$' || to_char(x, 'FM999,999,990.00')
                              from unnest(p.read_as) as x),
                      ', '))
           when p.auth_id is null then
             format('%s is not an authorization on file.', p.ref)
           -- The figure is on the record and another line has it. One payment
           -- answers for one line, so this one is either a second claim the
           -- practice has not recorded or the same line printed twice.
           when exists (select 1 from public.payments pay
                         where pay.auth_id = p.auth_id and pay.amount = p.amount) then
             format('A payment of $%s on %s already answers for another line - check whether the stub pays it twice.',
                    to_char(p.amount, 'FM999,999,990.00'),
                    coalesce(nullif(p.auth_number, ''), p.ref))
           when not exists (select 1 from public.payments pay where pay.auth_id = p.auth_id) then
             format('%s has no payment on file - record this line against it.',
                    coalesce(nullif(p.auth_number, ''), p.ref))
           else
             format('%s holds %s and this line pays $%s - check which the stub says.',
                    coalesce(nullif(p.auth_number, ''), p.ref),
                    (select string_agg('$' || to_char(pay.amount, 'FM999,999,990.00'), ', '
                                       order by pay.amount)
                       from public.payments pay where pay.auth_id = p.auth_id),
                    to_char(p.amount, 'FM999,999,990.00'))
         end as why,
         p.page_why
    from placed p
    left join vouched v on v.key = p.key
   where public.warrant_hands()
   order by p.warrant_date desc nulls last, p.warrant_no, p.ref;
$$;

comment on function public.warrant_review_queue is
  'Warrant lines still a question, one row per stub line however many scans '
  'read it, with whether a payment already on file accounts for it and, if '
  'not, the one thing that is unknown. Asks the records rather than a flag: '
  'nothing is written, and taking a payment back makes its line a question '
  'again (0376).';

revoke all on function public.warrant_review_queue() from public, anon;
grant execute on function public.warrant_review_queue() to authenticated;
