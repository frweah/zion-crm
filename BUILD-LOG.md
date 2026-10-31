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

---

## The eight findings, fixed — 16 October 2026

*Owner: fix all eight stress-test findings in that order, with a verify script
or check for each so they cannot come back. Filter and paginate the Hours and
client lists. Claim the scheduled text before sending. And measure, inside one
rolled-back transaction, the way verify_0_messaging_load.sql does.*

Five migrations (0205–0210), six new verify scripts, two new checks, and the
measurement the first report could not take.

### What the measurement says

500 clients, 2,000 authorizations, 20,000 logged hours, 5,000 documents,
1,781 job matches, seeded and timed inside one `begin … rollback` on the
production instance. Best of three, as each role, with RLS applied.

| | rows | before | after |
|---|---|---|---|
| Billing: the working list | 1,514 | **4,206 ms** | 543 ms |
| Clients list: last activity | 50 of 595 | 451 ms | **10.8 ms** |
| Billing → Hours | 20,000 → 60 | 464 ms | 81 ms |
| Client record: their billing | 3 | (the 4,206 ms above) | 19 ms |
| Home: the billing tile | 1,514 | (the same shape) | 226 ms |

And the ones that were never the problem, which matters just as much:

| | rows | ms |
|---|---|---|
| Home: every client, ordered | 595 | 2.8 |
| Clients list: the client rows | 595 | 0.7 |
| Clients list: every job match | 1,781 | 0.6 |
| One client's documents | 10 | 0.4 |

**Exactly one thing was over a second, and it was the working list.** The
first report predicted that by arithmetic and was right about it; it was
wrong, or at least overstated, about the client lists. Reading every client
costs 0.7 ms at five times the current caseload. Paginating *that* would have
bought nothing — the activity view beside it was the whole of that screen's
time.

Absolute figures move between runs on a shared instance (the hours-used
figure came back 293 ms on one run and 547 ms on another). The ratios are the
finding; the single numbers are not.

### 1. The hubs open

`/work`, `/communication` and `/hr` were reachable by **nobody**. `canReach`
was built from `reachableFor`, which flattens nav *items*, and a hub belongs
to the *group* — so the layout gate redirected every hub to Home, for every
role. Three of the four tabs on the phone bar and three sidebar headings
point straight at them.

`canReach` now grants a group's hub to whoever can see the group. Exactly,
not by prefix: a hub is a landing page and owns no screens beneath it.

**Why the check passed.** `check-nav.mjs` asserted that a hub *has a page*.
The rule is whether anybody can *open* it. It now asks `canReach` itself, for
every role, in both directions — a role that sees the group reaches its hub,
a role that does not cannot. With the fix reverted it fails eighteen times.

A stale comment in `lib/roles.ts` claimed these addresses "redirect to their
first screen (next.config.mjs)". They do not; there is no such redirect, and
`hub-page.tsx` renders real card pages. The comment described a design that
had been replaced.

### 2. Billing → Hours reads a month at a time

It asked `service_entries` for every row ever logged — no filter, no limit —
and serialised the lot into the page. It reads one month, sixty rows to a
page, with Earlier/Later and Newer/Older.

The hours-used figure the logging form shows no longer comes from those rows.
It came from counting them in TypeScript, per authorization and its own
entries only, which **missed every hour logged on a coaching month** — a
parent with 40 hours against it displayed 0 used, while the database refused
the next entry. It now comes from `authorization_hours_used` (0205), which is
the same function `check_entry_hours` enforces with, so the form and the
database cannot disagree.

### 3. The working list counts once

`billing_worklist` called `authorization_amount` and `authorization_attention`
**once per row**, and both read `service_entries` — the second through an `OR`
across a join, the shape that stops an index being used. It ran in three
places: Billing, Home's tile for Admin and Billing, and every client record's
billing tab, which fetched the whole practice's list and then threw away
everybody else's rows in JavaScript.

Both are set-wise now (`authorization_amount_for`,
`authorization_attention_for`), and the single-row functions are kept as thin
wrappers over them, so there is still one definition of each rule and the
authorization record cannot drift from the list. `verify_worklist_counts_once`
asserts they agree about **every authorization on file**, not about a fixture.

`billing_worklist` takes a client, and the client record passes it.

One correction carried in: the old attention query read carried hours as
`coalesce(parent.carried_used, own.carried_used, 0)`, while `check_entry_hours`
reads them from the root alone. A coaching month carries no hours of its own,
so the root is right, and this now matches what the database enforces.

### 4. Last activity, for the clients on the page

The obvious fix did not work, and the measurement is why it is a function and
not a `WHERE` clause:

- `client_last_activity`, every client — 595 rows, 451 ms
- `client_last_activity`, 50 ids — 50 rows, 358 ms
- `client_last_activity_for(50 ids)` — 50 rows, **10.8 ms**

The twelve unions are built in full and *then* filtered, so narrowing the
question does not narrow the work. 0207 pushes the client ids inside each
branch, which makes every one an indexed lookup.

`verify_last_activity` already existed and tested something I had not thought
of — that a note kept to Admin moves the date for Admin **and nobody else**.
I overwrote it by accident and recovered it from git; it now asks both
readers the same questions as both roles, including that one. A faster answer
that quietly shows more is not the same answer, and that is the way this
change could have gone wrong.

The job matches are narrowed to the clients shown. The client rows are not
paginated, and the measurement is the reason: 0.7 ms for 595. The display has
paged at fifty all along.

**A new check**, `check-unbounded-reads`, fails any read of a table that grows
with the work — rather than with the caseload — unless it is bounded by a
filter, a page or a limit. Its first version read the chain to the next line
starting with `supabase.`, so a query written across lines never ended and the
*next* query's filter was read as this one's — and `client_last_activity`, the
most expensive unbounded read in the codebase, came back clean. It counts
brackets now. It then found four more: both Insights screens read every hour
ever logged while showing a period, the leads board read every match on file,
and `readPayments` had an optional bound that nothing ever used.

### 5. Two people logging hours at once

`check_entry_hours` counted the hours used and then decided whether one more
fitted, with nothing holding the authorization in between. Two coaches logging
at the same moment both read the same figure and both got in — and hours past
the authorized total are hours the practice cannot bill, found at submission,
after the work is done.

The root authorization is locked before its hours are counted. It serialises
only entries against the same family; two coaches on different clients never
wait for each other.

**Testing it took three attempts, and the first two were wrong.** The obvious
assertion — a row locked by this transaction carries its id in `xmax` — passes
whether the fix is there or not, because inserting a service entry takes a
`FOR KEY SHARE` lock on its authorization for the foreign key anyway. That
script was written, passed, and thrown away. Replacing the guard inside the
first transaction to prove the control does not work either: the second
session then blocks on the *catalogue* rather than on the row, so it blocks
for the wrong reason.

So `scripts/check-hours-race.mjs` races two real connections, and its control
is two sessions working on *different* authorizations, which must not wait for
each other. Both transactions roll back; nothing is written.
`verify_hours_race.sql` carries the rest and says plainly which of its
assertions is structural and why.

### 6. A scheduled text is claimed before it is sent

`sendScheduledTexts` read the due rows, sent them, and *then* deleted them.
Two overlapping runs — Vercel cron delivers at least once, and the `curl`
command in the route's own comment can be run alongside the schedule — both
read the same rows and both sent. The client got the message twice.

`claim_scheduled_text` is a conditional update, which is the lock: Postgres
serialises the two runs on the row and only one finds it still `Scheduled`.

Which needed a way back. A run that dies between claiming and sending would
leave a text claimed for ever and never sent — a silent failure, worse than
the double send it replaced. So `claimed_at`, and anything still `Sending`
after fifteen minutes is handed back. `verify_text_claim` asserts both halves,
including that a claim made a moment ago is *not* handed back, since that
would be the double send by another route.

### 7. The 25 MB upload was never possible

This one turned out worse than reported, and the reported fix would have been
the wrong one.

The first report said the promise and the limit were exactly equal, and that
adding headroom would fix it. They were — but `bodySizeLimit` was never the
real ceiling. **Vercel refuses a request body over 4.5 MB in its own
infrastructure, and no Next setting raises it.** `bodySizeLimit: "25mb"` was a
promise the platform had never agreed to, so every staff and onboarding upload
above 4.5 MB died before any of our code ran — which is Melanie's failure from
30 September, still live on these paths after the one it was found on was
fixed.

So the bytes no longer go through a server action. Staff documents, document
replacement, and onboarding identity and credential scans upload from the
browser straight into the bucket, exactly as the client record already did —
`add-file.tsx`'s own comment says a 25 MB scan has no business passing through
a server action. The storage policy from 0198 already allowed precisely this,
so who may upload is unchanged; only which machine sends the bytes. The 25 MB
these screens promise is now reachable for the first time.

`check-upload-limits.mjs` was asking the wrong question entirely. It now
compares every promise against whichever is smaller — what we configured or
what the platform carries — and requires headroom rather than equality,
because a multipart body is bigger than the file inside it. It immediately
found two more: the authorization PDF import promised 10 MB and the bank
statement reader 8 MB, both through server actions. Those two are honest at
3 MB for now with a sentence that says what to do; moving them to
browser-direct is the better fix and is left below.

`serverActions.bodySizeLimit` is `4mb`, which is a number the platform will
actually honour.

### 8. A date has to be one somebody meant

Date validation was `/^\d{4}-\d{2}-\d{2}$/`, which accepts `0226-03-14`, and
the schema contained exactly one date range in it (`staff_personal_dob`).

A slipped year goes one of two ways and both are quiet. Backwards puts
`stale_date` centuries past, so the authorization is reported expired for ever
and raises an alert that doing the work cannot clear. Forwards means `bill_by`
never arrives, so it never falls Due, never reaches the working list, and is
never billed — with nothing at all to say so. That is the expensive one.

A date now has to be between 1990 and five years ahead, on an authorization's
nine date columns, on a document's date, and on an hour. In the database,
because the rule has to hold however the row arrives — the intake cron reads
dates off a PDF and the filing rules read them off a file name, and neither
goes through a form. A trigger rather than a CHECK, because the window moves
with today.

Only on the way in: a row already on file whose date is outside the window can
still be edited, and keeps it. Nothing on file is outside it today — that was
checked before the rule was added. `dateComplaint()` gives the same answer in
TypeScript so a person gets a sentence rather than a database error.

### The sidebar mark

The artwork is a full-colour gradient and **31.6% of its opaque pixels are
teal or blue** — measured, not eyeballed — so it is not the plate. It is drawn
as a single-colour silhouette through its own alpha, filled with `--side-ink`
on `--side-bg`: the theme's white on the sidebar's green, in both modes. Three
quarters of the PNG is transparent, including the gaps between the leaves and
inside the ring, so the silhouette keeps its structure at 36px. No new colour,
which `check-theme` already enforces.

### Left for the owner

- **Two uploads still pass bytes through a server action** and are now capped
  at 3 MB: the authorization PDF import and the bank statement reader. Both
  parse rather than store, so the fix is to upload to storage from the browser
  and read it from there. Say the word and it is a short piece of work.
- **`Home: next actions for 50 clients` is 356 ms** at ten times the size.
  Under the budget and not one of the eight, but it is the next thing on the
  list if Home ever feels slow.
- **The 4.5 MB platform ceiling applies to API routes too**, including the
  agent upload endpoints. They were not counted here because several stream
  rather than take a body, and I have not checked them one by one.

---

## The logo on a plate, and the end of the day — 18 October 2026

*Owner: revert the white silhouette and show the logo as it is, on a white
rounded plate, 8 px padding, white in both modes. And: an end of day entry
under My work for every role, modelled on the practice's EOD template.*

### The logo

The silhouette is gone. The artwork is shown as it was drawn, on a plate of
`--brand-plate` — pure white, declared in all three token blocks with the same
value, because it is the one surface in the app that deliberately does not
turn over with the theme. 8 px of padding, an 8 px radius, and nothing
recolours the logo.

The narrow rail decides the size. It is 64 px wide with 10 px of padding each
side, so 44 px to work in; the plate is the logo plus 8 px all round, which
puts the sidebar logo at 36 px and the rail's at 26 px.

**The exemption was not needed, and is there anyway.** `check-theme` reads
`.css`, `.tsx`, `.ts` and `.mjs` under `app/` and `lib/` — it never reached
`public/zion-logo.png`, so the palette rule had nothing to say about the
artwork in the first place. Rather than add a no-op, the decision is written
down: `BRAND_ARTWORK` names the file, the check prints it as a deliberate
exemption, and anybody who later teaches it to read assets will find the
reason already there. The plate is *not* exempt — `--brand-plate` is declared
in `tokens.css` with every other colour, which is why "no new theme colours"
still passes.

### The end of the day

Migrations 0211–0214, a screen at `/end-of-day` under HR (which `lib/roles.ts`
notes "was My work"), 22 assertions in `verify_end_of_day.sql`, and a
rolled-back smoke check.

**It is the practice's own form.** `Office/TEAM/EOD REPORTS/EOD Report
Template.xlsx` was read rather than guessed at, and the screen carries its
headings: Name of the Employee, Department/Agency, Date Prepared, Assigned
Manager/Team Leader; a TASKS LIST of STATUS / DESCRIPTION / NOTES; and
BOTTLENECKS with ACTIONS TAKEN/SUGGESTIONS. The template's three statuses are
Complete, In-Progress and "Pending/ To do"; the owner shortened the third to
Pending and that is what the screen says.

Three things the spreadsheet could not do, which are the reason for moving it:

- **A line about a client lands on that client's record.** Submitting writes
  every client line to that client's contact log, as `End of day report`, with
  the description as the topic and the status and notes as the outcome. The
  contact-log id is kept on the line, so a reopen and a second submit do not
  write the client's history twice — asserted.
- **What was unfinished is already on today's form.** In-Progress and Pending
  carry forward; Complete does not. From the last day they *submitted*, not
  the calendar day before: on a Monday what is still Pending is Friday's, and
  carrying from an empty Sunday would lose it.
- **It is submitted once.** Reopening is the same day only, needs a reason,
  and is written down. A day reopened a week later is history being rewritten
  rather than a mistake being fixed.

**A pasted report is read, not retyped.** Every line starting with a hyphen
becomes a task. A status in brackets is honoured — `- [Pending] chase the
intake` — which means the summary this app emails pastes straight back in
tomorrow.

**`staff.manager_id` is new.** The template's "Assigned Manager/Team Leader"
was something the CRM did not know. Admin sets it; null means the summary goes
to Admin alone, which is what happens today anyway.

**Who sees a day:** their own, Admin's everybody's, and a manager their own
people's. The last is a judgement call beyond the literal instruction — the
summary is sent to the manager, and a notification they cannot open is not
worth sending. Say the word if it should be Admin only.

### The transition

A message to service@ with EOD in the subject, from a member of staff, is
filed on their day record as a document and raises a reminder on their bell
and My day. The reminder clears itself when they actually submit that day.

**It cannot loosen the intake gate**, and that is the part worth saying twice.
The branch runs before the utah.gov rule, files only when the sender is on the
staff list, and when it does not file the message falls straight through to
the gate exactly as before. `check-intake.mjs` asserts all three: the ordering,
the fall-through, and that "EOD" is read as a word rather than three letters
inside "method", "period" or "neodymium".

Reading the day out of the subject (`EOD 5/13`, `MAE_EOD_JUNE 1, 2026`) found
two bugs in its own writing. `\b` counts an underscore as a word character, so
there is no word boundary before JUNE in `MAE_EOD_JUNE` — the boundaries are
written out now. And taking the first thing shaped like a date takes a version
number or a time instead; every match is tried, and 31 February is refused
rather than rounded.

**Review on 1 November 2026.** What to look at: whether anybody is still
emailing days, and whether the reminder is clearing — if it is clearing, the
habit has landed and this branch can go.

### What the checks caught

- **The day locked itself out of its own submission.** `submit_staff_day` set
  `submitted_at` and *then* noted on each line which contact-log entry it had
  written — which is a change to a line on a locked day, so the lock refused
  it and submitting any day with a client on it failed with the day's own
  guard. `verify_end_of_day.sql` found it on the first run, which is what it
  is for. 0213 does the filing while the day is still open and closes it last.
- **Three tables did not refuse the system account.** `verify_system_account`
  caught `staff_days`, `staff_day_lines` and `staff_day_events`, as it caught
  `staff_record_changes` in 0199 and `client_document_events` in 0202. 0214
  applies the rule. An end-of-day report is a person writing about their own
  work and is the last thing an account with no person behind it should file.
- **A table holding client data has to be in the records bundle or skipped
  with a reason.** `staff_day_lines` is skipped, for the same reason
  `inbox_documents` is: the filed copy is already in the bundle, because
  submitting writes the line to the client's contact log and `contact_log` is
  disclosed as `counselor_contacts`. Disclosing both would hand the client the
  same sentence twice, and an unsubmitted line is a draft of a day nobody has
  finished writing.

### The smoke case, and where it runs

The owner asked for: a Job Search user submits a day with one client-linked
line, the client's contact log shows it, one summary email is sent.

`scripts/smoke.mjs` opens pages and asserts they do not break; it posts
nothing. More to the point, a smoke test that really submitted a day would put
a junk end-of-day on a **real client's record** and a junk email in service@
on every deploy.

So it runs as `scripts/check-end-of-day.mjs`: the real flow —
`open_staff_day`, a client-linked line, `submit_staff_day` — as a real Job
Search user with RLS applied, against ZZ fixtures, inside a transaction that
is rolled back. It asserts the client's contact log shows the line exactly
once and that the summary carries the template's headings, the task and the
client. The one step it must not take is sending, so the email is checked by
reading the action: exactly one `sendEmail`, to service@zionvocrehab.com.

The screen itself is already in smoke for free — `/end-of-day` is on every
role's navigation, so the sweep opens it as a Job Search user on every deploy.

Like `check-hours-race.mjs`, it needs database credentials and so is not in
`prebuild`, which runs on Vercel.

### Left for the owner

- **Nobody has a manager yet.** `staff.manager_id` is empty, so every summary
  goes to Admin alone until it is filled in on each person's record.
- **Whether a manager should read their people's days**, as above.
- **1 November**: the review on the emailed-day transition.

---

## My work, and the first manager — 18 October 2026

*Owner: move the End of day entry from HR to My work for everyone; keep the
team view under HR for Admin and managers. Update check-nav and smoke. And set
Margaret Paasa as Rei Ruzzel's manager.*

### My work is a group again

There was no "My work" to move it to. HR *was* My work and was renamed on
21 Sept; its own comment still said "a person's own work and papers". So the
instruction only holds together one way, and that way is the right one: the
things a person does about their own working life are not the things an
administrator does about everybody's, and the two had been in one group under
a name that only fitted the second.

**My work** — Time clock, Hours, Statement approvals, End of day, Paperwork,
Certifications, Knowledge base, Forms and checklists.
**HR** — End of day — team, People, Contractors.

For anybody who is not Admin and manages nobody, HR now has no visible items
and drops out of their sidebar entirely. That is the intent, not a side
effect.

Three consequences worth naming:

- **Statement approvals stayed with Hours**, not with HR where it first went.
  It is a tab of the Hours screen, and `check-nav` caught it immediately: the
  way back off `/hours?tab=approvals` pointed at one group while `/hours`
  pointed at another, because the same route was in two groups at once. A
  screen whose tabs are split across two sidebar groups is a screen nobody can
  find the other half of.
- **`/my-work` was a redirect to `/hr`**, left from the rename. It is a page
  again, so the redirect is gone rather than pointing a live address at a
  different one.
- **The phone bar carries My work instead of HR.** Its four tabs are the
  group keys, and HR is now empty for nearly everybody — while the end of day,
  which is the thing people fill in on a phone, is in My work. HR has its own
  icon now too; two groups drawn the same way are two groups nobody can tell
  apart.

### A manager is not a role

The team view opens for an Admin by role and for anybody who manages somebody
by the fact that they do. That could not be written as a role: it changes the
moment somebody is given a manager.

So `Access` gained `manages`, read with the person in `getCurrentStaff` (one
extra join on a six-row table), and a nav item can say `managers: true`. It is
the only thing in the navigation decided by something other than a role or a
grant, which makes it the only thing that could go quietly wrong — a manager
sent their people's summaries who cannot open the screen those summaries link
to. `check-nav` now asserts it both ways for every role.

**And that assertion immediately found a real bug.** `/end-of-day/team` was
reachable by *everybody*, because `canReach` lets a screen be reached through
the one above it — `/clients/<id>` through `/clients` — and `/end-of-day/team`
sits under `/end-of-day`, which everybody has. A screen that is itself in the
navigation is now reached on its own terms; inheriting it from the screen
above would hand somebody a listed screen they are not listed for.

### Smoke opens the hubs now

`reachableFor` returns items, and a hub is not an item — so smoke had never
opened `/work`, `/communication` or `/hr` at all. That is precisely how three
hubs shipped unreachable by every role two days ago: the sidebar headings and
three of the four phone tabs pointed at them, and nothing in the sweep opened
one to find out. A hub is a screen and is swept like a screen.

### Rei reports to Margaret

Migration 0215, matched by name against the active staff list and refused
rather than silent if either name is missing or not unique.

What it does, so it is not a surprise:

- Rei's day summaries go to Margaret as well as Admin, on her bell and her
  My day.
- Margaret can read Rei's days. Nothing else about his record opens to her.
- Margaret gets "End of day — team" in her sidebar under HR, which she did
  not have. Her role is still Reports.

`verify_end_of_day.sql` now asserts this against the **real staff list**, not
only a fixture: every person who has a manager, that manager can read their
days. A fixture proves the rule is written; this proves it is in force for the
people it was set for.

Admin can set it on anybody from People → the person's record, where Manager
sits beside Role. Nobody can be their own manager — the action refuses it and
the migration checks the whole list.

### Left for the owner

- **Everybody else still has no manager**, so their summaries go to Admin
  alone. One dropdown each on their record.
- **The 1 November review** on the emailed-day transition still stands.

### A self-referencing embed signed everybody out — 18 October 2026

The deploy above was refused by the smoke test, and it was right to.

Reading whether anybody reports to somebody was written as a PostgREST embed,
`reports:staff!staff_manager_id_fkey(id)`. PostgREST will not resolve a
self-referencing one — *"Could not find a relationship between 'staff' and
'staff'"* — so the whole select failed, `getCurrentStaff` returned null, and
null from there means no access. **Every screen for every role answered
/no-access.**

Smoke caught it on the way to production, the deploy never promoted, and
nothing live was affected. The signature in the log is unmistakable in
hindsight: not one screen failing, but every screen for a role failing at
once, starting mid-sweep.

It is a count now, asked as its own question. A count over a six-row table
inside a request-cached function is not worth being clever about, and the
embed was the clever version.

**The amplifier matters more than the embed.** The select took only `data` and
ignored `error`, so a query that *failed* looked exactly like a person who had
never been given an account. It still returns null — failing open would be far
worse — but the fault is now logged with its reason instead of silently
signing out the practice. The middleware learned the same thing about
revocation on 15 October: an error is not an answer. That is twice now, in two
different files, and it is worth saying plainly as a rule — **when a check
cannot get an answer, that is not the same as getting the answer "no".**

Verified against production's PostgREST before the second deploy, rather than
after: the select the session runs returns 200, and the count returns 1 for
Margaret.

---

## The writing and screen standard, written down and checked — 18 October 2026

*Owner: the Writing and screen standard — a CLAUDE.md section, check-copy in
prebuild, applied to every screen now, report what changed.*

### What changed

**Seven sentences were pointing staff at screens that do not exist.** That is
the whole of the harvest, and it is a better one than it sounds.

The navigation has been regrouped twice — Dashboard became Home and Inbox
became Communication on 21 Sept; Clients came out of Work on 15 Oct — and the
copy naming those screens was not regrouped with them. Nothing broke, which is
precisely why nobody noticed: every link still worked, and only the words were
wrong.

| was | now | where |
|---|---|---|
| Inbox → Mail | Communication → Mail | Home |
| Dashboard → Tasks | Work → Tasks | Home, quick add, knowledge base |
| Clients → My clients today | Work → My clients today | Home |
| Billing → Invoices | Billing → Authorizations | the document inbox |
| aging on Billing → Invoices | aging on Admin → Money | Admin → Reports |

**Invoices had been deleted outright** in the Billing Simplification (§10),
and a staff member following that sentence would have gone looking for a
screen that was removed a month ago.

Four more of the same were in comments rather than on screens. They were
corrected too — a comment that lies is worse than no comment — but they are
not what the check judges.

### What did not change, and why that is the report

Nothing else. Not one *please*, not one apology, not one exclamation mark, no
"Are you sure?", no "click here", and all 74 buttons already say what pressing
them does — "Take it down", "Say it", "Do not send", "Place hold". Labels are
sentence case throughout and none carries a full stop.

That is worth stating plainly rather than padding: **the standard was already
being followed.** `check-words` has held the two length rules since 6 October
and `check-screens` the structural ones, and between them the voice stayed put.
What was missing was not discipline, it was a written statement of the rules
and a check on the one thing neither of them looked at — whether the words
still describe the app.

### The standard

`CLAUDE.md` is new, and its "Writing and screen standard" section is the
durable version: the voice, the screen, and what the rules deliberately do not
cover. It records the two rules this project keeps relearning, because both
have cost a production incident:

- A check that asks a question merely *near* the rule passes the bug it was
  written for.
- When a check cannot get an answer, that is not the same as getting the
  answer "no".

### check-copy

In `prebuild`. Six rules on the voice, two on buttons, and the one with teeth:
every "Group → Screen" in copy is read against the live navigation.

`scripts/copy-text.mjs` is shared with `check-words` so both judge the same
thing. Getting that extractor right took three passes, and the failures are
the point: the first version read spread operators as ellipses and non-null
assertions as exclamation marks; the second matched across generic type
parameters, so `useState<string | null>(null)` came back as prose. It now
throws away anything carrying the punctuation of code before reading it as a
sentence, and only looks for tag text in `.tsx` — in a `.ts` file every
`>…<` is a generic.

Put back as a test: restoring "Inbox → Mail" and "Dashboard → Tasks" fails the
check with both named.

**Exempt, on purpose.** The public website chat says "Please start a new one"
to a member of the public; courtesy to a stranger is not padding on a working
screen. Comments are never judged. Billing, authorizations, forms and warrants
keep the length exemption the design-language brief gave them.

---

## Security hygiene and feedback — 18 October 2026

*Owner: two-factor for all staff, an Admin offboarding action, a backup
restore test, and "Report a problem" in the avatar menu.*

### Report a problem

Staff have had nowhere in the CRM to say something is wrong since it was
built, so the only faults that got fixed were the ones the owner happened to
hear about in the corridor.

One form in the avatar menu, on every screen, which records **which screen
they were on** — half of what anybody reports is "this page" and they should
not have to describe where they were. Admin is told on the bell rather than by
email: a problem report is not urgent enough to interrupt somebody's evening.
Closing it clears the notification, so the bell and the list of open reports
cannot disagree. Admin reads and closes them under Admin → System.

**What was said is not edited**, by anybody, including the person who said it.
A report is an account of a moment and the useful thing about it is what they
thought at the time; closing one adds a note beside it.

The verify asserts that by reading the text back rather than by waiting for a
refusal. With no update policy RLS does not raise — it matches no rows and
reports success — so an assertion that expected an exception would have passed
whether or not the text was protected.

### Two-step sign-in

The CRM holds every client's disability information, their identity documents,
the practice's bank reconciliation and its payroll, and it has been protected
by a password and nothing else.

Supabase Auth does the cryptography. What was built is the practice's side:
the setting, whether the person in front of us has one, who has and has not,
and the lost-phone path.

**It ships switched off, on purpose.** Enrolment cannot be rehearsed on
somebody else's phone, so the first person through that screen is the first
real test of it — and if the screen were wrong with the setting already on,
nobody could get in to fix it, including whoever would have to. Admin turns it
on under Admin → System once the roster shows everybody enrolled; the screen
names who is still to do it.

Nobody is locked out by turning it on: somebody without a factor is walked
through setting one up, and somebody who loses their phone has it taken off by
Admin and sets up a new one. An Admin cannot take off their own — an
administrator who could has a second factor one click of their own password
away from not existing.

**The deadlock that nearly shipped.** The layout sends people to
`/security/two-factor`, and `canReach` refuses any path that is in no nav
group — so it would have sent them to Home, and the gate would have sent them
back, for ever. It only bites once the setting is on, which is exactly when
nobody could get in to fix it. `check-nav` now asserts that every role reaches
it.

`check-screens` wanted a back arrow on it. It does not get one: when the gate
sends you there, a back arrow returns you to the screen you came from and
bounces you straight back, and an arrow that lies about what it does is worse
than no arrow.

### Offboarding — already there

`offboard_staff` has been in the database since before this brief, with an
action, a screen and `verify_offboarding.sql`. In one transaction it
reassigns the clients and tasks, writes the record, and deactivates the
account; the action then bans the auth user, which lives outside the database.
It is reported here rather than rebuilt.

### The backup restore test — not done, and why

This one needs the owner. A restore is the one operation that can destroy the
thing it is meant to protect, and the only honest test of it is restoring to
somewhere that is not production and reading the result. That is an
infrastructure decision with a cost attached, not a code change.

What it needs, concretely: a throwaway Supabase project, a restore of last
night's backup into it, and a count of clients, authorizations, documents and
journal lines against production's. An afternoon, and it should be repeated
each quarter. Say the word and the drill can be written as a script that does
the counting, so the only manual step is the restore itself.

Until then, the fact worth having in writing: **nobody has ever tested that
these backups restore.** Supabase takes them; that is not the same thing.

---

## The 2026 baseline — 18 October 2026

*Owner: the 2026 baseline snapshot under Admin → Money.*

### What a baseline is here, and why

`ledger_settings.books_start` is **1 January 2027**, and `post_journal`
refuses anything dated before it. Everything the practice has done in 2026 is
therefore outside the ledger entirely, and on the day the books open there
would be nothing at all to say what came before.

So the baseline is the practice's position at a date, **counted once and
kept** — and the keeping is the point. A baseline that recomputed would not be
a baseline: an authorization corrected in March would quietly change what
December said, and the figure the practice compares itself against would move
without anybody deciding it should.

Under Admin → Money, above the export, because the export is this year's
working data and this is the line the year is measured from.

### What it captures

The money comes from `authorization_economics`, which is the practice's own
definition of each figure and is what the Money screen already shows:
**authorized, earned, invoiced, received, outstanding, not yet billed**, for
every authorization received on or before the day.

Beside it, the shape of the practice at the same moment: **clients,
authorizations, documents, logged hours**. Those are there so that a restore
or a migration can be checked against a known-good row rather than only the
money — which is also the beginning of an answer to the backup question
above.

`verify_money_baseline.sql` asserts the kept figure equals what the screen
computes on the day it is taken, so the snapshot and the screen cannot
disagree about the moment they describe.

### Frozen

Taken once for a day. Not edited, not deleted. A note may be added afterwards,
because explaining a row is not altering it; if the figures were wrong, take
another for a later day and say why.

Admin's to take and Admin's to read. The agent account cannot take one.

**The delete assertion is worth recording**, because it is the third time this
pattern has caught me this week: with no delete policy, RLS does not raise —
it matches no rows and reports success. A test that waits for an exception
passes whether or not the row survived. It reads the row back instead.

### This is a reading, and here is the reading

I did not have the message that listed this item, so what is built follows
from `books_start` and from what Admin → Money already shows. If the CPA
needs figures that are not in the list above — a cash position, a payroll
total, assets at cost — they are columns on one table and a line each in the
function, and the baselines already taken stay valid.

---

## Work and My work become one — 18 October 2026

*Owner: merge the Work and My work sidebar groups into one named My work, the
client work then the person's own, in that order. One icon, one phone-bar
entry, HR unchanged. Remove the old group and any redirect from it, and update
the checks so no screen is reachable from two groups.*

The two groups lasted a month and the line between them never held. "Work"
meant the caseload and "My work" meant your hours and your paperwork, which
reads clearly in a design note and not at all in a sidebar: a job coach
looking for their day had to know which of two similar headings it was under,
and the honest answer was often both.

**My work**, in the order somebody works — what is owed to clients, then what
is owed about yourself:

Tasks · My clients today · Jobs · Counselors · Hours · Statement approvals ·
Time clock · End of day · Paperwork · Certifications · Knowledge base · Forms
and checklists

**Jobs and Counselors were not in the owner's list and are kept anyway.** They
were in the old Work group, and dropping them would take two screens out of
the navigation altogether — which cannot be what merging two groups was for.
They sit with the client work.

The group took the position Work had, between Clients and Communication, so
the sidebar still reads client-facing first: **Home · Clients · My work ·
Communication · Billing · HR · Admin**. HR is untouched.

One icon — the case, under its own key, with the old Work alias gone. One
phone-bar entry, and Clients takes the slot Work had: Home · Clients · My work
· Communication.

`/work` is gone with no redirect, as asked. A bookmark to it will 404.

### The new rule in check-nav

**A screen belongs to one group.** That is how this kind of merge goes wrong —
a screen left listed in both, with two back arrows pointing different ways and
two places to look for one thing. Compared on the path rather than the href,
because `/hours` and `/hours?tab=approvals` are the same screen and may sit
together. All 32 screens belong to exactly one group.

### And check-copy earned its keep the same day

It immediately failed on four sentences naming "Work → Tasks" and "Work → My
clients today" — references this morning's pass had just *corrected* to point
at Work, now stale again because the group is gone. That is the rule working
as intended: the words describing the app are checked against the app, and the
check noticed within minutes of the group disappearing.

---

## The baseline measures the work, and the restore drill — 18 October 2026

*Owner: add operational measures to the frozen baseline, and script the backup
restore verification with the exact steps written down.*

### The measures

Added to the frozen baseline, beside the money: **median days from receiving
an authorization to submitting it** and **from submitting to paid**,
**placements started in the year**, **4-week and 90-day retention**, and
**clients by stage**.

Two of them read empty today, and that is the finding rather than a fault in
the measure:

- **No authorization on file has a submitted date.** 162 of them, none with
  `submitted_on`. The dates are set when the status moves through the app, and
  the records on file were imported with their status already on them. So
  neither median can be computed yet.
- **No placement has a 30, 60 or 90-day check recorded.** 30 placements, none
  checked. Retention is therefore unknown rather than nil.

Both store null, and the screen says **"not known yet"**. That distinction is
the point: *0 days to submit* reads as "same day" and *0 of 0 retained* reads
as "nobody kept their job", and either would be quoted back at the practice by
somebody who had not read the footnote.

Retention is kept as a **pair** — retained out of those we could possibly know
about — because a rate with no denominator can be read whichever way suits.
The denominator is placements old enough by the baseline's date to have been
checked at all, so a job that started last week is not counted as a failure.

**What "retained" means here, exactly**, because it is a proxy and should not
be quoted as more: a placement with a check recorded at that point. The table
holds the date each check happened and no outcome beside it, so the check's
presence is the best the record supports. If an outcome is ever recorded, that
is the line to change.

The verify asserts the relationship rather than the totals — the first version
expected "1 of 2" and failed at "1 of 8", because the fixture was counting a
table it does not own.

### The restore drill

`scripts/backup-fingerprint.mjs`. For every table: how many rows, and a
checksum over its contents. The checksum is what makes it worth more than a
row count — a restore that loses a column, truncates text or drops a timezone
keeps the row count exactly and changes the fingerprint. Row digests are
sorted before hashing, because a restore does not preserve row order.

Nothing in the output is client data: each table contributes a count and a
hash, so the file can be mailed, committed or pasted into a ticket.

**It had to be taught what not to compare.** Run against production twice in a
row it reported `staff_presence` as changed — which it had, because that table
is who is on the CRM right now. A fingerprint that calls an unchanged database
wrong is a fingerprint nobody will use, so volatile tables are excluded *and
listed in the output* as skipped. A table dropped quietly is how a check comes
to cover less than the person reading it believes.

Proved by breaking it: a doctored fingerprint with one row removed, one
table's contents altered and one table deleted fails with all three named.

### The steps, for the day they are needed

1. **Fingerprint what you have**, before touching anything:
   `node --env-file=.env.local scripts/backup-fingerprint.mjs > before.json`
   Keep `before.json` somewhere that is not the thing being restored.

2. **Make a scratch project.** Supabase dashboard → New project, same region,
   any name with `scratch` in it. Not a branch and not production.

3. **Restore the backup into it.** Dashboard → the production project →
   Database → Backups → the night you want → Download. Then in the scratch
   project, Database → Backups → Restore, and upload it. On a plan with
   point-in-time recovery, use Restore to a new project and pick the moment.

4. **Point this laptop at the scratch project.** Copy `.env.local` to
   `.env.scratch` and change `SUPABASE_DB_HOST` and `SUPABASE_DB_PASSWORD` to
   the scratch project's (Settings → Database). Change nothing else.

5. **Compare:**
   `node --env-file=.env.scratch scripts/backup-fingerprint.mjs --compare before.json`

   It prints `RESTORE VERIFIED`, or it names every table that did not come
   back, came back short, or came back different — and says not to cut over.

6. **Delete the scratch project.** It holds every client's record.

Repeat each quarter, and after any change to how the database is backed up.
The one thing that makes this worth doing is doing it before it is needed:
until step 5 has printed `RESTORE VERIFIED` once, the honest statement is that
the practice has backups and does not know whether they restore.

---

## The full writing and screen standard — 18 October 2026

*Owner: extend CLAUDE.md with the full rule set, add four rules to
check-copy, apply and report.*

### What changed

**131 pieces of copy**, across 60 files.

| | fixed |
|---|---|
| Titles that were sentences | 12 |
| Helper text over twelve words | 117 |
| Stale cross-references (from the group merge) | 4 |
| Feature names | 2 |

**The twelve titles.** "What this does not cover" → *Not covered*. "Still to
do before you are fully set up" → *Still to do*. "Where the money comes from"
→ *Funding sources*. "Time it as you go" → *A running timer*. "When people
have to ask" → *The threshold*. A title is a noun; each of these was a
sentence wearing a heading's clothes.

**The 117 pieces of helper text** were cut to twelve words or fewer, keeping
the fact that changes what the person does next and dropping the rest. The
64-word paragraph under the staff activity table became *"Hours count the day
worked; payments the day paid."* The 57-word explanation of the deploy account
became *"Not people. The deploy check reads every screen and can change
nothing."* Where the second sentence only elaborated, it went.

**Feature names.** Copilot → **Assistant** in the sidebar; the tooltip and the
screen-reader label still name Microsoft 365 Copilot Chat, because somebody
should know they are leaving for a Microsoft product. And `/insights/reports`
was titled "Key performance indicators" while its own nav entry said
"Reports" — now both say Reports. "Money insight" did not exist: that screen
has been plain *Money* all along.

### The four new rules

- **A title over four words with a verb in it.** A word list rather than
  anything cleverer: a heading is three or four words and the only question is
  whether it is a sentence in disguise.
- **Helper text over twelve words.**
- **Sales words** — seamless, effortless, powerful, smart, magic, AI-powered,
  journey.
- **Exclamation marks**, anywhere, not only after a word.

Proved by putting a fault back: *"Leaving the status alone is a seamless and
powerful answer, because sometimes nothing has changed yet!"* fails three of
them at once.

### What is exempt, and why

The explainer screens keep the exemption `check-words` already gave them, and
the **compliance screens join them**: the 1099 run, records requests,
retention and the books. Their helper text is what the IRS, the state and the
retention schedule require somebody to know before they act — which is exactly
the test the standard sets. Cutting *"A run is a snapshot… later edits to a
profile do not rewrite it"* to twelve words would remove the sentence that
stops somebody filing the wrong figures.

### Two mistakes worth recording

**The first rewriting pass broke two files.** It searched raw source for a
unique phrase, and two of those phrases appeared first in a comment and in a
string literal — so it ate a `*/` and broke a string. Both files were reverted
and redone by hand. The lesson is the one the extractor already knew and the
rewriter did not: *comments and strings are not screen copy, and a tool that
edits source has to know the difference.*

**And several replacements came out at thirteen words.** Written by eye,
counted by the check, and caught on the next run — which is the right order,
but a reminder that "about twelve" is not twelve.

---

## Two-step sign-in looked like it did nothing (19 Oct 2026)

**Reported:** scan the QR, type the code, and nothing happens — no error, no
success.

**It had worked every time.** The factor was enrolled at 04:19:43 and
confirmed at 04:21:08 on the morning it was reported, and it was sitting in
`auth.mfa_factors` as `totp/verified` while the screen was being described as
broken. All four of the things worth suspecting were fine:

| Suspected | Found |
| --- | --- |
| TOTP is not enabled on the project | It is. `enroll` returns a factor and a QR. |
| The verify step is erroring, silently | It is not. `challengeAndVerify` returns no error and a fresh session. |
| The challenge expires before verify | It does not. The challenge is created and answered in the same call. |
| The factor is not being saved | It is. Status `verified`, and the Admin roster shows it. |

This was established by enrolling a throwaway `ZZ` person end to end with a
software authenticator written for the purpose — base32, HMAC-SHA1, a
thirty-second step — printing the raw result of every step rather than only
the ones that failed.

### The screen was wrong in three ways, and each one looks like silence

**There was no state for having succeeded.** On a good code the screen did
`setCode(""); setEnrolling(null); router.refresh()`. With `enrolling` cleared
and the refreshed page now reporting a factor, the next branch to match was
*"Enter the code from your app"*. So a correct code was answered with a
request for a code. Give another, and it happens again. Forever. That is the
whole of the reported bug: not a failure, an unbroken loop of successes.

**Nothing was caught.** There was no `try` anywhere in the file. An error
thrown rather than handed back in the result would skip `setBusy(false)`
entirely and show no message, leaving the button reading "Checking…" with
nothing said.

**The code form answered the challenge on the first factor listed.** An
abandoned attempt — pressing "Set it up" and walking away, which is exactly
what somebody does while the screen appears dead — leaves an unverified
factor behind. Answering a challenge on that one asks for a secret nobody
ever scanned, so every code after it is wrong, with a message saying the code
was wrong. That one would have survived the other two fixes.

### The fix

The screen now knows whether this session has already used the second factor.
`two_factor_state()` was only ever asked *whether* somebody is enrolled; the
assurance level — the thing that separates "still owes us a code" from
"already through" — was read in the layout and nowhere else. The page reads it
too and passes it down, and the states are now: nothing set up, part way
through, owes a code, through, and **done just now**.

Plus a `try` around everything that talks to the authenticator, and a factor
chosen by being verified rather than by being first.

### Confirmed in the screen, not only in the API

A throwaway `ZZ Second Factor` was signed in against the real database and
walked through the real screen in a browser. The session was handed over as a
cookie rather than by typing a password into the form, so no credential was
entered anywhere.

- **Set it up** → QR and secret shown.
- A **wrong** code → *"That code was not right. It changes every thirty
  seconds — try the one showing now."* The QR stays up.
- The **right** code → *"Two-step sign-in is on. Your phone is set up."*
- **Reload** → *"Two-step sign-in is on. This sign-in used it."* Not another
  code prompt.
- A fresh **password-only** session → *"A code is asked for when you sign
  in."* Not a demand for one, because the practice does not require it yet.

Database afterwards: `totp/verified`, and the Admin roster listing them. The
person and their login were then deleted; the only factor left on the system
is the owner's real one, and `require_two_factor` is still `false`.

### What is not yet exercised

The step-up branch — an enrolled person asked for a code *because the practice
requires one* — cannot be reached without turning enforcement on for everybody,
and the instruction was to leave it off. The call it makes is the same
`challengeAndVerify` proven above, and the branch is covered by the new check,
but it has not been walked in a browser. Worth doing together on the day
enforcement goes on.

### The check

`scripts/check-second-factor.mjs`, in `prebuild`. It asks the three questions
the bug actually turned on, which is not the same as asking whether the screen
looks reasonable:

1. Every call to the authenticator sits inside a `try`.
2. On the path taken when the code was **right**, something is *set* for the
   screen to render — not merely cleared. Bounded to the enclosing block and
   to the part after the last early return, because otherwise the message set
   for a *wrong* code counts as saying the right one worked.
3. A factor is chosen by being verified, never by being first.

And that the page still reads the assurance level and passes it down.

**It was tested against the bug, not only against the fix.** Run against the
version as reported, it names all six faults. The first draft did not: it
asked whether the file had *any* state that is set and branched on, and the
broken file had `enrolling`, so it passed. A check written near a rule passes
the bug it was written for.

### One more thing the verify script taught

`verify_two_factor.sql` asserted the roster counted exactly **one** enrolled
person. That was written when nobody had enrolled; it failed today because
somebody finally had. It now asserts about the fixture person — enrolled, and
listed **once** despite carrying two abandoned attempts — rather than about a
total. An assertion that counts everybody starts failing the day the practice
starts using the thing it guards.

---

## Billing was down for everybody who used it (19 Oct 2026)

**Reported:** Margaret (Intake & Client Reports) gets *"Application error: a
server-side exception has occurred"* on every billing action. Admin works, so
it is role-specific.

**It was not role-specific.** That turned out to be the only part of the
report that did not hold, and it is worth recording because it would have
sent the next person looking in the wrong place. Put the fault back and sign
in as an Admin, and the Admin gets the identical error on the identical
click. Nobody could enter or update a billing item. Admin "working fine" was
Admin not having tried the same thing.

### What the logs said

```
Error: A "use server" file can only export async functions, found object.
  at .next/server/app/(app)/billing/authorizations/[id]/page.js
digest: 3989365429
```

Every export of a `"use server"` file becomes a callable server endpoint, so
an exported object is a contradiction: there is nothing to call. React
refuses the whole module the first time it is required.

Two files did it:

| File | Export | Arrived |
| --- | --- | --- |
| `billing/authorizations/actions.ts` | `EMPTY_BATCH` | 7769e27, 14 Oct |
| `billing/import/actions.ts` | `emptyImport` | earlier |

Both are the starting state of a form, which is why they were written next to
the actions that return them. Between them they cover adding an
authorization, editing one, the confirm queue and submitting - every billing
action one person had. Both now live in `lib/billing.ts`, where a constant is
only a constant.

**Not the navigation merge.** `de638bc` never touched billing; it changed
`lib/roles.ts`, the sidebar and three screens. The clock was running on a
rollback to the build before it, and the rollback would have cost yesterday's
two-factor fix and the writing standard without curing anything.

### The digest in the report was a different number

Margaret reported `1603980337`; production was logging `3989365429`; the
local reproduction produced `2406090998` and `2732931674`. They are all the
same fault. A Next.js digest is a hash computed per build, so **the same
error has a different digest on every deploy** and the number is not an
identifier to search on across builds. The message is.

### Why nothing caught it

- **`tsc` is happy.** The types are correct. `EMPTY_BATCH` really is a
  `BatchState`.
- **`next build` is happy.** Rebuilding the broken tree prints *Compiled
  successfully*. The rule is React's, and it is enforced when the module is
  first required on a request - on a dynamic route, that is in production,
  under a real person.
- **Smoke was happy, and this is the one that stings.** It opened `/billing`
  that morning and passed, because **opening a screen never loads the action
  module.** That happens on the POST, and in three months smoke had never
  made one.

### What now runs

**`scripts/check-server-actions.mjs`, first in `prebuild`.** A `"use server"`
file exports async functions and nothing else - not an object, not a
non-async function, not a default, not a re-export it cannot vouch for. 247
exports across 70 files pass. Run against the outage with the fault put back,
it names both offenders.

**Smoke posts the billing actions, as Margaret's role.** A new optional
`SMOKE_REPORTS_EMAIL` / `SMOKE_REPORTS_PASSWORD` account opens every screen
the Reports role reaches and then submits every form on `/billing` the way a
browser with JavaScript turned off submits one - the hidden `$ACTION_REF`,
`$ACTION_KEY` and previous-state fields React puts in a `useActionState`
form, posted back to the same URL with **no user field filled**, so each
action refuses on its own validation and nothing is written. Verified both
ways: four actions pass on the fixed build and all four fail with `HTTP 500 -
the action module did not load` on the broken one.

Only `/billing`, deliberately. It is the screen that carried both broken
modules, and its actions are the ones that refuse an empty submission. The
authorization record is opened but its actions are not posted blind: several
act on a record and one sends a packet to USOR, and this account cannot be a
system account, because a system account can only be Job Search
(`staff_system_is_job_search`).

**Until the owner creates that account the check says so loudly**, as a
GitHub annotation on every run, naming it as the gap this outage went
through.

### Confirmed, not assumed

A throwaway `ZZ Reports Tester` - Reports role, `billing/edit` grant, exactly
Margaret's shape - was signed in against the real database and driven through
the real screens. Add authorization, the record with its checklist and every
action form, and a bulk close carried out end to end on a synthetic
`VZZ000001` authorization: closed, reason logged, attributed to the tester.
No real authorization was touched, before or after. Then the same bulk close
as a `ZZ Admin Tester`, on the broken build, which is how the role question
was settled.

### Timing

Reported, logs pulled, cause found and both files fixed inside ten minutes;
the fix was live on production at `e363bb1` before the twenty-minute rollback
deadline. The six logged occurrences all sit between 19:10 and 19:11 on the
previous deployment, and there have been none since.

### And the fallback host

`zion-crm-red.vercel.app` now answers `308` to `crm.zionvocrehab.com`, path
and query preserved, set as a Vercel domain redirect rather than in
middleware so that preview deployments and the deploy check - which runs
against the custom domain - are untouched. Worth knowing: it is no longer a
fallback. If the custom domain ever fails, that address now fails with it.

---

## The stale ones can be found (19 Oct 2026)

**Asked for:** a Stale filter on Billing → Authorizations and a bulk Close for
the chosen rows with one reason applied to all, logged per record. Keep the
90-day submit block; Admin can still move a stale date on a single record with
a reason.

**Three of the four already existed**, which is worth recording so the next
person does not rebuild them. The bulk Close went in on 14 Oct: one reason,
`bulk_close` applying it row by row through `set_authorization_status` so each
record carries its own log line, and a result that says per row what happened
rather than one verdict for the batch. The 90-day block is
`authorization_blocked_from`, which is `stale_date + org_settings
.stale_grace_days`, and the submission checklist refuses on it. `moveStaleDate`
moves a single record's date, refuses an empty reason **on the server** rather
than only in the form, and writes the reason to `stale_reason` where 0156 logs
the change.

So the work was the filter, and one decision inside it.

### Stale is a fact, not a sentence

The working list already knew which rows were past saving - `is_blocked`, the
first branch of the attention line. The screen could have found them by
matching the words *"Cannot be submitted"*, and that would have worked today
and broken quietly the next time somebody rewrote the copy. 131 sentences were
rewritten yesterday.

`0221` lifts `is_blocked` out as a column of its own on
`authorization_attention_for` and carries it through `billing_worklist` as
`blocked`. Nothing else moved: the rule, every word of the attention line and
every urgency number are byte-for-byte what they were, and the migration says
so.

Two things made it awkward and are worth remembering:

- **Adding an output column means dropping the function.** `create or replace`
  will not change a signature. The list had to go first, because it reads the
  other one.
- **`authorization_attention(uuid, date)` was left alone deliberately.** The
  `authorization_record` view is built on it, so changing its shape means
  dropping and rebuilding that view - and a single record has no use for a
  flag that exists to filter a list. It goes on selecting `attention` and
  `urgency` by name, which the new column does not disturb. The view, the
  single-record attention and `billing_needs_action` were all read back after
  the migration to prove it.

### On the screen

A third chip beside Needs action and Show all: **Stale (2)**. It shows the
rows that can no longer be submitted, which is exactly the set the bulk Close
is for, and the checkboxes and the Close form are the ones that were already
there. The chosen view survives the billing-office filter and the confirm
queue's Open links, because a filter you lose by clicking anything is not a
filter.

The empty state says which view is empty: *"Nothing is past the grace - every
authorization here can still be submitted."*

### What is asserted

`supabase/verify_stale_is_a_fact.sql`, rolled back like the rest. Four
fixtures - a day past the grace, a day inside it, one not yet ended, and one
already submitted - and then the assertion that matters: **the flag and the
sentence agree on every row in the list, in both directions.** Rewrite the
copy without the rule and it fails; change the rule without the copy and it
fails. It also pins the grace at 90 days, and says in the failure message that
this is the assertion to change if the owner ever moves it.

105 verify scripts pass.

### Left as it was

`moveStaleDate` is open to Admin, Billing, and anybody holding a `billing/edit`
grant - which is Margaret. The instruction was that Admin *can still* do it,
which reads as keeping the escape hatch rather than narrowing it, and taking
access away from Billing is not a change to make on an inference. Say the word
and it becomes Admin-only.

---

## The 2025 caseload, closed out (22 Oct 2026)

Done on the owner's instruction, in one transaction, attributed to the Admin
who asked for it. Every row carries its own log line with its own reason,
because `zion.directory_reason` is what the client change log reads.

### What the counts turned on, and why they were reported first

Two columns looked like an authorization's date and were not: `received_on`
and `created_at` are stamped September and October 2026 on **all 162 rows** -
they are the import, not the authorization. The real history is in
`start_date` (2025-02-14 to 2026-09-20) and `bill_by`. Which one "dated 2026"
meant moved the client count from **30 to 17 to 6**, so it went to the owner
rather than being chosen here.

The activity test was dropped in the end, which was the right call for a
second reason the counts showed: the practice has **14 contact-log entries in
total, across 10 clients**, so "no contact-log entry in 2026" was never going
to protect anybody.

### What was done

| | |
| --- | --- |
| Clients referred in 2025 | 61 |
| → marked **Inactive**, reason "2025 caseload close-out" | **41** |
| → already Closed, left alone | 20 |
| Authorizations closed, reason "2025 — not billed" | 4 |
| Submitted or Paid, untouched | 144 |

Active clients: 73 → **31**.

**The twenty already-Closed clients were left Closed.** Closed is the more
final of the two states and they are already off every active list; moving
them to Inactive would have made them *easier* to reopen, which is not what
closing out a caseload means. Said here because it is a reading of the
instruction, not a literal execution of it.

The four authorizations: `V1011562` Kristie Collins, `V101697` and `V1016978`
both Jaxon Ewell, `V9997978` Gary Horrocks. Two of them are the same two rows
the Stale filter had just started showing.

### Still holding an open authorization

Four of the deactivated clients have an authorization that is neither Paid nor
Closed, which is the list the owner asked for:

| Client | Stage | Open authorization |
| --- | --- | --- |
| Beindu Kamara | Job Development | V1041928 (Due) |
| Bradley Johnson | Job Coaching | V999364 (Due) |
| Isaiha Peay | Placement | V1041336 (Due) |
| Tara Mercer | Closed | coaching 1058 (Due) |

Their billing is untouched, as instructed. Reactivating any of them is one
action on the All clients view.

### The duplicate

`Jaxon G. Ewell` was an import artefact: created 2026-09-29, no client number,
one authorization, sitting Active while the real record - `Jaxon Ewell`,
client 1064, referred 2025-11-24 - sat Closed with the same authorization
dates one digit apart. Merged into 1064, which now holds **2 authorizations
and 2 documents**, plus the stage history, tasks and notifications that came
with it. `merge_clients` moves every foreign key to the kept record, fills its
blanks without overwriting anything, and is Admin-only.

### The footprint, measured

`backup-fingerprint.mjs` before and after: 133 of 142 tables byte-identical.
What moved is exactly what should have: `authorization_events` +4,
`directory_changes` +43 (41 deactivations and 2 merge entries), and changed
contents in `clients`, `authorizations`, `client_stage_history`,
`client_recents`, `tasks` and `notifications`. Nothing else.

The executed script is kept at `supabase/once_2026-10-22_close_out_2025.sql`.
It is not a migration and is not meant to run again; the system of record for
what it did is `public.directory_changes`.

---

## The clients board (22 Oct 2026)

Clients opens on the active caseload as a board: seven fixed columns in the
order the work happens, one card per person. The list it replaced is a click
away as **All clients**, which is where an inactive client is found, searched
for, and put back.

### The seven, and what the old stages became

| Was | Is | |
| --- | --- | --- |
| Referral | **Intake** | 19 clients |
| Intake | **Intake** | |
| Assessment | **Assessment** | 5 · headed "Assessment (WSA)" |
| Job Development | **Job Development** | 2 |
| — | **Job Search** | new, empty |
| — | **Life Skills** | new, empty |
| Placement | **Job Placement** | 2 |
| Job Coaching | **Job Coaching** | 3 |
| Follow-Along | **Job Coaching** | owner, 22 Oct: it is coaching |
| Closed | *their last real stage, else Intake* | |

**Closed stopped being a stage.** It was both a stage and a status, and the
status is the one that means anything: a client who is finished has a status,
not a column. A client whose stage said Closed keeps the last stage they were
really in, read out of their own history. That is also what lets Reactivate
offer somebody back the column they left.

The stored value stays `Assessment`; the header says "Assessment (WSA)",
because a heading is where a clarification belongs rather than in every
history row written since February.

### Three rules that live in the database

**A move needs a note**, and that is the trigger's rule, not the form's. The
dialog asks, and a direct `UPDATE` is refused too - which is the whole point:
an import, a sweep, the agent and a hand-typed update at two in the morning
are all held to it. `verify_the_clients_board` asserts it against a bare
update, not against `move_client`, for exactly that reason.

**Closing refuses while an authorization is Submitted and unpaid**, and names
it. That money is with USOR; closing the client would close the authorization
with them and nobody would be chasing it.

**The chip on a card is never hand-set.** It is the single alert the database
already computes for that client's live authorizations - the same sentence the
record screen and the working list show - so the three cannot tell somebody
different stories.

### One query, measured

`clients_board()` returns every card with its stage, goal, counselor, assigned
staff, days in stage, the services currently authorized and the one alert.
Seeded to **501 clients inside a rolled-back transaction: 122ms cold, 103ms
warm**, against a one-second budget. The two things that would have been
per-card - the service tags and the alert - are aggregated over the whole
caseload at once, the way `billing_worklist` learned to in 0206.

It is `security definer`, so it reads past RLS by design, and therefore
**checks who is asking**: without that line any signed-in account, including a
client with a portal login, could have asked for the practice's entire active
caseload with names, goals and counselors attached. Caught by the portal's own
`verify_portal_rls`, which counts elevated functions that never check.

### Seven accents, both themes

`--stage-intake` through `--stage-job-coaching` in `tokens.css`, light and
dark, walking the existing palette from green to sand in the order the work
happens - so the board reads as a progression rather than seven unrelated
colours. Each carries its column header and a 4px left edge on every card
beneath it. All fourteen are checked as **text** on both grounds, which is the
stricter of the two jobs and clears the 3:1 an edge needs: `check-theme` now
holds 51 pairs per palette, lowest 4.85:1.

### What the rename broke, and how it was found

**Four database functions still said the old words.** `intake_referral` and
`referral_from_conversation` *inserted* clients at 'Referral', so a referral
arriving from a scanned form, a text or the website would have failed outright
against the new constraint. `referral_received_on` looked for the day somebody
reached 'Referral', so every referral would have read as arriving the day the
record was made. `referrals_without_authorization` chased clients at
'Referral' and would have chased nobody.

None of this was found by reading. Three verify scripts with nothing to do
with the board - texting, the intake, the web chat - failed on
`clients_stage_check`, and all three got there through a function. 0224 is
those four, each the live definition with one phrase changed, **built by a
script that dumps and edits rather than by hand**: the first draft was
reconstructed from a fragment and quietly lost half of
`referral_from_conversation`, including its role check.

**And a blanket rename broke a test's meaning rather than its syntax.**
Rewriting `'Referral'` to `'Intake'` across 33 verify scripts left
`verify_pipeline` asserting that a client standing at Job Coaching had not
reached Job Coaching. It was restored from git and redone by hand against the
new ladder. Same lesson as the copy sweep in October: a search-and-replace
does not know what the text means.

**The stage history is deliberately not constrained to the seven.** It is a
record of what happened, not a list of what is allowed; constrain it and the
next rename makes every earlier row unreadable. A verify fixture that writes
a synthetic 'ZZ Stage' to prove the activity view surfaces stage changes is
right to, and it caught the overreach.

### Checked

`verify_the_clients_board` - fifteen assertions, rolled back. A move refused
without a note and refused on a note of spaces; the move recorded with from,
to, who, when and the note; the same move in the contact log; closing refused
while an authorization is submitted and unpaid, with the number named; closing
taking the open authorizations with it; an inactive client never on the board;
reactivating restoring the stage asked for; every card an active unmerged
client in one of the seven columns; and anon able to do none of it.

**107 of 113 verify scripts pass.** The six that do not are not this work:
five came in with the client portal merge (`verify_portal_rls`,
`verify_portal_role`, `verify_records_request`, `verify_system_account`,
`verify_retention`) and one is an old fixture writing a funding source its own
constraint forbids (`verify_two_assignments`). They are listed below because
one of them is worth attention.

### What the portal's own check is saying

`verify_portal_rls` reports **39 security-definer functions that any
signed-in account can execute with no check of who is calling** - including
`set_authorization_status`, `bulk_close`, `edit_authorization` and
`submit_authorization_on_send` - and two tables a portal client can read
(`billing_service_rules`, `practice_forms`). Two more were mine and are fixed.
The rest predate this work and are a real finding: a client with a portal
login is a signed-in account. Not touched here, because thirty-nine functions
across billing is its own piece of work and not something to do quietly inside
a board.

### Done in the screen, not only in SQL

A `ZZ Board Fixture` client was created, opened from a card, moved Intake →
Assessment through the panel with a note, and then checked in the database:
stage changed, history holding `Intake -> Assessment` with the note, who and
when, and the contact log carrying the same line. Then deleted.

### Still open

**The optional attachment on a move.** The column
(`client_stage_history.document_id`) and the RPC parameter are in place and
the dialog has room for it, but uploading a file *during* a move is not wired:
uploads go browser-to-storage and then record, which is a two-step flow worth
doing properly rather than squeezing into this dialog. A file put on the
client's Files tab is already on the record; linking one from the move dialog
is a small follow-up.

**`SMOKE_MOVE_EMAIL` / `SMOKE_MOVE_PASSWORD`** - a Job Search account that can
write, plus one permanent inactive client named `ZZ Smoke Board`. With them,
every deploy moves that card between Intake and Assessment, asserts the
contact log, and asserts a move with no note is refused. Without them the run
says so as an annotation. It cannot use the usual `SMOKE_EMAIL`: that is a
system account and the database refuses its writes by design, which is what
makes the rest of the deploy check safe to run unattended.

### And a types bug worth keeping

`gen-types` rendered a `text[]` return column as `string` and a `uuid[]`
function result as `string`. The board's `services` and the portal's
`conversation_ids` were both mistyped, and every use of them as an array was a
type error waiting for somebody to write one. Both levels fixed.

---

## The elevated functions, and a suite that is finally green (22 Oct 2026)

### Two clients back on the board

Beindu Kamara to Job Development and Isaiha Peay to Job Placement, both with
"Still in service — reactivated 22 Oct" on the record and in their contact
log, attributed to the Admin who asked for it.

### The 39, counted properly

`verify_portal_rls` named 39 security-definer functions "a signed-in user can
call with no check of who is calling". Checked one at a time against the
database, that number was wrong in both directions.

**Ten were guarded and the check could not see it.** It looked for the *names*
of the guard helpers in the function body, so a guard one call deeper was
invisible. `bulk_close` checks `billing_hands()`, which checks
`current_staff_role()`; the check saw neither. Called as a real Job Search
member of staff, `bulk_close`, `bulk_mark_paid`, `set_authorization_status`,
`edit_authorization` and `records_request_bundle` all refuse, in their own
words. They were never open.

That matters more than being tidy. Thirty-nine names with ten wrong is how a
check teaches people to skim past it.

**And one was wide open.** `billing_followups_on` went through: any member of
staff could raise chase tasks across the whole practice and shift every
follow-up date fourteen days. It is the nightly sweep, called from
`/api/cron/notify` with the service role, and nobody signed in has any
business running it by hand.

| | Before | After |
| --- | --- | --- |
| `bulk_close` as Job Search | refused | refused |
| `bulk_mark_paid` | refused | refused |
| `set_authorization_status` | refused | refused |
| `edit_authorization` | refused | refused |
| **`billing_followups_on`** | **went through** | **refused** |
| `placement_clock_started` | refused by luck | refused by grant |

### A portal client is `authenticated`

This is the part that changed the scope. There is a `portal_client` database
role, and it is **not** what the portal signs in as. A client with a portal
login is a Supabase auth user with role `authenticated` and a session claim,
told apart from staff by `is_active_staff()` being false and nothing else.

So everything `authenticated` may execute, a client of the practice may
execute - and the 24 *readers* the check also named were not a footnote. What
is due on each client, which referrals have no authorization, a staff member's
email, the rate for a service, a billing-office reconciliation: all readable
by any client who knew the function's name. Two tables as well -
`billing_service_rules` answered `using (true)`, which was written when
`authenticated` meant staff and stopped being true when the portal arrived.

All of it is closed. 0225 guards the writers, 0226 and 0230 the readers, 0227
the two tables.

### Three mistakes made while closing it

**`is_active_staff()` was the wrong predicate.** It is false for the server
itself - the nightly sweep, the cron routes, every server action using the
admin client. Fifteen verification scripts went red within a minute of 0226,
which is where that would otherwise have been found: in production, a
fortnight later, with a cron job quietly returning nothing.
`reader_may_answer()` asks the question that actually matters - no claims at
all is the server, the service role is the server acting as itself, a
signed-in user has to be staff.

**Marking a function STABLE broke a policy.** 0225 marked
`authorization_is_coaching` stable on the grounds that it only reads. It does
only read - and it is called from the WITH CHECK on `service_entries`, after a
BEFORE trigger has created that month's authorization *in the same statement*.
A STABLE function uses the statement's snapshot and cannot see a row the
statement just made. It answered false, the policy refused, and a Job Coach
could not log coaching hours. The volatility was load-bearing.

**And a policy helper cannot carry a guard of its own.** Wrapping that same
function in a caller check gave it a second rule that could disagree with the
policy, and when it disagreed it returned null, and a null in a policy is a
refusal. The policy *is* the caller check. The verification now exempts any
function named inside a policy expression, which is a rule rather than an
exception for this one.

### The check, corrected

`verify_portal_rls` now resolves guards **through the call graph** - a
function is guarded if it asks who is calling or calls something that does -
names writers by whether they actually contain a write rather than by
volatility, and exempts policy helpers. It fails on any unguarded elevated
function, reader or writer, which is stricter than it was asked to be and
currently green.

Refusals are logged by `refuse_elevated()` as a server WARNING carrying who,
what and when. Not a table, and not for want of one: the exception rolls the
calling transaction back and an INSERT made just before it would go back with
everything else.

### The suite is green: 113 of 113

For the first time. The six that were failing:

| | What it was |
| --- | --- |
| `verify_portal_rls` | the 39, above |
| `verify_portal_role` | an eight-name allowlist, written when the portal did eight things and now does twenty-two. Replaced with the rule it was standing in for: the client role may execute nothing but the portal's own, and everything it may execute scopes itself to the session's account |
| `verify_records_request` | `portal_requests` and `portal_resumes` hold the client's own words and were in no section of the bundle, so a client asking for their file would have been handed one with pages missing |
| `verify_system_account` | three portal tables did not refuse the deploy account's writes |
| `verify_retention` | **mine.** See below |
| `verify_two_assignments` | a fixture writing a funding source its own constraint forbids |

### The one I broke, and what could not be recovered

0223 took 'Closed' out of the stages. `client_retention` worked out when a
file closed by looking for the most recent stage-history row saying 'Closed' -
so after the remap `closed_on` was null for everybody, `due` was false for
everybody, and **nothing could ever come up for disposal again**. Nothing
errors; a legally-required list is simply empty for ever.

0229 puts the date where it now belongs: `clients.closed_at`, stamped by a
trigger when the status becomes Closed and cleared if they are reopened.

**What is gone.** The remap overwrote the stage-history rows that said
'Closed'. Of the 25 closed clients, 22 never had such a row - their file holds
one entry, the day they arrived - so nothing was lost and their closure date
was already unknown. For the other three the row existed and now reads
'Intake'; those dates are gone and are not guessed at here. A file whose
closure date is unknown is never due for disposal, which is the safe
direction: a record kept too long is a filing problem, a record destroyed too
early is not recoverable. **Setting those three dates from the paper file is
the owner's to do.**

The trigger also fires only on a transition, not on insert: a client imported
with status Closed was being recorded as closing the day they were imported,
and an invented closure date starts a real retention clock.

### A file can come with a move

The move dialog takes an optional file and a document type. The bytes go
straight from the browser to storage, the way Add file does it and for the
same reason - a fifty-megabyte scan has no business passing through a server
action - and only the row is recorded through the server, once the file is up.
The move then carries that row's id, so the stage history says which document
came with it. If the upload fails the move does not happen: a move that
quietly lost its paperwork is worse than one that did not happen.

Done end to end in the screen: a file attached to a move of a ZZ fixture, the
attachment recorded with its own SHA-256 and a note saying which move it came
with, and `client_stage_history.document_id` pointing at it. Then deleted,
file and all.

### The mockup

**`zion-board-mockup.html` is not in the project folder, the parent folder,
the Desktop or Downloads.** It has not arrived on this side either time. The
board was built from the written description.

There is a `client master board for 2026-09-22 023851.png` beside the briefs,
and it is not that file: it is the practice's Notion master list from 22
September - a **table**, one row per client with columns for assigned staff,
status, stage, email, availability, date of birth, ethnicity, address and
preferred location. A list, not a board, and from before the board was asked
for. Two things in it are worth knowing anyway: it uses a stage called
*Onboarding* that is not one of the seven, and statuses *New* and
*Unreachable* that the CRM does not have.

---

## Sixteen records that were not clients, and a board that fits (22 Oct 2026)

### The two closure dates, named

0223 overwrote the stage-history rows that said 'Closed'. Chasing which were
actually lost turned up a smaller and more recoverable answer than the first
count suggested.

**Only two clients lost a date, not three.** The third - Jaxon Ewell, client
1064 - has a second history row dated 2026-09-29, but it was *written* at
23:10 that evening, which is when the duplicate record was merged into him.
It is the merged record's arrival row, not a closure. 1064's own history is
one row: the day he arrived. His closure date was always unknown.

The two that did lose one:

| Client | Likely closure date | Why |
| --- | --- | --- |
| **Penny Brown** (no client number) | **10 Sept 2026** | second history row, written 2026-09-10 03:05 |
| **Trinity Kair** (client 1060) | **10 Sept 2026** | second history row, written 2026-09-10 03:04 |

The remap changed only the stage word, so **the dates on those rows survived**.
Both were written minutes apart during the September import, which is what a
bulk "mark these closed" looks like. They are offered as candidates, not set:
whether 10 September is when the file closed or merely when somebody recorded
it is a question for the paper file.

### Sixteen deletions

Matched loosely, five of them spelled differently from the list: *Stephen
Bittaker* → **Stephen Bitteker**, *Sallay Mansary* → **Sallay Mansaray**,
*Jeanette Hicks* → **Jeantte Hicks**, *Blayce Mlaya* → **Blayce Malaya**,
*Amalynn* → **Amalynn Husband (Braden's mom)**.

Two names drew a second candidate, and both second candidates are different
people who were left alone: **Trinity Kair** (client 1060, closed - and one of
the two above) is not Trinity Trujillo, and **Jessica Shull** is not Jessica
Dominguez. *Hayden Bitteker* is likewise not Stephen Bitteker and is still
there.

None of the sixteen had an authorization, a ledger posting or a legal hold, so
the rule had no objection to any of them. All went through `delete_client`,
which wrote a `client_deletions` row for each naming what went with them -
notes, stage history, notifications, and for two of them a large mail log
(Stephen Bitteker 60 messages, Melanie Fabre 12).

**One is also a counselor.** `Melanie Fabre` the client was a duplicate of
`Melanie Fabre Morales`, who is a USOR counselor with an @utah.gov address -
which is presumably exactly why she was on the list. The counselor record is
untouched. (`Mary Vasquez` matched *Mary* Kautai on the first name only and is
unrelated.)

Clients: 97 → **81**, of which 17 active.

### The one that would not delete, and why that was a bug

`Munahi Ngarambe` refused:

> insert or update on table "client_document_events" violates foreign key
> constraint "client_document_events_client_id_fkey"

Not the rule - the rule had already said yes. She has two documents on file.
Both `attachments` and `client_document_events` cascade from `clients`, so
deleting her removed the attachments, and removing an attachment fires
`client_document_log`, which inserts an event naming the client. By the time
the foreign key is checked at the end of the statement the client is gone and
the insert has nothing to point at.

The same shape as the staff change log that made a staff row undeletable: an
audit trigger firing while the thing it audits is being removed. 0231 has the
log stand aside, and only for the client actually being deleted - a setting
`delete_client` sets and clears around the one statement. She deleted on the
retry.

**The other fifteen went through only because they had no documents.** Any
client with a file on record would have hit this.

### Delete, from both places

It was already on the client record for Admin, at the foot of the Profile tab
under **Delete this client**. It is now on **All clients** as well, beside
*Take off the board* / *Put back*, for Admin only, with the same two steps the
record asks for: a reason, and the client's name typed out. The typed name is
not security - it is the step that makes somebody read which row they are on,
and a list is exactly where that mistake is easiest to make.

### The board fits

| Width | Columns | Each | Sideways scroll |
| --- | --- | --- | --- |
| 1440 | 7 | 154px | none |
| 1280 | 7 | 131px | none |
| 390 | 1, picked | full width | none |

`repeat(7, minmax(0, 1fr))` rather than `1fr`, because a grid track's default
minimum is its content: one long client name would otherwise push the row
wider than the frame, which is the scrollbar this removes.

Counts moved into the headings - a chip of its own cost a line in every
column, seven times over. Descriptions cut to one line each. Card text wraps
on word boundaries (`break-word`, not `anywhere`, which was splitting "Job
Development" into "Job Developme / nt"), and a goal is clamped to three lines,
because some run to forty words - *"Industries: Retail/Commercial,
Healthcare/Pharmacy, Library. Skills: …"* - and in a seventh of the frame that
is the entire card. The full goal is in the panel when the card is opened.

Below 1280 the columns scroll sideways again rather than become seven slivers;
below 640 one stage shows at a time, chosen from a picker that carries each
stage's count.

**A note on 131px.** Seven columns in 965px of content area is what the
instruction asks for and what it costs - the sidebar and page gutters take the
rest of the 1280. It reads, and nothing is hidden off the edge, but it is
tight. Narrowing the sidebar to icons (the control is already in the header)
gives each column about 40px more.

113 of 113 verify scripts still pass.

---

## Two ways off the board (22 Oct 2026)

The card panel has a **Remove from board** heading with two choices, and the
card's *Move to…* menu carries the same two as its last items, after the seven
stages. They are deliberately two controls rather than one with a mode: a
single control that changed what the button meant is how somebody closes a
client they only meant to tidy away.

**Make inactive** is a filing decision. The card leaves the board and nothing
else happens — the authorizations stand, the billing stands, the record
stands, and putting them back is a note and a stage on All clients. Anybody
who can move a card can do it, because deciding a card does not belong on
today's board is the same kind of decision as deciding which column it sits
in.

**Close** ends the work. It takes the open authorizations with it and refuses
while money is out with USOR. Admin, Intake & Client Reports and Billing, as
before.

### The rule moved into the database

Making somebody inactive used to be done by the screen: a direct update and a
line in the contact log, written in the server action. That put the rule in
one caller — so an import, the agent, or anything else that wrote the column
could take a client off the board with no note and no log at all, and the
role check lived where only that one screen could see it.

`deactivate_client` (0232) is a function now, for the same reason
`move_client` is. It refuses an empty note, refuses somebody who is not
staff, refuses a client who is already inactive or closed, and writes the
note to two places: the client's own contact log, and the directory change
log beside the status change itself. The server action is four lines and a
message.

The role check went with it — or rather, went away. There is no role check on
making somebody inactive any more, here or on All clients, where the control
had been Admin, Intake & Client Reports and Billing only. The same act now
has the same rule everywhere, which is the owner's instruction read
consistently rather than applied to one screen.

### Asserted

In `verify_the_clients_board`, rolled back:

- a client cannot be taken off the board without a note
- making somebody inactive takes them off the board
- **and leaves their authorizations exactly where they were** — which is the
  whole difference from Close, so it is asserted rather than assumed
- the contact log carries the note, the person and the day
- their card is gone from the board
- **a Job Search member of staff cannot close a client**
- **— and can still take one off the board**

The change log is not asserted on a fixture, and the reason is worth writing
down rather than leaving as a gap: `directory_change_log` deliberately skips
any record whose name is a fixture name, so that a verification run does not
fill the practice's audit trail with ZZ people. Every client in that script
is a ZZ person. What is asserted instead is that the silence is the rule and
not an accident — if `is_fixture_name` ever stops recognising these names,
the log would start filling with them and the script would say so.

The real path was checked separately against a non-fixture name inside a
rolled-back transaction:

```
change log:  status {"from": "Active", "to": "Inactive"}
             "Paused at their own request." by Francis Weah
contact log: Off the board | Made inactive from Active
             "Paused at their own request." by Francis Weah
```

### Done in the screen, by both roles

As a **Job Search** account that can write: the card menu offered the seven
stages and *Make inactive*, with no *Close*; the panel offered *Make inactive*
alone. Making a client inactive went through and landed in the contact log
under that person's name.

As an **Intake & Client Reports** account: both appeared, in the panel and as
the last two items of the menu. Closing a client who had an authorization
still with USOR was refused in the dialog, naming it — *"ZZ Off Two has
VZZOFF01 still with USOR and unpaid. Chase or record the payment before
closing them."* With that one paid, closing went through, took the one Due
authorization with it, and said so.

113 of 113 verify scripts still pass.

---

## Client email (23 Oct 2026)

The practice already read its mail in the CRM and already sent from it. What
it could not do was keep any of it on a client, which meant the record of what
had been said to a counselor lived in whoever's Outlook had said it.

### Filing is a decision somebody makes

The sentence the whole feature is built on is the owner's: *"Nothing in a
mailbox is read, scored or stored unless filed; the CRM stores only filed
messages."* Everything below follows from taking it literally.

`mail_log` has carried a line about every message that matched a known
address since the sync was built — subject, date, direction, counterpart,
link. 0233 gave it the record of the *decision*: `filed_by`, `filed_at`,
`filed_how` (one of **sent**, **auto**, **by hand**), `restricted`, and
`unfiled_at`/`unfiled_by`/`unfiled_reason`.

Three ways a message comes to be on a client, and the screen says which:

- **sent** — the practice wrote it from the record.
- **by hand** — somebody dragged it onto a client, or opened it and pressed a
  name.
- **auto** — a reply arrived on a thread somebody had already filed. This is
  the only way a message reaches a client without a person choosing it, and it
  is not really an exception: the choice was made when the thread was filed
  and the sweep is honouring it. `client_for_thread` answers which client a
  conversation belongs to, **ignoring unfiled rows** — taking a thread off a
  client is a decision too, and a reply should not quietly undo it.

**Unfiling keeps the row.** It has to: the owner asked for unfiling to be
logged, and a log you can erase by using it is not a log. The row stays with
the reason on it and drops out of `client_mail`, which is what "removes the
message from the client's view, never from the mailbox" means from the
database's side.

### Where two instructions pulled against each other

> "Replies to a filed thread file onto the same client, marked auto; **anyone
> can unfile one**."
> "Unfile: the person who filed, or Admin."

Under the second rule alone, an auto-filed reply could only be unfiled by an
Admin — because nobody filed it, so nobody is the person who filed it. The two
are not actually in conflict. The second exists because the person who put
something on a record knows whether it belonged; the first says what to do
when there is no such person. 0242 reads them together: **a message nobody
filed can be taken off by anybody on the staff; a message somebody filed stays
theirs or Admin's.**

### Composing from the record

`/mail/compose?client=…` is a different screen from the blank one, not the
same screen with the boxes filled in. The recipients are **picked, not
typed** — counselor, billing office, the client's own address if it is on
file, the assigned staff member, each from the record — because an address
typed into a box is the one way a client's business reaches the wrong person
with the same surname. Anybody else goes in Cc by hand.

Three rules the owner set, checked in this order:

1. **A client is written to at the address on their own record.** Any
   recipient that is *some* client's address has to be *this* client's.
2. **A form goes as an attachment, never a link.** A body containing a link to
   the CRM, the portal or a storage URL is refused in one sentence naming the
   fix.
3. **Documents are attached from the client's file**, by reference. The bytes
   come out of storage through the sender's own client, so the storage policy
   decides whether they may have the file — a restricted document somebody
   cannot open is one they cannot attach, and that is one rule in one place
   rather than two that have to agree.

Anything sent is filed on the client as **sent**, and a line goes in the
contact log with who wrote, to whom, about what and when.

### Finding out what was sent

`sendMail` answers 202 and says nothing, which was fine while nobody needed to
know what had been sent and is useless now that it has to be filed. So the
message is written as a draft first — Graph answers that with an id and a
conversation — and the draft is then sent. Sending moves it to Sent Items and
may change its id, so the copy there is found by thread (a `$filter` on
`conversationId` with a sort is the kind of query Exchange answers with "too
complex", so the last ten are read and matched in memory). If it is not
indexed yet the draft's facts are filed with its thread, and the sweep files
the Sent Items copy onto the same client when it next runs — two rows on one
thread, both correctly on the client, which the record shows as one
conversation.

### The three letters

Admin → Templates holds **Authorization request**, **Progress report cover
note** and **Renewal chase**, with the merge fields the owner named:
`{client}` `{client_no}` `{counselor}` `{authorization}` `{service}`
`{issued}` `{ends}` `{me}` `{signature}`. The merge happens in the database so
the fields come from one place and a name is spelt the way the record spells
it. A field with nothing behind it leaves a visible gap — `——` — because a
sentence that reads perfectly with the date missing is a sentence that gets
sent with the date missing. Editing refuses an unknown field by name; a
counselor should never receive `{client_number}` in curly brackets.

Note and text templates stay where they are edited today. Moving them would be
a change nobody asked for.

### Who hears about a reply

A reply that filed itself tells the client's assigned staff member and one
standing recipient the practice names — Margaret, Admin-configurable on
Admin → Templates — in the bell and on My day. **Nobody else**, and that is
why the notification is written by name rather than through `notify_person`,
which stamps the recipient's *role* into `roles`. The read policy on
`notifications` lets anybody with that role see the row, so the convenient
path would have shown one client's correspondence to every Job Coach in the
practice. An empty `roles` and a `staff_id` is the same table saying "this
person, nobody else".

Only an **incoming** reply, and only an auto-filed one. Outgoing mail is
somebody in the practice writing and they know they wrote it; a message filed
by hand was read by the person filing it.

### Mail within a minute, with the sweep still behind it

Each connected mailbox is subscribed to Microsoft's change notifications
(0241). Microsoft posts to `/api/graph/notify`, which echoes the validation
token to be created at all, checks that every notification carries the
`clientState` its row holds, believes nothing else in the payload, and syncs
that mailbox. The sync runs *after* the response, because Microsoft treats a
slow endpoint as a failing one and drops the subscription after enough of
them.

`includeResourceData` is false on purpose. A notification carrying the message
would be a body arriving uninvited, which is the one thing the whole feature
is arranged to prevent.

**The fifteen-minute sweep stays, and it is what creates and renews the
subscriptions.** A delegated subscription is tied to a token that can be
revoked and expires inside three days whatever happens; anything depending on
a webhook arriving needs something behind it that does not. The subscription
makes mail arrive sooner. It is not what makes it arrive. The Mail screen says
when the mailbox was last swept, in words rather than a timestamp — "synced 4
minutes ago" answers the question somebody is actually asking.

### The rule that had to change, and the check that had to get sharper

`scripts/check-mail.mjs` held one blunt rule: nothing that touches mail
touches the database. Filing made that untrue — a sent message has to land on
the client and in the contact log — and the honest response was not to weaken
the rule but to write the thing it had been protecting.

`lib/mail-filing.ts` is now the one module that writes to the database about
an email, and it is deliberately the one module that cannot read one: it
imports neither Graph module, and none of its types has anywhere to put a
body. The check holds three things that together mean a body can never reach a
column — the two Graph modules cannot see the database; a module that can see
a body writes nothing itself; and the filing module cannot see a body. The far
end is `supabase/verify_mail.sql`: no column exists to put one in.

Each part was proved by putting the fault back and watching it fail. Four out
of five did. The fifth — "this check is checking nothing if the filing module
has stopped writing" — **passed the bug**, because `DB_WRITE` matched
`createHash(...).update(bytes)` and read a hash as a database write. It now
matches supabase's own shape, a table and then the verb.

### Verified

`supabase/verify_client_email.sql`, rolled back, 21 assertions:

- a message sent from the record is on the client and says it was sent, and
  the contact log carries who wrote to whom about what
- a reply on a filed thread files itself, marked auto, **with nobody's name on
  it**
- unfiling is refused without a reason; it comes off the client; **the row
  stays with who took it off and why**; a reply nobody filed can be taken off
  by anybody on the staff; a fully unfiled thread stops answering, so a reply
  does not undo the decision
- nothing unfiled can be stored at all — asked as "there is nowhere to put one
  and no way in", not as "there is none", which proves nothing: no column a
  body could occupy, nobody signed in can insert a row, and filing refuses a
  client who is not there
- a restricted thread is readable by the client's own staff member and is **a
  row with no words in it** to everybody else — redacted, not hidden
- the reply tells the assigned staff member and the standing recipient, none
  of the notifications carries a role, and a colleague in the same role who was
  told nothing can read none of them
- it is on My day as well as in the bell
- every template fills in, in one question, and leaves no field in brackets

Two of those were bent to be sure: a notification stamped with a role, and a
`client_mail` that hides a restricted thread instead of redacting it, both
inside a rolled-back transaction. The first attempt at the role test **read a
deliberately leaking notification as unreadable**. Every role in the practice
currently has exactly one person in it, so asking as whoever happens to be
third proves nothing — their role would not match either way. The fixture now
borrows the assigned staff member's role for the length of the transaction, so
the condition is made rather than hoped for.

### What the suite caught on the way

Four failures that were nothing to do with mail, and two that were:

**A grant nobody wrote.** `org_settings` is granted column by column, because
it holds the practice's EIN. Two new settings arrived without grants, and the
screen that edits them would have read null and written nothing, silently.
This is the third time — 0218 is the same fault on `require_two_factor` and
says so in its own first paragraph.

**Four writers where there should have been one.** Adding a defaulted
parameter to `log_mail_message_internal` and its three wrappers created a
*second function beside each*, because a new parameter is a new signature. Two
things went wrong at once: a ten-argument call became ambiguous, and — worse —
a new function starts with EXECUTE to PUBLIC, so three writers that had been
deliberately withheld from `authenticated` arrived wide open. 0235 drops the
originals and sets the grants explicitly. The lesson the elevated-function
sweep already wrote down, learned again: **a new signature is a new function,
with a new function's default grant.**

**An elevated reader that asked nothing.** `verify_portal_rls` named
`client_for_thread` — security definer, granted to anybody signed in, checking
nothing. It is a read and what it reads is small, but "small" is not a rule:
handed a conversation id it answers which client that correspondence belongs
to. It cannot simply be revoked, because a person's own sync calls it with
their session, so it asks `reader_may_answer` instead.

**A median that had outlived its fixture.** `verify_money_baseline` asserted
the median days-to-submit reads 10, which was true while the fixture's
authorization was the only one the practice had ever submitted. On 21 and 22
October two real ones were submitted, 22 and 23 days after they arrived, and
the median became 16. The measure was right and the assertion was quoting a
table it does not own — the same mistake the retention figures in that script
had already been rewritten for once. It now asserts the median lies inside the
spread the practice actually took, and that adding a faster authorization
pulls it towards itself and never away.

**A checklist line that answered neither yes nor no.**
`verify_submission_gate` asks that no line of the submission checklist, on any
authorization the practice actually has, comes back null — because a null
reads as a tick. One did: *"Service dates are the work's own"*, on V1037898.
The test was `not (service_start = start_date and service_end = end_date)`,
and that authorization has a service end in October and **no end date at
all**. So `service_end = end_date` is null rather than false, `true and null`
is null, and `not null` is null — three-valued logic in a line that looks like
it cannot have any. `is distinct from` is the comparison that was meant, and
it gives the honest answer as well as the useful one: the work's end date is
recorded and the authorization has none, so the dates are the work's own.

**And two new tables that did not refuse the system account.**
`verify_system_account` named `microsoft_subscriptions`. `mail_templates` went
with it, though nothing complained: it had the three policies hand-written,
which is the same three policies spelled a second time, and
`apply_system_read_only` is the one spelling.

114 of 114 verify scripts pass.

### On screen

- **Mail** — a message drags onto a name in the side list, or opens and files
  by pressing one; "the whole thread" brings the rest of the conversation with
  it. A filed message says which client it is on and how it got there, and
  offers to take it off. An attachment on a filed message can be kept on the
  client's record, under the one-document rule. The header says when the
  mailbox was last swept.
- **The client record** — a **Mail** section above the Activity timeline:
  filed threads newest first, the newest message standing for each and a count
  when there are more, because six rows saying "Re: Re: Re:" are the same
  thing six times. Nothing there is the message: opening one reads it live
  from Outlook, because there is no copy. A thread in a colleague's mailbox
  says so and offers Outlook's own link. **Restrict** is here, with the same
  rule as a restricted document.
- **The board's card panel** — **Write**, because writing to the counselor is
  the commonest next thing after moving a card.
- **Admin → Templates** — the three letters, the signature, and who hears
  about a reply.

### Smoke

A Reports account opens Compose on a ZZ client and the template list loads.
Opened rather than posted: posting would send a real email to a real counselor
on every deploy. What a GET proves is the part that breaks — the screen
rendering at all, under a role that is not Admin, with its recipient list and
its three templates on it, each of which comes from a different elevated
function.

### Still open

**The sweep stores mail nobody filed.** Of the 176 rows in `mail_log` today,
101 are on a *counselor* and no client, put there by the address sweep with
nobody deciding anything — which is not what *"the CRM stores only filed
messages"* says. They are kept for now, because deleting a year of
correspondence records is not something to do without being asked, and because
the sweep's counselor matching predates this instruction by months. It is the
owner's call: either those rows go and the sweep stops writing them, or
counselor mail is a deliberate second case and the sentence means client mail.
Either way, nothing new reaches a client without somebody filing it.

### Matching an address is not filing

This one was caught by deploying it, which is the wrong place to catch
something, and it is worth writing down exactly how.

0234 gave the single mail writer a `filed_how` parameter and defaulted it to
**auto**. That conflated two things which are not the same:

- **matched** — the sweep found a known address in a message and wrote a line
  about it. Nobody decided anything. This is what the sweep has done since it
  was built.
- **auto** — a reply arrived on a thread a person had filed. Somebody did
  decide; they decided when they filed the thread.

Because the default was "auto", every address match claimed to be the second.
The screen said *"filed by the sync, on a thread somebody filed"* about mail
nobody had ever touched — and the trigger that tells two people about a reply
fired on all of it. One sweep run after the deploy put **38 notifications and
38 My day items** in front of Margaret and Rei about mail that was not a reply
to anything. That is precisely the noise the owner's "nobody else" was written
to prevent, arriving through the front door.

0247 fixes it at the root rather than at the trigger:

- the word `matched` exists and is the writer's default, so only an explicit
  "auto" means a filed thread;
- every row already in `mail_log` becomes `matched`, because every one of them
  is an address match — nothing had ever been filed by a person, so there was
  no filed thread for any of them to be a reply to;
- and `client_for_thread` answers only for a thread a **person** filed. Without
  this the back door stays open: an address match puts a client on a thread,
  the next reply files as "auto", and somebody gets told, with nobody having
  chosen anything.

The 38 items were removed in the same transaction. None of them could have
been real — there was not one row in `mail_log` filed by hand or by sending,
so there was no filed thread for a reply to have arrived on.

Three assertions now stand where none did: an address match records itself as
an address match, raises no notification, and does not become a filing by
being replied to. Each was proved by putting the default back to "auto" inside
a rolled-back transaction and watching all three fail.

The deeper lesson is about where the default lived. A parameter that defaults
to the *interesting* case will be the interesting case everywhere it is left
out, and "left out" is the normal path. The default should have been the dull
one from the start.

114 of 114 verify scripts pass, with 24 assertions in
`supabase/verify_client_email.sql`.

### Matched, settled (23 Oct 2026)

The owner's decision on the 286 rows: **keep them**, and address matching
continues **for service@ only**.

That turned out to be a fact about one mailbox rather than a category.
`shared_mailboxes` is empty - there are no shared mailboxes connected at all -
and service@ is reached through Francis's own connection, because
`microsoft_connections` records his mailbox as `Service@zionvocrehab.com`. It
is the address on the letterhead: counselors write to it, referrals arrive at
it, and `INTAKE_MAILBOX` has named it since the intake was built.

So the gate is that constant and not a new flag. One person's sweep loads the
address book and consults it only when their mailbox *is* service@; for
everybody else the only reason to keep a message is that it belongs to a
thread somebody filed. Margaret's 132 rows, Rei's 6 and Melanie's 2 stop
growing; Francis's 151 carry on.

`syncSharedMailbox` keeps address matching, because a shared mailbox is the
practice's own correspondence by definition. One ordering bug fixed while
there: it matched by address *before* asking whether a person had filed the
thread, so a message whose address happened to match would record itself as
`matched` on a thread somebody had already filed - the less true of the two
answers.

**On the record, four words.** `Sent`, `Filed`, `Reply`, `Matched`, as a chip
on the thread's own row. Three of them mean somebody or something in the
practice put it there deliberately; **Matched** means the sweep recognised an
address and nobody read it or chose it. That is the distinction worth seeing
at a glance, so it is a word on the row rather than a sentence underneath it,
and it is the one chip without the accent.

**And anybody can take a matched message off**, with a reason (0248). The rule
is now one sentence instead of a list: *what somebody chose to put on a client
can be taken off by that person or an Admin; what nobody chose can be taken
off by anybody on the staff.* "Chose" is `filed_how in ('by hand', 'sent')`,
which is exactly the two values that record a person in `filed_by`.

**Checked, not remembered.** `check-mail` now asserts where the address book
is *read*: every place one person's sweep decides a message by address has to
sit inside a block guarded by the service@ gate. A check that merely looked
for `INTAKE_MAILBOX` in the file would pass a file that mentions it and then
matches everybody's mail anyway - and the first draft of this check was wrong
in a quieter way, asserting the reads were inside the block that *fills* the
maps rather than any block that guards them. Three faults put back and caught:
the gate removed, a personal mailbox deciding by address, and nothing deciding
by address at all.

25 assertions in `verify_client_email.sql`; 114 of 114 verify scripts pass.

---

## A day, written the way it was typed (23 Oct 2026)

Rei's feedback, which is the kind worth having: she writes a day's tasks with
sub-points indented under them, and the form threw all of it away. Two causes,
both ordinary and both wrong here.

**Description and Notes were single-line inputs.** A line break could not be
typed into them at all, and Enter submitted the form. They are boxes now, and
so are Bottlenecks and Actions taken, and all four grow with what is in them -
measured from the DOM on input and once on mount, so a note loaded from the
record opens at its full height instead of a two-line slot with a scrollbar.

**And every field was trimmed.** `trim()` is the right thing to do to almost
any form field and the wrong thing to do to these: it ate the indentation of
the first line and every blank line at the end. `keepAsTyped` replaces it and
does exactly two things, neither of which changes what anybody typed - CRLF
becomes LF, because a browser posts a textarea's breaks as CRLF whatever the
keyboard did and storing it raw would mean the text coming back differs from
the text going in; and a field of nothing but whitespace becomes empty, so an
untouched Notes box does not put four spaces on a client's record. A field
with any content keeps its leading and trailing whitespace exactly.

### Enter, and Tab

**Enter adds a line**, because that is what a textarea does. The day is saved
with the button, which is the change: the add-task row used to submit on
Enter, and now it does not.

**Tab is left alone**, deliberately and as the owner asked. A box that
captured Tab to insert an indent would strand a keyboard user in the middle of
a form, and the check fails any `onKeyDown` that touches it. Indentation is
typed with spaces, and the spaces are kept - which is the whole of the fix
rather than a workaround for it.

### Shown the same way in all three places

One class, `.kept`, with `white-space: pre-wrap` - `pre-wrap` and not `pre`,
so a long line still wraps to its column instead of scrolling it sideways. It
is on the task's description and notes in the day's table, and on the
bottlenecks and actions when the day is read rather than written. The team
view needed nothing: it is a list of days that opens the same form.

The summary email is the third place, and the one where this went least as
expected. The note used to be written out as `E'\n    ' || notes` - four
spaces, then the note - and **that was not mangling anything**. A prefix
leaves the note itself untouched, which I established by putting the four
spaces back and watching the round-trip still pass rather than by reasoning
about it. The real destruction was always the `trim()` and the single-line
input.

The four spaces still go, for a smaller and honest reason: they indent the
*first* line of a three-line note and leave the other two flush against the
margin, which reads as a hierarchy that is not there. The day record now shows
a note in its own shape and the email should agree with it rather than add a
shape of its own (0249).

The cost of that choice, stated rather than discovered later: a note whose own
line begins with a hyphen or a number will be read back as a task if somebody
pastes yesterday's email into the paste box. The alternative was to re-indent
every line, and re-indenting is rewriting what somebody wrote.

### Numbered lines paste in

`splitPastedReport` read `-`, `–`, `—`, `*` and `•`. It now reads `1.` and
`2)` as well, up to three digits, because half the practice writes a list that
way and a paste that silently read none of it was indistinguishable from a
paste that had not worked.

### What the new check found

`scripts/check-kept-text.mjs` runs the real functions rather than reading the
source for the two things that are behaviour: nine cases through
`keepAsTyped`, and a pasted list with both kinds of number in it. On its first
run it failed on something I had not gone looking for.

**`[In-Progress]` did not paste back.** The status parser lowercased the
bracketed word and stripped spaces and slashes - but not hyphens - so
"In-Progress" became "in-progress", matched nothing, and came back as
Complete. The summary email writes the status as `[In-Progress]`, so the one
form guaranteed to be pasted in was the one form that did not read, and the
function's own comment claimed the opposite: *"that is how the summary this app
sends writes them out, so yesterday's email pastes back in."* It does now.

Seven faults put back and caught: `keepAsTyped` trimming again, a field
trimmed in the action, a note shown without the class, the class no longer
keeping white space, a field returned to a single-line input, Tab captured,
and numbers no longer counting as bullets.

### The round-trip, through the real database

`scripts/check-end-of-day.mjs` already submits a day as a Job Search user
inside a rolled-back transaction, so the owner's test went there: a note with
a leading space, two levels of indentation, a blank line in the middle and a
trailing space, written to a line, read back out, carried through a reopen and
a second submit, and compared byte for byte - in the row, and as a substring
of the summary the email carries. A two-line description and a numbered
bottleneck go with it.

Three faults put back there too, in rolled-back DDL: a summary that re-indents
the note's inner lines, one that flattens them to a single line, and a field
trimmed on the way in. All three fail the assertion. A summary that merely
prefixes the note passes, correctly, because prefixing is not changing it.

That script had also been failing quietly since the stage rename in 0223 - its
fixture client was created at stage 'Placement', which the constraint stopped
accepting. It is run by hand rather than in `prebuild`, so nothing said so.
Fixed, and the reason is in the fixture.

114 of 114 verify scripts pass; 18 checks in `prebuild`.

---

## Margaret's six (23 Oct 2026)

Six things from the person who uses the CRM hardest. Two were real bugs, two
were already working and the finding is *why* she saw what she saw, and two
were changes to how the screens are arranged.

### 1. Job search updates were refused by the database

Real, and the plainest kind: the screen offered a panel the database would
not accept from her.

`addClientJob` gates on `CAN_EDIT_CLIENTS` — Admin, Job Search, Reports, Job
Coach, Case Manager. The policies on `job_leads`, `employers` and
`lead_matches` asked for Admin or Job Search. So the panel was offered to five
roles, accepted from two, and the three in between got *"new row violates
row-level security policy for table job_leads"* — which is the one thing a
person reading a screen can do nothing with.

`can_record_job_search()` is the single answer now (0250), because adding one
job writes to three tables and five role names written into six policies is
what drifts. **And the writer is recorded by the rule rather than by the
caller**: every insert in the app already set `created_by`, and "already does"
is not a guarantee, so the policy requires it to be the person inserting. A
row that does not say who added it cannot be added.

`supabase/verify_job_search_updates.sql` asks it once per role, *as* that
role, with a login of its own — all five add the employer, the job and the
client against it, and Billing is refused, because without that half the
script would pass on a policy that let everybody in. Three faults put back:
the old two-role policy, a policy that let everybody in, and one that did not
require the writer.

### 2. The billing grant — honoured, except in one place

I could not reproduce "cannot edit authorizations", and I tried hard enough to
say so plainly. As a Reports account holding billing/edit, **over the real
API**: editing the rate works, labelling an unnumbered authorization works,
reading the confirm queue works, the authorization record offers her the
number field, the status form, Correct and Submit, and `billing_hands()` — the
helper every billing RPC guards on — returns true for her. The screens all ask
`can(me, "billing", "edit")`, which honours a grant.

The likeliest explanation is that her report predates the 19 October outage
fix, when every billing screen answered a server exception for her role.

What I did find is one place the grant meant two different things at once, and
it is the place she needs:

**`InboxSection` redirected everybody who was not Admin and then, on the very
next line, worked out whether they held the grant** — a question that could
only ever be asked of an Admin. The database has opened the authorization
documents in that inbox to a billing edit grant since 0103. So the data said
yes and the screen said no, and the "Replace with this number" action lives
nowhere else. Admin → Documents now opens for a billing edit grant, showing
the inbox and not Retention or records requests, which are about the
practice's own obligations rather than about billing a client.

**And the unnumbered authorizations were invisible to the machinery meant to
label them.** Four places asked the same question the same way:

    .like("number", "(workbook)%")

which was right in January. The spreadsheet import (0079) labelled the
authorizations it had no number for that way, and **every one of those has
since been given its real number — there are none left**. What exists now is
authorizations with an empty number, and not one of the four places recognised
them. The confirm queue has never offered "Replace with this number" for an
authorization that actually needed it.

`authorizations.has_usor_number` is a generated column now (0251): the
question is about the row, so it is answered on the row, once. The two screens
that block a form from being sent on an unnumbered authorization were asking
the same stale question, so a form on one of Vicki Kuhn's two unnumbered
authorizations would have gone to the billing office with no number USOR could
match. They ask the column now too.

One more thing fell out of it: the navigation can say what *level* of an area
a screen needs. Documents needs billing at "edit", and without that a
view-only grant would have put it in the sidebar and then answered with a
redirect — which is the one thing a navigation must never do.

### 3. End of day, for a manager who is not Admin

Also already working, and verified rather than assumed: as a Reports account
managing somebody, on production, the HR group appears with **End of day —
team**, the screen opens, and the managed person's days are listed. The
database agrees — `day_is_mine_to_see` gives Margaret Rei's five days and
nobody else's.

What was missing is the second half of what the owner asked for: a manager
filling in their own day had no way across to their people's. **The team's
days** is now an action on the person's own End of day, for anybody who
manages anybody.

### 4. Home, in sections

Clock-in status, today's appointments and the calendar, notifications, then
the My day items as they were — each a plain block with its own heading rather
than a card, so nothing is a card inside a card. The one-number billing tile
stays where it was, and so does the tile row above: those are one number each
and a tap to the thing itself, which is what §1 asks of them.

**Alerts is called Notifications.** It reads the `notifications` table and
always did; the heading was the only place that said otherwise.

### 5. The logo

Three places checked, and the answer was different in each.

**The sidebar, both themes, and the narrow rail: correct.** On its white plate
— the one surface that does not turn over with the theme, because the artwork
is a full-colour gradient drawn for white — 36px in the sidebar, 26px in the
64px rail, and sharp: the srcset carries a 2× candidate, so a high-resolution
screen gets 96px for a 36px slot.

**The sign-in page had no logo at all.** Just the name. That is the most
likely thing "not displaying properly" meant, since it is the screen she sees
before anything else. It has the mark now, on the same plate, above the name.

**The summary emails cannot have one.** Every email the CRM sends is plain
text — `sendEmail` takes a `text` and nothing else — so there is no image to
be broken. Worth saying rather than quietly skipping.

**And there was no browser tab icon.** No `app/icon`, no favicon, nothing in
the metadata: every tab showed the browser's blank page mark. There is a 64px
icon and a 180px touch icon now, both resized from the practice's own artwork.

### 6. A group opens its screens

The sidebar was the six groups and nothing else, which was the right call in
September — each group's screens are also the tab strip across the top, so
listing them down the side as well was the same list twice. What makes it
not-twice now is that only one group's are shown: the one you are in, or the
one you just pressed.

Pressing a group opens it, closes whichever was open, and goes to its first
screen. There is no closing a group by pressing it again — a sidebar where
every group can be shut is one somebody can leave showing nothing, and the
group holding the screen you are on should always be showing its screens.

**Not in the rail.** Closed to icons there is no room for a label, and a
screen's name is all a sub-item has, so the rail stays the six icons it was.
The phone's bottom bar is untouched: its own component, its own five
destinations, and `check-nav` now fails if a sub-list appears in it.

Five faults put back there: the sub-list removed, two groups open at once, the
rail showing them, the layout no longer saying whether it is narrow, and a
sub-list growing in the phone bar.

### What the suite caught

`verify_leads` asserted the rule 0250 replaced — "only Admin and Job Search
may add an opening" — and its probe inserted a lead **without** `created_by`,
which the new policy refuses. Left alone it would have reported that no role
in the practice can add an opening. Both halves updated, and Billing is still
asserted to be refused.

115 of 115 verify scripts pass; 18 checks in `prebuild`.

### Smoke

A Reports account opens a ZZ client's Jobs tab, the add panel is there, and
its actions are posted — a submission refused by the action's own validation
is fine, and one refused by the *database* fails the deploy. That is Margaret's
bug, asked on every deploy.

---

## The sweep that reported success and never ran (24 Oct 2026)

Asked to put `/api/cron/sync` on the same scheduler as the others, every
fifteen minutes. It was already on it, and the reason it was not working was
not the schedule.

### Where the scheduler actually is

Not Vercel. `vercel.json` holds `regions` and nothing else — no `crons` block
— and every `/api/cron/*` route is driven by **pg_cron inside Supabase**,
calling them with `net.http_post` and the shared secret as a bearer token.
Eight jobs, named `zion-*`. Looking only at `vercel.json`, as I did first,
makes it appear nothing is scheduled at all.

`zion-outlook-sync` was there, at `50 12 * * *` — once a day. Altered in place
with `cron.alter_job` rather than added beside: two schedulers calling one
route double-fire, and BUILD-LOG §6 already records what that costs when the
route sends a client a text.

### And then it still did not run

Fifteen minutes later the job had fired twice, reported `succeeded` twice, and
not one mailbox had been swept. pg_cron's "succeeded" means the SQL that
*queued* the request ran — `net.http_post` is asynchronous and returns a
request id. The answer is in `net._http_response`, and the answer was:

    #8190  405
    #8184  405

**`/api/cron/sync` exported `GET` alone.** The scheduler posts. So the job has
answered "method not allowed" every day since it was created, while recording
a success every day, and the only sweeps that have ever happened were somebody
pressing Sync on the dashboard or the change-notification webhook firing.

The seven other cron routes all export both verbs. This one was the odd one
out, and nothing inside the database could notice: the job's own history says
it worked. `scripts/check-agent-routes.mjs` holds the convention now — all
eight routes answer POST, proved by taking it away and watching it fail.

That is also the honest correction to what I reported yesterday. I said the
sweep "is not scheduled anywhere". It was scheduled, daily, and broken.

### The renewal window

Six hours, now two days.

Six hours of grace meant six hours of outage — a bad deploy, a refused token,
a scheduler stopped — between a working mailbox and a dead one. It also made
any alarm beside it meaningless: a healthy subscription spent eighteen hours a
day inside twenty-four hours of expiry, so a check on that threshold would
have fired every day for ever.

At two days, a subscription is renewed with a clear day to spare and never
legitimately sits inside twenty-four hours. Being inside one is therefore a
fault, and can be reported as one. The cost is one PATCH per mailbox roughly
every twenty-two hours, against a ceiling of about seventy.

### What watches it now

`supabase/verify_mail_subscriptions.sql` — read-only, and about the practice's
live rows rather than a fixture, which is unusual here and is the point: no
arrangement of test data can tell you whether the real subscriptions are being
renewed. It fails when a subscription is inside a day of expiry, when one
carries an error, and when a connected mailbox has not been swept for two
hours. The third is there because the first two would not notice a scheduler
that stopped this morning: a subscription renewed yesterday looks healthy for
another two days.

**Admin → System → Mailbox watch** shows the same four facts for each mailbox:
watched until, renewed, swept, and how many times Microsoft has told us
anything. The date is the number to read.

### Confirmed

- The job runs `*/15 * * * *`, and the route answers its POST with 200.
- All four subscriptions renewed from **Mon 26 Oct 15:00** to **Tue 27 Oct
  18:04** — seventy hours out, past Monday.
- Every mailbox swept, and `verify_mail_subscriptions` passes on live rows.
- 116 of 116 verify scripts.

### A timestamp that nearly became an outage

Worth writing down because it cost twenty minutes and almost cost a false
alarm in a report. A probe of mine printed the database clock with
`select now() at time zone 'utc'`, which returns a timestamp **without** a
zone; node-postgres handed it to `new Date()`, which read it as local time and
shifted it six hours. The result said every pg_cron job had stopped six hours
earlier — four jobs at once, one of which I had just altered.

Nothing had stopped. Asking the database to do the arithmetic instead —
`round(extract(epoch from (now() - start_time)) / 60)` — gave "14 minutes
ago". When a timestamp implies an outage, confirm it a second way before
saying so.

## One permanent fixture (24 Oct 2026)

The practice now carries exactly one client that is not a client: **ZZ Smoke
Board**, inactive, on nobody's board.

Two smoke steps need a client to exist on production — one opens Compose about
them, the other posts the Jobs panel as Reports, which is the step that would
have caught Margaret's row-level security bug. They must not create one: smoke
writing a client to the practice's records on every deploy is worse than the
gap it fills.

`verify_zz_no_fixtures` permits that one name and nothing else. It is still a
rule rather than an exemption: any other ZZ or ZQ row fails as before, a
second copy of the name fails, and the fixture being anything but inactive
fails — a permanent fixture on somebody's board is a fixture that has stopped
being one.

Both steps fail again when it is missing, rather than warning. Proved by
pointing the constant at a name that is not on file and watching both fail,
which tests the branch without touching the live record.

## Typing in an authorization, the stray prefix, and three groups (26 Oct 2026)

Three things the owner asked for in one sitting, all of them on the billing
side of the practice.

### An authorization can be typed in, and can arrive already paid

The PDF drop was the way in and the typed form was folded underneath it behind
"No text in the PDF? Type it in instead". The practice has a backlog of
authorizations that were issued, worked, invoiced and paid before any of it
went through the CRM, and for those the PDF is beside the point.

So the two sit side by side now, **From the PDF** and **Type it in**, and the
typed form asks for things in the order a person reads them off the paper:
client, number, service, dates, what it is worth, the day it arrived. The
client is found by typing rather than scrolled to — a select of every client
the practice has ever had is a scroll of several hundred, and the one being
billed is the one just spoken to.

Then a switch: **Already paid**, which reveals the date, the amount and the
warrant number. Saving with it on produces a record that is Paid, carrying the
payment, counted in Money for the month the payment arrived, and not on the
working list.

The part worth writing down is what it does *not* do. It does not insert a row
with `status = 'Paid'`. Status on an authorization is not a column somebody
sets, it is what the ledger watches: `authorizations_post` fires on an
**update** of status, and `post_authorization` already has a branch for this
exact case — paid without having been submitted here — which raises the
receivable on the way past so the books balance. An inserted paid row would
skip all of it and show income in Money the ledger had never heard of. So
`add_authorization` does the same three things a person would do, in one
transaction: insert it, move it to Due, and hand the payment to
`record_payment`, which is the function that already knows how.

A new parameter is a new signature, and a new signature is a new function with
a new function's grants — the lesson from 0235, where three security-definer
writers arrived executable by anybody. The eleven-argument version is dropped
first and the grants on the fifteen-argument one are set explicitly.

The same form is now on the client's own Billing tab with that client already
chosen, and in the "+" in the header, where the authorization kind used to be
a sentence pointing at Billing — which is to say the "+" offered something it
could not do.

### The stray prefix

Every authorization dropdown and list was showing `~~` on some entries. What
wrote it was a placeholder marker for a record with no USOR number, and
0251 — mine, four days earlier — had tried to define "no number" by the shapes
those placeholders used to take: an empty string, or `(workbook)...`. The live
ones are called `coaching 1006`, so the definition recognised none of them and
163 real numbers *and* six records without one all read as numbered.

0252 replaces the guesswork with what a USOR number actually looks like:
`number ~* '^V[0-9]+'`, a generated column, indexed. 163 numbers recognised,
two empty and four placeholders not. `replace_placeholder_authorization` was
asking the same wrong question and would have refused all four records it
exists for; it asks the column now.

On screen the wording lives in two helpers in `lib/billing.ts` and nowhere
else: a number where there is one, and otherwise **No number yet**, with the
service and the client where there is room for them. Thirteen call sites were
moved onto it.

Finding the other six was `check-auth-number-display`, written for this and
run before it was believed. Four different stand-ins had accumulated over the
months — `~~`, `(workbook) coaching 1006`, `(no number)`, an em dash — and the
check found live ones still in Money, in the position report, in the
authorization report, in the counselor directory, in the progress report and
in the renewal-chase email. It holds two rules: the wording exists only in
`lib/billing.ts`, and no file writes its own string on the other side of
`number ||` or `number ??`, which is the shape every one of those four
arrived in. It reads the code with comments stripped, because the house style
writes down *why* at length and a rule about what a screen says, applied to a
comment saying what a screen used to say, is nonsense.

### Past, Current and Upcoming

The client's Billing tab was the working list with "History (N paid or
closed)" folded underneath. So "what has this client got coming" had no answer
at all, and an authorization that had not started yet appeared in neither
list.

Three groups instead, two of them on when the screen opens:

- **Past** — paid or closed. The work and the money are both done with.
- **Current** — being worked, and its money has not arrived.
- **Upcoming** — it starts after today.

The groups are the database's, not the screen's. `client_authorizations`
decides which of the three a record is in, once, which is why "a paid
authorization never shows in Current" is a thing the verification suite can
assert rather than a filter somebody reads and agrees with.

One deliberate reading, recorded because it is a judgement and not a fact: an
authorization that is neither paid nor future and whose dates have run out is
still **Current**. It is money owed and nobody is finished with it. Calling it
Past because its end date has gone by would hide exactly the rows the practice
most needs to chase.

Record payment, Close and Edit are on every row of every group. They are the
same forms the authorization's own page shows, imported rather than rewritten
— a second, shorter edit form is how the two stop agreeing about what may be
changed.

### Income by month, and a view that was written and thrown away

Money now has **Income by month**: every month there was income, newest first,
each month's total and a line per service beneath it, counted on `paid_on` —
the day the warrant arrived, which can be a year after the authorization was
issued and is the only date that says when the practice had the money.

It was first built on a view of its own, `income_by_month`, which was applied
to production and then dropped again. Two reasons, the second of which is the
real one.

The first is that it duplicated `billed_work`, where every other figure on the
Money screen comes from.

The second is that it was **wrong in a way that would have shown up later**.
`billed_work` leaves out an authorization whose months are counted separately;
the new view counted every Paid row. They agree today, because no coaching
parent has ever been marked paid as well as its months. The day one is, the
second definition would have reported that year's income twice. Two
definitions of the same figure do not disagree on the day you write them; they
disagree on the day somebody does something ordinary.

A payment date can be corrected on a Paid record, with a reason, which moves
it to the right month. The reason is required and logged by the trigger on the
table rather than by the action, so the correction is recorded however it
arrives — through this control or through the record's own edit form.

### The check that had been failing for weeks

`check-quick-add` was written when the "+" offered six kinds, and asserted
that it offered exactly those six by name and that each role was offered a
particular *number* of them. Three kinds were added over the following month.
Every one of those assertions went stale at once, and because the check is not
in `prebuild`, nobody found out: by today it had been failing on ten counts
for weeks.

It asks the rules now rather than the roster — a kind either dispatches or
hands over to the form its own screen uses, and a role is offered a kind only
if it may do that thing, with both lists read from the code that decides them.
It is in `prebuild`, which is the only reason to believe any of it tomorrow.

`verify_one_door` had the same disease in a different place: it named
`add_authorization`'s eleven argument types as a string, so the moment 0254
added four it stopped asking about the door and started asking about a
function that no longer existed — a question nothing can fail. It finds the
signature in the catalogue now, and asserts there is exactly **one** of it,
which is the 0235 trap this check should have been watching for all along.

### A view arrives with grants nobody asked for

Creating `client_authorizations` handed every signed-in person INSERT,
UPDATE and DELETE on it. Nothing in 0256 granted that: Supabase’s default
privileges grant every new table and view in `public` to `authenticated` in
full, and the view is a simple enough select that Postgres will write through
it - so a read-only list arrived shaped like a second door into
`authorizations`, which is the one thing `verify_one_door` exists to prevent.

It was not a door in practice, and the reason is worth knowing: with
`security_invoker` set, the base table’s privileges are checked **as the
person**, and no signed-in person has insert on `authorizations`. The attempt
is refused with "permission denied for table authorizations". Tested rather
than reasoned about. Without `security_invoker` the write would have run as
the view’s owner and consulted neither the grant nor the policies.

The grant is gone from this view. `verify_one_door` now asks the question that
matters - is any writable view onto this table one that writes as postgres -
and that assertion was proved by creating such a view inside a rolled-back
transaction and watching it get caught.

**Left for the owner:** thirteen existing views onto `authorizations` carry
the same default write grants, and `client_documents` is auto-updatable with
no `security_invoker` at all - its insert is refused today only because one of
its columns happens to be computed. Removing grants is changing who can access
what, so it is not something to do without being asked. The fix is one
statement per view.
### What it took

- 0252, 0253, 0254, 0255 and 0256 applied.
- 20 prebuild checks, two of them new.
- **119 of 119** verify scripts, including the new `verify_add_authorization`
  and `verify_billing_filters`.
- Both new checks proved by putting the fault back and watching them fail.

## The grants nobody asked for, and the intake's five seconds (26 Oct 2026)

Both of the things left for the owner earlier the same day, answered yes to.

### Nine views, not thirteen

The note above says thirteen existing views onto `authorizations` carry
Supabase's default write grants, and that `client_documents` is auto-updatable
with no `security_invoker` and refused an insert only because one of its
columns is computed. Both numbers were wrong and are corrected here rather
than quietly in place.

It is **nine** views - `authorization_economics`, `authorization_record`,
`billed_work`, `billing_position`, `client_activity`, `client_last_activity`,
`client_paperwork`, `client_pipeline` and `staff_capacity` - counted by
walking `pg_depend` through intermediate views rather than by eye. And
`client_documents` has no INSERT for `authenticated` at all; its ACL is
`authenticated=r`. The computed-column refusal that was observed was a second
wall behind a door that was already shut.

0257 takes the writes off all nine and grants SELECT back. The default
privilege itself is left alone, and that is a decision rather than an
omission: switching it off would take the writes off every future *table* in
the same breath, and some tables lean on it - `mail_templates` (0238) has no
grant of its own and the Mail screen writes to it. One question at a time.

The half worth checking was not that the writes went. It is that nothing
anybody uses went with them. Counted as each of the five people on the
practice - Admin, Billing, Case Manager, Job Search, Reports - across all ten
views, before and after: 169, 169, 148, 169, 2365/2171/1546/2257/2281, 169,
80, 25, 80, 7, identical on both sides. And a write through `billed_work`,
which is the one of them Postgres can write through, is now refused with
*permission denied for view billed_work*.

### The view that should not read as the invoker

`client_documents` was to be given `security_invoker` and was not, because the
verification the owner asked for is the thing that says no.

The view reads `attachments` with its owner's rights, and that is what makes
the restricted-document design possible: a document somebody may not open
comes back as a **row**, with its category, filename, note, path and size
blanked and `can_open` false. The screen says a document is there and that
this person cannot open it. The base table's own read policy stops at
`not restricted or can_see_restricted(client_id)`, so reading as the invoker
would not blank those rows - it would remove them. Measured inside a
rolled-back transaction, with the option switched on and the same question
asked again as each person:

| | sees now | blanked | with `security_invoker` | lost |
|---|---|---|---|---|
| Admin | 776 | 0 | 776 | 0 |
| Billing | 776 | 109 | 667 | **109** |
| Case Manager | 776 | 109 | 667 | **109** |
| Job Search | 776 | 42 | 734 | **42** |
| Reports | 776 | 0 | 776 | 0 |

The tempting repair - letting restricted rows through `attachments`'s read
policy and leaving the blanking to the view - is much worse than the thing it
fixes: `attachments` is a table the app reads directly, so the filename and
storage path of every restricted document would be one query away.

So the answer is that `security_invoker` is not what keeps this view safe.
Having no way in is. `verify_view_grants` asserts both halves - that it has no
invoker, and that `authenticated` holds SELECT and nothing else on it - so the
day somebody grants a write there, that fails rather than being a quiet
exception to a rule stated as "every view gets `security_invoker`".

It also puts the fault back: it creates a view of exactly the dangerous shape
inside the transaction, grants INSERT on it, and fails if the general
assertion does not notice.

### Thirty seconds for the intake

`zion-intake` had logged a pg_net error every fifteen minutes since it was
turned on - 96 a day - because five seconds is pg_net's default and reading
the forty most recent messages in service@ through Graph takes about 4.9 of
them before the response even starts. Nothing was lost: the route is
`maxDuration = 300` and finishes on Vercel long after pg_net has stopped
waiting. What was lost is the log, which is where the next real error has to
be visible.

0258 raises it to thirty seconds. The shared secret is not written down: the
command is read back out of `cron.job`, the parameter appended to it, and the
whole thing handed to `cron.alter_job` - the same reason 0183 copies its
command from a job that already carries the secret rather than typing it.
`zion-outlook-sync` and `zion-sms-reminders` already pass 240000, so this is
the third job to say how long it will wait rather than the first.

Watched for three ticks afterwards - 21:00, 21:15 and 21:30 - and all twelve
calls those quarter-hours make answered 200, with nothing timing out at five
seconds or at thirty. Worth saying because one clean tick would have proved
nothing: intake had been timing out on roughly two ticks in three, so three in
a row is the first run of them the log has.

### What it took

- 0257 and 0258 applied.
- **120 of 120** verify scripts, including the new `verify_view_grants`.
- 20 prebuild checks.
- The new script proved twice over: run before 0257 it failed on all fifty-four
  grants, and its general assertion catches a dangerous view planted on purpose.

**Still the owner's:** twenty-four other views in `public` carry the same
default write grants, none of them onto `authorizations`. Three are
auto-updatable - `my_tour_progress`, `offboarding_readiness` and
`updates_for_me` - and all three have `security_invoker`, so a write through
one of them is checked against the base table as the person, which is why
none of the twenty-four is a door today. One statement each if you want them
gone. And whether to turn off the default privilege for the whole schema,
which is the tables question above, not this one.

## The other twenty-four, and a list stops being the rule (26 Oct 2026)

The note directly above left twenty-four views carrying Supabase's default
write grants and said it was the owner's call. The answer came back the same
day: take them off, keep SELECT, leave the schema-wide default privilege on.

### Twenty-four views, one hundred and forty-four grants

0259 revokes and re-grants each of them. The count is exact and worth writing
down, because it is what the check was then shown to catch: six privileges -
INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER - on twenty-four views,
144 grants, every one of them to `authenticated` and none to `anon`.

None of the twenty-four was a door. Three of them are simple enough for
Postgres to write through - `my_tour_progress`, `offboarding_readiness` and
`updates_for_me` - and all three had `security_invoker`, so the write would
have been checked against the base table as the person and refused there. The
other twenty-one are not auto-updatable and refused a write on their own
account. But both of those are properties of how a view happens to be
written, not of what anybody decided, and the second wall is not a reason to
leave the door open. All three now refuse at the view itself: *permission
denied for view my_tour_progress*, and the same for the other two.

Nothing writes through a view, asked again rather than carried over from
0257: no `.insert`, `.update`, `.delete` or `.upsert` anywhere in the app
against one of these names; no function body in `public` with a write
statement against a view; and no view in `public` with an INSTEAD OF trigger
or a rule of its own, which is what a view meant to be written through would
have.

And the half that matters more than the grants going: nothing anybody uses
went with them. Counted as each of the five people on the practice - Admin,
Billing, Case Manager, Job Search, Reports - across all twenty-four views,
before the revokes and after, inside one rolled-back transaction. 120 pairs,
every one identical, and not one role refused a view on either side.

### A list is what let this happen

`verify_view_grants` named ten views when it was written yesterday. Adding
twenty-four more names to it would have made it longer and no better, because
the way these grants arrived in the first place is that nobody was asking the
question of anything new. So the first section now asks the catalogue: does
any view in `public` give `anon` or `authenticated` more than SELECT. A view
created next month is judged by that without being added to anything, and
when it fails it names the view and the privilege rather than saying a number.

Run against the schema as it stood before 0259 it failed on exactly 144
grants, named, across exactly 24 views. It also puts a fault back on purpose
- grants UPDATE on `updates_for_me` inside the transaction - and fails if
that one is not found and named. That injection only runs when the baseline
is clean, which is the point: from a dirty schema the planted grant proves
nothing, and complaining about it would bury the 144 real ones underneath.

The older, narrower assertion stays: a view `authenticated` can write through
has to send the write back to the base table, which is what `security_invoker`
does. It is strictly redundant while no view has any write grant at all. It is
kept because the day somebody deliberately makes a view writable, that is the
condition that still has to hold, and it keeps its own planted fault.

The schema-wide default privilege stays on, as the owner decided: turning it
off would take the writes off every future *table* in the same breath, and
`mail_templates` (0238) has no grant of its own while the Mail screen writes
to it.

### What it took

- 0259 applied; **35 of 35** views in `public` now SELECT-only for
  `authenticated`, nothing for `anon`.
- **120 of 120** verify scripts, 20 prebuild checks, build and typecheck clean.
- The rewritten check proved twice: 144 named failures before 0259, and a
  grant planted on purpose afterwards.

## A week is what a month is made of (28 Oct 2026)

The Monthly Reports brief asked for one report per active client per calendar
month, a section per service, drafted from the record on the 1st, signed and
sent to the counselor. The owner amended it the same week: build the week
first, and let the month be made of weeks.

That amendment is the whole design, and it is worth saying why rather than
recording it as a preference. A month read off the record four weeks later is
read by somebody who no longer remembers it, so the reading is whatever the
record says and the holes in it are invisible. A week read on the Monday after
is read by the person who was there: they know that Tuesday's appointment did
happen and was logged as a no-show, and they fix it while fixing it is cheap.
By the 1st the month is four confirmations instead of one act of recall — and
it can be honest about what it does not have, because it knows which weeks
somebody looked at and which nobody did.

### Dated lines, not prose

Both reports hold `content` as sections of dated lines rather than finished
text, and that is what makes the month out of the weeks. A week straddles the
month boundary five times a year; the month takes the lines dated inside it
and leaves the rest, so the same week serves October and November without
anything being counted twice or dropped. Where no weekly report covers a
stretch of the month — a client taken on mid-month, a week nobody drafted —
the month reads those days off the record directly and records the stretch in
`gaps`, so "nobody looked at 4 to 10 November" is on the screen rather than
absent from it.

A service the client holds an authorization for is a section whether or not
anything happened under it, and says "No activity recorded". A service they do
not hold is not a section at all. The two together are the brief's "empty
sections omitted" and its "the gap is visible, not hidden", which read as a
contradiction until you notice that one is about services and the other about
activity.

### What a timer may copy

This is the part that needed slowing down for. The existing progress report
pastes note text into an activity log and is safe because it runs as the
person: RLS has already removed the notes they may not read. These are drafted
at ten to one in the morning UTC by the service role, which no policy applies
to.

So two rules, in two places. A report carries `visible_roles` the way a note
does and is read by the roles it names, by Admin, or by the person whose
client it is — that last clause by name, because an ordinary note is visible
to four of the six roles and a report about a client their own job coach
cannot open is a rule protecting nobody. And a note narrowed below those four
is narrowed on purpose, so its words are not copied into a document that will
be signed and posted to the state: the line says the note's type and date, the
count goes in `withheld`, and the screen says how many were held back. 34 CFR
361.38 is the rule underneath — what reaches a counselor is what the service
needed.

### The order a month goes in

Draft, Reviewed, Signed, Sent, enforced by a trigger rather than by a screen.
Sent needs a signature, an address and the PDF that was signed. A sent report
cannot be changed, because the record of what the counselor was told does not
change after they were told it. A signed report that turns out to be wrong is
reopened, and reopening says why — the reason is kept on the row.

And a signed month freezes the weeks it was assembled from, the straddling one
included. A PDF the practice has signed whose own weeks no longer add up to it
is worse than either version alone, so the week refuses and names the way
round: reopen the month, which somebody has to give a reason for.

### Daily, because pg_cron does not know about Utah

`zion-reports` runs every day at 12:50 UTC and the route asks whether it is
Monday in Utah, or the 1st in Utah. A job pinned to a UTC day of the month is
a job that drafts March twice and skips November one year in some number of
years, and nobody would find that for a month. The unique keys on client and
week and on client and month make every other run cost one query. 12:50 sits
twenty minutes ahead of the nightly digest on purpose: the drafts have to
exist before the mail that tells somebody about them goes out.

### Three things the rest of the practice had to be asked about

Each of these was a check already in `prebuild` or the verify suite refusing
the new tables, which is the suite working rather than the suite being in the
way.

`verify_mail` fails any new `content` column until somebody looks at it, on
the grounds that no table may hold an email body. These two hold the
practice's own writing about its own work, and the *subjects* of filed mail —
a body could not get in even by mistake, because `mail_log` has no body column
to copy one from. Added to the list with that reason.

`verify_records_request` fails any table with a `client_id` that is in neither
the bundle nor a written list of exclusions. Both are in the bundle (0263),
including the weekly one: most of its lines are disclosed through their own
sections already, but the week's own sentence is nowhere else, and the
`staff_day_lines` exclusion turns on there being another copy.

`verify_portal_rls` caught `weekly_report_is_frozen` as an elevated function a
signed-in person could call without it checking who was asking. It is not
granted to anybody now: its only caller is a trigger, which is security
definer itself and so calls it with the owner's rights whoever set it off.

### What it took

- 0260 to 0263 applied. `check-reports` is the 21st check in `prebuild`;
  **121 of 121** verify scripts pass, build and typecheck clean.
- `check-reports` runs the real week arithmetic over every day of two years:
  every day of all 24 months belongs to exactly one of the weeks its month is
  assembled from, and the four clock changes add up.
- Seven faults put back on purpose and every one of them named: the freeze
  trigger dropped, the status trigger dropped, the read policy's owner clause
  removed, the scheduled job absent, the note gate removed, the job pinned to
  a day, and the week arithmetic switched to local time.
- That last one is why `check-reports` collects its dates instead of walking
  them. With local getters on a UTC instant, `addDays` returns the day it was
  given at the clock change, and the first version of the check looped for
  ever instead of failing. A check that hangs before every build is worse than
  the bug it was looking for, so a step that does not move is now a named
  failure: *stepping a day at a time did not get past 2026-03-08.*

## A referral arrives once a day (29 Oct 2026)

Found while reading the first weekly drafts, which is the only reason it was
found at all. One client had 223 lines in a single week, all of them the same
sentence: *Referral received by email from Referral Page.* The practice's
contact log held 623 rows and 547 of them were on that one record, arriving
four an hour and still arriving.

`zion-intake` runs every quarter of an hour and reads the newest forty
messages in service@. Nothing is marked read and nothing is moved, so a
message in that window is handed to the rules again on every run. That is the
design rather than an oversight — a document that arrives twice is one
document, a re-sent referral is a re-send — and it works because every write
in the intake rules is idempotent.

Every write but one. `intake_referral` guards the client, the attachment, the
task and the notification, and then inserted the contact-log row
unconditionally. The reason it went unnoticed for six days is worth keeping:
every *visible* consequence of a referral was already guarded, so the task
list, the bell, the email and the document all looked right. Only the contact
log grew, and nobody reads six days of one client's contact log — until a
report is drafted off it, at which point it is the whole report.

0264 gives that insert the guard the rest of the function has. The fact the
row records is that the referral arrived on that day, so the key is the client
and the day: a referral genuinely sent again a week later is a second arrival
and says so, and a second reading of the same arrival is not. The counselor
name is deliberately not in the key — it is read off the form and can differ
between two readings of the same page.

The two assertions went into `verify_the_intake.sql` beside the re-send case
they belong with, and with the fault still live they name it: *the referral
was read twice on one day and logged it 2 times.* The second one is there
because a guard on the client alone would have passed the first and silently
lost every re-referral the practice ever receives.

Two things this did not touch. The 547 rows already written are the owner's to
decide about. And the reason that client exists at all is a separate fault:
the referral was for a client already on file, and the parser read the name off a
heading — the record is called *The assessment is due* and the counselor
*Referral Page*.

## A month is a document, and a document gets signed (29 Oct 2026)

The weeks were the primitive; this is the month as the thing that leaves the
building. Draft, Reviewed, Signed, Sent, a PDF on the client's record, and a
counselor who cannot receive anything else.

### One renderer, three places

`lib/report-text.ts` turns a month's content into an array of lines, and the
screen somebody signs on and the PDF they sign both draw that array. The
forms have had this rule since 0100-something — `formToText` is the one
renderer and the PDF only lays it out — and the reason is the same: a screen
that laid the sections out in its own way would be a second renderer, and the
day the two disagreed the practice would have signed something it had not
read. `check-reports` asserts both files draw it and neither maps over the
sections itself.

It has no imports that can only run in a request, which is what lets the
check run the real renderer over made-up content before every build. That
cost one small move: the shape of a report — its types and the word General —
is now `lib/report-shape.ts`, which imports nothing, and `report-period.ts`
re-exports it so nothing else had to change.

### What the summary is allowed to say

Counted, never characterised. "Job Coaching: 12.5 hours over 7 visits" is in
the record; "good progress" is not, and a draft that wrote the second would
be putting words in the signer's mouth that they would then sign. Five lines
is the brief's cap, and the cap now lives in one constant because the first
version of the check could not tell whether it was there at all: the summary
is made of five kinds of line, so no content can produce a sixth, and the
fixture passed happily with the cap deleted. A check that asks a question
merely near the rule passes the bug it was written for, again.

The sentence that matters most is the dullest: *No service hours were logged
this month.* That is what a counselor was never being told, and it is why
this exists.

### What a counselor gets and what they do not

The weeks' own sentences go in, where the person who did the work confirmed
them — that is the one part of the report nobody read off the record. An
unconfirmed week's sentence does not: it has not been stood behind.

The stretches of the month no weekly report covered are on the screen and not
in the PDF. The days themselves are in both, read straight off the record;
what the counselor is told is how much of the account a member of staff
confirmed, which is what they need. Which Monday somebody here missed is our
problem, and 34 CFR 361.38 is the reason to say the first and not the second.

Notes narrowed below the four roles keep the treatment the weeks gave them:
the line stays, dated and named by type, the words do not, and the report says
how many were held back.

### Signing, and the order it happens in

The PDF is built from the content on the row rather than from the record as it
is now, so what is signed is what was on the screen. It is filed as an
ordinary attachment, so it is in the client's documents, in a records
request, and wherever else a document is looked for. Then the row is stamped
and points at that attachment.

The stamp is last on purpose. Interrupted after the stamp, the record would
say Signed and name no PDF — a report nobody can check against what the
counselor received, which 0260 refuses to send. Interrupted before it, there
is a PDF on the record against a row that still says Draft, which anybody can
see. Of the two, the second leaves the record honest.

The attestation is shared with the forms (`lib/pdf-page.ts`), and that was the
point of extracting it. It is the sentence the practice is certifying, and two
copies of it would be two things it says it is certifying; the day they
drifted nobody could say which one the counselor had. Only the certification
sentence differs, because a form certifies the information on the form and a
report certifies the account of the services.

### Sent means sent

Send hands off to Compose about the client — the existing screen, with the
report's own PDF already ticked and the report named on the form. Three
things are true before anything leaves: the report belongs to this client,
the practice has signed it, and the file attached is the PDF it was signed as.
The third is the one that matters. A report marked Sent whose counselor
received some other document is worse than a report never sent, because the
record then says they were told something they were not.

Which document that is comes from `pdf_attachment_id` on the row, never from
the address bar. And the row is marked Sent after Microsoft accepted the
message, never before: a row that said Sent first would be a report the
practice believed the counselor had.

The question and the marking live in `lib/mail-filing.ts` with the other
things the mail lets the database answer, because `app/(app)/mail/actions.ts`
says at the top that nothing is written to the database in it, and that
sentence is worth more than the convenience of ignoring it.

### What it took

- `lib/pdf-page.ts`, `lib/report-shape.ts`, `lib/report-text.ts`,
  `lib/report-pdf.ts`, `lib/staff-signature.ts`; the month screen and its
  actions; the Compose coupling.
- `check-reports` grew from 6 assertions to 13. Eight faults put back and the
  eighth exposed the cap that could not be tested, which is now tested where
  it lives.
- 0264 is written and not applied: applying it was refused twice by this
  session's own guard rails, so it is waiting on the owner.

## A heading is not a name (29 Oct 2026)

The other half of the referral loop. 0264 stopped the contact log growing; this
is why there was a client for it to grow on.

The record was called *The assessment is due*, its counselor *Referral Page*,
its referring office *Observations:*. All three were read off a real DWS-USOR
94, and the thing worth keeping is that the correct answer was also on the
form, three lines further down, labelled exactly as a parser would want:
`Client Name:` followed by it. The reader did not fail to find the name. It
stopped at the first thing that resembled one.

### What resembled one

A 94 opens with USOR's own instructions:

```
This form is to be completed by the VR Counselor, Community Rehabilitation Program (CRP)
Provider, and the client. The assessment is due when the team meets to review the results, agree to
goals, and sign the assessment.
Counselor Referral Page
Client Name: ...
```

`applyFieldRule` accepts a label at the start of its line, or with a colon or a
full stop after it. The full stop is the one that did it: *client* matched the
label, the `.` after it read as a separator, and "The assessment is due" read
as a name — four capitalised-ish words, which the old name pattern accepted
because it accepted any letters at all.

Line 6, `Counselor Referral Page`, is a column heading with a label at position
zero, so the counselor read as "Referral Page". And the office came off
`Worksite Simulation Location:` with `Observations:` on the line beneath — the
existing guard skips a line below that matches another rule's label, and
`Observations:` matches none.

### Two guards, either sufficient

`fieldOnly` on a rule means: a colon straight after the label, or the label
alone on its line with its value beneath. Prose satisfies neither half. It is
opt-in and set on three rules — name, counselor, office — rather than changed
globally, because the looser question is what reads `AUTHORIZATION NUMBER
V1234567` off sixteen real authorizations, and tightening that to buy this
would be trading a working thing for a fixed one.

The second guard is in the name pattern: a name is capitalised words, a
sentence has lowercase ones. "The assessment is due" fails on *assessment*.

Both were injected separately and **neither failed the check on its own** —
each stops the fault by itself. That is deliberate, but it means the check does
not test either one, so the pair was removed together to confirm the fixture
still reproduces `"The assessment is due"` exactly. It does. The counselor and
office guards do each fail alone, and were watched doing it.

Third guard, and general rather than opt-in: a line ending in a colon is naming
a box, not filling one.

### The check that passed

`check-referral-parse` had five cases and all five were green while this was in
production. Every fixture put the fields in the first few lines with nothing
around them, which is the shape of no real form — the exact failure CLAUDE.md
describes, asking a question merely near the rule. The whole document is now a
fixture: instructions, column heading, the real field, address and phone lines,
a mid-form `Location:`/`Observations:` pair, and the signature block. USOR's
prose is kept verbatim because the prose is what did it; the client, address
and counselor are invented, because a real one does not go in a repository.

Four assertions, not one. The fault produced four wrong values and a check
asking only about the name would have shipped the office.

### When no name can be read

Before: the route threw. The poll failed, the document sat in the queue, and
nobody was told — so the only way anybody found out was by opening the inbox.
That was survivable while the reader guessed, because it almost never fired.
Now that the reader refuses, it is a branch real forms arrive in.

`intake_referral_unreadable` leaves the document exactly where it is and tells
the intake owner, once, keyed on the document — the same guard 0264 put on the
contact log, because the same fifteen-minute poll is behind it. No reply goes
to the counselor: thanking somebody for a document nobody can file says
something untrue.

It creates no client record. A record named for the fact that nothing could be
read would collect every unreadable referral, sit in the client list, and need
merging out again — which is the week this fix came out of. The queue already
holds documents whose client is not clear, and that is what this is.

### The fault above this one

`classify-document` has `REFERRAL_FORMS = ["94", "98"]` and calls 94 "the
referral". The document that caused all of this is titled **WORK STRATEGY
ASSESSMENT**. If 94 is the WSA rather than the referral, then every assessment
that arrives at service@ is read as a referral and may create a client, and the
name reader is only the second line of defence. Left alone pending an answer,
because which USOR number is which form is not something to guess at twice in
one file.

## A note says which service it is about (29 Oct 2026)

Brief section A. A note carried a *type* — Meeting, Interview, Coaching
session — which says what shape the contact was and not what it was about. A
meeting can be about job coaching or about life skills, so the type cannot sort
a report into one section per service, which is what Rei asked for and what
361.38 wants anyway.

So a note now carries a category as well as a type, and the two are orthogonal
on purpose. Seven categories: Job development, Job coaching, Job search,
Assessment, Life skills, General progress, Personal.

### Personal is the reason the column exists

A note about somebody's housing, health or family is on the record because the
practice needs it to do the work, and is none of a counselor's business. It
cannot be sorted out of a report if nothing says which notes it is.

Three places drop it — the monthly report, the on-demand report, and the USOR
96 autofill — and the database narrows its roles to Admin and Case Manager
whatever the screen asked for, on insert *and* on an update of the category,
because the usual way a note becomes personal is somebody realising it
afterwards.

Two guards again, and the second one matters: the category filter keeps the
note out of the report, and the roles keep its words out even if the filter
were ever removed. The type filter on USOR 96 is not one of the two — a
personal note about a job interview satisfies the type list and the role list
both, which is the gap the category closes.

One thing it deliberately does **not** do: a Personal note is not counted in
`withheld`. "Two notes are not included here" about somebody's housing is still
telling a counselor something. The check asserts the drop happens before the
counter is touched, and watched it fail with the two lines swapped.

A records request still contains them. That is the client's own record and
their own life; the rule is about what reaches a counselor.

### Required going forward, backfilled when asked

Eight hundred and thirty-two notes predate the column and the brief asks for
the backfill to be reported before it runs, so NOT NULL could not land in the
same migration as the column. Required-from-now-on is enforced on insert
instead, so the rule is live from the moment 0266 applies rather than from
whenever the backfill is approved.

The screens refuse a note with no category — the picker opens on the client's
stage, so nothing arriving means the box was emptied on purpose and the right
answer is to ask rather than to pick. The machine-written notes — filed mail, a
matched job lead — are filled from the client's stage by a trigger instead,
because stopping those writes would lose the note, and a category somebody can
correct beats a note nobody has.

### One map, three callers

`category_for_stage` in the database and `categoryForStage` in
`lib/report-shape.ts` are the same map, and `check-reports` reads one against
the other. Three things need it: the screens guess with it, the backfill will
read the stage the client was on the day each note was written, and the checks
assert they agree.

Job Placement maps to Job development rather than getting a category of its
own. Placement is what development is for, the practice bills it that way, and
a seventh section nobody authorized would say "No activity recorded" on every
report. Anything the stage list grows later falls to General progress: a guess
landing in the general section is one somebody can correct, and a guess landing
in a billed service is one that reaches a counselor.

### The check that passed with the guard switched off

`check-reports` grew from 13 assertions to 19, and one of the new ones had to
be written twice. The first version matched
`NOTE_CATEGORIES.includes(category as NoteCategory)` in the action's source and
passed happily with `false &&` written in front of it — a question asked merely
near the rule, which is the fault CLAUDE.md names twice and which this file has
now produced twice in two days.

The rule moved into `noteCategoryFromForm`, which the check *runs*: empty
string, whitespace, a category nobody declared, the wrong case, and a non-string
all have to come back as nothing, and all seven declared ones have to come back
as themselves. The wiring is still a source read, but a narrow one — the raw
form value must not be read anywhere in the action, so there is no second path
for a guard to be taken off the front of. Four faults against it, all four
caught, including the original `false &&`.

`verify_note_categories.sql` is the database half: eight assertions, four
faults injected into 0266 and all four watched failing — the trigger not
filling from the stage, Personal not narrowed, Job Placement mapped elsewhere,
and a category dropped from the check constraint.

That last fault took three attempts to inject. Twice it silently did not reach
the database at all and the verify passed, which looks exactly like a check
that cannot fail. It was neither: a `drop constraint` sent through a heredoc on
stdin never ran, so the migration's own `if not exists` guard skipped the
faulty constraint and left the real one in place. The lesson is the obvious
one — a fault injection needs its own assertion that the fault arrived.

## A record you can quietly tidy is a record nobody can trust (29 Oct 2026)
Undoing the misread referral, approved by the owner. 548 duplicate contact-log
rows deleted, one arrival kept; the record merged into the real one; the
duplicate intake task closed and the overdue bell behind it resolved. The
practice contact log goes from 626 rows to 78.

Three things came out of doing it rather than planning it.

**There was no correction log for a client record.** Authorizations have had
one for months. 0267 gives clients the same table, same columns, same
append-only rule, and the seven entries from this correction are its first
rows. They sit on the kept record, not on the one that was merged away, so
somebody opening her record can see what was done to it; `client_name` holds
the name as it read at the time, which is what makes that readable.

The grants on it are worth reading. Supabase grants everything on a new table
in `public` to `authenticated` before any migration line runs, so the grant of
select and insert narrows nothing - the revoke is the part that works. TRUNCATE
is the reason it is a revoke and not a policy: a policy is per row and TRUNCATE
has no rows, and the append-only trigger is a row trigger too. Both of the
table's other defences miss it entirely.

**merge_clients has never worked on a client with a filed document.** Two
separate faults, one after the other, both found by running it:

It walks the foreign keys to find what to move, which is why it has kept
working as tables were added - but four of those tables are append-only logs
whose triggers refuse every update, so it raised "The document log is a record"
and rolled the whole merge back. The fix is not to make the logs writable. An
append-only log records what happened, and what happened is that the document
was added to the record that was later merged away; rewriting the row to name
the kept client would make it say something untrue. So those rows stay, the
merge says which ones it left, and merged_into is the link that keeps them
reachable. Which tables those are is asked of the catalogue rather than listed,
so a fifth log added later is handled by having its trigger.

Then it collided on a unique key. One weekly report per client per week, and
both records had one for the same week. Where they collide the kept record's
row wins and the merged-away one goes, counted and reported rather than
swallowed.

verify_client_merge had three assertions and passed throughout. Every fixture
in it was a client with no documents, which is not a client the practice has.
It now files a document and gives both records a draft for the same week, and
the two drafts carry different notes - with identical ones a merge that keeps
the wrong row passes, because the count afterwards is one either way, which is
what the first version of that assertion did.

**A verify script can test the grant and think it tested the trigger.**
verify_client_corrections asserted that a correction cannot be edited, and
passed with the append-only trigger dropped: `authenticated` has no UPDATE on
the table, so the update never reached the trigger. The trigger exists for the
caller the grants do not stop - a SECURITY DEFINER function, a migration, a
script with the service key - which is most of what writes here. That is now
its own assertion, tried as a caller with the grant.

Four faults against 0267 and three against 0268, all seven caught, all run
inside transactions that roll back so production is never weakened even for the
length of the test.

client_corrections is out of the records-request bundle, with the reasoning in
the skipped list. What it holds is the practice's account of its own mistake in
the practice's own terms - these first entries name a function and a polling
interval - and every correction is a correction to something the bundle already
discloses as it now correctly reads.

## Job placement is its own section (29 Oct 2026)
0266 folded the Job Placement stage into Job development, on the argument that
placement is what development is for and the practice bills it that way. The
owner's answer: 36 authorizations name Job Placement on its own, and a
counselor reading about a client who has been placed wants the placement, not a
development section with a hire buried in it. Eight categories, not seven.

The backfill ran with that change, reported first as the brief asks. 832 notes,
by the stage the client was on the day each was written: Job coaching 248, Job
placement 189, General progress 176, Job development 158, Assessment 48, Job
search 13. Nothing left blank, and `category` is NOT NULL from here.

NOT NULL is not the same guard as the insert trigger and the verify now says so
separately. With it dropped, the trigger still fills an insert - so a check that
only ever inserted would pass - and an update to null goes straight through.
The callers that do that are migrations and scripts holding the service key,
which is most of what writes to this database.

**Where a placement stands, whatever month the report covers.** Everything else
in a section is dated inside the period, which is right for activity and wrong
for retention: a counselor reading November about somebody hired in September
was told nothing about the hire. Each placement now contributes one standing
line naming the hire date and every retention check the record holds.

It carries a date like every other line, because the month slices on dates and
a line without one falls out of a week - but the date is the end of the period
and means "as at", so the renderer prints it without a date column and above
the dated entries. A section with a placement and nothing else this month says
"Nothing further recorded this month" rather than "No activity recorded", which
would be the section contradicting the line above it.

Only dates the record actually holds. A check that has not happened gets no due
date here: the screens work that out from the start date, and a report printing
a date nobody recorded would be making a commitment on somebody's behalf.

check-reports goes from 19 assertions to 22, and one of the existing ones had to
be rewritten: it read the category list out of 0266 by name and failed the
moment 0269 added an eighth. It now asks which migration declares the
constraint, rather than being told. Five faults injected, all five caught.

## The same form travels in both directions (29 Oct 2026)
DWS-USOR 94 is the Work Strategy Assessment and it is one sheet of paper used
twice: the counselor sends it with the client's details filled in and the
assessment blank, and the CRP sends it back with the assessment written on it.
The practice's own filing has said so all along - "94 (WSA Referral -
editable)" and "WSA form 94 ZZ Testperson complete" sit in the same folder. Every
94 was read as a referral, so a completed assessment coming back was a new
client arriving.

So the form number says which form and the state of its assessment body says
which direction it is going.

What made this harder than it sounds: the *referral* half of a 94 arrives
filled in. Current work skills, family supports, communication needs - that is
the counselor describing the client, and on the 23 October document all of it
was written and all seven Observations boxes were empty. A rule reading the
whole form would call every referral a completed report. So it reads the
assessment boxes only, and there is a fixture asserting that the counselor's
half being filled in does not tip it.

Headings are what the extracted text actually confuses with answers, not
labels. The assessment sections head themselves with how long they take -
"Natural Support Assessment (1 hour)", "Transportation Assessment (30 min)" -
and that duration is the one reliable mark. Prose is no use: the headings print
their checkbox labels on the same line, so "Interpersonal skills How the client
reacts to criticism" has as many ordinary words in it as a real answer.

Signatures are counted and reported, never relied on. Of three real completed
94s, one had two signature lines in its text and two had none - they are signed
with an image or on paper, and a PDF's text says nothing about either. A rule
resting on signatures would have called two completed assessments blank.

Form 98 is decided by the same rule without naming it: it is titled REFERRAL
FOR CRP ASSESSMENT, has no assessment section at all, and so is always the
referral form itself.

Measured against six real documents: 0 of 17 boxes written in on the referral,
7, 13 and 13 on the three completed ones, no assessment section on either 98.
Not a close call.

A form that is neither - one or two boxes - is read as neither, which was the
owner's instruction. Not as kind Unreadable, though: that queue exists to feed
documents to OCR, and a form that already has text would be read, produce the
same text, and come round again for ever. It is left as the USOR form it is
with `referral` false, which is the path that files it on the client if the
client is clear, leaves it in the queue if not, and creates nobody either way.

**And a thing found while looking for where to put the new cases: prebuild ran
21 of the 32 check scripts.** check-classify and check-auth-parse were two of
the eleven it skipped - the document classifier and the authorization reader,
both changed earlier the same day by somebody who believed the suite was
running. They passed, which is luck rather than diligence.

Six of the eleven were ordinary logic checks that had simply never been wired
in. They are in now: 28 of 32. The remaining five cannot run there and
check-checks.mjs names each one with the reason and what it would take - two
need two database connections, one reads the database, and two import a
server-only module and are one split away from joining the others, the way
lib/report-shape.ts was split out of lib/report-period.ts.

check-checks is first in the chain and checks itself: a check in neither list
fails, a reason left behind for a check that has been wired in fails, a reason
for a check that no longer exists fails, and a typo in the chain fails. Five
faults, five caught. CLAUDE.md has said a check outside prebuild is a check
that rots since check-quick-add went stale; it turns out to apply to the
checks themselves.

Eleven faults across the two: six against the classifier rule, five against
check-checks.

## An application says where it got to (30 Oct 2026)

`lead_matches.status` has held one word per job application since 0013, and the
word has been overwritten every time something happened. An application that
reads "Not selected" today cannot say when it was applied for, whether the
employer ever answered, or who found out. Three date columns were bolted on
over the years - applied_on, interview_on, decided_on - and between them they
cover three of the nine things that happen.

So the status becomes a row rather than a column. `job_status_history` holds
one entry per status, each with the day it happened and the person who reported
it, and is added to and never changed. That is the only shape that can answer
"when did we hear"; an overwritten column cannot, however many columns it is
given.

The nine, which are the owner's list: Applied, Employer responded, Interview
scheduled, Interviewed, Offer, Hired, Declined by employer, Client withdrew, No
response.

**The eight words stay, and this is the part worth understanding.** Seven
database functions, four views and most of the leads board read
`lead_matches.status`, so it is maintained as the latest entry rather than
abolished, and `lead_status_for_application` is the one place the nine words
and the eight meet. Two of the nine map quietly on purpose:

'No response' leaves the application reading 'Applied'. Nothing happened, so
nothing on any other screen has changed - and the note trigger fires on that
column, so mapping it to anything else would write a sentence into 202 clients'
contact records saying that nothing happened.

'Employer responded' and the two interview statuses collapse, because what the
eight words are asked for is whether an application is over and roughly how far
along, and both pairs answer the same.

Whether to collapse the two vocabularies into one is the owner's decision and
is not taken here: it is 281 rows, 30 call sites and a rename of 'Not
selected' and 'Withdrawn', which is report-first work.

### What the 281 applications already on file have been through

Derived, never invented. A row that records applied_on was applied for on that
day; a row that says 'Not selected' was declined. Both are written as the
entries they are, and the fourteen rows at 'Interview' split on
interview_result, which 0117 added for exactly that question - the six saying
'Done' become 'Interviewed' and the other eight 'Interview scheduled'.

None of the 58 applications past Applied has a decided_on, because the import
that created them carried no decision date, so those entries are dated the day
the practice's own record last said so and their note says the date is not a
known one. Nothing invents a date it does not have.

274 applications have history; the 7 at 'Saved' have none, because a job
somebody saved to try is not an application and gets its first status when it
becomes one.

**The seed changed nothing, and the migration proves it rather than claiming
it.** The last thing in the file asserts that every application still holds
exactly the word it held before the file ran, which is true if and only if the
mapping is faithful to what was on file. It failed on the first run, on 52 of
the 281:

`created_at` defaulted to `now()`, which is fixed for a whole transaction. An
application carried over as "applied, then declined" got two entries with the
identical timestamp, and with the dates equal too - no decided_on, so both fell
back to the same day - there was nothing left to say which came last. Half of
them read as still Applied. `clock_timestamp()` fixes it, and an append-only
log wants real insertion order anyway.

### Nothing heard for a fortnight

'No response' after 14 days, overridable, in `/api/cron/chase` with the two
rules that are also about days passing. Overriding it is recording the next
status, which is what the table is for: the sweep reads the latest entry, so
once anything later exists it never speaks again about that application.

It notifies nobody and emails nobody. A notification about something not
happening, on every application that has gone quiet, is how a notification list
stops being read. On the day this ships it marks 202 applications, and the
place that says so is the client's Job Search tab, where somebody is already
looking.

### Two bugs the verification script found before anybody else could

**Removing a job stopped working.** The client's Job Search tab has offered
"Remove this job" since 0013. With the history cascading off the application
and an append-only trigger refusing every delete, that button became a sentence
about a record. The authorization correction log has had the exception for
years - a row being carried off by the cascade behind a deleted parent is not
being edited by anybody - and `application_is_gone` is the same question asked
about an application. The script asserts both halves: a removed job takes its
history with it, and an entry whose application is still there cannot be
deleted by anybody, including something privileged.

**A back-dated entry could move an application backwards.** Somebody recording
on Thursday that the employer rang on Monday, after Tuesday's interview is
already on file. The trigger recomputes the latest from the history rather than
taking the entry just written, and the fixture for it is in the script.

### And one from building the check

`check-job-status.mjs` asks the places the two vocabularies are written down
rather than trusting them: the nine in `lib/constants` against the nine in the
migration's check constraint, every one of the nine against a word the mapping
gives it, and every word the mapping gives against the eight `lead_matches`
accepts - which is the half that breaks silently, since a mapping to "Rejected"
would satisfy everything else and fail on the first person to record one.

Two of its first assertions asked a question merely near the rule, which is the
failure CLAUDE.md says to suspect first:

"the route reads NO_REPLY_DAYS" passed with `p_days: 14` hard-coded, because
the import line still mentioned the name. It now reads the call.

"the trigger says 'never changed or removed'" - the phrase `merge_clients`
looks for in the catalogue - passed with the exception message rewritten,
because the section above the trigger is headed with those words in a comment.
It now reads the function body.

### Part of the record

A records request asks for everything on file about a person, and the bundle
disclosed the application row and would have disclosed none of its statuses.
`verify_records_request.sql` could not have caught it: it walks the tables
carrying a `client_id` and `job_status_history` carries none, reaching the
client through the application the way `service_entries` reaches it through its
authorization. Both are disclosed inside their parent's section, which is what
0271 does, and the assertion holding it there needed `is distinct from` rather
than `not (... = ...)` - with the section missing the comparison is null, so
the fault fell through and reported the wrong thing.

21 assertions in verify_job_lead_status.sql, 6 in check-job-status.mjs, 1 added
to verify_records_request.sql. Eighteen faults injected, eighteen caught, three
of them only after the check or the fault itself was corrected.

## Chat becomes Team (30 Oct 2026)

The owner asked for a staff chat with four new tables. Most of it was already
built, under a different name, by 0104 and 0106 - `conversations` with
`kind = 'internal'`, `conversation_participants`, `messages`, `read_receipts`,
with Supabase Realtime already published on three of them, groups, threads
about a client, mentions, five minutes to correct a message, read receipts, and
search. It was in the navigation as Communication → Chat.

Reported before anything was built, and the owner's answer was to extend it
rather than build a second one. Which is the right answer and worth saying why:
four new tables would have given the practice two inboxes, two unread counts,
and messages about one client split across two systems.

**What was actually in there, which is the reason extending is cheap:** four
internal conversations, all direct, two people each, no titles, none about a
client, none archived - and eight messages in five weeks. One had been edited;
none removed; no attachments anywhere. 229 of the 245 messages in the table are
texts and 8 are website chat. Nobody had ever started a group, which is a fair
description of what happens when starting one is a decision somebody has to
make before they can say anything to the practice.

### Everybody is in one group

So one group exists without anybody starting it. `conversations.system_key`
finds it again - a title would not do, because titles are typed by people and
this one has to be the same row tomorrow after somebody has renamed it.

Membership is a trigger on `staff` rather than a step in the screen that hires
somebody, so it holds for the screen, for an import, and for a correction run
months from now. Deactivating sets `left_at` rather than deleting the row: what
somebody said stays where they said it, which is 0106's rule for leaving a
group and the only version of this that leaves a readable conversation behind.
Rehiring clears it rather than adding a second row.

Two triggers refuse what every other conversation allows: it is not left, and
it is not archived. Leaving the group everybody is in is a thing somebody would
do once and then never be told anything by the practice again; archiving it
would do that to all of them at once. The message says what to do instead -
turn off the pop-up.

### The three rules kept rather than replaced

The brief reversed three decisions already made and written down. The owner
kept all three, and each is now asserted rather than remembered:

The pop-up shows who sent it and which thread, and **not the words** - a
message may be about a client and the screen may be in a room with somebody who
should not read it. A person who wants the first line turns on "Show the message
in the pop-up", which is off until they do.

Files attach **by reference**, never a second copy, so a file keeps its own tier
and retention. Dragging or pasting one uploads it and then attaches it by
reference like anything else - which needed somewhere for it to go, because
`attachments.client_id` is `not null` and its storage policy joins through it.
`chat_files` is the one table this needed, and it is not one of the four:
there is no second conversation, no second message, no second membership. A
dropped file is internal until somebody files it on a client deliberately.

`remove_message` stays: the author taking their own words back blanks the body
and leaves the marker.

### A message can be taken off the screen, and that is not deleting it

Admin hiding a message is a different act from an author taking their own words
back, which is why both exist. Hiding keeps the words and shows them to Admin
alone, because a thing taken down is still something that was said and Admin is
who has to answer for it.

The log is a table and not a column. A column would say the message is hidden;
it would not say that it was hidden on Tuesday, shown again on Wednesday
because the complaint was wrong, and hidden again on Friday. A moderation
decision that can be reversed needs the history of the decision, which is why
`client_corrections` is a table too.

**Four places read messages and all four had to be changed.** The read policy,
`search_messages`, `my_unread` and `client_chat_mentions` each decide for
themselves, because three of them run as their owner and a policy does not
reach inside a SECURITY DEFINER function. Three agreeing and one not is a
message somebody took down coming back in a search, and `check-team-chat.mjs`
asserts all four.

### Where it lives

Team is in the sidebar directly below the main tabs, with its own unread count
- `my_unread`, not the Inbox badge beside it. The Inbox badge is what is
waiting from outside the practice; a colleague's question is a different
question, and they were one number.

Clicking it opens a pane from the right over whatever page is open, and the
page keeps its scroll, its half-filled form, its unsaved authorization.
Answering a colleague should not cost somebody the thing they were doing, which
is the whole reason it is a pane and not a route - a navigation would unmount
it. It is still a link to /team, so a middle click and a browser without
JavaScript both get the full page.

The screen moved from `/messages` to `/team` by becoming a component: the page
is rendered by /team rather than copied into it, because two files drawing one
screen is two files to change and the forgotten one is the one somebody is
looking at. `/messages` redirects, carrying its query string, because `?c=` is
which thread somebody was sent to.

### Three checks had to learn something

Moving a screen out of a hub broke three checks, each for a good reason, and
each fix makes the check say more rather than less:

`canReach` gates typed URLs against the navigation, so a screen in no hub is
refused - which would have locked everybody out of Team and out of the
`/messages` redirect, since the gate runs before the page does.
`SIDEBAR_SCREENS` names them, and **check-nav asserts each one is really opened
from the sidebar**, so being in no hub cannot become the place unreachable
screens go to be forgotten. That assertion reads the layout and the components
the layout renders: an earlier version read the layout and then waved the
component through by name, which would have passed for any path at all.

check-screens wanted a title and a way back on the redirect. A page whose whole
job is to send somebody somewhere else is not a screen - nobody reads it. The
first test for "is a redirect" was "has no angle bracket", which failed on
`Promise<Record<…>>`: a type is not a screen. What makes it a redirect is that
it renders nothing.

check-theme caught three house-style violations in the pane's CSS: two colours
written out instead of `--scrim`, a duration of its own instead of `--motion`,
and `opacity: 0` on something with text in it. All three were mine and all
three were right - the pane now slides and nothing fades.

### Two of the new check's assertions asked a question near the rule

"the pop-up has a preview setting" passed on the import line alone. It now
asserts the narrow thing: every read of the arriving message's body is guarded
by the setting, in the same expression.

"a file is attached by reference" asked whether the three kinds appear, which
passed with a fourth appended. It now asks what the list *is*.

### Not applied

The four migrations are written and dry-run green against production inside a
rolled-back transaction - 26 assertions in `verify_team_chat.sql` and 14
behavioural ones besides - but **they are not applied**: the auto-mode
classifier refused both `run-sql.mjs` and the migration tool as a production
deploy. Everything that does not need them is live.

26 assertions in verify_team_chat.sql, 8 in check-team-chat.mjs, 30 checks in
prebuild. Twenty-seven faults injected, twenty-seven caught - three of them
only after the check or the fault itself was corrected, and one "miss" that
turned out to be Git Bash rewriting `/team` into a Windows path before the
fault could be applied.

## The rest of Team chat (30 Oct 2026)

0272-0275 applied, and the half that needed them built: File to client, the #
client chip, "mentioned in Team chat" on the record, dropping a file into a
thread, and the Teams meeting button.

### Two scripts in the suite broke, and both were right to

**The load test counted 51 conversations where it expected 50.** The Everyone
group is a real conversation the fixture's staff member is in, because the
trigger put them there the moment they were hired. The assertion now expects
50 plus however many groups the practice keeps, counted rather than written as
51 - so the next kept group does not break it again, and the query being timed
is still the real one over everything the person is actually in.

**verify_staff_chat named `post_message(uuid, text, jsonb, uuid[])` by hand**,
in a grant assertion, and 0274 gave the function a fifth parameter. So the
script failed where it should have passed - which is the lucky direction.
Written the other way round it would have been worse: an assertion about a
function that is not there passes, quietly, for ever. It now asks the
catalogue for every overload of each function it cares about, and asserts
separately that `post_message` exists at exactly one signature.

### File to client

A message onto a client's record, with one of the eight categories chosen. A
copy, not a move: the thread is what happened and the note is what the
practice decided was worth keeping about a person. The note says whose words
they were, because whoever reads it in six months is not whoever filed it.

"Contact-log entry with category" needed reading. `contact_log` is the
counselor contact log and has no category; the thing on a client's record that
carries one of the eight and feeds the monthly report is `notes`. So it writes
a note, and the report picks it up without anything else being changed.

The client is searched through `search_clients` - the same matching the Ctrl+K
box uses - rather than listed, so what this finds and what the rest of the CRM
finds are the same thing, and a thread is not holding the whole caseload in a
select.

The category has no default. 0266 would fill one in from the client's stage,
which is a guess, and 'Personal' narrows the note to Admin and Case Manager -
not a decision anybody should make by leaving a field alone.

A dropped file goes the same way, except that storage cannot be copied from
SQL: the bytes are copied with the service key and then
`file_chat_file_to_client` checks the rules and writes the attachment row. If
the row is refused the copy is removed again, because a file sitting in the
client's bucket with no attachment row is a document on somebody's record that
the record does not know about.

### The # chip

Built on the @ machinery that was already in the composer rather than beside
it: one caret rule, one menu, one keyboard behaviour. The difference is that a
client's name has spaces in it, so # runs to the end of what has been typed
rather than to the first space.

A chip stays only while its name is still in the message, so deleting the words
deletes the chip. What goes to the database is the id.

And the client's record shows a **link and never the words**: who was talking,
which thread, when. Somebody naming a client in a thread is not writing a note
about them - the conversation belongs to the people in it until one of them
decides it belongs on the record and files it.

### The Teams meeting button

Through the person's own Graph connection, so the meeting is theirs. The CRM
keeps the join link, in the thread and on the client's record, and nothing
else: no recording, no transcript, no attendance.

`OnlineMeetings.ReadWrite` is asked for separately, like Mail.Send and for the
same reason - the owner grants it in Azure first and each person consents once
on their own connection. Until then the button says "Not connected yet", which
is read off the connection's scopes rather than discovered by calling Graph
and showing somebody a Microsoft consent error page.

### Three things only a static check can hold

Each is a decision the screen makes before it calls anything, so the database
cannot be asked to enforce it:

A # chip is sent as a reference. A screen that put the client's name in the
body and nothing in `p_clients` would look identical to somebody typing, and
the client's record would know nothing.

Filing is a copy. A screen that removed the message after filing it would pass
every database assertion, because the database is not asked to stop it.

A dropped file is attached by reference. A screen sending the storage path in
the message body would be a second copy by another name.

28 assertions in verify_team_chat.sql, 11 in check-team-chat.mjs, 125 verify
scripts and 30 prebuild checks green. Seven more faults injected, seven
caught - one after the fault itself was corrected, because removing an import
is a compile error rather than something a check has to notice.
