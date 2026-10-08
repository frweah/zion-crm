-- Zion Vocational Rehab CRM — a counselor is reached one way
-- (Billing Simplification Brief §11)
--
-- "Client, counselor, billing office, service, rate, dates, hours are entered
-- once and read everywhere."
--
-- `clients.counselor_contact` is a free-text box on the client's profile for
-- how to reach their counselor. The counselor's own record already holds the
-- phone, the fax and the email, so this is the same fact written a second time
-- - and the duplication audit found the two disagreeing.
--
-- Looked at closely, twelve clients carry one. Every value is a phone number,
-- and none of them contains an email address. Compared on the last ten digits:
--
--   eight are the counselor's own number written in a different format -
--   8014462560 against (801) 446-2560 - and say nothing new;
--   two are the only record anywhere of one counselor's phone number, because
--   their counselor record has none;
--   one carries a fax number the counselor record does not have;
--   and two are truncated to nine digits, which is not a phone number at all.
--
-- So the column is not simply deleted: what is only written here is moved onto
-- the counselor first, and only then does the box go. The truncated ones are
-- left behind deliberately - a nine-digit number is not a number, and the
-- counselors in question both have a complete one on their own record.
--
-- No client names or numbers appear below. Everything is matched on the data.

-- ── what is only written on the client ──

/**
 * A phone number for a counselor who has none.
 *
 * Only where the client's box holds a full ten digits, and only where the
 * counselor record is empty - this fills a gap, it never overwrites. Where
 * several clients of one counselor disagree, the longest value wins, which is
 * the one that was not cut short.
 */
with digits as (
  select c.counselor_id,
         right(regexp_replace(c.counselor_contact, '[^0-9]', '', 'g'), 10) as ten,
         length(regexp_replace(c.counselor_contact, '[^0-9]', '', 'g')) as how_many
    from public.clients c
   where c.counselor_id is not null
     and nullif(btrim(c.counselor_contact), '') is not null
),
best as (
  select distinct on (counselor_id) counselor_id, ten
    from digits
   where how_many >= 10
   order by counselor_id, how_many desc
)
update public.counselors k
   set phone = '(' || substr(b.ten, 1, 3) || ') ' || substr(b.ten, 4, 3) || '-' || substr(b.ten, 7, 4)
  from best b
 where k.id = b.counselor_id
   and coalesce(nullif(btrim(k.phone), ''), '') = '';

/**
 * A fax number, where the client's box mentions one and the counselor has none.
 *
 * The box is free text, so a fax arrives written as "... · fax (801) 254-7200".
 * Taking the digits after the word is reading what somebody wrote; guessing
 * which of two numbers is the fax would not be.
 */
with faxes as (
  select distinct on (c.counselor_id) c.counselor_id,
         right(regexp_replace(
           substring(c.counselor_contact from 'fax[^0-9]*([0-9().+ -]{10,})'),
           '[^0-9]', '', 'g'), 10) as ten
    from public.clients c
   where c.counselor_id is not null
     and c.counselor_contact ~* 'fax'
   order by c.counselor_id
)
update public.counselors k
   set fax = '(' || substr(f.ten, 1, 3) || ') ' || substr(f.ten, 4, 3) || '-' || substr(f.ten, 7, 4)
  from faxes f
 where k.id = f.counselor_id
   and length(f.ten) = 10
   and coalesce(nullif(btrim(k.fax), ''), '') = '';

-- ── and then the second copy goes ──

alter table public.clients drop column if exists counselor_contact;
