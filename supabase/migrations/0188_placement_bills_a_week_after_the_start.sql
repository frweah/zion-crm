-- Zion Vocational Rehab CRM — a placement bills a week after the start
--
-- Owner decision, 10 Oct 2026, amending Rule 8: a Job Placement
-- authorization's bill-by is the hire date plus **seven** days, not
-- twenty-eight. The four-week milestone stays, as Rei's retention check, and
-- is no longer anything to do with billing.
--
-- Two separate clocks that used to be the same number, which is why they were
-- easy to confuse:
--
--   bill-by, now +7. When the practice means to have the bill out.
--   the retention milestone, still +28. When somebody looks at whether the
--   placement held.
--
-- bill_by_for reads this table, and placement_clock_started computes bill-by
-- through bill_by_for rather than writing a number - so changing the row here
-- is what changes the behaviour. The function is touched only to say, in
-- words, that its 28 is the milestone and not the billing.

update public.bill_by_defaults
   set days = 7,
       note = 'USOR 60 + 92. Bill within a week of the start; the four-week check is Rei''s, not billing''s.'
 where service in ('Job Placement', 'Job Placement (SE)');

-- The column comment named the old number, and a comment that lies is worse
-- than none.
comment on column public.bill_by_defaults.anchor is
  'What the days are counted from: received (the day the form reached the practice), month_end (the month a coaching child covers), first_work_day (Job Placement, from the client''s first day), placement (HQI riding on a placement).';

do $$
declare r record;
begin
  for r in
    select service, anchor, days from public.bill_by_defaults
     where service in ('Job Placement', 'Job Placement (SE)') order by service
  loop
    raise notice '% bills % day(s) after %', r.service, r.days, r.anchor;
  end loop;
end $$;
