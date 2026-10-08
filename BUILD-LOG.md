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

