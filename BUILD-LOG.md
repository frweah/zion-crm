# Build log

What each block of work shipped, what was left out and why, and anything that
needs the owner. Newest at the bottom, so the file reads in the order the work
happened.

Written as each block deploys, so that picking the work up later means reading
the last entry rather than reconstructing it.

---

## Design language, step 1 — the bell, the person, Home as tiles

Deployed `e4603ec`, 5 Oct 2026.

**Shipped**

- A notifications bell in the header on every screen: unread texts, website
  chats, staff chat, mail, tasks due today or overdue, and alerts raised for
  the person's role — four tables in one list, in time order. Fetched when it
  is opened rather than polled.
- The two actions it offers are the two the dashboard already had: mark a
  conversation read, put an alert aside until tomorrow.
- An avatar menu top right: initials, name, role, their paperwork, their
  hours, sign out. These were at the foot of the sidebar among the screens.
- Home opens as tiles — work session, waiting for a reply, tasks due, today's
  appointments, caseload, alerts — one number each and a tap to the thing.
  Two columns on a phone.

**Chosen against**

- No new read-state table for the bell. It reads what the practice already
  keeps, so the bell and the screens cannot drift apart.
- Mail is wrapped so a stale Outlook token cannot empty the bell.

**Needs the owner** — nothing.

---

## Design language, step 2 — hubs, hub pages, the phone bar

Deployed `4cdf2ff`, 5 Oct 2026.

**Shipped**

- Six sidebar entries: **Home · Work · Communication · Billing · HR · Admin**.
  Work holds clients, their tasks, the jobs and the counselors;
  Communication holds mail, texts, chat, the website chat and the calendar.
- Each hub opens on a page of feature cards (`/work`, `/communication`,
  `/hr`) built from the hub's own navigation entries, so a screen added to a
  hub appears on its card page without anybody remembering to add it.
- A bottom bar on a phone — Home · Work · Communication · HR · More — with
  the unread badge on Communication. Hidden above 760px, where the sidebar
  does the job.
- `/hr` was a redirect to `/hours`; it is a hub page now. `/my-work` points at
  the hub. Every other old path still redirects.
- `check-nav` asserts the new six, that each hub's page exists, and where each
  screen lives; `check-screens` now accepts a page whose header comes from a
  shared body one directory up.

**Chosen against**

- Time clock, Updates, Directory and the knowledge base are named in the
  brief's hub lists but are steps 3, 4 and 6. Adding navigation entries for
  screens that do not exist would fail `check-nav` and the deploy check, so
  each joins its hub as it is built.

**Needs the owner** — nothing.

---

## Design language, step 3 — the time clock and My day

Deployed `8e3dd0c`, 5 Oct 2026.

**Shipped**

- **Time clock** (`/time-clock`, HR hub): clocked-in-since, today's total and
  this period's total as three tiles, with the clock in / clock out control
  under them. What is asked at clock-out is unchanged — the hours from the
  clock, the category, what the time was spent on — because it was already
  right; the categories offered are the person's role's (0134).
- **My day** (`/my-day`, Home): today in one column. Appointments at their
  time; tasks due and clients with something due under them, because a task
  due today does not happen at nine o'clock and pretending it does invents a
  schedule nobody agreed to.
- Every hub card now carries one line saying what the screen is for.

**Chosen against**

- The time clock does not repeat the session list or the statements; those are
  on Hours, one click away, and a screen that shows everything is a screen
  nobody reads.

**Needs the owner** — nothing.

---

## Design language, step 4 — Updates, Directory, and the two-pane Inbox

Deployed `8e07116`, 5 Oct 2026.

**Shipped**

- **Updates** (`/updates`): Admin posts a heading, what it says, an optional
  link, and who it is for — a role or everybody. A post can require
  acknowledgement and stay pinned until the person reads it. Reading is a
  button, not a scroll position. Admin sees how many have read each post and
  **who has not**, by name, which is the reason the feature exists.
- **Directory** (`/directory`): colleagues and counselors, with initials, role
  or office, and one tap to message, call or email.
- **The Inbox opens two panes** on a desk: the thread, and the client's card
  beside it — stage, who works them, who bills them, their counselor, their
  number, and what is next. Where there is no client, the same space offers
  the three things to do with an unknown number. One column on a phone,
  thread first.
- `verify_updates.sql`: only an Admin posts; a role's update is invisible to
  another role; a person records their own reading and nobody else's; Admin
  sees who has read and a colleague sees only themselves.

**Chosen against**

- No photographs in the directory. The practice holds none, and a page of
  grey circles says less than initials do — the same initials the avatar menu
  draws, so a person looks the same wherever they appear.
- No reactions on updates yet (the brief marks them optional). Read or not
  read is the question being asked; a thumbs-up would blur it.
- Attachments on an update have their columns but no upload yet: the
  `_Bills`-style folder work in E3 brings the same file plumbing, and doing it
  once is better than twice.

**Found while building** — the mail privacy check refuses any column that
could hold a message body, and read `updates.body` as one. It is an
announcement written in the CRM rather than a copy of anybody's message, but
the column was renamed to `text` (what `notifications` already uses) rather
than given an exception: a privacy rule with a list of exceptions is one
somebody will add to without thinking.

**Needs the owner** — nothing.

---

## Design language, step 5 — tasks as checklists

Deployed `42af989`, 5 Oct 2026.

**Shipped**

- **Steps.** A task can have steps, and a step is a task: same rules, same
  inline editing, same history. The database refuses a step of a step and
  refuses to let a step repeat — the task it belongs to does that.
- **Notes.** A word about why something slipped or what to try next, which
  was going in the title. A note cannot be edited afterwards: one somebody can
  rewrite is not a record of what was said.
- **Repeating.** Week, month, quarter, 90 days, year. Finishing one opens the
  next, **dated from the one just finished**, so a report sent a fortnight
  late does not push every future month a fortnight late — and the new one
  carries the steps, unfinished.
- The list is a checklist: a finished row strikes, goes grey and drops to the
  bottom; steps sit under their task rather than loose among the others.
- `verify_task_checklists.sql` covers all of it, including that a one-off
  opens nothing and a repeat stops when told to.

**Chosen against**

- Repeating is a database trigger rather than a nightly job, because a task is
  finished from four different screens and all four should behave the same.
- Attachments on a task are not built. The file plumbing arrives with E3's
  `_Bills` folder, and doing it once is better than twice.

**Needs the owner** — nothing.

---

## The timing check, corrected

Deployed `b4da89b`, 5 Oct 2026.

Step 5's deploy failed the timing check and the screens were fine — the smoke
check passed and production stayed up, which is why the timing check runs as
a job of its own. What it caught was Communication taking over eight seconds
to go quiet on the **first** click after a deploy; measured again warm, same
walk, same place: 548 ms.

The first request to a screen after a deploy wakes a serverless function.
That is Vercel's cold start, nobody can act on it, and a check that fails on a
slow morning is one somebody turns off. Each screen is now clicked once to
warm it and timed on the second visit. Ceiling stays at 8 s, target at 2 s.

---

## Design language, step 6 — the knowledge base, and the practice's own forms

Deployed `ffb5a24`, 5 Oct 2026.

**Shipped**

- **Knowledge base** (the old SOPs screen): articles as cards on shelves, with
  a search that reads the articles and not only their titles. "Where do I…?"
  is the first shelf, because it is the question people arrive with — they
  want a screen, not a procedure.
- **Forms and checklists** (`/forms-and-checklists`, HR hub): the practice's
  own three — a client visit, a worksite check, an incident — filled in on a
  phone and saved against the client. One field per line, real keyboards for
  numbers and dates, the camera for a photograph, and the photograph shrunk in
  the browser by the same helper the paperwork uploads use.
- A filled form is append-only, like a note. `verify_practice_forms.sql`
  proves it cannot be rewritten, cannot be filed as somebody else, is offered
  by role, and that a used template cannot be deleted out from under its
  entries.
- A client's filled forms join their records-request bundle (0140), which the
  bundle check demanded the first time it ran.

**Chosen against**

- USOR's forms are untouched. They are somebody else's document with somebody
  else's rules, they live on Billing, and they work.
- The signature field records that the filer signed rather than drawing a
  second signature pad: the practice already holds each person's signature
  from Paperwork, and two places to keep one is one too many.

**Needs the owner** — nothing.

---

## Design language, step 7 — settings, one feature at a time

Deployed `f7f62fa`, 5 Oct 2026.

**Shipped**

- **Settings** (`/admin/settings-hub`, Admin hub): a card per feature — the
  practice, website chat, work and hours, note headings, shared mailboxes,
  tax years — each on its own page.
- **System** keeps what it is actually for: the access log, and the records
  the system keeps about itself. It points at Settings for the rest.
- The work-and-hours page shows the categories with the roles each is offered
  to, which was invisible until now.

**Chosen against**

- Nothing about billing moved. The brief leaves billing, authorizations,
  forms and warrants alone, and so does this.
- Categories are shown rather than edited on the settings page. They are rows
  (0134), the practice has changed them twice in a year, and a form for
  something changed twice a year is one nobody remembers how to use.

**Needs the owner** — nothing.

---

## Design language, step 8 — label, number, button

Deployed `531ace3`, 6 Oct 2026.

**Shipped**

- `scripts/check-words.mjs`, in `prebuild`: an empty state is one sentence,
  and no working screen carries more than 200 characters of explanation. The
  rule was already agreed and already being lost, so it is checked rather
  than remembered.
- Fifteen screens rewritten to meet it. Empty states became one sentence by
  joining the second clause on rather than deleting it — "Nothing yet — add
  the first job this client has applied for" says what the two sentences
  said. Four paragraphs of explanation on working screens were cut to the
  one fact somebody acts on: the staff-invite screen now says people are
  emailed an invitation and the CRM opens when they finish, instead of
  listing the seven onboarding steps they are about to be walked through.
- The timing check now reports what it found as a commit annotation, not only
  in its log.

**Chosen against**

- Billing, authorizations, forms and warrants are exempt from the check, as
  the brief exempts them (§4). Judging screens by a rule the brief tells us
  to leave alone would be rewriting what was asked to stay put.
- The hint bar, the knowledge base, onboarding and the policy screens are
  exempt too: they exist to explain things, and a word limit on them is a
  limit on the place the explanations were moved to.
- The check reads only static prose. Anything assembled from an expression at
  runtime is skipped, because what a text extractor pulls out of one is a
  fragment of code, not a sentence worth judging.

**Needs the owner** — nothing.

---

## The timing check, read without a token

Deployed with step 8.

Step 7 went live and its timing job failed, and the finding was in a GitHub
job log, which needs a token to read: the check knew which screen was stuck
and nobody else could. Three changes, so the next failure says what it is
where the failure is seen:

- Every finding — a slow screen, a sign-in that did not work, a sidebar with
  no links, an error the walk did not expect — is now emitted as an `::error`
  annotation, which shows on the commit and in the Checks list.
- An unexpected error is collected as a finding instead of ending the run as
  a stack trace.
- A click waits the ceiling (8 s), not Playwright's default half-minute, and
  names the link it was waiting on.

It said it on the first try. Step 8's run reported `the walk stopped:
page.goto: Timeout 30000ms exceeded` — the fault was the check's own: the
warm pass returned to the dashboard between every link, which is 24 loads of
the heaviest screen in the app, and one of them took longer than half a
minute. The walk is now two laps of the sidebar, clicking on from wherever
the last link left it, which is both how a person moves and one load per
screen instead of four.

**Needs the owner** — nothing. Step 7's own finding is not recoverable; its
screens are re-timed on every deploy from here.

---

## ERP E1 — the ledger and the books

Deployed `922c645`, 6 Oct 2026, live with `70d70c8` (below).

Migrations 0141-0145, two verification scripts, nine screens. The books open
on **1 January 2027** and every posting below is live from this deploy and
does nothing at all until then, which is what lets the whole module be built
and verified in October without touching the operational year still running.

**Shipped**

- **Chart of accounts** (0141), seeded from the brief: bank, undeposited
  funds, receivables, payables, contractor payables, equity, one revenue
  account per service the practice actually bills, and the cost lines. Rows,
  not code - the practice and its CPA change these without a deploy. An
  account that holds postings is retired, never deleted. What the CRM posts
  to automatically is a *role* on the account rather than a name, so renaming
  "Accounts receivable (USOR)" cannot quietly break a posting.
- **Double-entry journals** with three rules the database keeps rather than
  trusts: debits equal credits (a deferred constraint, so no route commits an
  unbalanced entry), the ledger is append-only (a mistake is reversed with a
  reason, never edited), and a closed month refuses postings.
- **Postings made automatically** from what the practice already records: an
  item submitted is receivable against its service's revenue; an item paid is
  cash in hand; a statement approved is contractor cost owed; each claim on
  it is its own expense, mileage at the rate on the day driven; a payout
  clears what was owed and leaves the bank. Each carries a link to the event
  that caused it, and source-plus-event is unique, so "every source event
  posts exactly once" is a rule and not a hope.
- **Manual journals** (Admin, with a reason, optionally an attachment) and
  **opening balances**, entered once and dated the day the books open. The
  owner's answer is that they are zero, which makes this a mechanism used
  once that has to be right anyway.
- **Bank statements** (0143): CSV or OFX, parsed by name rather than by
  column position; importing the same file twice adds nothing; each line is
  matched to a posting, posted as one, or set aside with a reason; and a
  statement **cannot be marked reconciled while a difference remains** -
  refused, not warned about.
- **Eleven reports** (0144) on one screen with one period picker: Profit &
  Loss on either basis, balance sheet, cash flow, trial balance, payables
  aging, revenue by service, office and counselor, contractor cost, the
  general ledger, and the 1099 tie-out. Every figure is a sum of postings,
  asked for when the screen opens: nothing stored, so no report can drift
  from the ledger and there is no totals table to rebuild.
- **Period close**, Admin only, with reopening written into the access log,
  and a **year-end package**: every report for the year as a CSV plus a
  covering note, in one zip for the CPA.
- `verify_ledger.sql` (19 assertions) and `verify_bank_import.sql` (10). The
  suite is 78 scripts, 0 failed.

**Chosen against**

- **A warrant is paid into Undeposited funds, not straight into Bank.** A
  warrant is a cheque: it exists before it is at the bank, and the deposit is
  a separate event the statement will show. Posting it straight to Bank would
  make the ledger disagree with the statement by however many days the cheque
  sat in a drawer, and bank reconciliation is the one report that cannot be
  allowed to be approximately right.
- **Cash comes from the billing item, not from `payments`.** `payments` is
  what the warrant-stub reader writes when a warrant PDF is uploaded -
  useful, optional, not always there. The billing item is what Margaret
  always touches. Posting from both would count the same money twice.
- **Cash basis is carried on the posting, not inferred.** A payment credits
  receivables, not revenue, so a cash-basis Profit & Loss cannot be read off
  the accounts. Each cash posting names the revenue or expense account it
  belongs to, and both bases then come from one ledger rather than two.
- **An automatic posting into a closed month moves to the next open month and
  says on its face what day it happened.** A warrant that arrives after the
  month was closed is still money that arrived; breaking the billing action
  that caused it would be worse, and losing it worse still. A journal
  somebody writes by hand into a closed month is refused outright.
- **Eleven reports on one screen, not eleven screens.** A report is chosen
  and a period is chosen, the same two controls every time; eleven pages
  would be eleven places to fix the date picker.
- **`/books`, not `/insights/books`.** check-nav holds Insights to Admin
  alone (owner, 14 Sept 2026) and the people who read the books are the two
  already in the Billing group all day. The sidebar entry is Billing's, with
  posting and closing still Admin's wherever somebody arrives from.
- **A sixty-line zip writer instead of a dependency.** The year-end package
  is the only thing the app will ever zip. Stored entries only; a CPA's
  unzipper does not care that CSVs were not deflated.
- **The entity dimension is here from the start**, defaulting to Zion Voc
  Rehab, though consolidated reporting is E5's. Retro-fitting a dimension
  onto a year of postings is exactly the rebuild the brief says to avoid.
- **PDF is the browser's print**, not a generated document. Every report
  screen is already laid out for printing, and a second rendering path for
  the same table is a second thing to keep in step.
- **The two-person rule is not built.** The brief makes it optional - Admin
  posts, Billing drafts - and until somebody asks for it a draft is simply a
  journal Admin has not posted yet. Building a draft state nobody uses would
  mean a second shape for every entry screen to handle, for a control the
  practice has not asked for. It is a setting to add, not a rewrite.

**Two things the verification suite caught that would have shipped**

- `journal_lines` carries a client_id, so `verify_records_request` refused the
  ledger the moment it existed. The answer was to include it (0145) rather
  than to add a reason to a skipped list - the same argument that settled
  `updates.text`: a privacy rule with a list of exceptions is one somebody
  will add to without thinking. A records request now returns the postings
  that name the person, in words rather than in debits and credits.
- The eleven new tables did not refuse writes from the automated accounts.
  `verify_system_account` named all eleven; 0143 now sweeps them.

**Needs the owner**

- **The CPA confirms the chart and the basis before 1 January 2027.** Cash is
  the default, as agreed, and the toggle is on the report. Nothing here needs
  a deploy to change.
- **The bank account.** One ledger account is seeded as "Operating account";
  add the real ones and their last four digits on Books, Bank statements.
- Opening balances are zero, as agreed. If that changes, they are entered
  once, on the day the books open.

---

## ERP E2 — budget and forecast

Deployed `dfcd915`, 6 Oct 2026, live with `70d70c8` (below).

Migrations 0146-0147, one verification script, two screens.

**Shipped**

- **A budget by account and month** (0146), typed by a person, against
  actuals that come from the ledger. The variance is signed so positive is
  good either way: revenue above budget and cost below it both read as a
  gain. A column that means "more", leaving the reader to work out whether
  more is good, is a column misread every month by everybody.
- **A forecast in three bands, never summed into one number by the
  database.** Committed work (an item in the pipeline, placed in the month
  its service bills), authorized and not yet earned (spread to the
  authorization's end date), and an estimate from the referral trend. Those
  are three different degrees of certainty, and the month a forecast matters
  is the month somebody needs to know which part was which.
- **A cost forecast** of what is already owed, which is a fact, kept separate
  from the average of the last three finished months, which is a guess.
- **Ninety days of cash by week**, carrying the balance forward, using the
  lag the practice actually experiences - the median days from submitting an
  item to being paid for it, measured from its own history rather than
  assumed. Thirty days until there is history.
- **Two nightly alerts**: an account past its budget by more than a
  tolerance the owner sets, and the cash forecast dropping below a floor the
  owner sets. Both are off until somebody sets a number.
- `verify_budget_forecast.sql`, 13 assertions. The suite is 79 scripts, 0
  failed, and `verify_notifications.sql` still trips all eleven older rules.

**Chosen against**

- **An account nobody budgeted is never over budget.** A zero somebody never
  typed is not a promise, and treating it as one would fill the alert list
  with accounts that are "over" by whatever they happen to cost.
- **A tolerance, not a threshold in dollars.** An account a few dollars over
  on the second of the month is noise, and an alert that is noise is one
  people learn to click past - which costs exactly the alert that mattered.
- **One cash alert naming the first week it happens**, not one per week.
  Thirteen alerts saying the same thing is the same thing said thirteen
  times.
- **Nothing about the forecast is stored.** Every figure is recomputed when
  the screen opens, so a forecast cannot go stale in a table somebody forgot
  to refresh. A budget is stored, because somebody typed it.
- **The budget form is one account and its twelve months**, with a "the same
  every month" box, rather than a thirty-by-twelve grid of six hundred
  fields with one save button and no way to tell what changed.
- **The whole notification generator was recreated to add two rules**, as
  0121 did, because a function body cannot be amended in place. That is only
  safe because `verify_notifications.sql` builds a situation that trips every
  rule and asserts each kind by name: a rule lost in the copy fails a script
  rather than going quietly missing from somebody's evening. The eleven
  existing rules were read out of the live database rather than retyped.

**Needs the owner**

- **The cash floor**, on Books, Forecast. Empty means no warning.
- **The budget itself**, when the CPA has confirmed the chart. Nothing here
  needs the budget to exist: the variance report simply shows actuals with no
  budget beside them.

---

## ERP E3 — vendors, bills and purchasing

Deployed `70d70c8`, 6 Oct 2026.

Vercel's build failed on E1 and again on E2, and succeeded on this one with
no change to the cause. Both commits build clean from a fresh clone with
`npm ci`, which was checked rather than assumed, so the fault was not in the
code; the most likely explanation is Vercel's build cache. Worth knowing the
shape of it: production sat two commits behind for half an hour and the only
sign was the deployment status, because a failed build never reaches the
smoke test at all.

Migrations 0148-0149, one verification script, three screens and two tiles on
the owner's Home.

**Shipped**

- **Vendors** (`/books/vendors`): who the practice pays, their terms, the
  account their bills usually land in, and whether they get a 1099.
- **Bills with a life** (`/books/bills`): entered, approved, scheduled, paid.
  Each step posts on its own - approved is money owed, paid has left the bank
  - so what the books say the practice owes is what the bills say, always,
  without anybody reconciling the two. Voiding reverses what was posted.
- **Approval is a threshold, not a role.** Under the number the owner sets,
  whoever does the billing approves a bill; over it, only an Admin. The
  database decides it, not the screen.
- **Recurring bills**: rent, software, insurance. The nightly job writes the
  ones that fall due, awaiting approval like any other.
- **Payables age by vendor** as well as by person, oldest cleared first, and
  the owner's Home gained two tiles: bills due this week, with how many are
  late, and the total owed to contractors and vendors.
- **Purchase requests** (`/requests`): somebody asks, an Admin decides.
  Everybody can reach it, unlike the rest of the books.
- **Vendor 1099s join the existing run.** A recipient is a contractor or a
  vendor, exactly one of the two; one run, one threshold, one list of what is
  not ready, one tie-out.
- `verify_vendors.sql`, 17 assertions. The suite is 80 scripts, 0 failed.

**Chosen against**

- **No vendor tax number is kept.** A 1099-able vendor has a W-9, the W-9 is
  a document, and what the CRM stores is that it is on file and the last four
  digits - which is exactly what a 1099 snapshot records anyway. A second
  place to hold tax numbers is a second thing to protect, for no gain.
- **A recurring bill is created, not posted.** The month the rent changes is
  the month an automatic posting would be wrong and nobody would notice.
- **A second 1099 pipeline for vendors.** Two pipelines would mean two places
  to discover in February that a W-9 was missing.
- **Purchase requests are not inside Books.** Books is for the two people who
  keep them; asking to buy a laptop is everybody's, and a screen only Billing
  can open is one the person who needs it cannot reach. Off until the owner
  sets an amount, and the screen says so in a sentence.
- **The document agent filing bills from a `_Bills` folder** is not in this
  block. The bill table carries the document path it will need, and the
  agent's folder rules are their own piece of work; a half-wired agent that
  files some bills and not others would be worse than entering them by hand
  for now.

**One thing found on the way, and the owner should know**

The migration history's copy of `generate_1099_run` named a column the
database no longer has - `contractor_profiles.e_delivery_consent`, renamed to
`e_delivery_consent_on`. The live function worked, so it had been changed in
the database at some point without a migration, and the history alone could
not have rebuilt it. The function is reconstructed and held to
`verify_1099.sql`, which pins the threshold rules, the not-ready list, the
freezing and the foreign-person rule, and all of them pass. It is worth
knowing that this can happen: a change made in the Supabase SQL editor is
invisible to the history until something like this trips over it.

**Needs the owner**

- **The bill approval limit** and **the amount people ask above**, both on
  `/requests`. Empty means Admin approves everything and nobody has to ask.
- The vendors themselves: the landlord, the software, the insurance, the
  accountant, with the W-9 status for any that get a 1099.

---

## ERP E4 — the asset register

Deployed `1c5a397`, 6 Oct 2026.

Migrations 0150-0151, one verification script, one screen, one column on the
offboarding checklist.

**Shipped**

- **The register** (`/books/assets`): tag, what it is, serial, cost, when it
  was bought, warranty end, who has it, and what it is worth now. The book
  value is not stored - it is the cost less what has been depreciated, and
  the depreciation is postings, so this screen and the balance sheet cannot
  disagree.
- **Assignment history.** Handing a laptop from one person to another is a
  return and an assignment in one act, because a screen that did them
  separately would eventually do only one. One person holds a thing at a
  time, and who had it before stays written down.
- **The offboarding checklist reads the register.** "Equipment to hand back"
  is a count of real things with real tags, on the same view that already
  answers what else is still attached to somebody.
- **Straight-line depreciation**, posted by the nightly job for each of the
  last three finished months, every night. Posting is idempotent - a row per
  asset per month is what stops a second one - so a night that does nothing
  costs three queries, and a night the job did not run is caught by the next
  one. Gating it on the first of the month would have meant one missed night
  losing a month of depreciation with nothing to say so. The lives are the CPA's to
  set. The last month takes the rounding, so nothing is left on the books
  forever; a month already posted is never rewritten.
- **Disposal**: the cost and the depreciation come off together, what was got
  for it goes in, and what is left is a gain or a loss. One function, because
  a disposal recorded on a screen and posted later is a disposal posted
  wrongly.
- `verify_assets.sql`, 15 assertions.

**Chosen against**

- **Depreciation calculated on the fly.** It is a real monthly expense, and a
  report that worked it out each time would stop agreeing with the trial
  balance the moment a life changed.
- **A month that has not finished.** Refused outright, rather than
  pro-rated: a part-month posting that gets topped up later is two entries
  for one month and a reconciliation nobody can follow.
- **Automatic capitalisation.** A bill posts to whichever account the person
  choosing it picks; the register records what the practice owns. Wiring the
  two together would mean the CRM deciding what is an asset, and the
  threshold for that is the CPA's judgement, not a rule in code.

**Needs the owner** — the lives, with the CPA, on Books, Equipment. The
seeded ones are the usual 36, 24, 84, 60 and 36 months; they post nothing
until the books open.

---

## ERP E5 — more than one set of books

Deployed `1c5a397`, 6 Oct 2026.

Migration 0152, one verification script. **Nothing here changes a single
figure while there is one entity.** That is the point: it is the groundwork,
verified now, so that adding the PCA is an afternoon rather than a quarter.

**Shipped**

- **Every report takes an entity**, or none, which means every set of books
  the reader may see. Today that is one and every answer is identical. The
  same account code in two charts consolidates to one line, which is what
  "sum the entities" means to somebody reading a report.
- **A second set of books with the first one's chart**: `create_entity` copies
  the accounts, the roles and the settings, so the two can be read side by
  side without mapping one onto the other.
- **Transfers between entities post both sides in one transaction**, through
  a "Due from related entity" account that nets to nothing when the two are
  consolidated. A transfer from a set of books to itself is refused.
- **A posting cannot mix entities.** A deferred constraint refuses an entry
  whose lines reach into another entity's chart - the mistake that leaves
  consolidated figures right and each entity's own figures wrong, and is
  invisible until somebody files.
- **Access is per entity.** An Admin sees all of them; everybody else sees
  the entities named for them, and with none named, the default one - which
  is what they saw before the table existed, so nobody is locked out by its
  arrival. A CPA brought in for one entity is given one row.
- `verify_entities.sql`, 14 assertions, including that one entity's report
  shows one entity's money and a consolidated one sums both.

**Chosen against**

- **An Admin scoped to entities.** The brief says access is per entity, and
  it is - but an Admin who adds the PCA's books and then cannot open them
  until somebody grants access is a trap, and the person who would fall into
  it is the owner.
- **An entity picker on every screen.** It appears only when there is more
  than one set of books. A choice with one option is a control that teaches
  people to ignore controls.
- **Consolidating by mapping charts.** The second chart is a copy of the
  first, so consolidation is a sum rather than a translation table somebody
  has to maintain.

**What still has no entity, and why that is right for now**

A billing item, a contractor statement and an expense claim have no entity
of their own, so everything they post goes to the default set of books. That
is correct today: Zion does the work and Zion bills it. When the PCA starts
billing, those three tables gain an entity column and the posting functions
read it - which is a column and a default, not a rebuild, because the ledger
underneath already carries the dimension. Saying so here is cheaper than
rediscovering it.

**Needs the owner** — nothing until the PCA exists. When it does: Books,
add the entity, and the chart comes with it.

---

## The deploy watcher, and a token

Deployed with the smoke change above.

Three times today this session read "checks not started" for a deploy whose
checks had passed. The cause was its own: unauthenticated, GitHub allows
sixty API requests an hour for the whole machine, and the watcher asked
every twenty seconds - sixty requests per watch, the entire budget.

- The site's own `/api/version` is asked every twenty seconds, because it
  costs nothing; GitHub is asked every two minutes, and only once the commit
  is actually live, since there is nothing for the checks to say before then.
- A rate limit now reports itself as not knowing, which exits 3, rather than
  as a failure. "I could not find out" and "it failed" are different answers
  and were being given the same way.
- One line per change instead of one line every twenty seconds.
- `GITHUB_TOKEN` or `GH_TOKEN` is used when either is set.

**Needs the owner** — a read-only GitHub token in `.env.local`, as
`GITHUB_TOKEN`. A fine-grained token with read access to this repository's
Actions and Deployments is enough; it raises the limit from sixty requests
an hour to five thousand, and the watcher stops guessing. Nothing breaks
without it.

---

## The cash forecast waits for the books

Deployed `<pending>`, 6 Oct 2026.

Found while reading the Books screens back in the state they will actually be
in for the next three months: before the books open there are no postings at
all, and the cash forecast read that as no money. It would have shown the
practice running to nothing all through the autumn - and worse, if the owner
set a cash floor now, the nightly alert would have fired in red every night
about a balance nobody is keeping yet. An alert that is wrong for three
months running is an alert nobody reads on the day it is right.

- The cash forecast returns nothing until the books open, and the screen says
  so in a sentence.
- The revenue and cost forecasts are deliberately left alone: they are built
  from billing items and authorizations, which are real today, so they are
  worth reading before the ledger exists. Only the cash side needs a starting
  balance, and only the cash side waits.
- `verify_budget_forecast.sql` gained the assertion, and is now 14.

**Needs the owner** — nothing.

---

## What the ERP brief asked to be verified, and where it is

The brief lists six things the books must be held to. Each one is a script
that builds the situation and tries to break it, and the whole suite is 82
scripts with nothing failing. Written out here so somebody - the owner, the
CPA, whoever is reading this in a year - can check the list rather than take
it on trust.

| What the brief asks | Where it is held to it |
| --- | --- |
| Debits equal credits on every posting | `verify_ledger.sql` — a one-sided entry and an unbalanced one, both refused at commit, through the deferred constraint rather than through code |
| The trial balance balances | `verify_ledger.sql` — after a month of items, statements, claims and payouts |
| Every source event posts exactly once | `verify_ledger.sql` — an item submitted, touched again, and submitted again |
| Bank reconciliation cannot close with a difference | `verify_bank_import.sql` — an unsettled line, a statement that does not add up, and a ledger that disagrees: three refusals |
| The 1099 tie-out equals payables | `verify_vendors.sql` — money recorded paid and never posted shows as a difference; a bill paid the proper way round ties out exactly |
| Closed periods refuse writes | `verify_ledger.sql` — a journal by hand refused, and one the CRM makes for itself moved to the next open month, saying what day it happened |

And the things the brief did not think to ask for, which the suite found
anyway: `journal_lines` carries a client_id and so belongs in a records
request; eleven new tables did not refuse writes from the automated
accounts; and the migration history's copy of `generate_1099_run` named a
column the database no longer has.

---

## Who opens the books, settled

Deployed `5c84d7d`, 6 Oct 2026.

I had this the wrong way round for an hour and the correction is the useful
part, so it stays written down.

The deploy check signs in as the automated-check account, which is Job
Search, and the books are Billing's - so I concluded that none of the
fourteen new screens had been opened by anything, and said so here in those
words. It was a reasonable inference and it was wrong: the second account's
secrets **are** set, the Billing pass does run, and the books were opened on
this deploy like every other screen.

What settled it was the annotation that went in with this change. It fires
only when `SMOKE_BILLING_EMAIL` is missing, and on `a3029b3` it did not
fire, while the run's other annotations came back normally - so the branch
that reports the gap never ran. Writing the check to say something out loud
is what made its own silence informative.

**What this change is worth keeping for**

- The deploy check follows each hub's own cards. The navigation lists hubs,
  not the screens inside them, so without this the eleven screens under
  Books would have been reachable only through a list somebody maintained by
  hand - which is the fault this check exists for, from the day Clients to
  Jobs crashed on production after a route moved.
- It opens a bank statement's own screen the way it already opens a client
  and a billing item, so the moment a statement is imported that screen is
  covered too.
- If those secrets are ever removed, the gap is now a warning annotation on
  the commit naming every screen nobody opened, counting the ones inside a
  hub rather than naming the hub and meaning eleven things.

**And the timings.** Design language step 8 asked for the clicks to be
re-measured. On `a3029b3` the idle check raised no slow-screen warning at
all, which means every screen went quiet inside the two-second target rather
than merely inside the eight-second ceiling it fails on.

**Needs the owner** — nothing.

---

## Closing a paid item is not undoing it

Deployed `<pending>`, 6 Oct 2026.

Found by reading the posting trigger back against Margaret's statuses rather
than against the test that passes. It reversed the cash whenever an item left
Paid for anything else, which is right for every status but one: **Closed**
is an ending, not a correction. An item that was paid and is then closed off
has still been paid, and the money is still in the practice's hands.

Left alone, closing a paid item would have taken a real receipt off the
books, with a reversal nobody would read until a month would not reconcile -
and the month it first mattered would be a month somebody had already
reported on.

The reversal now happens only for the statuses that mean the payment came
undone: back to Submitted, Pending, Correction needed, Billing review or
Ready for billing. **Submitted** is deliberately unchanged - an item
submitted and then closed has been refused or abandoned, and what was owed
should come off.

`verify_ledger.sql` gained the assertion, and is now 26.

**Needs the owner** — nothing.

---

## Tidying: the old branches, and the token slot

6 Oct 2026. No deploy; neither of these touches the app.

**Thirteen merged branches deleted.** Every one was fully merged into main,
so nothing unique went with them. Their heads, for the record, in case a name
is ever wanted again: audit-passes `2eff812`, dashboard-refinements
`92804f3`, design-step-1 `e4603ec`, design-step-2 `4cdf2ff`, design-step-3
`8e3dd0c`, design-step-4 `8e07116`, design-step-5 `42af989`, design-step-6
`ffb5a24`, design-step-7 `531ace3`, fix-signature-upload `97aded9`,
idle-warm `b4da89b`, page-timings `79dac28`, rei-items `55c7f9b`.

**Two branches kept, deliberately.**

- `portal` is not merged into main. It is the client-portal work, which the
  owner put on hold, and this branch is the only place it exists - locally
  and on the remote. Deleting it would throw the work away rather than tidy
  up.
- `claude/competent-darwin-de263d` is fully merged and holds nothing main
  does not, but it is checked out in a session worktree under
  `.claude/worktrees/`, which belongs to another session rather than to this
  one. Git will not delete a branch somebody has checked out, and removing
  another session's worktree is not tidying. It comes away with Settings,
  Storage, "Clean up inactive sessions" once that session has been quiet
  thirty days.

**The token slot is documented, not filled.** `.env.example` now carries
`GITHUB_TOKEN` with the exact scopes - fine-grained, this repository only,
read-only Actions and Deployments, nothing else. The value is the owner's to
generate and paste into `.env.local`, which is git-ignored; issuing secrets
is not something this session does, and a token pasted into a chat would be a
token that then lives in a transcript.

**Needs the owner** — generate that token if the deploy watcher is worth
five thousand requests an hour to them, and paste it into `.env.local`.
Nothing breaks without it.

---

# Billing Simplification Brief

Owner, 7 Oct 2026: build all of §§1-13, ahead of the ERP brief, before
15 October so the month-end close runs on the new flow.

## The duplication audit (§11), before anything was built

`scripts/duplication-audit.mjs`, run against production. §11 says the build
is not done until a later run finds none, so this is the baseline it will be
measured against. Fifteen findings, in the three shapes §11 asks about.

**One fact, kept in more than one place.** Seven facts are stored two or
three times over:

| The fact | Where it lives | Also kept in | Rows disagreeing today |
| --- | --- | --- | --- |
| Which service the work is for | `authorizations.service_type` | `billing_items.service`, `invoices.service_type` | 0 |
| The rate, and whether it is hourly | `authorizations.rate/rate_type` | `billing_items.rate/billing_type`, `rate_schedule` | 0 |
| What the work came to | rate x hours on the authorization | `billing_items.amount`, `invoices.amount` | 0 |
| When it was sent, and to whom | `billing_items.submitted_at/recipient` | `invoices.sent_date/payee` | 0 |
| That it was paid, and on what warrant | `billing_items.paid_on/warrant` | `invoices.paid_date/warrant`, `payments.warrant_no` | 0 |
| Counselor and billing office | `clients.counselor_id`, `counselors.office` | `clients.referring_office`, `clients.counselor_contact` | **2** |
| Hours worked | `work_sessions`, `service_entries` | `billing_items.hours` | 0 |

Six of the seven agree today, and that is worth being clear about: they agree
because triggers copy them and nobody has yet edited one side. A copy nobody
has contradicted is still a copy, and the first person to change a rate on
one record and not the other produces a bill that is wrong in a way no screen
shows. The seventh has already happened - **two clients whose referring
office does not match their counselor's office** - which is what the rest
will look like given time.

**Documents.** 24 columns across 16 tables hold a path to a file. No two rows
share a storage path, so nothing is physically stored twice *yet*, and there
is **no fingerprint anywhere in the database** - the only hashes are for
login codes, IP addresses and chat tokens. So §11's "the fingerprint matches
and the second copy is dropped" does not exist: a PDF that arrives from the
agent and again by upload is stored twice and nothing notices. 35 filenames
in `attachments` and 39 in `inbox_documents` are already used by more than
one row.

**Lists.** `authorizations` is read by **16** screens, `invoices` by 8,
`service_entries` by 7. §11's "if two screens show the same records, one of
them goes" has a lot to bite on.

## The placeholder count (§9), before anything is deleted

`scripts/placeholder-counts.mjs`. Counts only; it changes nothing.

- **20** placeholder authorizations in all - the ones the spreadsheet import
  created with no USOR number, numbered `(workbook) ...`.
- **19** have nothing attached at all: no hours, no forms, no invoice, no
  payment, no carried hours, no billing item. §9 deletes these.
- **1** is not deletable: it has a form attached. §9's condition is "no
  hours, forms, invoice or payment", so a form keeps it, and it stays on the
  client's Billing tab as history.
- **No money is involved either way.** Nothing paid sits on any of the
  twenty, so no paid total moves whichever way this goes. That is worth
  knowing because it is the risk §9 was written to avoid.
- They are spread across 20 clients, one each, except the one client with
  the form.

The per-client breakdown was printed and is deliberately **not** written
here: the standing rule is no client data in the repository or its history,
and a table of client numbers against counts is client data. It went to the
owner directly.

## The placeholders, deleted (§9)

Owner approved on 7 Oct 2026, having seen the counts. **Sixteen deleted, not
nineteen** - and the three that survived are the reason the test was widened
before the delete rather than after it.

The first count asked six tables whether anything was attached. The schema
says **ten** things point at an authorization, and six of those cascade: a
delete would have taken the authorization's corrections, completions, hours
requests, invoices, payments and service entries with it, while three more
would have been orphaned by a SET NULL. So the test is now built from the
foreign keys themselves, read out of the schema, and a table added later is
included without anybody remembering to add it.

On the full test, **four** placeholders have something attached:

| What it holds | How many | Why it stays |
| --- | --- | --- |
| A logged correction | 2 | Deleting cascades the correction away. A record of a change somebody made is the last thing to destroy to tidy a list. |
| Two attachments | 1 | Deleting orphans two PDFs - they lose what they document, which is the opposite of §11. |
| A completed form | 1 | §9's own condition keeps it. |

Strictly, §9's delete condition names "hours, forms, invoice or payment", so
a literal reading would have removed the corrections and the attachments
too. Put to the owner, who settled it the same day: **keep them.** All four
stay as history on the client's Billing tab, which is where §9 puts kept
placeholders anyway. Closed question.

**What the delete did**, all verified inside the transaction before it
committed - any one of these failing would have rolled it back:

- authorizations 176 to 160; placeholders 20 to 4.
- Every one of the ten child tables has exactly as many rows as before, so
  nothing cascaded.
- The sum of every payment in the database is unchanged at the penny:
  142,947.50 before and after.

`scripts/delete-placeholders.mjs` counts by default and needs `--delete` to
act, so it is safe to run again to see where things stand.

## What the brief lands on, which the owner should know

The ERP brief is **already built and live** - E1 to E5 shipped 6 October. Its
ledger posts from `billing_items`, on the statuses `Submitted` and `Paid`,
and E2's revenue forecast reads `billing_items` too. §1 removes that table.

So this is not work that comes "ahead of" the ERP: it requires rewiring E1's
posting trigger and E2's forecast onto the authorization. That is a known,
contained piece of work - the postings are one trigger function and the
forecast is one query - and it is called out here because the order matters:
the ledger has to keep posting across the migration, or a month of revenue
goes missing silently.

---

## §§1-7: the authorization is the bill

Deployed `<pending>`, 7 Oct 2026. Migrations 0155-0159, one new verification
script, five rewritten, two deleted.

**What changed.** The billing item is gone as a working record. Every
authorization now carries its own status (Authorized, Due, Submitted, Paid,
Closed), the day the form was received, the day we mean to bill by, the day
it goes stale, the submission and the payment. Job Coaching is a parent
holding the hours with a child authorization per month, each with its own
bill-by, forms, status and payment. One list - `billing_worklist` - returns
everything not Paid and not Closed with the single most pressing thing wrong
with each row.

**The fold, held to §7's own test.** 160 authorizations became 162 - the two
coaching children of the one authorization that already had two monthly
items - and **the paid total came through at 142,947.50, matching
`billing_items` to the penny.** Every child table has exactly the row count
it had. Captured before, compared after, not assumed.

**The stale rule, as the owner revised it on 7 Oct.** Service dates outside
the authorized period are a hard block. Submitting after the end date is
allowed and flagged. Only 90 days past the end date refuses, and the 90 is
Admin-adjustable. A missing end date warns and never blocks. Day one on the
real data: **22 rows, 4 that cannot be submitted** (ended between December
2025 and May 2026), 6 past the end date and still submittable with the
closing date shown, 2 with no end date, 9 overdue against bill-by, 1 clean.
Under the first reading of §4 it was 13 blocked.

**Six faults the work surfaced, each of which would have shipped quietly**

1. **The coaching hours alert would never have fired again.** It summed
   hours logged against the authorization itself; coaching hours now land on
   the month, which is a child. Every parent would have read zero used, for
   ever.
2. **`unbilled` and `committed` would have been zero everywhere.** Both read
   "when the status is not Open, this is zero", and Open was gone - so the
   economics view, `staff_capacity`, `billing_position` and the Money insight
   would all have shown nothing, with nothing failing. `verify_capacity`
   caught the first; the rest were then looked for rather than discovered one
   screen at a time. Checking a spliced definition for the table that was
   removed is not enough; the status values have to be checked too.
3. **Five more views asked for `'Open'`** and would have returned nothing,
   which looks exactly like a practice with nothing to show (0159).
4. **The USOR forms gate would have been lost.** `check_invoice_forms`
   refused to send an invoice while a required form was outstanding. The
   invoice is going; the rule came with it, onto the submit, rather than
   being rediscovered the first time a packet reached USOR without its 93
   and 95.
5. **The payment lag would have been poisoned.** All 139 paid rows from the
   workbook have no submission date. Requiring one for Paid meant backfilling
   it from the payment date - which would have told `ledger_payment_lag()`
   that USOR pays on the day of billing and wrecked the cash forecast built
   on it yesterday. Submitted needs a date; Paid does not.
6. **Two new columns were unreadable.** `org_settings` is granted column by
   column, so the grace the owner sets would have been written by an Admin
   and read by nobody. `verify_columns` caught it.

**Chosen against**

- **A coaching child carrying the USOR number.** It is the same
  authorization, for one month of it, and §11 says a fact lives in one
  place: the number is the parent's and is read from there. Searching by
  number finds the authorization rather than twelve copies of it.
- **Backfilling the missing submission dates** - see fault 5.
- **Dropping the billing item now.** It stays, frozen against every write,
  for one deploy: §7's test needs it to compare totals against, and the old
  Items screen is reachable until §9 replaces it. Frozen rather than live
  because two records disagreeing about what was billed is what this brief
  exists to end; deleted rather than frozen in §10, because §13.17 says so.
- **One giant deploy.** The database, its readers and the app's status
  filters land together - they have to - but the screens are their own
  deploy. A smaller surface is a smaller thing to be wrong.

**Where §11 stands.** The audit still finds 15, unchanged, and that is
expected: the facts are single-sourced in the database now, but the screens
still read `invoices` (8 of them) and the tables still exist. §9 and §10 are
what clear it. The audit is the measure, and it is run again at the end.

**Owed, and named here so it is not forgotten.** `verify_warrants` lost one
assertion about `billing_position`'s figures: every one of them came off the
invoice, and warrant reconciliation still writes invoices until §10 moves it
onto the authorization. It returns with §10 and §13.9. The rest of that
script - reading the stub, matching the lines, refusing a bad match - is
untouched.

**Needs the owner** — nothing. The 90-day grace and the 14-day stale warning
are on `org_settings` and are yours to change.

---

## §§9, 10, 12, 13: two tabs, one record, and the invoice gone

Deployed `b652652` and `ec7ff4a`, 7 Oct 2026. Migrations 0160-0168, two new
verification scripts, fourteen rewritten, one renamed.

**What changed.** Billing is two tabs. The authorization is the screen: the
forms, the signed authorization, the submission checklist and Report & bill were
four places and are now one record, with one line at the top saying the single
most pressing thing about it. The invoice is gone - table, screens, actions,
exports, and the billing item with it. Nothing creates a bill except entering an
authorization, and that now goes through one function with direct insert
revoked, so it is the database that enforces the one door rather than a code
review. A warrant line that matches a submitted authorization pays it with no
click; anything else waits with the reason on it. Paid and Closed are off the
working list and live under History on the client, with every total in Admin
Money.

**Two things I shipped in §§1-7 that were wrong, found by measuring rather than
re-reading**

1. **The forms gate refused 22 of 22 rows.** I had carried a rule from
   `check_invoice_forms` onto the submit so it would not be lost with the
   invoice. The rule had never once run: its trigger fires only when an invoice
   becomes Sent, and no invoice in this database has ever been Sent - all 139
   are paid history imported from the workbook. Worse, it does not match the
   practice: 305 signed USOR forms are filed as scans against four rows in
   `forms`, none completed. Measured against the live worklist, my version
   refused every authorization waiting to be billed, Margaret's whole close
   included. The day-one count I reported said four could not be submitted. The
   true number under what I shipped was all of them.

   The test stays, computed and always on the checklist. Whether it refuses is
   an Admin setting, and it starts off. §13.10 makes the forms real, and the
   switch is there for that day.

2. **A checklist line that could never pass.** "Signed authorization" read
   `billing_items.signed_auth_path`, null on all 153 rows - nothing had ever
   written it. The signed authorization is an attachment. The line reads the
   attachments now and passes for 8 of the 22 live rows instead of none.

**Eight more faults the work surfaced**

1. **A checklist line could answer null.** With no billing address anywhere the
   recipient line returned null rather than no, and a null slipped past
   `not passed` in both helpers as though it had passed. 1,944 lines across
   every authorization are now asserted never to answer null.
2. **Warrant reconciliation broke the moment the invoice table went,** because
   the function still named it. `verify_one_door` now asks which functions name
   a record that no longer exists - and the same question found two billing-item
   guard functions sitting with nothing to guard, which is what §13.17 forbids.
3. **A warrant line of any amount against an already-paid authorization** would
   have recorded a payment against work already settled. It has to match the
   payment that paid it now. This was my own new code, caught by the fixture
   that used to test the invoice amount guard.
4. **Admin Money filtered authorizations on `status = 'Open'`,** removed in §4,
   so its follow-up column has been empty since. The dashboard's "earned, not
   yet invoiced" read zero for the same reason. That makes nine places this
   status rename reached; the first five were in §§1-7.
5. **The flat-fee completion rule was asking the wrong column.** The checklist
   tested `service_end` while the practice records the fact in `completions`.
   It was wrong for 7 of the 15 flat fees being worked - 11 of 18 rows pass now
   where 3 of 22 did.
6. **The records-request bundle disclosed invoices and billing items** in two
   sections. A records request is a legal disclosure, and it now shows the
   authorization and its own history: the same facts, from the record the
   practice actually has, with no second section that could read as a second
   charge.
7. **A leaked probe connection blocked a migration for three minutes.** One of
   my own dry runs was killed mid-transaction and held the lock. The probes now
   set `idle_in_transaction_session_timeout`, so the database lets go by itself.
8. **The reconciliation matched on prose.** The screen decided which rows were
   unpaid by comparing against the string "Unpaid invoice". The kinds are
   machine values now, and the words belong to the screen.

**One of mine that was wrong rather than the code.** A verify assertion claimed
the practice was owed 400 for one piece of work. A reversing journal is filed as
`source_kind` 'Reversal' against the journal it reverses, not against the
authorization, so netting the ledger by source alone reads gross. The ledger was
right: a submission withdrawn and remade is owed once, and that is now what the
script asserts. Worth knowing for every ledger test and report: follow the
reversal, or read gross.

**Chosen against**

- **Walling off the close.** Three rules came off the invoice and none of them
  had ever run. Promoting a dormant rule to a live wall is how a close stops
  over something nobody at the practice did - the owner's own reasoning for the
  90-day grace, applied to the forms and the completion. Both are computed and
  shown; neither refuses. The owner can turn the forms one on in one click, and
  the completion one is one word in the gate.
- **Backfilling a billing date.** `billed_work` dates history from the payment,
  because the invoice's own date *was* the payment date on all 139 rows, to the
  day. There was never a real billing date for that history, and inventing one
  would have told the payment lag that USOR pays same-day - the same trap §7
  avoided.
- **Making the duplication audit reach zero by loosening it.** See below.
- **A `(workbook)` prefix as an identifier.** §9 strips it, and two screens
  found their placeholders by matching that text, so stripping it would have
  hidden them from the code that manages them. They have a column saying what
  they are instead.

**Where §11 stands: 15 findings, now 11, and the audit itself was wrong.**

Five of its seven tracked facts were duplications between the authorization, the
billing item and the invoice. Both copies are gone, so those are resolved by
construction rather than by agreement - and `verify_one_door` keeps it that way
by refusing a second record, which is better than counting how far two have
drifted.

The audit was also reporting things that are not duplication. It flagged
filename collisions as duplicate files: two clients may both have an
"authorization.pdf". And it reported eleven screens reading one authorization as
eleven findings, when a fact read in many places is exactly a fact kept in one -
that check was measuring the opposite of the rule. An earlier version of my fix
guessed at which screens *show* a list rather than total one, and reported false
findings; a check that cries wolf is worse than no check, so that section now
reports and does not judge, except for one thing it can state exactly: the
working list is one component, and no screen lays out a second.

**What is genuinely left, and what each would take**

- **`clients.counselor_contact`** duplicates the counselor's email and phone,
  and disagrees with the counselor record on 12 clients. One migration to drop
  the column and read it from `counselors`, and the screens that show it. It is
  client data, so I have left it for a deliberate pass rather than folding it
  into a billing deploy.
- **23 file-path columns across 15 tables,** with the same stored object pointed
  at from two tables in three places: the inbox staging pair (130 objects, which
  is a pipeline and arguably correct), staff documents and staff files (10), and
  tax submissions (3). §11's "one document store" is a real piece of work and it
  is not billing's - it touches HR and tax records. Named here so it is not
  mistaken for done.

**Owed, and now paid.** `verify_warrants` lost an assertion about
`billing_position`'s figures in §§1-7, because every one of them came off the
invoice. It is back, read from the authorization: what was authorized, what the
warrant paid, and nothing still owed.

**Needs the owner**

- **Turning the USOR forms block on,** when the forms live in the system rather
  than on paper. One setting on Admin, and §13.10 is what makes it true.
- Nothing else. The 90-day grace and the 14-day warning are yours as before.

**Not built, and deliberately**

§12.1 (an authorization read off a dropped PDF) and §13.10 (USOR forms generated
from the record) are the two you put after the 15th, and they are not here. The
typed form and the documents-folder confirm queue are what Add authorization
offers today. §13.14 wants quick-add to offer "Add authorization (from PDF)",
which waits on §12.1; quick-add offers one billing action today, Log hours, and
no invoice.

---

## §§13.11, 13.13, 13.15: the rate comes from the schedule, one alert per record

Deployed `3834650`, 7 Oct 2026. Migrations 0169-0170, one new verification
script, three rewritten.

**There were two rate schedules.** One is the table Admin can edit; the other
was `SERVICE_DEFAULTS`, hard-coded in `lib/constants.ts`, in the CRM's service
names rather than the workbook's - and the hard-coded one is what the Add
authorization form filled in.

They disagreed, and it mattered. **The code said Job Development + HQ Indicator
was 560. The schedule says 1,120, and the practice has billed it at 1,120
twelve times** - it is the development fee at 560 plus one High Quality
Indicator at 560, which the workbook expresses as two rows rather than one. So
the form has been offering half the rate for its second busiest service, and
the only thing between that and a short payment was whoever typed over it. This
is the "4.50 instead of 45.00" the form warns about, in the form's own default.

The duplication audit could not see it, because one of the two copies was
TypeScript. Worth remembering: that audit reads the database, so a fact
duplicated between the database and the code is invisible to it.

The schedule wins, because it is the document USOR and the practice agree on
and Admin can change it without a deploy. Each of its rows now says which CRM
service it prices, the one the workbook expresses as a sum has a row of its
own, and the form reads `service_rate()` and shows where the figure came from -
so a different number on the PDF is a decision somebody makes rather than a
field they overwrite without knowing what it was. A rate changed in Admin is
the rate the form offers, with no deploy, and that is asserted. The code copy is
deleted.

**One alert per record (§13.11).** The record and the working list already
showed one line. The alerts did not: three separate kinds were raised per
authorization, and one ending soon with its hours nearly gone raised two of
them - so somebody clearing their notifications saw the same piece of work
twice with no way to know it was once. They are one alert now, carrying the
same sentence the record and the list carry, from the same function.

Which meant hours-low had to join that function, since §13.11 names it among
the four. Running out of hours now sits just below "cannot be submitted" - it
is the one of these that means stop serving somebody rather than get on with
billing - and it is the one alert that still reaches Job Search. A kept
placeholder raises nothing: §9 took it off the working list, and it has no
business alerting either.

**Two more things quietly wrong**

1. **The chase keyed off `followup_due` alone.** That column is set when the
   status moves, so it is normally there - but an authorization submitted
   ninety days ago whose follow-up date was never set would have been chased by
   nobody. It reads the submission's own age too. Keying off the fact rather
   than a column derived from it.
2. **No billing tile on the dashboard at all** for billing staff; the money
   counters are Admin's (§13.16) and rightly so, but §13.15 asks for one
   number. It is there, counted by the same function the working list counts
   itself with, so the tile and the list cannot disagree.

**§13.16, checked rather than built.** No alert carries a money figure to
billing staff - the one they see says "submitted 45 days ago with no payment",
which is a chase and not a figure - and every roll-up is already behind Admin.

---

## §§5, 12.5: coaching hours land on the month, and the month is the bill

Deployed `d9525be`, 7 Oct 2026. Migrations 0171-0174, six verification scripts
rewritten.

**Every coaching month would have been billed at nothing.** Hours logged
against a coaching authorization stayed on the authorization; `authorization_
amount` for a month counts only that month's own entries; and both places that
log hours offer the authorization, not the month. So the working list would have
shown nothing to bill, the checklist's Amount line would have failed, and the
ledger would have posted nothing - for the practice's only monthly service and
most of what USOR pays for.

Nobody had hit it because the two months that exist were opened by the fold and
no hours have been logged since. Margaret's first coaching month would have been
the first to find out.

Hours now land on the month they were worked, and the month is opened if the
calendar has not reached it - nobody logging Tuesday's hours should have to know
whether October exists yet.

**Fixing it broke the same thing in five more places,** each asking "what hours
are on this authorization?" by looking only at the row it was handed:

1. **The hours cap waved coaching hours through entirely.** A month carries no
   `total_hours` of its own (§5), so the guard found null and returned early -
   no cap at all. It counts across the authorization and every month under it
   now, against what the authorization actually says.
2. **`committed`** - "authorized, not yet earned", on the dashboard - read a
   twenty-hour authorization with every hour worked and billed as 900 of work
   still to do.
3. **`hours_left`** read that same authorization as having every hour still
   available.
4. **`service_date_for`** could not find a coaching parent's first billable day,
   and dated everything today.
5. **A coaching warrant line stopped matching.** The stub prints the parent's
   V-number and the parent holds no hours, so every coaching payment went to the
   review list. A line resolves to the month it paid now: the one submitted for
   that amount, exactly one of them, or it waits. Twelve months at the same rate
   come to the same figure, and guessing which month a warrant paid is how one
   gets marked paid twice while another waits for ever.

So **"this authorization's hours" has one definition** -
`authorization_entries()` - and the readers ask it rather than each keeping
their own. Four of the five above were found by tests rather than by looking,
which is the usual way, and is the argument for the definition being one thing.

**Chosen against.** The economics view keeps its own inline sum, with a comment
saying there are two and why: it is a spliced definition built from a chain of
CTEs, and threading a set-returning function through it would buy correctness
that is already there at the cost of a rewrite nobody asked for.

**A fixture that had to change its method, not its expectation.** Over the
authorized hours can no longer be reached by logging - the cap refuses it across
every month. The way it happens in practice is an amendment: USOR reducing an
authorization below what has already been worked. That is what the fixture does
now, and it is a better test for being the real path.

---

## §12.1, §13.10 and the counselor's phone number

Deployed 8 Oct 2026. Migration 0175, one screen removed, one check added.

**§12.1: the PDF is the way in.** Reading an authorization off its PDF already
worked - the parser finds the number, the service, the hours, the rate and the
dates by labelled patterns, with no model and nothing leaving the building - but
it lived on a screen of its own while the typed form sat on Billing as the
obvious thing to do. They have swapped places. Dropping the PDF is the primary
Add authorization, at the top of Billing; the typed form is behind a fold,
labelled for what it is for, which is a scan with no text in it. The separate
screen is gone and redirects, because two screens doing one job is what §11 is
about.

**Two things that were wrong with the PDF route, and the second is worse**

1. **It threw the PDF away.** The file was read, parsed and dropped, so an
   authorization entered from its own authorization document had no document on
   it. The PDF is now kept when it is read and moved into the client's folder
   when the client is known, with one attachment row pointing at it - one
   object, never a copy (§11). It also makes the checklist's "Signed
   authorization attached" line true for anything entered this way, which it
   could not be before: 8 of 22 live rows have that line green.

2. **It had been broken for two deploys.** It inserted into `authorizations`
   directly, and 0168 revoked that from everybody - so the route this brief
   makes primary answered with a permission error. `verify_one_door` asks which
   *functions* create a bill and never thought to ask about the app.

   There is a check for that now, and it was written against the break: it
   catches the old code and passes the fixed version. A rule the database
   enforces still needs a check in front of it, because "the database will stop
   it" means the person using the screen finds out, not the person writing it.

**§13.10: forms are generated, not filled.** The machinery was already there -
each USOR form is filled in from the record and the service log, rendered by the
one renderer, and signed by the completion recorded against a name. What was
missing was the way to it from the record that needs it: the authorization said
"still wanted: DWS-USOR 93 + 95" and offered no way to produce them.

It does now, one button per outstanding form, and the forms already produced are
listed beside them. And the blank-form picker is gone from the client's
Documents tab: it asked which form, which authorization and which month - three
questions the authorization already knows the answers to - and a second way to
make a form is a second way to make the wrong one. The tab still lists them,
because that is what a documents tab is for.

Coverage is every form the practice produces: 60, 92, 93, 94, 95, 96 and 148.
USOR 98 is not on the list because it is received from the counselor, not
produced.

**§11: a counselor is reached one way.** `clients.counselor_contact` was a
free-text box on the client's profile for the counselor's phone and fax - the
same fact the counselor's own record holds, and the audit found the two
disagreeing on twelve clients.

Looked at closely, every one of the twelve was a phone number, and none held an
email. On the last ten digits: **eight were the counselor's own number in a
different format** (8014462560 against (801) 446-2560), two were the only record
anywhere of one counselor's phone, one carried a fax the counselor record
already had, and two were truncated to nine digits, which is not a phone number.

So the column was not simply dropped. The one phone number that existed nowhere
else was moved onto the counselor first, matched on the data rather than by
name, and the truncated pair was left behind deliberately - both of those
counselors have a complete number on their own record. Then the box went, and
the profile reads the counselor instead of asking.

**Where §11 stands: 10 findings, all of them the one you deferred.** Checks 1
and 3 are clear - no fact is kept in two tables, and the working list is one
component with no second version of it. What remains is §11's "one document
store": 23 file-path columns across 15 tables, with the same stored object
pointed at from two of them in three places - the inbox staging pair (130
objects, which is a pipeline and arguably correct), staff documents and staff
files (10), and tax submissions (3). That is HR and tax plumbing rather than
billing, and it is yours to schedule.

---

## ERP Controls: the 1099 tie-out follows the reversals

Deployed 8 Oct 2026. Migration 0176, one assertion added.

The ERP brief's Controls name six things that must be verified. Five already
were - debits equal credits, the trial balance balances, every source event
posts once, a bank reconciliation cannot close with a difference, a closed
period refuses writes. The sixth, "1099 tie-out equals payables", had a hole.

**The tie-out could not see a reversal.** It counted the ledger side by naming
the payment kinds - 'Contractor payment' and 'Vendor bill' with a Paid event -
and a reversal is neither: `reverse_journal()` files it as source_kind
'Reversal' against the journal it reverses. Measured, by paying a vendor bill of
500 and undoing it the way the books undo things: **recorded 0, posted 500,
difference -500.** A phantom, in the one report somebody has to be able to trust
in January, and the kind that sends a person looking for an error that is not
there.

It also had to decide which year a reversal belongs to, and the answer is the
year of the payment it undoes - not the day somebody got round to undoing it.
The operational side already works that way, reading the bill's own paid_on,
which goes back with the payment; a tie-out whose two sides answer for different
years cannot balance.

**This is the third time the same shape of mistake has turned up**, and worth
naming as a pattern: a reversal is linked by the journal it reverses, not by the
thing that was paid or billed. Anything that filters journals by source and sums
reads gross. A report that sums *by account* is safe, because the reversing
lines land in the same accounts - which is why the general ledger and the
records-request bundle were not affected, and I checked rather than assumed.

---

## §13.14: quick-add's two billing actions

Deployed 8 Oct 2026. No migration.

"Quick-add offers two billing actions only: Add authorization (from PDF), Log
hours." It offered neither, and the thing that looked like one was something
else: **"Work session" writes `work_sessions`, which is what somebody did with
their day, not `service_entries`, which is what the practice bills.** Conflating
the two is how a month of coaching ends up as nobody's billable time, so both are
offered and both say which they are.

**Log hours** picks the authorization, not the client - the authorization implies
the client, and the hours land on the month they were worked by themselves
(0171), so asking for a month would be asking somebody to do what the database
does. It hands off to the same action the Hours tab uses, so the rules about
future dates and authorized hours live in one place.

**Add authorization** is a link to the PDF drop on Billing rather than a form.
An authorization read off its own document is the point of §12.1, and a quick
form that let somebody type one would be the second door §10 closed.

There is no invoice action, and the cap is the brief's: two.

---

## Where the two briefs stand

**Billing Simplification Brief: §§1-13 are built.** The one thing outstanding is
§11's "one document store" - 23 file-path columns across 15 tables, with three
pairs pointing at the same object - which the owner has deferred to a later pass,
and which is HR and tax plumbing rather than billing.

**ERP Brief: E1-E5 and the Controls are built and verified.** What is left is
owner input, which is listed in the brief itself: the chart of accounts and
opening balances with the CPA, the books start date, cash or accrual as the
default, which bank accounts to import, the approval threshold for bills, asset
lives, and the cash floor for the alert.

**Also waiting on somebody other than me**

- Turning the USOR forms block on, once the forms live in the system rather than
  on paper. One setting on Admin; §13.10 is what makes it true.
- Melanie's Outlook connection for billing@zionvocrehab.com still has no
  connection row, so mail from that address cannot be verified from here.

---

## The 404 under Billing, and the checks that were not running

Deployed 8 Oct 2026. No migration.

**What I could and could not reproduce.** Every link on the Billing working list
and on the client's Billing tab resolves: the client link, the record link, the
filters, the warrant review, the confirm queue. I checked them against the real
route map, and checked the data too - as a Billing user, under RLS, the
authorization record and the client record both return rows for every row on the
worklist. So I could not reproduce a 404 from the code as it stands, and I am
not going to claim a fix for something I did not find.

**What I did find is one removed route with no redirect.** Five routes came out
in the billing work; four got a redirect and `/billing/items/:id` did not. For
anybody with a bookmark, or a tab left open on the old Items table, clicking a
row answered 404 - which is the most likely thing that happened, and is a fault
either way. It redirects to the working list now. Not to an authorization,
because it cannot: a billing item's id is not an authorization's, and the item
table is gone, so there is nothing left to look the pairing up in.

**Then the part that matters more than the bug.** `check-nav` ran nowhere. Not
in `prebuild`, not in a workflow - the only workflow is the smoke test. So every
check I have added to it in this session gated nothing: the one that refuses an
offer to raise an invoice, the one that refuses a bill written round the door,
and the nav checks that predate them. I had been running them by hand and saying
"the build will catch it next time", and the build would not have.

Every file-only check is in `prebuild` now - nav, exports, agent routes,
filename rules, screens - so they run on `npm run build`, which is what Vercel
runs, which means a deploy fails rather than a reviewer noticing.

**And a dead-link check,** because this class needs one: tsc does not read
strings, the build renders pages rather than following links, and the smoke test
opens the screens the navigation lists rather than the links those screens emit.
It collects every route that exists and every redirect, extracts every link the
app writes, and reports any that reaches neither. 41 linked paths, all of them
landing.

**Two things about writing that check, both of them mine.** Its first version
reported two findings that were artifacts of my own extractor, and it passed a
link to the removed `/billing/items/<id>` - because it dropped a trailing
interpolated segment and found `/billing/items`. An interpolation after a slash
is a path segment and an interpolation stuck to the end of one is building a
query string; the text says which, and the check now tells them apart. I only
know it works because I put the bug back and watched the build fail on it, which
is the only way to know a check works.

**The smoke test follows the links now.** It already reached the authorization
record from the list rather than by URL; what it did not do was follow anything
else the list offers. It follows up to twenty links from the Billing list and
from the client's Billing tab, and a 404 or a server error among them fails the
run. A link this role cannot open is said as an annotation instead of failing:
that is a judgement about what to show somebody, and rolling a deployment back
over it would be wrong.

**And then the checks failed the deploy, which is the point of them.** Putting
the file-only checks into `prebuild` broke the Vercel build, so that commit
never shipped and production stayed where it was. Two of the five only ever
worked in my own working copy:

`check-screens` worked out a file's project-relative path by splitting the
absolute path on "/zion-crm/". In a checkout named anything else - a worktree,
or the clone a deployment builds from - the split found nothing, the path stayed
absolute, and the exemptions, which compare against "app/(app)/page-head.tsx",
matched nothing; the check then reported the four components it exists to
exempt. **That is the "screens check fails inside a worktree" note I have been
carrying as a quirk for weeks.** It was a bug, and writing it down as a quirk is
what kept it alive. Paths come from the script's own location now.

`check-agent-routes` looked for one exact newline and four spaces between two
calls. A Windows clone gets CRLF from git by default and matched neither.

Both verified the way the first attempt should have been: in a fresh clone, with
CRLF line endings, prebuild runs all ten green - and then the real deploy
succeeded and the smoke test opened six authorization records reached from the
list.

**One more pass on the smoke test.** Following every link on a page also follows
the sidebar, which is in every page's HTML, so it warned three times a run about
hub roots a role cannot open - a question about the sidebar, and already the
navigation checks' business. The sidebar's own entries are skipped. An
annotation that fires every time is an annotation nobody reads, which is the
same argument that got the duplication audit's third section rewritten.

---

## The 404 was Open on the documents-folder queue

Deployed 9 Oct 2026. No migration.

**Found, and it was mine.** Open on every row of "From the documents folder"
emitted `/billing&doc=<id>#from-documents`. The href was built by appending
"&doc=" to a base that came from `withBo(...)`, and that worked for as long as
the base was `/billing?tab=authorizations`, which always carried a "?". §9 made
the base `/billing`, and from that moment "&doc=<id>" was part of the path
rather than a parameter. Eighty documents, every row, 404.

It is composed with URLSearchParams now, so there is no arrangement of the two
filters where the separator can be wrong - checked against all four.

**Why nothing caught it, including the checks I had just written.** The link
comes out of a callback rather than out of an `href="..."`, so the dead-link
check could not see it: that check reads the links written out, and this one is
built. And the smoke test's link follower refused any href carrying a fragment -
so the one link on the page that was broken was the one link it skipped. Both
of those were my blind spots, written the day before.

Three things close it:

- **A rule about building links.** In a URL-shaped template literal, "&name="
  must have a "?" in front of it; where it cannot, the query belongs in
  URLSearchParams, which gets the separator right by construction. Proven by
  putting the bug back and watching the build fail on it.
- **The follower drops the fragment** instead of refusing the link.
- **Open is clicked on purpose.** The first row's href is read off the page and
  opened, and the assertion is not just that it answers: the row that was
  clicked has to come back showing as the open one, which is what says the
  document view - its PDF and the pick-and-confirm form - actually came up.

**What I keep learning the hard way.** Twice now a check I added has been
written against the shape of the code I was looking at rather than the shape of
the bug: the dead-link check that read only literal hrefs, and a follower that
treated a fragment as a reason to skip. A check is worth what it catches, and
the only way to know is to put the fault back and watch it fail - which is now
how each of these got signed off.

---

## §11's file-path pass: the rule already held, the audit was asking wrong

Deployed 9 Oct 2026. No migration.

Ten findings, and **not one of them was a copy.** §11 forbids a file stored
twice - "a PDF exists once, in the client's file; an authorization, a form, a
note, a warrant line, a records request *reference* it" - and the audit was
counting references, which is the thing §11 asks for.

Measured properly:

- **No duplicate objects anywhere.** No fingerprint appears at two paths, in the
  inbox, the warrant documents or the tax submissions.
- **`inbox_documents.sha256` is UNIQUE**, so the same file arriving twice is
  refused by the database - which is §11's "the fingerprint matches and the
  second copy is dropped". The verify suite has asserted it all along: "the same
  file in two folders is one document, whatever it is called."
- The 647-object "overlap" between `attachments` and `inbox_documents` is one
  object named by its arrival and by its filing. That is the reference.

And three of the ten were worse than wrong: **the audit was comparing views
against the tables they read.** `inbox_pending` is a view over
`inbox_documents`, `staff_documents` over `staff_files`, `updates_for_me` over
`updates` - so the same rows were being reported as two stores of one file.

So the pass is a rewrite of the question rather than a change to the data:
tables only, the same bytes at more than one path, and the fingerprint rule
asserted so it cannot go quietly. The column inventory stays as information.

**One more of the same mistake, found while here.** Section 1 noted every fact
it knew about whatever the drift query returned - so it reported a fact as
duplicated while saying in the same breath that nothing disagreed, and a count
that *could not be taken* was reported in the same words as a count of zero.
A finding is drift now. A count that fails to run says so.

**The audit finds none**, and `--check` passes, which is what §11 asks for. It
is not in `prebuild`: it needs the database, and a build that cannot reach the
database would fail for the wrong reason.

**Why check 2 was wrong in the first place.** It is the third section of this
audit I have had to rewrite for the same reason: it measured something easy to
count rather than the thing the rule forbids. Section 3 counted screens that
read a record. Section 1 counted facts rather than drift. Section 2 counted
references rather than copies. The lesson is cheap to state and I keep paying
for it: write the check against the sentence in the brief, not against the
shape of the data.

---

## The idle check was racing the sidebar

The idle check failed on a healthy deployment: "signed in, but the sidebar
offered no links to follow", three seconds in, on the same commit where the
smoke test opened forty screens and passed. It reads `nav.side a[href]` as soon
as `quiet()` returns, and `quiet()` returns as soon as no request has been made
for a moment - which is a beat before the sidebar is in the DOM.

It waits for the links now. If the sidebar genuinely has none the wait times out
and it still fails; it just no longer fails by reading too early.

Production was not rolled back: only the smoke job does that, and smoke passed.

---

## End-to-end on production, as Billing

9 Oct 2026. One fix: the service the PDF reader claims to have found.

Run against the production database as a real Billing member - `authenticated`
with their claims, so RLS, the grants, the triggers and the submit gate all
applied as they do for them - inside one transaction, rolled back. Checked
afterwards that nothing survived: no ZZ authorization, no hours, no journal, and
the books-start I borrowed back at 1 Jan 2027.

    1.  read the PDF                     works
    1b. kept and filed in storage        works
    2.  confirm it from the folder       works
    3.  change its end date and bill-by  works
    4.  log hours against it             works
    5.  submit it                        works (the record's move; no email)
    6.  open it from the client record   works

**Not covered, and not pretended otherwise.** Signing in as a person needs
their password, which is not mine to type, so the HTTP layer and the server
actions were not exercised - the screens themselves are covered by the smoke
test, which opens them on every deploy and now clicks Open on the confirm queue.
And Submit emails the packet to USOR about a real client: the record's own move
is proven, the send is not, and it should not be proven by sending one.

**One real defect, found and fixed: the service was being invented.** The
reader's label for the service is the bare word "service", which is all over a
USOR authorization in prose, and the value was any three-to-sixty letters after
it. Over 186 real authorizations it claimed a service on nineteen, and most of
those nineteen were wrong - an email address, "services/materials. Final
invoices must be submitted within ninety (90)", "services at $45.00 per hour".
The service decides which USOR forms are required and the day the work must be
billed by, and it arrived on the confirm form looking as though the document had
said it. It is matched against the services the practice bills now, longest
first so "Job Development + HQ Indicator" is not read as "Job Development", and
anything else is left for the person to pick. Nothing had ever been saved from
it - the import action refuses a service that is not on the list - so what was
wrong was the reading.

**What the reader actually manages on real forms,** now that I have looked:
the authorization number off 136 of 186, start dates off 180, end dates off 177,
the client off 165. The hours and the rate it does not read at all - 131 of the
186 report both as missing - which is worth knowing, because the screen's own
warning is about a rate keyed as 4.50 instead of 45.00 and that rate is being
typed every time.

**Two things I got wrong on the way, both the same mistake.** I twice declared a
defect from querying the wrong field key - first `number` instead of
`authNumber` against the stored parses ("136 of 186" read as "none of 186"),
then the same key in my own harness, which made a working parser look broken.
Both times the fix was to print what the code actually returns instead of
assuming what it is called. The service defect is the one that survived
checking.

---

## Four fixes: the test rows, deleting a client, the list, and the way back

Deployed 9 Oct 2026. Migrations 0177 and 0178, two new checks, one new screen
panel, eleven headers.

### 1. The test counselor in the directory

**Nothing was found in production, and that is the honest answer.** Every text
column in the database was swept — 517 of them across every table, plus
`auth.users` — for ZZ, ZQ, V0000 and the other fixture shapes. Zero matches.
Counselors, clients, staff, authorizations, service entries, attachments,
documents, notes, contact log, tasks, work sessions, vendors: clean. So there
was nothing to delete, and nothing was deleted.

What was wrong was that this could not be *shown* before, which is the half
worth keeping:

**`verify_zz_no_fixtures.sql`** asks the question directly and fails if a
fixture-shaped row is ever committed. It is static SQL rather than generated,
because the first version was generated and it cried wolf: `format()` built
predicates that reported six hits in `directory_changes.entity_name` and five
in `inbox_documents.ocr_text` which three separate checks in node disproved. A
check that reports findings nobody can reproduce is worse than no check. The
rewritten one was proven the other way round — a leaked `ZQ Leaked Counselor`
was inserted and committed, and it caught it.

**`scripts/check-verify-scripts.mjs`**, now in `prebuild`, makes the leak
impossible at the source: every verification script that writes must have
exactly one `begin;`, exactly one `rollback;`, no `commit;`, and nothing after
the rollback. It reads all 84 of them and reports: 79 that write all roll back,
none commits, 5 are read-only and need no transaction. A script that forgets its
rollback now fails the build rather than leaving a row behind.

### 2. Deleting a client

Admin can remove a client. This needed care, because a delete is the one
operation nobody can inspect afterwards.

**The rules, in `delete_client(client, reason)`** — Admin only; a reason
required and a reason of spaces refused; refused while any authorization is
Submitted or Paid, and the refusal *names which ones*, because "close those
first" is useless without them; refused while a legal hold stands or a records
request exists. Recorded before anything is removed, in `client_deletions`,
which has no foreign key to clients on purpose — the row has to outlive the
thing it is about. And DELETE on `clients` is revoked from everybody, so the
function is the only door: a delete that goes around it would carry no reason
and leave nothing saying it happened.

**What it ran into.** Thirty-three tables name a client. Twenty-one cascade,
which is the point — their notes, tasks, forms, files, authorizations. Eight
keep their row and let the client go, because they are the practice's record of
what it did rather than the client's. Three of those eight are append-only, and
an emptied pointer is still an update, so they refused:

| | |
|---|---|
| `access_log` | refuses every update, full stop |
| `journal_lines` | refuses every update, full stop |
| `work_sessions` | refuses any change to the fields that make a claim |

Which meant **a client who had ever been looked at could not be deleted** — and
every real client has been looked at. The first working version of this feature
did not work on a single live record. The test found it, not a screen.

Two different answers, because the two cases are not alike:

- **The ledger keeps its rule and the delete is refused instead.** A client the
  books name is not deleted; they are closed. Nothing about `ledger_append_only`
  changed.
- **The access log and time records learned one narrow exception**: a
  `client_id` may go from a value to null, and only to null, and only when that
  client no longer exists. Nothing a row asserts is touched — the log still says
  who opened what and when, the time record still says who worked which hours on
  which day. Only the pointer to a record the practice decided was never real is
  emptied, and `client_deletions` keeps that name and id.

  The exception cannot be used as an edit, which is the whole reason it is
  phrased that way: from a screen the client still exists, so the guard refuses
  exactly as before. Only the referential action, firing after the parent row
  has gone, ever sees the state that allows it. Both directions are tested.

**What the record says.** `client_deletions` carries the name, the client
number, the stage and status, the reason, who, when — and two counts read from
the catalogue rather than from a list somebody keeps up to date: `carried` (what
went with them) and `cleared` (what kept its own row with the pointer emptied).
So "it cascaded cleanly" is a number somebody can read rather than a claim. A
real delete in the test records `{"notes": 2, "tasks": 1, "legal_holds": 1,
"authorizations": 1, "client_stage_history": 1}` carried and `{"access_log": 1,
"work_sessions": 1}` cleared.

**The screen.** On the client's profile, Admin only. It says what Closed does
first and points at it, because that is what almost everybody who opens this
actually wanted. What is left is deliberately slow: a reason, and the client's
name typed out. The typing is not security — it is the step that makes you read
which record you are on, which is the mistake this is most likely to be. Every
refusal comes from the database and is shown as it arrives; the screen holds no
second copy of the rules, because it does not know which authorization is still
Submitted and the database does.

**`verify_client_deletion.sql`** — eighteen checks: each refusal from the
direction that would break it, the exception tried as an edit and refused, the
cascade counted both ways, the merged record keeping its life, and the audit row
reading true. The ledger case posts a real line rather than asserting the rule,
and unwinds it by failing the block it was made in — which is the only way to
take something back out of a ledger that refuses a delete as firmly as an edit.

### 3. What leaves the working list

Migration 0177. §9 says "if a row needs no action from the person looking at it,
it doesn't show", and two things did show: an authorization belonging to a
client the practice had closed, whatever its own status. `billing_worklist` now
excludes them. Live effect: 16 rows down to 14.

Closing the client does not rewrite the authorizations — they keep their own
status and stay readable on the record, so the history still reads true. They
are simply not work any more. And reopening the client brings its live work
back, because the decision that took them off is the only thing that put them
there.

**`verify_the_list_is_actionable.sql`** proves all five: Closed leaves at once,
Paid leaves at once, a closed client takes all their work off, the statuses are
not rewritten, the dashboard count agrees with the list, and reopening restores
it.

### 4. The way back out of Books

Every sub-page under Billing → Books — Reports, Journals, Chart, Bank, Bills,
Vendors, Budget, Forecast, Assets, Close — now draws the shared `RecordHeader`
with a back arrow to the Books overview, instead of `PageHead`, which has none.
A bank statement goes back to the statement list it came from rather than two
levels up past it. `check-screens` holds the line: all 63 screens draw the
shared screen or record header.

---

## The ZZ rows, and a way back off every screen

Deployed 9 Oct 2026. Migration 0179, thirteen screens, one new check.

### The test counselor was real, and I had said it was not

Last deploy I reported that a sweep of every text column found no leftover
fixture rows, so nothing was deleted. That was wrong, and the owner was right:
six rows reading **"ZZ Report Test Counselor"** were sitting in Recent changes
on Counselors → Directory. Three Added/Removed pairs, ninety seconds apart, 21
Sept 2026.

Two separate failures put them there and kept them there:

1. **`verify_zz_no_fixtures.sql` never asked `directory_changes`.** It is
   written out table by table, from the list of tables the verification scripts
   write to - and the change log is written by a *trigger*, so it is on none of
   their inserts. The sweep came back clean because it did not look.

2. **The dynamic version had found them, and I threw the finding away.** The
   first draft of that script looped over `information_schema` and reported
   `directory_changes.entity_name` among its hits. I decided it was crying wolf
   and rewrote it by hand without that table. It was not crying wolf about this
   one. A detector reporting two things, one true and one false, is not a
   detector that can be dismissed as a whole, and I dismissed it as a whole.

**Where they came from decides what prevents the next one.** That name appears
nowhere in this repository and never has in any commit - so they were not left
by a verification script at all. They were committed by hand, by me in an
earlier session, inserting and deleting a test counselor while the counselor
report was being built.

Which means the guard the owner asked for - *stop the log recording rows
written inside a rolled-back transaction* - cannot be the mechanism: a log row
written by a trigger inside a transaction that rolls back goes with it, so
there is nothing there to stop. What put these in front of somebody was a write
outside any transaction, and the only thing that catches that is the name.

**So the log asks what it is being asked to record.** `directory_change_log`
now returns without writing when the name follows the fixture convention. It
holds however the write arrives: a script that forgot its rollback, a statement
run by hand, a probe left open. The convention is written down once, as
`is_fixture_name(text)`, and both the log and the no-fixtures check read it -
so what is refused on the way in and what is detected afterwards cannot drift
apart.

**The log had to be allowed to let them go.** `directory_changes` is
append-only, which is right, and it refused the delete - an append-only rule
protecting test data in a screen that could not be corrected. The guard learned
the same shape of exception the access log learned in 0178: a row the log would
now refuse to *write* may be removed. Nothing real can match it, because the
predicate deciding what goes in is the predicate deciding what may come out.

Six rows removed. One real entry left in the log (Melanie's, 8 Oct), untouched.

**Both halves are tested, and the detection half was proven by leaking a row on
purpose:** a committed `ZQ Leaked Log Row` makes `verify_zz_no_fixtures` fail,
and removing it makes it pass. `verify_directory_changes` checks that an
invented counselor leaves no entry **and that a real one still does** - a guard
that had quietly stopped logging everything would pass a test that only checked
the first half.

One consequence worth recording: the counselor that script asserts logging on
had to stop being `ZZ Dir Counselor`, since the log now skips that name. It is
`Oakley Dir Testperson` with a `zz-dir@example.test` address, which is the other
half of the same convention and is what `verify_zz_no_fixtures` already sweeps
counselors for - so if that script ever leaks, the counselor is still caught.

### A way back off every screen, not just Books

The sidebar gets somebody *to* a hub's screens. It never got them *off* one: a
sub-tab or a record page is reached by clicking into it, and the only way out
was the browser's own button or guessing which sidebar entry came closest.

Thirteen screens now draw `RecordHeader`'s back arrow, pointing at the screen
directly above:

| Screen | Goes back to |
|---|---|
| Settings → Mailboxes, Note headings, The practice, Tax years, Website chat, Work and hours | Settings |
| Billing → the authorization record, Warrants | Authorizations |
| Today → Needs attention | Today |
| Mail → New message | Mail |
| Paperwork → Onboarding, the policy | Paperwork |
| Knowledge base → Where do I…? | Knowledge base |

With the eleven Books pages and the six record pages that already had one, all
**30 screens below a hub** have the way back.

**The check is the point, and it checks the thing that is easy to get wrong.**
`check-screens` now reads `NAV_GROUPS` for what the sidebar can already reach,
and for every other screen requires the arrow **and** that it points at the
nearest screen above - which for a record's sub-page is the record, not the list
two levels up. Checking only that `back=` appears would pass an arrow aimed at
the wrong screen, and that is the mistake that looks right until somebody
clicks it.

Both faults were put back to prove it: removing the arrow from Where do I…?
fails with *"screens below a hub with no back arrow"*, and pointing the bank
statement at `/books` instead of `/books/bank` fails with *"back arrows pointing
past the screen above"*. Both were restored.

---

## Every screen says how to get out of it

Deployed 10 Oct 2026. One component, one layout line, one check extended, two
smoke assertions. No per-screen edits.

The last pass gave the thirty screens *below* a hub's tabs a back arrow and
left the tabs themselves without one — so Billing → Hours, Communication →
Texts, Clients, Books and twenty-three others still had no way out but the
browser's own button. Now every screen has one except the hubs' landings.

**Two kinds of screen, two different answers.** A record page goes back to
something only that page knows — this client, this statement, this request — so
it draws its own arrow on `RecordHeader`. A hub's tab goes back to where the
hub opens, which the navigation already knows, so a single component in the
layout draws that one for all twenty-seven of them. That is the argument
`group-tabs.tsx` already makes for itself and it applies unchanged: one list,
one rule for which tab is current, and adding a twenty-eighth screen to a hub
should not mean remembering a twenty-eighth arrow.

`HubBack` is handed the same `nav` the tab strip is handed and decides the
current tab with the same `currentItemHref`, so the arrow and the tabs cannot
disagree about where somebody is. The arrow itself moved into `back-link.tsx`
and `RecordHeader` draws that instead of its own copy — two definitions of one
affordance is how the records and the tabs came to have different answers in
the first place (§11).

**Which screens show none, and why it had to be decided rather than assumed.**
Work, Communication and HR open on a page of cards, which is not one of their
tabs — so every tab there gets an arrow and the landing is never one of them.
Home, Billing and Admin have no such page and open on their first screen, so
that screen is the one without an arrow. Six landings: Today, My work,
Communication, HR, Authorizations, Documents.

That last part is the whole reason this needed asking. **Billing → Hours is not
its own screen** — it is `/billing?tab=hours`, the same route as Billing →
Authorizations, and the same is true of HR's Statement approvals and
Certifications, Admin's Contractors, and Communication's Website chat. An arrow
"on Hours" is an arrow on the Billing landing unless the tab decides it, and
the owner's instruction said the landing should have none. So the tab decides:
`/billing` shows nothing, `/billing?tab=hours` shows "← Billing".

**What the check can prove, and what it cannot.** `check-screens` now reads the
navigation and requires every screen to be covered by one of the two
mechanisms: 27 hub tabs from the layout, 30 records and sub-pages from their
own header, 6 landings needing none — 63 in all. It also refuses a screen that
draws a second arrow under the layout's, and still refuses one whose own arrow
points past the screen directly above.

But it reads files. It can say the layout draws the arrow; it cannot say the
arrow *arrives*, because `HubBack` is a client component reading the current
tab and whether it reaches the HTML depends on how the route renders. A missing
arrow would look exactly like a screen that is fine. So the smoke test asserts
it on the screens as served — every hub tab each account reaches, with Billing →
Hours and Communication → Texts named, and a failure if either was never
opened by anybody.

Three faults were put back to prove the check: dropping `<HubBack>` from the
layout fails with *"the layout does not draw HubBack"*; handing it a different
navigation from the tabs fails with *"the arrow can disagree with the tabs"*;
and giving Knowledge base its own arrow on top of the layout's fails with
*"screens drawing a second back arrow under the layout's"*. All three restored.

One correction to the previous entry: there are **six** hub landings, not eight.
The code has six navigation groups, three of which (Work, Communication, HR)
have a landing page of cards and three of which (Home, Billing, Admin) open on
their first screen.

### What the deployment said, and the correction

`ed315aa` deployed successfully and the arrow was there on both screens the
owner named — the smoke log reads `Billing: /billing?tab=hours has the way
back` and `Job Search: /messages/texts?tab=texts has the way back`, across 43
hub tabs.

**And the new assertion failed on two screens, both because the assertion was
coarser than the component.** It is worth writing down which, because both are
real distinctions I had not seen:

- **Purchase requests is everybody's screen.** For a role that can open the
  rest of Billing it is a tab, and gets "← Billing". For a Job Search person it
  is the *only* Billing screen they can open, so it is that role's Billing
  landing — and an arrow there would point at `/billing`, a screen they cannot
  open. Which items a hub has depends on the role, and my assertion read the
  unfiltered navigation.
- **`/billing?doc=<id>` is the Authorizations tab with a document picked**, not
  a tab of its own. No `tab` means the first tab, which is the landing, so it
  correctly shows none. My assertion string-matched the href against a list of
  landings and `/billing?doc=…` is not literally `/billing`.

So the component was right twice and the check was wrong twice — the same shape
of mistake as §11's audit and the dead-link check before it: a check that asks
a question *near* the rule instead of the rule.

**The fix is one definition, not a better copy.** `hubBack(groups, pathname,
tab)` now lives in `lib/roles.ts` and three things read it: the arrow the
layout draws, the deploy check that asserts the arrow arrived, and twenty-one
cases in `check-nav` — including the two screens that failed on production, so
the subtleties fail the build rather than being rediscovered live. Putting the
coarse rule back makes exactly those two cases fail:

    FAILED  the way back is wrong: Billing on /billing?tab=hours goes back to nowhere, not /billing
    FAILED  the way back is wrong: Job Search on /requests goes back to /requests, not nowhere

---

## Intake automation, part one: the roles and the one reader

10 Oct 2026. Migration 0180, one module moved, one classifier question added.
Groundwork for the Intake Automation Brief rather than the intake itself.

### Job Coach and Case Manager

Two roles the practice had been working around. Both see every client; neither
sees Billing's money or Admin. Case Manager is what the database already calls
'Reports' under a name that says what the person does. **Rispah is a Case
Manager** - her record and invite were already there, so only the role was set.

Job Coach is Job Search plus one thing, and that one thing is the role: logging
billable hours against a **coaching** authorization. So it is a rule in the
database and not a checkbox on a screen - the client record offers a Job Coach
only their coaching authorizations, and `service_entries`' row rules refuse the
rest however the request arrives.

**Two things about that rule were wrong before the verification caught them,
and both are the kind that would have shipped quietly.**

1. The first version asked `exists (select 1 from authorizations ...)` inside
   the policy. A subquery in a policy runs as the person being checked, so it
   reads `authorizations` through `authorizations`' own row rules - and a Job
   Coach who cannot select the row gets `false`. It refused the coaching hours
   the role exists to log. Now a `security definer` helper answers.

2. That helper was `stable`, and that was subtler. Logging coaching hours fires
   `route_entry_to_month` (0172), a BEFORE trigger that opens that month's
   child authorization and points the entry at it. So by the time the row rules
   are checked, the authorization being asked about was created earlier in the
   *same statement* - and a `stable` function reads the snapshot from the start
   of the statement, where that row does not exist. It answered "not coaching"
   about a coaching authorization. It is `volatile` now.

   This took a bisect to find: pre-creating the month child as postgres made
   the coach's insert succeed, which pointed at the child's creation rather
   than at the check.

**The "Billing (to be assigned)" seat is gone.** The brief said to reassign
anything referencing it to Melanie first - checked across all 130 foreign keys
to `staff`, and the only references were its own two HR records, its onboarding
checklist and its employment row, which went with it. Nothing of anybody
else's pointed at it, so nothing was reassigned. The migration raises an
exception rather than deleting quietly if that ever stops being true.

`verify_job_coach_and_case_manager.sql`: eight checks, including that the four
roles that already existed are unchanged.

### One reader, because mail is a second way in

`readDocument` lived inside `app/api/agent/file/route.ts`, which was right
while the agent was the only way a PDF arrived. Mail from a counselor is a
second way, and a second copy of that function would be a second answer to "is
this an authorization" - the question the whole intake rests on. So it is
`lib/read-document.ts` now and both callers use it. Nothing about the reading
changed; `check-agent-routes` holds the same rules, asked of the file that now
holds them.

**The classifier answers one more question rather than gaining a kind.** A
referral is a USOR form - 94 or 98 - or a WSA referral that names no form at
all, so `Classification` carries `referral` alongside `kind`. The kinds are
what the document inbox stores and files by, and adding one would have meant
touching that; the question intake actually asks is "does this start a case",
which is now answered by the same classifier that answers everything else.

Seven cases hold it, and the ones that matter are the noes: a USOR 95 monthly
report is not a referral, and neither is an authorization whose own text says
"this authorization follows the referral dated...". Either read as a referral
would create a client from a document that is not one.

The WSA mark is words rather than a form number, which is the weakest kind of
mark there is - so it is asked last, only of a document nothing else has
claimed, and it can never take one from an authorization or a form.

---

## Intake automation, part two: email to client to authorization

10 Oct 2026. Migrations 0181-0183, one new route, three new modules, three new
checks. Rules 1-5 of the Intake Automation Brief, and Rule 4's reply.

### Where it reads, and what it leaves alone

Only **service@zionvocrehab.com**, and no personal inbox. It turned out to need
no new permission at all: service@ is already connected, as Francis's own
Microsoft connection, with Mail.Read and Mail.Send granted. A shared-mailbox
registration is read first in case that changes, so the connection can move
without the code knowing.

Only **@utah.gov** senders are acted on. Thirteen cases hold that, and the ones
that matter are the noes: `dana@utah.gov.example.com`, `dana@notutah.gov`,
`dana@utah.gov.co`, `utah.gov@gmail.com`. A referral is the one document that
can create a client, so the cheapest way in is the one worth closing. Everything
else is left alone - not read, not recorded against anybody, nobody notified -
and **the skip is logged**, which is how somebody answers "did the counselor's
email arrive" without guessing.

### Three parts, with a boundary between each

This is the shape the codebase already had for the nightly sweep, and following
it is what kept the thing readable:

- **`lib/intake-mail.ts`** holds the mail token. It reads, hands over each PDF,
  and thanks the counselor when told to. It never sees the database.
- **`app/api/cron/intake/route.ts`** holds the database client. Per PDF it reads
  with the one reader, stores it the way the agent stores one, and asks the
  rules what it is.
- **The rules are in the database** (0182). Client created, document attached,
  task raised and notification written in one transaction - so a client created
  without the task raised cannot happen. They hand back the words to email.

That split is why the rules are testable without a mailbox, which is the whole
point: they are the part that can be wrong in a way nobody notices.

### One notification, three places

`notify_person` writes the bell row, the My day item and returns the words for
the email. All three already existed and none knew about the others.

The useful discovery was that **the My day item and the intake task are the same
row**. My day reads `tasks` for the person, open, due today or earlier - so Rule
1's "raise the intake task" and Rule 5's "a My day item" were one sentence
written twice, which is exactly what Rule 5 says. One call, one task.

It is idempotent on its reference, because the mailbox is polled: a poll that
overlaps the last one must notify nobody twice. The task is keyed on the
assignee as well as the document, because a placement authorization is
Margaret's to confirm *and* Rei's to act on - two items, not a collision.

### What the rules refuse

- **A referral** creates the client only when none is on file; attaches and says
  "re-sent" when one is; and on an ambiguous name **creates nothing** and asks.
  Two records for one client splits their authorizations, hours and forms, and
  the splitting is only noticed when a bill is short.
- Known aliases are the names of records merged away - a merge already keeps the
  old row pointing at the surviving one, so the old name is already recorded as
  another way of saying the same person. That is why there is no aliases table.
- **An authorization never creates a client.** The name on it may be a
  misspelling of somebody who exists, and a client created from it is the
  duplicate Rule 1 goes to such lengths to avoid.
- A re-send **overwrites nothing**. What is on the record was put there by
  somebody; a form is not a correction. Blank fields are filled, nothing else.

### Four things the schema and the rules disagreed about

Each of these was found by the verification refusing something that had to work.

1. **The one door had to admit the intake.** `add_authorization` is the only way
   a bill comes into being (0168) and its guard is "Admin and Billing" - the
   intake is neither, running as the service role with nobody signed in. The
   guard now also admits `filing_caller_role() = 'service_role'`, the name this
   codebase already uses for that caller. The alternative was an insert of its
   own inside the intake, which is precisely what 0168 existed to remove.

2. **An authorization must carry a rate, and the brief says not to read one.**
   `rate` is NOT NULL and an hourly authorization must carry hours. So what is
   written says nothing rather than guessing: rate 0, which is the column's own
   default and means "nobody has said", hours 0 for the same reason, and the
   note says in words that they were not read. Whether it is hourly or flat is
   *not* a guess - `billing_service_rules.billing_type` already records it per
   service. The submission gate already refuses an authorization with no amount
   and no dates, so a figure nobody typed cannot reach an invoice.

3. **A policy's subquery runs as the person being checked.** Not intake - the
   Job Coach rule in part one - but the same lesson twice in one day.

4. **`min(uuid)` is not a function**, and `tasks.source_ref` is a uuid while a
   notification's dedupe key is text. One document can be the reason for two
   notifications to two people, so those are now two separate parameters.

### The reply, and the rule it widened

Rule 4: reply "Received, thank you." from service@, one per document, a re-send
getting the same reply.

Whether a reply is owed is a fact about the record, so **the database claims
it** - `intake_record_mail` records what was decided and returns whether this
run is the one that should send. Two overlapping polls cannot both thank the
counselor.

This is the first thing in the system that sends mail without somebody pressing
Send, and `check-mail.mjs` said so: *"only app/(app)/mail/actions.ts may"*. That
rule was right until today and is now not the whole truth, so it was widened
deliberately and the new sender is held to **much less** than the old one: it
may only *reply*, only with `THANKS`, never send or forward or delete, and never
touch the database. The check asserts every one of those. A rule that is nearly
true is worse than one that says exactly what it means.

The `resolveMailbox` rule needed the same treatment for the opposite reason:
that function answers "may this person open that mailbox", and the intake has no
person. So it is held to the stricter thing - it cannot choose a mailbox at all,
only read the one it is handed.

### What holds it

- **`verify_the_intake.sql`** - fifteen checks, the brief's own list.
- **`scripts/check-intake.mjs`** - the sender cases, and that there is one
  reader, one classifier, no OCR path of its own, and no notification wording in
  the route. Proven by putting both faults back: adding `extractPdfText` to the
  route and writing "New referral:" into it each fail.
- **`scripts/check-referral-parse.mjs`** - five cases, including that the office
  is not read out of "UTAH STATE OFFICE OF REHABILITATION" (the trap the
  authorization parser fell into on real forms) and that a referral with no name
  on it says so rather than inventing one.
- Both new checks are in `prebuild`.

A side effect worth noting: `scripts/check-auth-parse.mjs` had been **dead**,
failing on a module it could not resolve, and adding an explicit `.ts` to one
import fixed it. It passes now.

### Not done in this pass

Rules 6, 7 and 8 - the missing-authorization nudge at 7 and 14 days, the
authorization-ending chase at 30 days, and Hired starting the placement clock.
They are scheduled rules rather than mail handling, and they are next.

The brief's smoke step ("Margaret's My day shows the item after a fixture
referral") is not done as written: the smoke account is read-only by design
(0120) and cannot raise a referral, and it could not see Margaret's My day if it
did. What the verification proves instead is that the item is addressed to
Margaret, open, and due the next business day - which is the day My day will
show it, since My day lists what is due today or earlier.

---

## Intake automation, part three: chasing what has not arrived

10 Oct 2026. Migrations 0184-0185, one new route, one new verification. Rules
6, 7 and 8 - the last of the brief.

Rules 1-5 were about what arrives. These three are about what does not.

### Rule 6 — a referral with no authorization

Day seven and day fourteen, and no other day. The counselor is emailed from
service@ with Margaret copied in; after the second one it is a task and no more
email, because a third identical message is nagging rather than chasing.

**Reading it as "day 7 and day 14" rather than "7 days or more" is the whole
difference on the day it goes live.** The brief says "Repeat once at 14 days
with the same text; after that, task only" - so a client who has been at
Referral for three months has had both days pass and gets the task alone. The
other reading would have emailed every counselor in the practice about every
referral ever left open. Checked against the live data before committing to it:
**22 clients are waiting on an authorization today, and 0 of them would be
emailed.** From tomorrow it chases new referrals as they age.

The date a referral arrived comes from three places that disagree, so the
earliest wins: the contact log entry the intake writes (which carries the date
off the form), the stage history's arrival at Referral, and failing both the
day the record was made.

What was sent is counted in its own table rather than read back out of the
contact log. The log is what a person reads and it says a nudge went; counting
prose is how something gets sent three times.

### Rule 7 — an authorization about to run out

Thirty days before the end date, with hours left or a flat fee not yet
submitted: Margaret gets the task and the drafted request, billing@ hears too,
and **nothing is emailed to the counselor**. That is the brief's decision and a
good one - a renewal is a conversation and the practice's side of it should not
arrive by itself.

"Still has hours remaining" is read off `authorization_economics`, which
already knows that a coaching parent's hours are logged on its months (0172).
One ending in forty-five days is left alone; one with its hours used up is left
alone however close the end date, because there is nothing to continue.

### Rule 8 — the placement starts the clock

A hire now starts four things by itself. **This reverses a deliberate earlier
decision** and it is worth saying so: the screen used to read "Create the
placement when you are ready - it is a separate step on purpose." The brief
reverses that, so a hire records its date, starts the placement on it, sets the
four-week milestone and puts the first day of work on the placement
authorization.

**Two of the four needed nothing written at all, which is the good news:**

- **Bill-by is not written.** Job Placement's bill-by anchor is already
  `first_work_day` plus 28 days in `bill_by_defaults`, and `bill_by_for`
  computes it. So the one fact recorded is the first day of work, and "start +
  28" follows from it - the only arrangement where the two can never disagree.
- **USOR 60 and 92 are already outstanding.** `form_templates` marks both
  `required_for_billing` for Job Placement and `authorization_missing_forms`
  reads that. The verification asserts it instead of writing it a second time.

The milestone is set as the match's own follow-up date and nothing more:
`sync_match_reminders` (0117) already turns that field into a task and a
calendar entry and pushes it to Outlook.

**And that is where the one real bug was.** The first version set
`follow_up_on` in a BEFORE trigger, and nothing reached the calendar. The
reason is exact: `lead_matches_reminders` fires `after update of ...
follow_up_on`, and `update of` is about **the columns a statement names**, not
about what changed. A BEFORE trigger assigning the field does not fire it. So
the milestone is now set by its own `update` statement naming the column, from
the function that runs after the hire - and the verification watches for the
calendar row rather than for the date alone, which is what caught it.

Rule 8 runs on an AFTER trigger rather than from the screen, because the brief
says "when a job match is set to Hired" - not "when somebody hires through the
client record". A hire recorded any other way starts the same clock. A hire
with no placement authorization creates none and asks Margaret for one, which
is the brief's own carve-out: an authorization is USOR's to issue.

### The mail rule, widened once more and narrowed again

Rule 6 is the second thing that sends mail without somebody pressing Send, so
`check-mail.mjs`'s rule - which part two had narrowed to "this file may only
reply, and only with THANKS" - stopped being true. It now says the thing that
actually matters: **this file composes nothing it sends.** THANKS is a
constant; the nudge's words are built in the database beside the rule that
decides a nudge is owed, and handed in.

That check was wrong twice before it was right, and both are worth recording:

1. It flagged the module's own error strings ("a nudge with no words in it") as
   composed prose. Those never leave the building. It now looks only at what
   reaches a send call.
2. The fix matched on `));` where the call ends `});`, so it found **no send
   calls at all** and passed without checking anything - and a deliberately
   composed subject and body sailed straight through. The same shape of mistake
   as the dead-link check and the back-arrow check before it. Finding no send
   call is now itself a failure.

Both faults were put back and both now fail.

### What holds it

`verify_the_chasing_rules.sql` - seventeen checks, including the three that
decide whether this is safe to switch on: a client waiting three months gets no
email, a day between seven and fourteen gets no email, and a nudge already sent
is not offered again.

`check-intake.mjs` gained two: the chase route carries the words the rules
wrote and composes none of its own, and Rule 6's nudge is the only outbound
mail in it - so Rule 7 cannot quietly grow a send.

### Scheduling

`zion-chase` runs daily and is **left active**, because its first run provably
sends nothing (22 waiting, 0 emailable). The migration prints those two numbers
as it schedules, so the decision is visible at the moment it is made.

`zion-intake` - the fifteen-minute mailbox poll from part two - is still
**inactive** and still the owner's to switch on. Its first run would reply to
mail already handled by hand, which is a different risk entirely.

### One verification had to change its mind

`verify_job_tracker.sql` asserted the decision Rule 8 reverses, in as many
words: *"ok Hired creates no placement - that stays a separate decision"*. The
suite failed on it, which is the check doing its job.

It is rewritten rather than deleted, and it says in the script why: the brief
is the later decision and it is explicit, so a hire now starts the placement on
the hire date. **The half of the old rule the brief keeps is still checked** -
a hire creates no *authorization*, because that is USOR's to issue. So the
block went from two assertions to three and still guards the part that matters
about money.

---

## The intake is on, and the first run found a gap in it

10 Oct 2026. `zion-intake` switched on by the owner. Migration 0187.

**What the first run did: nothing.** Nineteen messages looked at, nothing sent,
no client created, no authorization, no notification. Thirteen were not from
utah.gov (the practice's own domain, gmail, yahoo, three advocacy
organisations) and were left alone entirely. Four were from utah.gov with no
PDF - two invoice replies, a résumé request. Two carried a PDF that was neither
a referral nor an authorization.

The thing that had been worried about - a morning of thank-yous to counselors
for mail already handled by hand - did not happen, because the recent mail
contained no referrals or authorizations at all.

**And one of those two PDFs showed that the brief was not finished.**
`rlhill@utah.gov` sent "Fwd: Scanned image from State of Utah", read as
Unreadable: a scan with no text layer. The Timing section says "Scanned PDFs:
queue for OCR, run the rules when text is available", and only the first half
was built. A scan is stored with no text, which is exactly what
`/api/agent/ocr-wanted` looks for, so the queueing needed no code - but nothing
looked at the document again once the agent sent the text back. A referral
arriving as a scan would have been read and then left sitting, creating no
client and telling nobody.

This was reported as complete in part two. It was not.

**What it needed.** `intake_scans_now_readable()` lists documents the intake
could not read which now have OCR text, and `intake_rules_ran_late()` records
what was decided and claims the reply that was never owed while the document
was unreadable. The intake route looks at that list on every run.

Deliberately narrow: only a document the intake *could not read* is offered
again. One it read and decided was 'other' was genuinely read, and asking again
every quarter of an hour forever is work that never ends.

**The risk this created, and what guards it.** A scan decided later is a second
place the rules are asked from, and two copies of "is this a referral" is the
one thing this whole pipeline cannot afford. So the decision was lifted out of
`onePdf` into `askTheRules`, which both callers use, and `check-intake.mjs`
fails the build if the rules are called directly more than the three times that
function contains, or if there is no single function at all.

The reply went the same way. There is now exactly one `replyOwn` call site in
the system - `replyToCounselor` in `lib/intake-mail.ts` - so what an automated
reply says can be read in one place, and the check holds every reply call to
THANKS.

`verify_the_intake.sql` is seventeen checks now: a scan is offered again only
once the agent has read it, and not a third time once the rules have run.

**Noted for the owner, unrelated to the gap:** two of the four utah.gov
messages with no PDF were counselors replying about invoices (Vicki Khun - Job
Placement Invoice, Carl Wilkins - Job Development Invoice). service@ is being
used for billing correspondence as well as referrals. Harmless, since the
intake only acts on PDFs, but worth knowing.


---

## Billing unlocked — 14 October 2026

*Owner: "Billing is too locked down. Build all of this together."*

Five asks, all built. Migrations 0190–0194, and `verify_billing_unlocked.sql`
alongside them — 36 assertions, including the owner's own three.

### What was actually locked

Not the permissions. RLS has let Billing write every column of
`authorizations` since 0121. The lock was in three places nobody would have
guessed from the brief:

1. **The state machine refused `Due → Paid`.** So clearing an old item meant
   stepping it through Submitted — and the Submitted gate checks the service
   dates against the authorized period and refuses anything more than 90 days
   past its end date. Which is exactly the backlog. The gate exists to stop a
   packet going out that USOR will return; recording money that already
   arrived sends nothing.
2. **`correct_authorization` was Admin-only and handled two fields** — service
   and client. Everything else could be changed in principle and on no screen.
3. **No screen offered any of it.**

### A blocker that turned out not to be one

`ledger_period_open()` raises when an entry is dated before `books_start`, and
`books_start` is 1 January 2027. A payment recorded today looked like it would
be refused by the ledger.

It is not: `post_journal` returns null before the books open, so a payment
recorded now posts nothing and raises nothing. The ledger stays untouched
until January, which is what the owner's rule 5 asks for anyway. Tested
directly rather than reasoned about, because the whole of asks 1 and 3 rested
on it.

### What changed

**The receivable is raised on the way past.** This is the part that would have
lost money quietly. `post_authorization` debits AR at Submitted and credits it
at Paid. A record going straight to Paid never met the first, so the second
would have credited a receivable nobody raised — the trial balance would still
balance and AR would be short by the amount, silently, forever. So reaching
Paid from anything but Submitted now makes the Submitted posting first.

Nothing posts today, because the books are shut. The wiring is proven against
a temporary start date, the way 0157 did it.

**A reason is asked for at the moment the value moves,** by a trigger rather
than by the screens — because the sweeps, the imports, the agent and three
screens all write this table, and a rule that lives in one caller is a rule
the next caller does not have.

And it is asked for on a *correction*, not a first entry. Filling in a number
that was blank is recording what the paperwork says; changing a number that
was already there is a correction. That distinction is load-bearing: warrant
reconciliation writes `paid_amount` where there was none, and requiring a
reason for that would have stopped every payment the warrant reader records.

**A payment recorded by hand is not paid twice.** Clearing a months-old item
usually means a remittance with no warrant number — the stub arrives weeks
later in a scan. The warrant reader now recognises a by-hand payment with no
warrant number, claims it, and writes the number it never had onto both the
payment and the record. An exact warrant match still wins.

**Bulk clear reports per row.** Each row is its own savepoint, so one row that
cannot be priced does not take the other nine down. Six of the twenty-one open
authorizations come to nothing (hourly, no hours logged) — those are named,
with what stopped them, rather than passed over in silence.

**Clients joined the directory change log** (0192) instead of getting one of
their own. Their stage changes were kept; everything else — the counselor they
are assigned to, the billing office they are billed through, their phone
number — could change and leave no trace. Counselors have had this since 0099.

Two things made that more than adding a table name. The entity CASE ended in
`else 'Office'`, so a client would have been filed as an office — a default
branch that does not fail, it mislabels. And `LABELS` in the history component
had no client field names, so a client edit would have read "Edited" with
nothing under it: a log that looks like it is working while saying nothing.

### What the verification suite caught that review would not have

Four real faults, all found by running all 91 scripts rather than the new one:

- **`authorization_corrections.field` is a closed list** — Service, Client,
  Number, Document. A correction to a rate or an amount violated the check and
  raised. The new tests only exercised the number, so they passed;
  `verify_client_deletion.sql` found it by clearing an amount in its own setup.
- **`authorization_corrections.reason` must not be blank,** and the trigger was
  willing to write a row with no reason. Fixing that properly was better than
  widening the constraint: this is the *correction* log, and a change with no
  reason is not a correction.
- **The append-only guard broke client deletion** — the same mistake 0179
  corrected in the directory log, an append-only rule standing in front of the
  one deletion that is sanctioned. The corrections cascade off the
  authorization; the guard now lets a row go when the authorization it
  describes has already gone, which only the cascade can arrange.
- **Giving a placeholder its real number was refused.** A "(workbook)"
  placeholder has a number already there — that is what a placeholder is — so
  importing a confirmed authorization PDF stopped working. The function was
  already writing its own correction-log line with a better reason than a
  person would type, so it hands that reason over and its manual insert comes
  out. One copy of the rule rather than two racing.

### An assertion that had to be rewritten, not deleted

`verify_authorization_is_the_bill.sql` asserted that `Authorized → Paid` is
refused — the behaviour the owner has reversed. Rewritten to assert the new
rule, keeping the half that was really at stake: both ledger legs, so the
receivable cannot be credited without being debited. Then the fault was put
back and the check watched to fail (AR debited 0 times, revenue 0) before
being restored.

Worth recording: the assertion "AR nets to nothing" passed *with the fault
present*, because the AR credit still happens. The debit and revenue
assertions are what have teeth. A check sitting near the rule passes the bug
it was written for — the fourth time that lesson has come up in this project.

Three fixtures in other scripts were cutting hours or wiping an amount paid
silently, which production should no longer allow. They now say why, the way
the screen makes a person say why.

### Left for the owner

- **`client_no`, `legacy_id`, `ghl_id`, `merged_into`, `import_review`** are
  not editable. They are the practice's own numbering and the plumbing written
  by the import, the texting service and the merge. Say so if any of them
  should be.
- **`Paid → Due` is still refused.** Undoing a payment goes back through
  Submitted, which is the move the ledger reverses off.
- **A payment is recorded on Submitted or Due,** as the brief says. An
  authorization still at Authorized is set to Paid from the status control
  instead, which records the payment the same way.

---

## The USOR roster, imported — 14 October 2026

*Owner: import the published offices-and-counselors CSV into the counselor
directory, with rules.*

118 rows in, 22 offices and 100 counselors out. Migrations 0195 (room for it)
and 0196 (the data), plus `verify_usor_directory.sql` — 18 assertions.

### The decision the brief did not mention

The directory names offices by **city** — Centerville, Taylorsville, Tooele.
USOR names them by **district** — "Davis District (25)" *is* Centerville. And
63 clients and 19 counselors point at the city names as text.

So importing the roster's labels verbatim would have produced 22 offices beside
the existing 6, orphaning every one of those 63 clients from a billing office.
The city name stays the key; the district goes in a column of its own
(`usor_district`) rather than into the note, where it would have been prose.
Six offices matched existing ones by city and were filled in rather than
duplicated.

The one office that is not a city: the Center of the Deaf and Hard of Hearing,
which sits in Taylorsville and would have collided with the office already
called that. It keeps its own name.

### Three things the schema could not hold

- **An office had no phone column.** The roster's phone is the office main
  line, repeated on every row of that office. It is the office's number, so it
  is stored on the office — and no counselor's phone was touched, because
  several have their own direct lines on file and a switchboard would have
  overwritten them.
- **`offices.billing_office_id` was NOT NULL.** True of six offices that exist
  *because* the practice bills into them; false of sixteen whose CRP nobody has
  named. Now nullable, which the app already coped with — `readBillingOffices`
  maps a missing one to null and "clients with no billing office" is an
  existing filter. `verify_usor_directory.sql` asserts that a client at such an
  office gets *no* billing address rather than the wrong one, which is what
  makes leaving it empty safe rather than merely tidy.
- **A billing office carried one contact.** USOR Administration is an
  accounts-payable department: a grant manager, two financial managers, an AP
  supervisor, two purchasing agents and two accounting techs. Eight do not fit
  in one row, and seven stuffed into a notes field is seven people nobody can
  look up. New table, `billing_office_contacts`.

  The existing single-contact columns were **left alone** rather than folded
  in. Two homes for one fact is a real cost; the alternative was restructuring
  the column that decides where billing mail goes, the day after a billing
  deploy, for an import. Written down here rather than done quietly.

- And `billing_offices.billing_email` had to look like an email. USOR
  Administration publishes no group address at all, and the table already has
  `has_group_address` for exactly that distinction. Blank is now allowed on the
  same terms `contact_email` always had — empty, or real, nothing in between.
  Submission already refuses and says "there is no billing office address for
  X" rather than mailing nowhere.

### Matching, and the guesses taken back out

`directory_name_key()` reduces a name to what two spellings share: accents
stripped, brackets dropped ("Ben (William) Powers" → ben powers), gaps
collapsed, and short forms mapped to long ones. Email is tried first and is
exact — that is what catches Josh Madsen against the Joshua Madsen on file,
since they share an address.

The nickname map started with fifteen pairs and ended with four. The ones that
came out had no evidence behind them, and one was confidently wrong about a
real person: the roster's only Ben is **Ben (William) Powers at
wpowers@utah.gov**, so `ben → benjamin` would have mismatched him. Kami could
be Kamille or Kameron or Kimberly. What survived is only what this data shows:
Josh/Joshua (same email), Jenny/Jennifer (the roster annotates it), Matt/Matthew
(the Matt on file is matthewc@utah.gov), Bill/William (both forms appear).

A wrong match merges two counselors and there is no undoing it, so a guess here
is worse than no guess. The verify script asserts the four pairs collapse **and
that the discarded ones still do not** — if somebody adds them back, it says so.

### What it refused to do

- **No stored email or phone was replaced.** Four matched counselors have "No
  email published" on the roster and kept their working addresses.
- **One row disagrees** rather than being blank: Sherida Burge, roster
  `slhicks@utah.gov`, record `sburge@utah.gov`. Kept the one on file — it
  matches her current surname, and a packet sent to the wrong address is not
  recoverable by trying again. Reported, not silently resolved.
- **A matched counselor's office is never moved.** Moving one moves the billing
  office their clients bill through, which is why it has its own function and
  asks for a reason. The import *raises* if a roster row would move somebody,
  rather than choosing. All eleven were already in the right office.
- **Sallie Muir's email was not imported**: the roster prints
  `smuir@utan.gov` — utan, not utah. She is on file with the flag on her
  record.

### Found by running all 92 verify scripts

Two things the new script would never have caught:

- **`verify_billing_offices.sql` asserted that every office has a billing
  office** — the rule the owner has now overruled. Rewritten to assert the half
  that was really at stake: the six the owner mapped have not drifted, and
  nothing has *guessed* one for the sixteen since.
- **`verify_system_account.sql` caught the new table** not refusing the agent
  account's writes. One `apply_system_read_only` call — found by a check that
  sweeps every table rather than by anybody remembering.

### And a fault in my own verify script

The first `DO` block collected failures into an array and never raised them.
Eleven assertions printed "ok" while a real failure went to the floor — and one
was failing: I had asserted a billing contact named "ZZ Pay Person" would
appear in the change log, when the log correctly ignores fixture names (0179).

Same shape as the dead-link check, the back-arrow check and check-mail before
it: a check sitting *near* the rule rather than on it. Both halves are now
tried — a real name is logged, an invented one is not — and the duplicate
check was proved by inserting a second "Josh Madsen" and watching it fire.

### The report

| | |
|---|---|
| Counselors on the roster | 100 |
| matched to somebody on file | 11 — 6 by email, 5 by name |
| added | 89 |
| in the directory now | 108 (77 with an email, 31 without) |
| Vacant posts skipped | 9 |
| Offices on the roster | 22 |
| added | 16 |
| filled in (address, main line, district) | 6 |
| **needing a billing office** | **16 — nothing guessed** |
| USOR Administration contacts | 8, as a billing office |

The sixteen waiting for a billing office are flagged on the Counselors screen
where the decision gets made, not only in this report: Blanding, Brigham City,
Cedar City, Center of the Deaf and Hard of Hearing, Delta, Heber City, Logan,
Manti, Moab, Ogden, Price, Provo, Richfield, Roosevelt, St. George, Vernal.

### Left for the owner

- **Those sixteen billing offices.** Until one is set, a client at that office
  gets no billing address and submission refuses — deliberately.
- **Sallie Muir's real address**, and a glance at four more where the address
  does not obviously match the name: Kelly Anderson (`kkay@utah.gov` — the
  roster itself says "email as printed"), Lisa Poole (`loverby@`), Cristiane
  Lundgreen (`alundgren@`), JoAnne Leilua (`joanneleiua@`). Normal after a name
  change, worth checking before anyone relies on them.
- **The eight USOR Administration contacts are shown, not editable.** The brief
  asked for them to be recorded; maintaining them by hand can come when it is
  wanted.

---

## The sixteen, an upload, an alias, the green, and a staff record — 14 October 2026

Five things, migrations 0197–0200, two new verify scripts, 94 passing.

### The sixteen billing offices

Asked rather than guessed. The CRP billing offices on file are all Salt Lake
area and the sixteen districts span the state, so no mapping could be derived —
and the owner's answer was one billing office per district with the address
left blank.

Worth saying plainly, because at a glance it looks like it achieves nothing: a
packet for a client at one of these is still refused. What changed is *which*
refusal. Before, the office had no billing office at all and there was nothing
on screen to fill in. Now it bills through a named district CRP whose address
is not yet known — a row somebody can type one address into — and until they
do, submission says "there is no billing office address for X" and sends
nothing. Neither state mails paperwork to the wrong district; this one names
what is missing.

### Melanie could not upload her ID

Reproduced as her before changing anything, which is what found it. Every part
of the database path worked: she could read her employment row, insert her own
`staff_files` row and read it back. Storage was where it failed, and the error
blamed the wrong thing:

```
insert into storage.objects (bucket_id, name) values ('staff-files', …)
  -> allowed
insert into storage.objects (bucket_id, name) values ('staff-files', …) returning id
  -> ERROR: new row violates row-level security policy
```

The only difference is `RETURNING`, and `RETURNING` applies the **select**
policy to the row being handed back. The select policy was `is_admin()`. The
storage service inserts with RETURNING because it answers with the object it
made — so this was never Melanie, or Billing, or onboarding. **No role but
Admin could upload anything to that bucket**, and every one of them got an
error about a policy violation on a row they were allowed to write.

The fix is a read policy: a person may read their own folder, which is the
right rule anyway — being unable to see the ID you uploaded is how you upload
the wrong page twice. `staff_file_owner()` reads the owner out of all three
path shapes the bucket holds.

Two more faults found while in there. The insert policy was `is_active_staff()`
and nothing else, so **any member of staff could write into anybody's folder**;
narrowed to their own or an Admin's. And the delete policy's inactive-staff
freeze asked `storage.foldername(s.name)` — the *person's* name, not the
object's — so it compared "Melanie Morales" with a uuid, never matched, and
**the freeze it exists to enforce had never once applied**.

Verified across all six roles: each can upload to its own folder and read it
back, none can touch another's, an Admin can do both. Putting the Admin-only
read policy back fails the check naming exactly the five non-Admin roles.

### Rispah's alias

`staff_emails`, with `staff_by_email()` resolving a sign-in address or an alias
to one person. Her sign-in stays `rispah@zionpersonalcareagency.com`.

**One thing to know:** nothing in the CRM resolved an inbound address to a
member of staff before this. The mail sweep matches clients and counselors and
deliberately stores nothing else — "no match, no record" is the rule that keeps
the rest of a mailbox out of the CRM entirely, and widening it would have
changed what mail is stored. So the alias is recorded, resolvable and on the
screen; what it does *not* do yet is pull mail in, because there is nothing
asking the question. Say the word and I will wire it where you want it.

### The green theme

From the Zion Theme Comparison. Light is the default — white page, white cards,
green kept to the sidebar, sand the one accent. Dark makes the green the page.
Serif headings in both. Looked at both on the running app.

`check-theme` now checks **both** palettes, where it used to check one and
forbid dark mode outright. Its token parser had to start reading each block
separately: regexing the file and letting the last value win would have checked
the dark values twice and the light ones never.

It found five pairs under 4.5:1 in the comparison's palette, which is the check
doing its job:

- sand hover with green ink, 3.78:1 — the hover now lifts lighter
- muted on the sand soft fill, 4.35:1
- dark: the red on a card, 4.32:1; on the sand hover, 3.86:1
- dark: the sand focus ring against a strong line, 2.80:1

All 37 text pairs now reach 4.5:1 in both modes (lowest 4.63 light, 4.88 dark)
and edges 3:1. Breaking one value fails the build, which is where it was
already wired.

**One departure from the picture:** the comparison's sand button carries white
text. White on `#B98B5A` is 2.6:1 — it fails the same rule in the same sentence
that set it. The sand fill carries deep-green ink instead, and sand *as text*
is the darker `--accent-text`. That is the only difference, and it moves
towards the rule rather than away.

Also added `color-scheme: light dark`, without which a dark green page opens a
white calendar popup — and this app asks for a date on nearly every screen.

### A staff record an Admin can edit

Name, sign-in address, phone, role and aliases now have a form; employment,
start date and pay already had one. Every change is logged by a trigger with
who made it and whether it was somebody else's record — a trigger rather than a
line in the screen, because the sweeps and imports write these tables too. A
document can be replaced, keeping the row so whatever points at it still does.

**Not the directory log.** Clients and counselors write to `directory_changes`,
which every member of staff can read, on purpose — it is a directory. A staff
record carries pay rates and a home phone number, and the diff keeps the old
and new value of everything that moved. Putting staff in there would have put
everybody's pay in front of everybody. Separate log, Admin and the person
themselves.

### The line the owner drew, and what was on the wrong side of it

`sign_tax_form` **allowed an Admin to sign somebody else's W-9**. Its guard read
`if not (is_admin() or v_owner = current_staff_id())` while raising *"You can
only sign your own form."* The message described the rule; the code did
something else. Corrected to what the message always claimed — an Admin can
still prepare, correct, attach to and supersede anybody's form, and cannot sign
one.

E-delivery consent was also an Admin's to tick. Now a trigger refuses it —
a trigger rather than a policy because the paperwork screens write through the
service-role client in places, which bypasses RLS and not triggers.

`sign_staff_policy` was already safe and is untouched: it takes no staff id at
all, so there is no argument an Admin could pass to sign as somebody else.

Two things the verify script found while settling this:

- Once the Admin was stopped, **nobody** could record a consent — the only
  people allowed to write `contractor_profiles` were the only ones forbidden to
  write that column. An earlier draft added a function for the contractor;
  `verify_1099.sql` knew that `set_e_delivery_consent()` had existed since the
  1099 work, so the duplicate was dropped rather than shipped.
- The guard has to be about *granting*, not clearing. Recording a consent
  somebody did not give misrepresents them; recording that we do not have one
  means their 1099 goes on paper, which is the safe fallback. An Admin may
  always take it off and never put it on.

### What the suite caught that the new scripts did not

- `verify_system_account.sql` caught both new tables not refusing the agent
  account's writes — a sweep over every table, twice.
- `verify_1099.sql` caught the consent deadlock.
- `verify_tax.sql` asserted that nobody but an Admin could fetch staff
  paperwork bytes — including the contractor whose W-8BEN it is. That is the
  old rule, and the one that broke the upload. Rewritten to keep the half that
  matters: a *colleague* still cannot.
- `verify_inactive_staff.sql` checked the freeze by looking for the word
  "foldername" in the policy's text — and passed for the wrong reason, because
  the word was there inside the subquery that never matched. Now it checks the
  effect.
- `verify_billing_offices.sql` asserted every office has a billing office, the
  rule being overruled; rewritten to assert that no district was attached to a
  Salt Lake CRP it has no relationship with.

---

## A theme switch, and Rispah's two addresses — 14 October 2026

### The switch

Light / Dark / System in the avatar menu, System the default, saved per person
like the sidebar width, applied on the click.

Two places hold it, for two different jobs:

- **`staff_prefs`** is the record — theirs, per person, what the menu reads to
  show which is chosen, and what follows them to another machine.
- **A cookie** is how the page is painted. The root layout reads it and stamps
  `data-theme` on `<html>` before anything renders, so somebody who chose dark
  never sees a white page flash first.

Reading the preference in the root layout instead would mean a database call on
every request including the sign-in screen — the sort of thing that took
production down on the 14th. An inline script would have been the other way
round the flash; a cookie read needs no script at all.

**System is the absence of both.** No row, no cookie, and the stylesheet falls
through to `prefers-color-scheme`. The default is default by having nothing
stored rather than by storing the word.

The click stamps the attribute before the server is told, so the screen turns
over immediately — every colour is a token and the tokens are defined against
that attribute. If the write fails nothing is undone: the person asked for dark
and has dark; what they lose is it being remembered, and telling them their
theme did not save while they are looking at the theme they chose would be a
worse screen than the one they asked for.

`color-scheme` moved into tokens.css and now follows the choice rather than
only the machine — otherwise somebody on a dark machine who picked light gets
a dark calendar popup on a white page.

**Verified all three states on the running app**, which is where the three-state
bug usually hides:

| machine | choice | stamped | page | color-scheme |
|---|---|---|---|---|
| dark | Light | `light` | white | `light` |
| — | Dark | `dark` | `#44594F` | `dark` |
| dark | System | none | `#44594F` | `light dark` |

And stamping the attribute with no reload flips the background, which is what
the button does.

`check-theme` needed a new distinction: **defining** a palette and **applying**
one are different things. A palette can only be written in CSS, so a stylesheet
other than tokens.css naming the theme still fails. A component naming it is
stamping the attribute, which has to live somewhere — so the two files allowed
to do that are listed by name, and a third appearing is worth a line in a
review.

### Rispah

Both halves of the record were **already right** and this says so rather than
changing something to look busy: `staff.email` is the PCA address and the Voc
Rehab one went on as an alias in 0199. The migration asserts it.

**Her invite went to the PCA address**, not the Voc Rehab one — so the
conditional in the ask does not apply and no dual sign-in was built. Since the
Voc Rehab address is an alias of that same mailbox, the invite landed in the
right inbox either way. She has not accepted it yet (sent 10 Oct, never
confirmed, never signed in).

**Mail to either address was already attributed to her**, and it is worth being
precise about why: attribution is by mailbox, not by address. `syncStaffMember`
sweeps one person's mailbox with that person's own token and writes their
`staff_id` on every row it keeps; staff addresses are never matched against
anything. Two addresses on one mailbox are one person's mail whichever one a
message was sent to.

What did not hold is which address Exchange calls primary. Graph answers `/me`
with whatever is configured, and for her that could be either. The CRM stored
it and compared it with nothing — so if Graph had reported the Voc Rehab
address, there would have been a connection under an address nobody had
recorded as hers, and `staff_by_email()` would have said it reaches nobody.

So connecting a mailbox now records its address as one of the connecting
person's, if it is not already known: the CRM learns the alias from Exchange
instead of waiting for somebody to type it. And if that address is already
**somebody else's**, it refuses by name — that case means a person connected a
mailbox that is not theirs, and every message swept out of it would have been
filed under the wrong name. The dashboard says so plainly rather than as a
Microsoft error, because Microsoft did nothing wrong.

### Noted, not touched

`verify_messaging_load.sql` sits exactly on its own budget: the unread count is
allowed 250 ms and measures about 252 alone, so it passes or fails depending on
how busy the database is — 1047 ms when run at the end of the full suite. I did
not change messaging and have not re-tuned it, because quietly raising a budget
to make a check green is how a check stops meaning anything. It needs either
headroom or an isolated measurement, and which one is the owner's call.

---

## The messaging budget stands — 14 October 2026

*Owner: keep the 250 ms budget, measure best-of-three, run it before the rest
of the suite. If best-of-three still exceeds 250 ms, report it rather than
raise the budget.*

**There is no slowdown to report.** The unread count comes back in 88–99 ms,
measured at the front of three separate full-suite runs, against a budget of
250. The same measurement was 252 ms alone and 1047 ms at the end of the suite
before this. The query was never the problem: the first-run cost and ninety
rollback-heavy scripts ahead of the stopwatch were.

Two changes, neither moving the line:

- **It runs first.** Order here is the filename — the suite is a glob, which is
  also how `verify_zz_no_fixtures.sql` comes last — so the file is
  `verify_0_messaging_load.sql`. A digit rather than `aa`, because
  `verify_1099.sql` exists and a digit sorts ahead of a letter: `aa` would have
  put it second and looked like it had worked.
- **Best of three.** Each of the three queries is timed three times and the
  fastest kept. The first run of anything pays for a cold cache and a cold
  plan. The row counts are still checked on every one of the three, so the
  repetition buys a better clock and gives up no correctness.

The assertion still fires: tightening the budget to 1 ms fails all three, and
the message names best-of-three so a failure cannot be read as a blip.

---

## The revocation check signed out the deploy check — 15 October 2026

The `.gitignore` commit failed smoke: eighteen Billing screens passed, then
every screen after them redirected to `/login`, and production rolled back to
the previous deployment. A `.gitignore` change cannot do that, and it did not.

The clean cutover is what names it. Static files kept working — they sit
outside the middleware matcher — while every gated screen after a point was
refused. That is a session dying mid-run, not a permission.

The cause is the revocation check added on the 14th:

```ts
if (asked !== "timeout") revoked = !asked.data.user;
```

under a comment promising *"on a failure or a timeout the request goes on"*.
Both could not be true. A thrown error and the timeout did go on; an answer of
`{ data: { user: null }, error: AuthApiError }` — what the Auth service returns
for a token it will not vouch for, including one whose refresh token has been
rotated out from under a client — set `revoked` and signed the person out.

The same class of fault as `sign_tax_form` the day before: **a guard whose
comment described the rule and whose code did something else.**

It needs the refresh to land inside the one-minute window, so it bites
sometimes and not others — which is why the identical middleware passed three
deploys earlier the same day.

**The asymmetry decides the fix.** Answering "revoked" when we only failed to
ask signs out somebody who is working, which is an outage. Answering "not
revoked" when they really were revoked costs a minute — and `requireStaff()`
independently refuses anybody without an active staff row on every page load,
so deactivation still takes effect at once.

So only a clean "there is no such user" counts now; an error of any kind leaves
the request alone. This makes the check quiet by design: it will miss a
sign-out elsewhere that the Auth service reports as an error rather than as an
empty user. That is the trade, made on purpose rather than by accident, and the
constant's own comment now says so instead of promising the opposite.

**Not changed, and worth the owner knowing:** `scripts/smoke.mjs` captures its
cookies once at sign-in and never stores the ones it is sent back, so it holds
a refresh token that can go stale under it. A browser does not behave that way.
That made this fault much likelier to show up there — but the fault was real
and could reach a person through an ordinary concurrent-refresh race, so the
middleware is fixed rather than the harness quietened.

---

## Files on a client, and Clients on the sidebar — 15 October 2026

Migration 0202, `verify_client_documents.sql` (15 assertions), and the smoke
harness taught to keep its cookies.

### The harness, first

`scripts/smoke.mjs` snapshotted its cookie jar once at sign-in and sent that
same string for the rest of the run, ignoring everything the server sent back.
It now applies `Set-Cookie` from every response — additions, rotations and
removals — the way a browser does, so a refresh token that rotates mid-run
cannot fail a run on its own. One jar for the process, emptied when a different
account signs in, because two accounts sharing a jar would send the first one's
session with the second one's requests.

The parsing was exercised against chunked Supabase cookies, a rotation, a
`Max-Age=0` deletion, a past `Expires`, and a malformed line.

### Most of item 1 already existed

`attachments` is the table, `client-files` the bucket, and the agent, the
authorization confirm queue and Admin → Documents already read these rows. The
upload, download and delete actions were there. Four things were not:

- **Two dates.** `created_at` is when somebody uploaded it, which is not the
  date on the paper — sorting by it puts a form signed in March under a scan of
  it made in October. `document_date` is the document's own, defaulting to
  today and editable; existing rows backfilled from `created_at`.
- **A fingerprint.** The owner asked for the same dedupe the document store
  has. `attachments` had `unique (storage_path)`, which dedupes the *path* —
  and every upload gets a fresh timestamped path, so the same scan uploaded
  twice landed twice. It now carries `sha256`, computed in the browser where
  the bytes already are, unique per client. Partial, so rows predating it do
  not collide: a null means nobody asked, not that it is unique.
- **No update policy at all**, so a name could not be corrected after upload.
  Admin or the uploader now, the same test delete already used.
- **A log**, for adds, edits and removals.

### The reversal worth naming

The client record said, approvingly: *"Restricted documents are filtered out by
RLS, not here — a staff member without access does not learn that they exist."*
The owner reversed it. What is gained is that a colleague can tell a client
with nothing on file apart from one whose file they cannot see, so they ask
instead of uploading a second copy. What is given up is that the existence of a
restricted document is itself now visible — a guardianship order on a file says
something by being there.

The redaction is a **view**, not a screen, because a screen that filters is a
screen somebody forgets to write. `client_documents` hands back the row with
its name, note, type and path blanked and `can_open` false. The table still
refuses the row outright, so only the view softened and the bytes did not —
asserted both ways.

**The type is redacted with the name.** "Guardianship document" says precisely
the thing the restriction exists not to say. The date survives: a date alone
tells nobody anything and it keeps the list in order.

### A three-way drift, found on the way

The category list was written out three times — in the upload action, in the
files tab, and as a check constraint — and they disagreed: the database allowed
**Guardianship document** and neither screen offered it, so a guardianship
order could be filed by the agent and not by a person. One `DOCUMENT_CATEGORIES`
now, matching the constraint.

The add-file form was extracted so the client record and the "+" share one
control rather than two copies of the fingerprint, the size limit and the
restricted rule. From the "+" the restricted box is off and says where to go
instead of claiming the person is not allowed — that screen knows which clients
they may restrict for and the modal does not.

### Clients on the sidebar

It was a tab inside Work: the practice's central record, one level down behind
a hub you had to know the name of. Now its own group between Home and Work,
one item, so the sidebar draws a single button straight to the list. **Not
duplicated in Work** — two tab strips offering the same screen is what §11 says
to stop doing. Work gave up the people icon it was borrowing and took the
checklist.

`/clients` is that group's landing, so it carries no back arrow, like the other
six landings; `check-nav` and `check-screens` were updated to expect seven.
Role limits did not move: they live on the screens and in the database.

### What the suite caught

`verify_records_request.sql` refused the new log: a table holding client data
must be in the records bundle or skipped **with a reason**. It is skipped, and
the reason names the tension rather than burying it — the documents themselves
are disclosed, and `access_log` is in the bundle, so "the practice's own
handling is disclosable" is already the house position for *reads*. Extending
it to writes is the practice's call, not a thing to settle while adding an
upload button. Nothing is lost by waiting: the rows are kept and append-only.

### Left for the owner

- **Restricted access is Admin, Intake & Client Reports, and the assigned
  staff member.** The brief said "Admin and the staff assigned", which would
  drop Reports. I did not narrow it — that would take access away from a role
  that has it today, across every restricted file already on record. Say the
  word if Reports should lose it.
- **The smoke assertions need accounts.** Job Coach and Case Manager sign-ins
  are not configured, so those two print a note rather than running; Billing
  runs. The restricted check runs for any role whose account exists and which
  has a document it may not open.

---

## Some documents are restricted before anybody decides — 15 October 2026

*Owner: default Restricted on for ID, medical/psychological, guardianship/legal
and financial; the uploader can un-tick it; log when they do.*

Migration 0203, six more assertions in `verify_client_documents.sql`.

### Three of the four did not exist

The client document types were Signed USOR form, Work schedule, Authorization,
Signed intake, Employer verification, Invoice, Guardianship document, Other.
Of the four kinds named, only guardianship was among them — there was no way
to say a document was somebody's ID, or medical, or financial, so the
instruction would have been inert for three of its four cases. **Identity
document**, **Medical or psychological** and **Financial document** are new.

### Invoice is not "financial"

The nearest existing type to "financial" is Invoice, and it is the wrong one.
There are **130 invoices on file and none restricted**: they are what the
practice bills USOR, not a client's bank statements. Defaulting them to
restricted would hide routine billing paperwork from Billing staff who are not
the assigned worker — which is most of them.

So "Financial document" is its own type, for the client's own money — a
benefits letter, a bank statement, a representative-payee record — and Invoice
stays open. The one place this departs from a literal reading of the brief,
and it departs towards what the brief is for.

### The list is a table now

It was written out three times before yesterday; 0202 brought it to a constant
and a check constraint. That was still two, and the database now needs to know
something a constant cannot carry — *which types are sensitive* — because the
log has to fire however a row arrives, not only when it comes from the form.

So `client_file_categories`, like `staff_file_categories` already is for the
other side of the house, and the check constraint becomes a foreign key to it.
The screens read it, the form reads it, the trigger reads it. Adding a type is
a row rather than a deploy. The keys are the strings already on 770 documents
and are not renamed; only the label changes — "Guardianship document" shows as
"Guardianship or legal document", because the heading was guardianship/legal
and a court order about anything else belongs there too.

**Guardianship document had zero rows** — allowed by the constraint, offered by
no screen. That was yesterday's drift, and it is now reachable.

### A hole this closed

From the "+" I had hard-coded `canSeeRestricted={false}`, on the grounds that
the modal does not know which clients a person may restrict for. Harmless
while the switch started off. Not harmless now: an ID added from the "+" would
have defaulted to restricted, found the switch disabled, and gone up
**unrestricted** — the one outcome the default exists to prevent.

So the modal asks. `clients_i_can_restrict()` answers once, calling
`can_see_restricted()` rather than restating what it means.

### The default, and declining it

The switch follows the type until somebody moves it: choosing a different type
sets it to that type's default again, and touching the switch stops that —
at that point the person has said what they want and the form should stop
arguing. A warning appears where the decision is being made rather than in the
small print underneath, because somebody turning this off for an ID should see
what it means while their hand is on it.

Declining it is written down by the trigger, as its own key in the log, so it
can be looked for rather than inferred later by joining to a category list
that may have changed its mind since. Three cases are asserted: an ID filed
open is recorded, an ID filed restricted is not (it is a document, not a
decision), and an invoice filed open is not reported at all.

Un-restricting an existing file was already logged — `restricted` has been a
watched field since 0202 — and still is.

### Left for the owner

- **Signed intake is not in the default-on set.** It is not one of the four
  named, so I did not add it. The upload screen's own guidance has always said
  to restrict anything carrying disability or intake detail, and a signed
  intake is the example it gives — so it is a candidate. One row to change.
- **Nothing was applied retrospectively.** The 770 documents already on file
  keep whatever restriction they have; this changes what a new upload starts
  as. The 106 restricted ones are all Signed USOR forms.

---

## A signed intake starts restricted — 16 October 2026

*Owner: yes, add Signed intake to the default-restricted set.*

Migration 0204. One row: `restricted_by_default = true` where the key is
`Signed intake`. The set that starts restricted is now Financial document,
Guardianship document, Identity document, Medical or psychological, Signed
intake, and `verify_client_documents.sql` asserts exactly that string.

This closes a gap the upload screen had been pointing at on its own. Its
guidance has always read "tick restricted for anything carrying disability,
medical or intake detail — a signed intake or a USOR 94". A signed intake was
the example it gave while being the one type the default did not cover.

Nothing retrospective: the signed intake already on file keeps what it has, and
this decides what the next one starts as. Suite green at 95.

---

## Stress test — 16 October 2026

*Owner: stress test, report only, change nothing yet. Six areas. Findings
ranked by what a staff member would hit first, with what happens today and what
it should do. Proposed fixes here, then wait.*

**Nothing in this entry is a change.** No migration, no code, no deploy.

### What this test is, and is not

The brief asked for a throwaway branch seeded with 500 clients, 2,000
authorizations, 20,000 service-log hours and 5,000 documents, with every list
and the Home page timed for every role at that size.

**That measurement did not happen, and no number below is one.** Three routes
were tried and all three closed:

1. Seeding inside a `begin; … rollback;` transaction on the production instance
   — the technique `verify_0_messaging_load.sql` already uses, chosen because a
   branch runs on its own compute and a timing from it describes that machine
   rather than this one. Declined: it writes to a shared resource. That is the
   right call and I am not arguing with it.
2. Read-only timing of the same queries at today's size, with RLS applied by
   setting the role and the JWT claims per staff member. Also declined.
3. A Supabase branch, as originally asked. Branching is not set up on the
   project; starting one is a billable, several-minute operation, and that is
   the owner's call rather than mine.

So **part 1 below is read off the queries, not off a clock.** The query shapes
are facts; the consequences at the brief's size are reasoned from them. Where I
say a thing scans 20,000 rows per authorization, that is arithmetic on the SQL,
and it still wants a stopwatch before anybody sizes a fix.

One number that is worth having by itself: **`service_entries` has 0 rows
today.** Nobody has logged an hour yet. Every hours finding below is therefore
invisible on the current database and arrives with the first week of real
logging. Today: 97 clients, 162 authorizations, 770 documents, 281 job
matches, 298 tasks.

Parts 2 to 5 are read off the code and, where a claim could be tested locally,
tested. Part 6 is partly proven and partly not; it says which is which.

---

### 1. Three of the four phone tabs, and three sidebar headings, bounce to Home

**The first thing anybody hits, on any role, at any data size, today.**

`/work`, `/communication` and `/hr` are the hub landing pages — the card pages
a group opens on. They are reachable by **nobody**:

```
/work            Work           reachable by: NOBODY
/communication   Communication  reachable by: NOBODY
/hr              HR             reachable by: NOBODY
```

That is `canReach` called for every role in `ROLE_NAMES`, not an inference.
`canReach` tests the pathname against `reachableFor(who)`, which is
`navFor(who).flatMap(g => g.items)` — nav **items**. A hub is a property of
the **group**, so no hub is ever in that list, and the layout gate in
`app/(app)/layout.tsx` redirects every one of them to `/dashboard`.

Both navigations link straight at them:

- `app/(app)/bottom-bar.tsx:38` — the phone bar, `href={g.group.hub ?? g.items[0].href}`,
  over the four main keys `dashboard, work, inbox, hr`. **Three of the four
  phone tabs go to a page the gate refuses.**
- `app/(app)/nav-links.tsx:50` — the sidebar group heading, same expression.

What happens today: tap **Work**, **Communication** or **HR** on a phone, or
click those headings in the sidebar, and you land on Home. Silently — a
redirect, not an error.

What it should do: open the hub's cards.

**Why the check passed.** `scripts/check-nav.mjs:149` asserts a hub has a page:
`if (g.hub && !stat.has(g.hub)) fail(...)`. It asks whether the *file exists*.
The rule is whether *somebody can open it*. Line 61 then excludes hubs from the
orphan sweep (`!hubs.has(r)`), so nothing else looks at them either. This is the
same failure this project keeps meeting: a check that asks a question near the
rule passes the bug it was written for.

A stale comment points the same way. `lib/roles.ts` still says the group
addresses "redirect to their first screen (next.config.mjs)". They do not —
`next.config.mjs` has no entry for `/work`, `/hr` or `/communication`, and
`hub-page.tsx` renders real card pages. The comment describes a design that was
replaced.

**Proposed fix.** Include hubs in reachability: have `reachableFor` (or
`canReach` directly) accept a group whose visible items are non-empty as
granting its own hub. Then extend `check-nav.mjs` to assert, for every group
with a hub, that at least one role reaches it and that every role who sees the
group reaches it — and put the fault back first: break `canReach` for hubs and
watch the new assertion fail before trusting it.

---

### 2. Billing to Hours fetches every service entry ever logged

`app/(app)/billing/page.tsx:75`

```ts
tab === "hours"
  ? supabase.from("service_entries")
      .select("id, auth_id, date, hours, non_billable, notes, primary_code, secondary_code, staff_id")
  : …
```

No `.eq()`, no date window, no `.limit()`, no `.range()`. Every row, every time
the Hours tab opens, serialised into the server-component payload.

Today that is 0 rows and instant. At the brief's 20,000 it is 20,000 rows of
nine fields — on the order of two to four megabytes per page load, before React
renders any of it. The tab is Billing's own and Billing opens it many times a
day.

What it should do: a month at a time, or the authorizations on screen, with
paging — the screen only ever shows a period.

**Proposed fix.** Filter to the selected period and the live authorizations,
and page. The month is already the unit everywhere else in billing.

---

### 3. The working list re-scans every logged hour twice per authorization

`public.billing_worklist()` (0177) is a plain `stable` SQL function over
`authorizations`, and for **each row** it calls two things:

- `public.authorization_amount(a.id)` — a correlated
  `select sum(e.hours) from service_entries e where e.auth_id = a.id`.
- `cross join lateral public.authorization_attention(a.id, p_today)` — which
  sums `service_entries` **again**, this time joined to `authorizations` on
  `c.id = coalesce(a.parent_id, a.id) or c.parent_id = coalesce(a.parent_id, a.id)`.
  An `OR` across a join is the classic shape that stops an index being used, so
  this is a scan rather than a lookup. It also runs two more scalar subqueries
  per row against `org_settings` (`stale_soon_days`, `stale_grace_days`).

At the brief's size, minus Paid and Closed, call it roughly 1,500 live rows,
each touching a 20,000-row table twice. The arithmetic lands in the tens of
millions of row-touches per call. That is comfortably past one second, and it
is not a close call — but it is arithmetic, not a measurement.

It runs in three places, not one:

- `app/(app)/billing/page.tsx:66` — the Billing page itself. Expected.
- `app/(app)/dashboard/page.tsx:313` — `billing_needs_action()`, which is
  `count(*)` over the whole worklist, on **Home**, for Admin and Billing.
- `app/(app)/clients/[id]/page.tsx:570` — the client record's Billing tab calls
  the **entire** worklist and then `.filter(w => w.client_id === id)` in
  JavaScript to show one client's handful of rows.

The alerts badge is *not* in this set, and that is worth recording: `getAlerts`
reads the `notifications` table with `.limit(50)`, generated nightly. That part
was built right.

What it should do: compute the hours once, set-wise, rather than per row; and
the client record should ask for one client.

**Proposed fix, in order of payoff:**

1. Give `billing_worklist` an optional `p_client uuid` and have the client
   record pass it. Smallest change, removes a full scan from every client
   record view.
2. Replace the two per-row hour sums with one aggregate joined in — a single
   `group by` over `service_entries` against the authorization family, computed
   once per call instead of once per row.
3. Give `billing_needs_action` its own narrow count rather than counting rows
   of the full worklist, or read the nightly `notifications` table, which
   already knows what needs attention.

Each of these is a candidate for a `supabase/verify_*.sql` that asserts the
figures are unchanged — the risk in (2) is arithmetic drift, and the existing
`verify_authorization_is_the_bill.sql` is the model.

---

### 4. The Clients list and Home load every client, and the whole activity union

Two separate things, same cause.

**Home** — `app/(app)/dashboard/page.tsx:88` selects every client, ordered by
name, for every role on every load. No limit.

**The Clients list** — `app/(app)/clients/page.tsx:67` fetches every matching
client with no `.limit()` and no paging, then sorts, free-text searches and
filters in memory. Its own comment is honest about it: "at this caseload it is
cheaper and far clearer to finish the job in memory". That was true at 97
clients. It is a decision with a shelf life, and Clients became a main sidebar
tab for every role yesterday, so every role now loads it routinely.

Alongside it, on the same page:

- `client_last_activity` (line 93), with **no narrowing at all** — not even to
  the clients being displayed.
- every row of `lead_matches` (line 108).

`client_last_activity` (0094) is the one that grows worst. It is a **twelve-branch
`UNION ALL`**, fully materialised and then grouped by client, over `notes`,
`client_stage_history`, `lead_matches ⋈ job_leads`, `tasks`, `forms`,
`contact_log`, `placements`, **`service_entries ⋈ authorizations`**,
`calendar_events`, `mail_log`, `sms_messages`, and `payments ⋈ authorizations`.
It is `security_invoker = true`, so each of those twelve tables has its RLS
predicate evaluated as the reader — correct for privacy, and the reason this
cannot be waved away as a cheap scan.

What it should do: ask for a page of clients, and ask for last-activity only
for the clients on that page.

**Proposed fix.** Paginate the list (the database already applies most of the
filters; the in-memory ones are the sort by counselor and quiet-since), and give
`client_last_activity` a companion function taking a client-id array — the shape
`client_next_actions_for` already established when it replaced the N+1 on the
caseload. Then Home asks for the tiles it shows rather than the whole roll.

---

### 5. Two people logging hours at once can overdraw the authorization

`public.check_entry_hours` (0002, rescoped by 0171) is a read-then-check with no
lock:

```sql
select coalesce(v_carried, 0) + coalesce(sum(e.hours), 0) into used_hours
  from public.service_entries e
 where …;
if used_hours + new.hours > v_total then raise exception …
```

`v_total` comes from the root authorization, which is never locked — no
`select … for update`, and the default isolation level is read committed. Two
coaches logging against the same authorization in the same moment both read the
same `used_hours`, both pass, and both insert. 58 of 60 hours used, two entries
of 1.5, and the authorization ends at 61.

That matters more here than a generic race would: hours past the authorized
total are hours the practice cannot bill USOR for, discovered at submission.

0171 did fix the scope — it counts across the coaching parent and all its
months, and uses the root's total, so the guard and `authorization_attention`
now agree. The lock is the remaining half.

What it should do: refuse the second entry, exactly as it refuses the first one
that would exceed.

**Proposed fix.** Take `select 1 from public.authorizations where id = v_root for update`
at the top of the trigger, before the sum. It serialises only entries against
the same authorization family, which is the contention that has to be
serialised anyway. A `verify_*.sql` for this needs two sessions, which the
suite does not have — so the honest check is the lock's presence plus the
existing over-cap refusal, and the race itself recorded here as reasoned rather
than reproduced.

---

### 6. A doubled cron sends the same client the same text twice

`lib/sms.ts:217` — `sendScheduledTexts` selects `status = 'Scheduled'` rows due
now (`.limit(100)`), sends each, and **then** deletes the row. There is no
claim. Two overlapping runs — Vercel cron is at-least-once, and a manual `curl`
alongside the schedule does it too — both select the same rows and both send.
The client gets the message twice; the second run's delete is a no-op and it
still reports a send.

`app/api/cron/messages-digest/route.ts:64` has the same shape at lower stakes:
send, then `messages_digest_sent`. A double fire is two digest emails to staff.

Everything else about the crons is sound and worth recording: all eight routes
check `CRON_SECRET`, and `generate_notifications` is genuinely idempotent —
`on conflict (dedupe_key) do update` (0170), which is why a doubled `notify` is
harmless.

What it should do: send once.

**Proposed fix.** Claim before sending:
`update sms_messages set status = 'Sending' where id = ? and status = 'Scheduled' returning *`,
and send only if a row came back. The conditional update is the lock. Same for
the digest: mark through-seq first, send after, and let a failure re-open it.
A `pg_try_advisory_lock` around each job would also stop two runs overlapping
at all, and is the smaller change if the per-row claim looks invasive.

---

### 7. A 25 MB staff upload is refused before any of our code runs

This is Melanie's failure from 30 September, still live on a different path.

- `app/(app)/admin/staff/document-actions.ts:10` — `MAX_BYTES = 25 * 1024 * 1024`
- `app/(app)/paperwork/onboarding/actions.ts:16` — the same
- `next.config.mjs:38` — `serverActions: { bodySizeLimit: "25mb" }`

The promise and the limit are **exactly equal**, and the request body is bigger
than the file it carries: multipart boundaries, headers, the other form fields.
A genuinely 25 MB document is refused by Next before the action is entered, so
the screen's own friendly message is unreachable and what the person sees is
"Application error: a server-side exception has occurred" — precisely the
symptom `scripts/check-upload-limits.mjs` was written to prevent.

**Why the check passed.** It compares `if (value > bodyLimit)`. Strictly
greater. 25 MB is not greater than 25 MB, so it passes, while the real question
is whether the promise *plus encoding overhead* exceeds the limit.

What it should do: accept a 25 MB file, or promise less.

**Proposed fix.** Raise `bodySizeLimit` to `"30mb"` and change the check to
require headroom rather than equality — compare against roughly 90% of the body
limit and say so in the failure text. Then put the fault back: set the limit
equal again and watch the check fail.

The client-file path is clean by contrast, and the contrast is the point: that
upload goes browser-straight-to-storage, the bucket limit is 52428800 (0073),
and `add-file.tsx:10` is `52428800`. Identical, with no body in between to add
overhead. A 50 MB client file works; 50.1 MB is caught in the browser with a
sentence that tells you what to do.

---

### 8. A wrong-year date is stored without complaint

Date validation is `/^\d{4}-\d{2}-\d{2}$/` (`files/actions.ts`, twice). It
accepts `0226-03-14` and `9999-12-31`. The database has essentially no date
sanity either — a sweep of the migrations finds one range constraint in the
whole schema, `staff_personal_dob` (0100), between 1900-01-01 and `current_date`.
Authorization `start_date`, `end_date`, `received_on` and `stale_date` have
none.

What happens today, on a slipped keystroke:

- a year in the past (`0226`, `2026` typed as `0226`) makes `stale_date` long
  past, so `authorization_attention` reports it blocked or expired forever and
  raises an alert nobody can clear by doing the work;
- a year in the future (`2062`) means `bill_by` never arrives, so it never falls
  Due and quietly never gets billed.

The second is the expensive one, because nothing complains.

What it should do: refuse a date outside a sensible window at the point of
entry, and say which date and why.

**Proposed fix.** One shared validator — a date must be within, say, 1990 to
five years ahead — used by every action that takes a date, plus check
constraints on the authorization date columns so it holds however the row
arrives. That is the lesson 0203 already applied to document categories: the
rule belongs in the database, because a copy in TypeScript is the one that
drifts. A `verify_*.sql` asserting a year-0226 authorization is refused is
straightforward.

---

### 9. There is no degraded mode when Supabase is slow

The middleware is bounded, and that was the fix for the 504
`MIDDLEWARE_INVOCATION_TIMEOUT`: both session calls sit inside a
`Promise.race` against `SESSION_TIMEOUT_MS`, and a timeout leaves the request
alone rather than treating no-answer as an answer.

The pages have nothing of the kind. No page server component sets
`maxDuration`, and no page query has an `AbortSignal` or a race — the only
`maxDuration` exports in the codebase are on API routes and crons. Home fires
roughly fifteen queries in one `Promise.all`. With Supabase slow or down for ten
seconds, every one of them hangs and the page runs into the platform's own
function limit, so what a staff member sees is Vercel's error page, not
anything this app wrote.

What it should do: say "the database is not answering, try again in a minute",
and where a tile cannot load, render the page without that tile.

**Proposed fix.** A shared timeout wrapper around page queries, with tiles that
can fail independently rendering an inline "could not load" rather than taking
the page down. The middleware's `Promise.race` is the pattern to copy — it is
already written and already proven by that incident.

Mail and email handle their own outages well and should be left alone:
`lib/email.ts` returns a result instead of throwing, so a Resend rejection
reaches the caller as text it can show; `lib/mail-access.ts` turns an expired
Outlook refresh token into `reason: "expired"` with "The Outlook connection
needs reconnecting." One rough edge only — when Microsoft supplies its own
error, the raw `AADSTS…` string is what reaches the person instead of that
sentence.

---

### 10. A stale edit form overwrites, quietly but recoverably

Two people editing the same authorization: both saves go through
`edit_authorization` (0190), which does take `select … for update`, so there is
no torn write. And it is a compare-and-set per field — `if v_svc is not null and
v_svc <> v_auth.service_type` — not a blind overwrite of the whole row.

What that leaves is last-writer-wins across the round trip. A opens the form,
B changes the service type, A saves with the value A loaded, and B's change is
reverted. Every change is logged with who made it and the reason the function
insists on, so it is visible and recoverable afterwards — but nobody is told at
the time.

What it should do: tell A the record changed while the form was open, and let A
decide.

**Proposed fix.** Send the record's `updated_at` as a hidden field and have
`edit_authorization` refuse when it no longer matches, with a message naming who
changed it. Cheap, and the correction log already holds everything the message
needs.

---

### 11. Smaller things, recorded rather than ranked

- **A 50 MB upload is hashed in the browser.** `add-file.tsx:95` does
  `crypto.subtle.digest("SHA-256", await file.arrayBuffer())` — the whole file
  into memory at once. The comment is right that hashing server-side would
  defeat the direct upload, but on the Android phone this project already has
  history with, a 50 MB `arrayBuffer` is a plausible tab crash. Streaming the
  hash in chunks would cost little. The fallback is already graceful: no
  `crypto.subtle` means an empty fingerprint and an upload without dedupe.
- **Search does not fold accents.** The Clients free-text filter is
  `name.toLowerCase().includes(needle)`, so "Nunez" does not find "Núñez".
- **Two different sort orders for one list.** Home orders by name in Postgres;
  the Clients list sorts with `localeCompare` in JavaScript. They disagree on
  accented names.
- **`clientWords` drops accents** — `clientName.toLowerCase().split(/[^a-z]+/)`
  in `lib/filename-rules.ts:291` yields `[]` for a fully accented name, so the
  `bare` signal is computed from the wrong residue. I could not construct a case
  where this changes the filing outcome: accented and ASCII names classify
  identically in every shape I tried, because `bare` is only the last-resort
  branch at line 401. Recording it as latent and untested rather than as a
  finding — `check-filename-rules.mjs` has no accented or apostrophe fixture,
  which is the part actually worth fixing.

---

### What was tested and found sound

Worth writing down, both because it is the larger part of the answer and
because two of these were hypotheses I expected to confirm and could not:

- **Route handlers all carry their own authorization.** I expected a hole here:
  layouts do not run for route handlers, so the three under `app/(app)/` get no
  `canReach` from the layout. All three check for themselves — the warrant image
  with `can(me, "billing", "view")`, the books package and report export with
  `canReach(me, "/books")` — and `/api/export/[kind]`, `/api/hours/statement`
  and `/api/mail/attachment` each gate too, the statement route down to "only an
  Admin draws up somebody else's".
- **Hours past the authorized total are refused**, with a message that says the
  figures and what to do: "Request additional hours from the counselor first."
- **Two authorizations with the same number are refused** —
  `authorizations_number_unique` on `normalize_auth_number(number)`, globally,
  partial so blanks do not collide.
- **The same file twice is caught and explained.** The `sha256` index gives
  "This client already has that exact file on their record", the orphaned object
  is removed from storage rather than left unreachable, and storage paths are
  `crypto.randomUUID()`, so two simultaneous uploads cannot collide and cannot
  delete each other's bytes. I went looking for that last bug specifically; it
  is not there.
- **A PDF that is an image is detected, not mis-parsed.** `lib/pdf-text.ts:152`
  flags `scanned` when the text layer is under 40 non-space characters, the
  import form says so, and the intake cron routes it to OCR.
- **A counselor with no email is handled everywhere it matters**, in those
  words: "No email on file for …, so they are not copied", "Nobody to send it
  to", "No phone or email on this counselor's record."
- **No PostgREST injection surface.** Every interpolated `.or()` in the codebase
  carries a UUID or an ISO date — never user text. Free-text search never
  reaches the database.

### Part 6, honestly

The hub finding above is part 6's headline and is proven by code. The rest of
"every hub tab at 390 px" is **not done**. The CSS has been thought about —
`.tabs` is `flex-wrap: wrap`, so tabs stack instead of scrolling sideways;
`.table-wrap` is `overflow-x: auto`; there are breakpoints down to 520 px — and
one thing is worth a look when somebody has a phone in hand: `.tabs` is
`position: sticky` with 32 px of padding, so a group with ten screens (Books)
wraps to several rows and becomes a tall sticky block on a 390-point screen.
That is a reading of the stylesheet, not an observation.

I could not render the signed-in app at 390 px. The browser pane cannot sign in,
and stubbing auth to get there means editing files, which this brief ruled out.

### Left for the owner

- **Measuring part 1 needs a decision.** Either allow the rolled-back seeding
  transaction against production, or say to start a Supabase branch and accept
  that its timings describe different hardware. Until then the load findings are
  query-shape arguments. I would take the rolled-back transaction: it is what
  `verify_0_messaging_load.sql` already does, and it measures the machine the
  practice uses.
- **Nothing here has been changed.** Eleven findings and their proposed fixes,
  waiting.
