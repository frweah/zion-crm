-- Zion Vocational Rehab CRM — a warrant accounts for every dollar on it
--
-- Warrant F15677921, 3 November 2026, $2,610.00, arrived today and was read
-- by the agent at 50% confidence. One of its two lines came out as an amount
-- and nothing else — no voucher, no V-number — and the other was not seen at
-- all. The page said so and waited, which is the design working.
--
-- What was missing is what a person can do about it. The review screen offers
-- two answers, "record this line" and "set it aside", and both are about a
-- line the reader found. Neither helps where the reader found half a stub:
-- the $360 line had nowhere to be entered, and recording the $2,250 line on
-- its own would have turned the page green with $360 of the warrant nowhere
-- in the practice's books.
--
-- So two things are added. A person reading the page image can **add a line
-- the reader missed** and **correct the figures on a line it read wrong** —
-- and in both cases the line goes back to waiting, because supplying what the
-- stub says is not the same as deciding what it pays. The database still
-- checks the V-number against the authorizations on file, still checks the
-- amount against what the authorization comes to, and still refuses the same
-- line twice. `raw` is never touched: it is what the reader saw, and it is the
-- evidence that a correction was a correction.
--
-- And the gap that let the page go green is closed one level up, where it
-- belongs. A page's lines adding up to the page total is the wrong question —
-- a stub scanned twice gives two pages, and either copy may be read in part.
-- The real rule is about the warrant: **the money recorded against a warrant
-- number comes to that warrant's total.** That holds for all 208 warrants
-- this practice has read, and it held before today: F15677921 is the first and
-- only one it has ever failed for. `warrants_not_accounted_for` asks it, and
-- the warrants screen shows the answer.

begin;

-- ── a line the reader missed ─────────────────────────────────

create or replace function public.add_warrant_line(
  p_page uuid,
  p_voucher text,
  p_invoice_ref text,
  p_client_code text,
  p_client_name text,
  p_service_date date,
  p_amount numeric
) returns uuid
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_page  public.warrant_pages%rowtype;
  v_staff uuid := public.current_staff_id();
  v_name  text;
  v_no    integer;
  v_line  uuid;
begin
  if (public.current_staff_role() is null or public.current_staff_role() not in ('Admin', 'Billing'))
     and not public.staff_has_area('billing', 'edit') then
    raise exception 'Only Admin and Billing add a line to a warrant page.'
      using errcode = 'insufficient_privilege';
  end if;

  select * into v_page from public.warrant_pages where id = p_page for update;
  if not found then
    raise exception 'That warrant page does not exist.' using errcode = 'no_data_found';
  end if;
  if v_page.status = 'Not a warrant' then
    raise exception 'That page is not a warrant stub.' using errcode = 'check_violation';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'Give the amount on the line, as the stub prints it.' using errcode = 'check_violation';
  end if;
  if coalesce(btrim(p_invoice_ref), '') = '' then
    raise exception 'Give the V-number on the line.' using errcode = 'check_violation';
  end if;

  -- A line already on the page for this authorization and this amount is the
  -- one being looked at, not a new one. Caught here rather than left to the
  -- duplicate rule further on, so the person gets a sentence about the page
  -- in front of them instead of one about payments.
  if exists (select 1 from public.warrant_lines l
              where l.page_id = p_page
                and public.normalize_auth_number(l.invoice_ref) = public.normalize_auth_number(p_invoice_ref)
                and l.amount = p_amount) then
    raise exception 'That line is already on this page.' using errcode = 'unique_violation';
  end if;

  select coalesce(max(l.line_no), 0) + 1 into v_no
    from public.warrant_lines l where l.page_id = p_page;
  select name into v_name from public.staff where id = v_staff;

  insert into public.warrant_lines
    (page_id, line_no, raw, dept, voucher, invoice_ref, described_ref,
     client_code, client_name, service_date, described_amount, amount,
     status, problem, decided_by, decided_by_name, decided_at)
  values
    (p_page, v_no,
     -- Said plainly in the column a person reads first. The OCR's own reading
     -- of the page is in warrant_pages.ocr_text and is not overwritten; this
     -- line has no reading of its own because the reader never found it.
     format('Added from the page image by %s', coalesce(v_name, 'a member of staff')),
     '', upper(btrim(coalesce(p_voucher, ''))),
     public.normalize_auth_number(p_invoice_ref),
     public.normalize_auth_number(p_invoice_ref),
     btrim(coalesce(p_client_code, '')), btrim(coalesce(p_client_name, '')),
     p_service_date, p_amount, p_amount,
     'Needs review', 'Added from the page image — not yet matched.',
     v_staff, coalesce(v_name, ''), now())
  returning id into v_line;

  update public.warrant_pages pg
     set lines_total = (select sum(l.amount) from public.warrant_lines l where l.page_id = pg.id),
         status = 'Needs review'
   where pg.id = p_page;

  return v_line;
end;
$$;

comment on function public.add_warrant_line is
  'A payment line on a warrant stub that the reader did not find, entered by '
  'somebody looking at the page image. The line waits for review like any '
  'other: supplying what the stub says is not deciding what it pays.';

revoke all on function public.add_warrant_line(uuid, text, text, text, text, date, numeric)
  from public, anon, authenticated;
grant execute on function public.add_warrant_line(uuid, text, text, text, text, date, numeric)
  to authenticated;

-- ── figures the reader got wrong ─────────────────────────────

create or replace function public.correct_warrant_line(
  p_line uuid,
  p_voucher text,
  p_invoice_ref text,
  p_client_code text,
  p_client_name text,
  p_service_date date,
  p_amount numeric
) returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_line  public.warrant_lines%rowtype;
  v_staff uuid := public.current_staff_id();
  v_name  text;
begin
  if (public.current_staff_role() is null or public.current_staff_role() not in ('Admin', 'Billing'))
     and not public.staff_has_area('billing', 'edit') then
    raise exception 'Only Admin and Billing correct a warrant line.'
      using errcode = 'insufficient_privilege';
  end if;

  select * into v_line from public.warrant_lines where id = p_line for update;
  if not found then
    raise exception 'That warrant line does not exist.' using errcode = 'no_data_found';
  end if;

  -- A line that has already paid something is history. Changing the figures
  -- under a payment would leave the payment saying one thing and the line it
  -- came from saying another, and the payment is the record.
  if v_line.status <> 'Needs review' then
    raise exception 'That line is %, so its figures are part of a payment now.', lower(v_line.status)
      using errcode = 'check_violation', hint = 'Set it aside and add the line again if the reading was wrong.';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'Give the amount on the line, as the stub prints it.' using errcode = 'check_violation';
  end if;
  if coalesce(btrim(p_invoice_ref), '') = '' then
    raise exception 'Give the V-number on the line.' using errcode = 'check_violation';
  end if;

  select name into v_name from public.staff where id = v_staff;

  update public.warrant_lines
     set voucher = upper(btrim(coalesce(p_voucher, ''))),
         invoice_ref = public.normalize_auth_number(p_invoice_ref),
         described_ref = public.normalize_auth_number(p_invoice_ref),
         client_code = btrim(coalesce(p_client_code, '')),
         client_name = btrim(coalesce(p_client_name, '')),
         service_date = p_service_date,
         described_amount = p_amount,
         amount = p_amount,
         problem = format('Read from the page image by %s.', coalesce(v_name, 'a member of staff')),
         decided_by = v_staff,
         decided_by_name = coalesce(v_name, ''),
         decided_at = now()
   where id = p_line;

  update public.warrant_pages pg
     set lines_total = (select sum(l.amount) from public.warrant_lines l where l.page_id = pg.id)
   where pg.id = v_line.page_id;
end;
$$;

comment on function public.correct_warrant_line is
  'The figures on a warrant line as somebody reads them off the page image, '
  'where the reader got them wrong. The line stays waiting for review, and '
  'raw keeps what the reader saw.';

revoke all on function public.correct_warrant_line(uuid, text, text, text, text, date, numeric)
  from public, anon, authenticated;
grant execute on function public.correct_warrant_line(uuid, text, text, text, text, date, numeric)
  to authenticated;

-- ── and the warrant that does not add up ─────────────────────

create or replace function public.warrants_not_accounted_for()
returns table(warrant_no text, warrant_date date, total numeric, recorded numeric,
              gap numeric, pages integer, lines integer)
language sql
stable
security definer
set search_path to 'public'
as $$
  select * from (
    with stub as (
      -- One warrant, however many times its stub was scanned. The total is
      -- the same figure on every copy; max() picks it without caring which
      -- copy was read best.
      select p.warrant_no,
             max(p.total) as total,
             min(p.warrant_date) as warrant_date,
             count(distinct p.id)::int as pages,
             (select count(*) from public.warrant_lines l
               join public.warrant_pages q on q.id = l.page_id
              where q.warrant_no = p.warrant_no)::int as lines
        from public.warrant_pages p
       where p.warrant_no <> '' and p.total is not null and p.status <> 'Not a warrant'
       group by p.warrant_no
    ),
    money as (
      select y.warrant_no, sum(y.amount) as recorded
        from public.payments y where y.warrant_no <> '' group by y.warrant_no
    )
    select stub.warrant_no, stub.warrant_date, stub.total,
           coalesce(money.recorded, 0), stub.total - coalesce(money.recorded, 0),
           stub.pages, stub.lines
      from stub left join money on money.warrant_no = stub.warrant_no
     -- A cent, because a stub prints cents and a rate does not always divide.
     where abs(stub.total - coalesce(money.recorded, 0)) > 0.005
     order by stub.warrant_date desc, stub.warrant_no
  ) as rows_for_staff
   where public.reader_may_answer();
$$;

comment on function public.warrants_not_accounted_for is
  'Warrants where the money recorded against the number does not come to the '
  'warrant total. A stub read in part leaves money the practice was paid and '
  'has not written down, and nothing else was asking.';

revoke all on function public.warrants_not_accounted_for() from public, anon;
grant execute on function public.warrants_not_accounted_for() to authenticated, service_role;

commit;

-- ════════════════════════════════════════════════════════════
-- Warrant F15677921, from the stub
--
-- On the owner's instruction of 9 November 2026, with the figures he read off
-- the stub. The agent read the page; these are the two lines on it:
--
--   6006  27AW00000096031  V1037901A / 954423-C Sample-V1037901-360.00     360.00
--   6006  27AW00000096109  V1037898  / 955515-C Sample-V1037898-2250.00  2,250.00
--
-- (The surname on the stub is the client's. It is in the database, where it
-- belongs; the stand-in here is the one lib/warrant-parse.ts uses in its own
-- worked example. Both lines are the same client.)
--
-- The reader found the second as an amount alone — "2,250.90", no voucher, no
-- V-number — and did not find the first at all. The vouchers are his reading;
-- the OCR has 27AW0000009610**3** for the second and he has ...**9**, and the
-- paper is in front of him.
--
-- Nothing below records a payment. The two lines are put on the page as the
-- stub prints them, and then the ordinary reconciliation decides: it checks
-- each V-number against the authorizations on file, checks each amount
-- against what the authorization comes to, and finds the $2,250 already
-- recorded by hand on 6 November — which is how that payment gets the warrant
-- number, date and voucher it was entered without.
--
-- The V-number is entered without the claim suffix the stub prints before
-- the slash. The suffix is USOR's claim letter, not part of the
-- authorization: no authorization in this practice carries one, and the
-- matching looks the number up as it is given. Which claim the line pays is
-- on the line already, in the invoice number and the letter after it.
-- ════════════════════════════════════════════════════════════

begin;

do $$
declare
  v_page  uuid;
  v_line  uuid;
  v_added uuid;
  v_counts record;
  v_gap    numeric;
  v_who    text;
begin
  -- As the owner, because reading a stub is something a person does and the
  -- line records who did it.
  perform set_config('request.jwt.claims',
                     json_build_object('sub', '00cd300a-b606-4cab-9413-dbb2082f8f07',
                                       'role', 'authenticated')::text, true);

  select p.id into v_page
    from public.warrant_pages p
   where p.warrant_no = 'F15677921'
   order by p.received_at
   limit 1;
  -- The name the stub prints, taken from the record rather than written
  -- down here: no client is named in this repository.
  select c.name into v_who
    from public.clients c
    join public.authorizations a on a.client_id = c.id
   where a.number = 'V1037898';

  if v_page is null then
    raise exception 'Warrant F15677921 is not in the practice yet — the agent reads it first.';
  end if;

  select l.id into v_line
    from public.warrant_lines l
   where l.page_id = v_page and l.status = 'Needs review' and l.amount = 2250.90;

  if v_line is not null then
    perform public.correct_warrant_line(
      v_line, '27AW00000096109', 'V1037898', '955515', coalesce(v_who, ''), null, 2250.00);
  end if;

  if not exists (select 1 from public.warrant_lines l
                  where l.page_id = v_page
                    and public.normalize_auth_number(l.invoice_ref) = 'V1037901') then
    v_added := public.add_warrant_line(
      v_page, '27AW00000096031', 'V1037901', '954423', coalesce(v_who, ''), null, 360.00);
  end if;

  -- The agent's own role for the matching, which is what does the matching
  -- every other day of the week.
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  select * into v_counts from public.reconcile_warrant_page(v_page);
  raise notice 'F15677921: % reconciled, % already recorded, % still to review',
    v_counts.reconciled, v_counts.already_recorded, v_counts.needs_review;

  if v_counts.needs_review <> 0 then
    raise exception 'Warrant F15677921 still has % line(s) waiting — nothing has been changed.',
      v_counts.needs_review;
  end if;

  select w.gap into v_gap from public.warrants_not_accounted_for() w
   where w.warrant_no = 'F15677921';
  if v_gap is not null then
    raise exception 'F15677921 totals 2610.00 and % is recorded against it.', 2610.00 - v_gap;
  end if;

  perform set_config('request.jwt.claims', '', true);
end $$;

commit;
