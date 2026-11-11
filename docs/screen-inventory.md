# Zion CRM — screen inventory

Read from the code on 11 Nov 2026, before the phone app and before any simplification (nothing was run). Sources: `lib/roles.ts`, `lib/client-tabs.ts`, `lib/quick-add.ts`, `lib/constants.ts`, `app/(app)/layout.tsx`, `bottom-bar.tsx`, `group-tabs.tsx`, `nav-links.tsx`, `dashboard/page.tsx`, and every `page.tsx` under `app/(app)` with the components it renders. "(inferred)" means I counted from a component list or a section I did not read line by line.

## How taps are counted

- The phone path starts on Home (`/dashboard`). On a phone (<760px) the sidebar is hidden and the bottom bar shows **Home, Clients, My work, Communication, More**.
- One tap each for: a bottom-bar item, a hub card, a tab (the group tab strip *is* shown on phones), a row or card, a button, a dropdown (opening it and picking counts as 1), and the final submit. Typing does not count.
- **Getting to a client record** through the bottom bar takes 3 taps: Clients (1) → card on the Board (2), which opens a side panel → "Open the record" (3). `/clients` opens on the Board, which shows only active clients. The header search box is shorter: tap the box (1), type, tap the result (2).
- **"+" quick add** (on every screen): + (1) → kind (1, but "Note" is already selected) → client dropdown (1) → submit (1). Kinds by role (`kindsForRole`, which looks at the **role only**):

| Role | "+" kinds |
|---|---|
| Admin | Note, Task, Job, Interview, Placement, Work session, Log hours, Add authorization, File (9) |
| Job Search | Note, Task, Job, Interview, Placement, Work session, Log hours, File (8) |
| Reports (Margaret) | Note, Task, Job, Interview, Placement, Work session, File (7). Her billing grant does **not** add Log hours or Add authorization. |
| Billing | Work session, Log hours, Add authorization, File (4) |
| Job Coach | Note, Task, Job, Interview, Placement, Work session, Log hours, File (8) |
| Case Manager | Note, Task, Job, Interview, Placement, Work session, File (7) |

- **Clock in** is one tap in the header on every screen (Clock in → Start break / End break → Clock out).
- **Where "More" goes** on a phone: the first group not on the bar (`rest[0]`).
  - Admin and Billing: More → `/billing` (Overview).
  - Reports with a billing grant: More → `/billing` (inferred: the grant makes Billing items visible).
  - Job Search, Job Coach, Case Manager, and Reports without the grant: More → `/requests` (Purchase requests).
  - The HR and Admin groups have no way in from the phone nav at all (see the "Landings" section).

Roles key: **A** Admin, **JS** Job Search, **R** Reports (Intake & Client Reports), **B** Billing, **JC** Job Coach, **CM** Case Manager. "+grant" means the screen opens with the matching area grant.

---

## Home group (bottom bar: Home)

| Route | Title | Roles | Primary actions (n) | Main task | Taps | Hard words | >4 actions |
|---|---|---|---|---|---|---|---|
| `/dashboard` | Today · <weekday, month day> | All | Start work session (A, JS, B, JC only) / End work session / Save the session; Reply; Mark read; Match to client; Create referral; Spam; Open (notification); Hide until tomorrow; Log hours (past appointment); Outlook; task row Mark complete / Remove / due date / assigned to (A); Connect Outlook / Sync now / Disconnect (≈12) | See what is waiting and act on it from the row | 0 to see; replying to a text is Reply (1) → Send (2) = 2 | Work session, Notifications "raised by the practice", "authorization short of hours", "counselor follow-up", caseload, stage, Sync, "the number on Inbox" (no screen is called Inbox: the group is Communication). Keep: authorization, counselor | **yes** |
| `/dashboard/needs` | Needs attention | All (by `/dashboard` prefix); linked only from Admin's "The business" cards | 0 (list switcher: Tasks due, Interviews, Follow-ups due, Inactive clients, Missing paperwork) | Read one of the practice-wide lists | A: Home → business card (1) | Follow-ups, Inactive, Missing paperwork. Keep: authorization | no |
| `/my-day` | My day · <date> | All | It happened; It did not happen; Wrong client; Assign it; Discard; task Mark complete / Remove (7) | Today in time order, plus "Reports due" and things to file | Home → My day tab (1) | Placement, Assessment, Job development, period, "To file". Keep: — | **yes** |

## Clients (bottom bar: Clients)

| Route | Title | Roles | Primary actions (n) | Main task | Taps | Hard words | >4 actions |
|---|---|---|---|---|---|---|---|
| `/clients` (Board) | Clients | All. Close: A, R, B | On a card: Move (stage), Make inactive, Close, Open the record, Write (5) | Open a client, or move a card to its next stage | Clients (1) → card (2) → Open the record (3) = 3; moving a stage: → stage dropdown (3) → Move (4) = 4 | Stage names (Intake, Assessment (WSA), Job Development, Life Skills, Job Placement), Board, "Make inactive" vs "Close". Keep: counselor | **yes** |
| `/clients?tab=all` | Clients | All. Add referral: A, JS, R, JC, CM. Delete: A | Add referral → Save referral; Save this view; Apply / Clear filters; Sort; Put on / Take off the board; Delete (6) | Add a new referral | Clients (1) → All clients (2) → Add referral (3) → Save referral (4) = 4 | Referral, caseload, billing office, funding source, flagged for review, "Saved view". Keep: counselor | **yes** |
| `/clients/[id]` header (on every tab) | <client name> | All. Each button is gated by role (below) | Log a visit (A, B, JS, JC, +billing grant, only with a coaching authorization); Report & bill (only when there is something to bill); Job update; Message; Email counselor (only with a counselor email); Add note; Add task; Send report (5–8) | — | — | USOR ID, "Report & bill", "Log a visit", stage, unbilled. Keep: counselor | **yes** (on every tab) |
| `/clients/[id]?tab=activity` | <client name> | All | Header + Write (mail), Reply, Open in Outlook, Start the thread, Save and add to Outlook, Not this one, Remove, Exclude thread (header + 8) | Read what has happened with this client | Record (3) → Activity is the default tab = 3 | Thread, Exclude thread, Outlook, Coming up | **yes** |
| `/clients/[id]?tab=profile` | <client name> | All read. Edit: A, JS, R, JC, CM; client details also B. Intake: those five. Delete: A | Save details; Show more details; Move stage; Add a number; Add a contact; Record consent / Record it; Take it off; Withdraw consent; Open the intake record → Submit / Update intake; Delete this client… (≈10) | Finish intake (R) | Record (3) → Profile (4) → Open the intake record (5) → Submit intake (6) = 6 | Intake, restricted, consent, guardianship, release of information, stage history, Directory history. Keep: counselor | **yes** |
| `/clients/[id]?tab=notes` | <client name> | All. Add: A, JS, R, JC, CM (inferred: writing is checked server side) | Add note; Replace it with the <type> headings (2, plus header) | Add a note | Record (3) → Add note (4) → Add note (5) = 5. "+": + (1) → client (2) → Add note (3) = **3** | Note headings, note type | yes (header) |
| `/clients/[id]?tab=jobs` | <client name> | All. Edit: A, JS, R, JC, CM | + Add job → Add job; Edit / Save; Remove this job; Record it (application status); History; Create placement → "Yes, create it"; Save placement; Add placement (7) | Log a job application | Record (3) → Job update (4) → + Add job (5) → employer dropdown (6) → Add job (7) = 7. "+": + (1) → Job (2) → client (3) → employer (4) → Add job (5) = **5** | Placement, "Create placement", application status, CIE (on the placement form, inferred) | **yes** |
| `/clients/[id]?tab=billing` | <client name> | All read. Act: A, B, +billing edit. Others see "Read-only for your role." | Add an authorization (expander) → Save authorization; group filter chips; open an authorization (2–3) | See this client's authorizations | Record (3) → Billing (4) = 4 | Authorizations grouped by status, units, carried hours, unbilled, "Paid & outstanding". Keep: authorization | no (header still makes it yes) |
| `/clients/[id]?tab=documents` | <client name> | All. Restricted files: A, R, the assigned staff member, +restricted grant | Reports; Send report → Copy / Download / Email to <counselor>… → Send to <email>; open USOR form; Attach (file); Rename; Open; Remove (≈8) | Send a progress report; add a file | Send report from the header: Record (3) → Send report (4) → Email to… (5) → Send to… (6) = 6. File: "+" → File (2) → client (3) → Attach (4) = **4** | Progress report, "USOR forms", restricted, categories. Keep: counselor | **yes** |
| `/clients/[id]?tab=messages` | <client name> | All read. Send: A, JS, R, JC, CM. Portal: A, R, the assigned staff member, +restricted | Send; Send at <time>; Do not send; template chips; Save template; Record consent; Retry; Give portal access → Give access; Send the invitation; Message in portal; Turn off access; Sign everyone out of the portal; Ask in portal; Approve; Send back; Accept; Withdraw (≈17) | Text the client | Home "Reply" (1) → Send (2) = 2; from the bar: Record (3) → Message (4) → Send (5) = 5 | Consent, portal, "Sign everyone out", scheduled send, mentions, résumé request. Keep: — | **yes** |
| `/clients/[id]/reports` | Reports | Open: all. Act: A or the client's assigned staff member | Draft it; Assemble it; Confirm; Save; Reopen; Read the record again (6) | Confirm the weekly report (R, CM) | Home → My day (1) → "Reports due" row (2) → Confirm (3) = **3**. From the bar: Record (3) → Documents (4) → Reports (5) → Confirm (6) = 6 | Assemble, Draft, "Read the record again" | **yes** |
| `/clients/[id]/reports/[month]` | <report title, month> | Open: all. Sign: A or the report's owner | Save; Mark read; Sign it; Send it; Reopen; Assemble it again from the weeks; The signed PDF (7) | Sign and send the monthly report | My day (1) → Reports due row (2) → month row (3) → Sign it (4) → Send it (5) → Send on New message (6) = **6** | Assemble, signed PDF. Keep: counselor | **yes** |
| `/clients/[id]/forms/[formId]` | <USOR form name, e.g. USOR 95> | All open. Fill: A, B and the editing roles (inferred) | Add row; Save draft; Sign and lock; Email the form; Preview the email; Attach; Fill again from the record (7) | Fill in and sign a USOR form | Record (3) → Documents (4) → form row (5) → Sign and lock (6) = 6 | Sign and lock, readiness. Keep: authorization, counselor. Forms are exempt from the copy length rules | **yes** |

## My work hub (bottom bar: My work)

| Route | Title | Roles | Primary actions (n) | Main task | Taps | Hard words | >4 actions |
|---|---|---|---|---|---|---|---|
| `/my-work` | My work | All. Cards: A/JS/R 11; JC/CM 10 (no "My clients"); B 9 (no Tasks or My clients) | 0 (cards) | Pick a screen | My work (1) | — | no |
| `/tasks` | Tasks | A, JS, R, JC, CM (tasks area), +tasks grant. Not B | Add task; Mark complete; Remove; Reopen; Put it back; How did it go? → Done; Add a step; Say it; Save (9) | Add or finish a task | Finish: Home task row Mark complete (1) = 1. Add: "+" → Task (2) → client (3) → Add task (4) = 4 | "Say it" (a button that adds a note), steps, repeat | **yes** |
| `/my-clients` | My clients — what is next | A, JS, R | 0 forms (each next-action is a link) | See what is due on each client | My work (1) → My clients — what is next (2) = 2 | Caseload, stage | no |
| `/leads` | Jobs | All open. Edit: A, JS only | Add opening; Add employer; Save (inline edits) (3, inferred) | Add an opening | My work (1) → Jobs (2) → Add opening (3) → Add opening (4) = 4 | Openings, "Putting a client forward", placement, retention | no |
| `/leads/[id]` | <opening title> | All open. Edit: A, JS | Status Save; Add (put a client forward); application status Save; Create placement… → Create placement (4) | Put a client forward for an opening | Jobs (2) → opening row (3) → client dropdown (4) → Add (5) = 5 | Put forward, match, placement | no |
| `/counselors?tab=directory` | Counselors | Open: all. Directory, Contact log and Hours requests: A, JS, B, JC, +counselors grant. R and CM see only Colleagues | Add (counselor); Save (billing office) ×2 (3) | Look up a counselor | My work (1) → Counselors (2) = 2 | Billing office, caseload, agency. Keep: counselor | no |
| `/counselors?tab=contact` | Counselors | As above | Log contact (1) | Log a call to a counselor | My work (1) → Counselors (2) → Contact log (3) → Log contact (4) = 4 | Contact log. Keep: counselor | no |
| `/counselors?tab=hours` | Counselors | As above | Submit request; Save (response) (2) | Ask a counselor for more hours | … (3) → Hours requests (3) → Submit request (4) = 4 | Hours request. Keep: authorization, counselor | no |
| `/counselors?tab=colleagues` | Counselors | All | Message (1) | Find a colleague's number | My work (1) → Counselors (2) → Colleagues (3) = 3 | — | no |
| `/counselors/[id]` | <counselor name> | A, JS, B, JC, +counselors grant | Save; Move (office) (2) | Edit a counselor's details | Counselors (2) → row (3) → Save (4) = 4 | Directory history, office. Keep: counselor | no |
| `/hours` (Your time) | Time & statements | All | Start work session / End work session / Save the session / Discard; Log; Correct → Save correction; Save (category) (5) | Log a work session by hand | My work (1) → Time & statements (2) → Log (3) = 3. "+": + (1) → Work session (2) → Add work session (3) = 3 | Work session, period, category, "append-only" (in "+") | **yes** |
| `/hours?tab=statements` | Time & statements | Contractors only | Submit statement; Claim (expense); Remove; Set it (mileage rate) (4) | Submit the period's statement | My work (1) → Time & statements (2) → Statements (3) → Submit statement (4) = 4 | Statement, period, mileage, expense | no |
| `/hours?tab=approvals` | Time & statements | A only | Approve; Return… → Return; Reopen; Open the statement (4) | Approve a contractor statement | My work (1) → Time & statements (2) → Statement approvals (3) → Approve (4) = 4 | Statement, contractor | no |
| `/time-clock` | Time clock | All | Start work session / End work session / Save the session / Discard; That is right (2–3) | Clock in or out | Header Clock in = **1**; via the screen: My work (1) → Time clock (2) → Start work session (3) = 3 | "Sessions closed for you", period. "Clock in" (header) and "Start work session" (this screen, Home) start the same timer under two names (inferred: both read `work_session_timers`) | no |
| `/end-of-day` | My end of day | All | Add; Change → Save; Remove this line; Paste a report → Read it; Submit day; Reopen (6) | Submit the day | My work (1) → My end of day (2) → Add (3) → Submit day (4) = 4 (one line) | Bottlenecks ("what got in the way"), roll-up. Keep: authorization | **yes** |
| `/paperwork` | Paperwork | All. "Everyone's paperwork" table: A | Sign and file (W-4 / W-9 / W-8BEN); Save (e-delivery consent); Save signature; Remove it; Open; Claiming a tax treaty benefit? (≈6) | Sign your tax form | My work (1) → Paperwork (2) → Sign and file (3) = 3 | W-4, W-9, W-8BEN, 1099, I-9, EIN/TIN, e-delivery, tax treaty, natural supports | **yes** |
| `/paperwork?tab=certifications` | Certifications | All | 0 (read only, inferred) | See when a certification runs out | My work (1) → Certifications (2) = 2 | Credential, certification | no |
| `/paperwork/onboarding` | Onboarding | All (the layout forces new staff here). Team table: A | Save and continue; Upload; Add <document>; Put forward; That is everything I hold for now; Sign; Save; Go to the dashboard (8) | Finish first-day setup | Forced landing; 1 tap per step | Onboarding, I-9, W-4, "Put forward", "dashboard" (the nav calls it Home) | **yes** |
| `/paperwork/policy` | Data-handling policy | All (forced when a new version is due) | Sign (1) | Sign the new policy | Forced landing → Sign (1) | Data-handling, version | no |
| `/sops` | Knowledge base | All. Edit: A | Save procedure; Add procedure (2) | Read how something is done | My work (1) → Knowledge base (2) → shelf item (3) = 3 | Procedure, shelf, SOP (in the route only) | no |
| `/sops/where` | Where do I…? | All | 0 (links) | Find which screen does a thing | Knowledge base (2) → Where do I…? (3) = 3 | Lists every screen by name, so the jargon of all of them shows up here | no |
| `/forms-and-checklists` | Forms and checklists | All | Fill one in → Save it (1 per form) | Record a visit or worksite check (JC) | My work (1) → Forms and checklists (2) → Fill one in (3) → client (4) → Save it (5) = 5 | Worksite check, incident, checklist | no |

## Communication hub (bottom bar: Communication)

| Route | Title | Roles | Primary actions (n) | Main task | Taps | Hard words | >4 actions |
|---|---|---|---|---|---|---|---|
| `/communication` | Communication | All. Cards: 6 for A/JS/R; 5 for others (no Weekly updates) | 0 | Pick a channel | Communication (1) | — | no |
| `/mail` | Mail | All (needs Outlook connected) | New message; Search; Reply; Reply all; Forward; Delete → Move to Deleted Items; File to client; Take off <client>; Keep on the record; Restrict; Connect Outlook / Turn sending on (≈11) | Read and answer mail | Communication (1) → Mail (2) → message row (3) → Reply (4) → Send (5) = 5; Home tile → message (2) | Outlook, File to client, restricted, mailbox, "Keep on the record" | **yes** |
| `/mail/compose` | New message | All | Send (1) | Email a counselor | Record (3) → Email counselor (4) → Send (5) = 5 | Template. Keep: counselor | no |
| `/messages/texts?tab=texts` | Texts & web | All. Assign / match / referral: A, JS, R, JC, CM | Answer / Open thread; Assign; Match to a client → That is them; Create a referral → Start a referral; Spam / Not spam (≈6) | Answer a client's text | Communication (1) → Texts (2) → Answer (3) → Send (4) = 4; Home Reply (1) → Send (2) = **2** | Portal, spam, referral, "unknown number". Keep: — | **yes** |
| `/messages/texts?tab=web` | Texts & web | All | Answer; Send; Assign (3) | Answer a website visitor | Communication (1) → Website chat (2) → Answer (3) → Send (4) = 4 | Website chat, visitor | no |
| `/calendar` | Calendar | All | New appointment; Edit; Save and add to Outlook; Connect Outlook (4) | Book an appointment | Communication (1) → Calendar (2) → New appointment (3) → Save and add to Outlook (4) = 4 | Outlook | no |
| `/messages/weekly-updates` | Weekly updates | Open: A, JS, R. Send: A, JS, R | Draft this week now; Send all approved (n); Save the wording; Approve / Back to a draft; Send it; Do not send (6) | Approve and send the Friday texts | Communication (1) → Weekly updates (2) → Approve (3) → Send it (4) = 4 per client | Draft, approved, consent | **yes** |
| `/updates` | Updates | All. Post / take down: A | Post an update → Post it; I have read this / Mark as read; Take it down (3) | Read and acknowledge a post | Communication (1) → Updates (2) → I have read this (3) = 3 | — | no |
| `/team` (and `/messages`, which redirects here) | **Messages** (the sidebar calls it Team) | All. In the sidebar only; on a phone it is reached through the floating chat bubble | Search; Open conversation; Start the group; Send; Attach; Add someone; Correct; Remove; Leave; Archive; File to client; Start a Teams meeting; Email me after 30 minutes away; On/Off settings; Allow desktop notifications (≈15) | Message a colleague | Bubble (1) → conversation (2) → Send (3) = 3 (inferred) | Thread, archive, mention, Teams, digest | **yes** |

## Billing group (phone: More, for A, B and R with a grant; for everybody else More opens Purchase requests)

| Route | Title | Roles | Primary actions (n) | Main task | Taps | Hard words | >4 actions |
|---|---|---|---|---|---|---|---|
| `/billing` (Overview) | Billing | A, B, +billing grant | Add authorization (header). **Bug (inferred from code):** the link is `/billing#new-authorization`, which renders Overview, and that section exists only on the Authorizations tab (1) | See the month | More (1), or the Home Billing tile (1) | Needs billing, Waiting on USOR, voucher, short-paid. Keep: authorization, warrant | no |
| `/billing?tab=authorizations` | Billing | A, B, +billing grant (edit to act) | Open (pending document) → Confirm / Replace <n> with this number; From the PDF (import); Type it in → Save authorization; Mark n paid; Close n; Record payment; Set aside; Needs action / All / Stale (≈8) | Confirm an authorization the inbox found (B) | More (1) → Authorizations (2) → Open (3) → Confirm (4) = 4. **Bug (inferred):** `hrefFor` builds `/billing?doc=…` with no `tab=authorizations`, so "Open" lands on Overview and the document does not open | Stale, proposal, carried, bill-by date, packet, units. Keep: authorization, warrant | **yes** |
| `/billing?tab=hours` | Billing | A, B, +billing grant; logging also JS, JC | Log; Save; Earlier / Later (2) | Log billable hours | More (1) → Service log (2) → authorization (3) → Log (4) = 4. "+": + (1) → Log hours (2) → authorization (3) → Log the hours (4) = 4 | Service log, coaching codes ("natural supports", "worksite sups"), non-billable. Keep: authorization | no |
| `/billing/authorizations/[id]` | <client> — <service>, <month> | A, B, +billing grant (edit to act) | Send the packet and mark it submitted; Mark ready to bill; Record (delivered); Move it; Close it; Open it; The hours were not logged yet; There was no service this month; Produce <USOR form>; Record the payment; Save the record; Set it; Move it (≈13) | Send the invoice packet (B) | Home Billing tile (1) → "Needs billing" row (2) → Send the packet… (3) = **3** (+1 if a form must be produced first) | Packet, submitted, bill-by, delivered, billing office, short-paid, voucher, "Produce USOR 95". Keep: authorization, warrant, counselor | **yes** |
| `/billing/invoices` | Invoices | A, B, +billing grant (view); Record: edit | Export; Record it (a query); Done (3) | See what USOR owes | More (1) → Invoices (2) = 2 | Short-paid, query, period, export. Keep: warrant | no |
| `/billing/warrants` | Warrants | A, B, +billing view. Not in nav: reached from Money insights and the "Every warrant received" link | Record payment; Set aside (2) | Match a warrant to an authorization | More (1) → Authorizations (2) → "Every warrant received" (3) → Record payment (4) = 4 | Voucher, reconcile, workbook. Keep: warrant, authorization | no |
| `/books` | Books | A, B, +billing grant | 0 (10 cards) | Pick a ledger screen | More (1) → Books (2) = 2 | Ledger, chart of accounts, journal, reconcile, trial balance, balance sheet, CPA | no |
| `/books/reports` | Reports | A, B, +billing | Show; Download CSV (2) | Run a financial report | Books (2) → Reports (3) → Show (4) = 4 | Accrual, payables, aging, P&L, CSV | no |
| `/books/budget` | Budget | A, B, +billing. Edit: A | Show; Save this account; Download CSV (3) | Set the budget | Books (2) → Budget (3) → Save this account (4) = 4 | Account, period | no |
| `/books/forecast` | Forecast | A, B, +billing. Edit: A | Save (1) | Read the cash forecast | Books (2) → Forecast (3) = 3 | Forecast, pipeline, net. Keep: authorization | no |
| `/books/vendors` | Vendors | A, B (edit), +billing | Add a vendor; Edit; Save (3) | Add a vendor | Books (2) → Vendors (3) → Add a vendor (4) → Save (5) = 5 | Vendor, 1099, W-9, EIN | no |
| `/books/bills` | Bills | A, B, +billing. Approve / pay: A | Enter a bill → Enter; Add a recurring bill → Add; Deal with → Approve / Schedule / Mark paid / Void (6) | Enter a bill | Books (2) → Bills (3) → Enter a bill (4) → Enter (5) = 5 | Post, void, schedule, recurring | **yes** |
| `/books/assets` | Equipment | A, B, +billing. Edit: A | Add something → Add; Hand on → Record it; Dispose; Save (4) | Record equipment | Books (2) → Equipment (3) → Add something (4) → Add (5) = 5 | Dispose, depreciation, "Hand on" | no |
| `/books/bank` | Bank statements | A, B, +billing. Add: A | Add a bank account → Add; Import (2) | Import a statement | Books (2) → Bank statements (3) → Import (4) = 4 | Import, statement, reconcile | no |
| `/books/bank/[id]` | <account> · <start> to <end> | A, B, +billing. Settle: A | Settle → Post / This is that posting / Set aside; Reconcile this statement (5) | Reconcile a statement | … (4) → statement row (5) → Settle (6) → Post (7) → Reconcile this statement (8) = 8 | Settle, post, posting, reconcile, ledger | **yes** |
| `/books/journals` | Journal entries | A, B, +billing. Write: A | Write an entry → Post; Reverse (2) | Correct the books | Books (2) → Journal entries (3) → Write an entry (4) → Post (5) = 5 | Journal, post, reverse, debit, credit | no |
| `/books/chart` | Chart of accounts | A, B, +billing. Edit: A | Add an account → Add; Set; Retire / Use again (3) | Add an account | Books (2) → Chart (3) → Add an account (4) → Add (5) = 5 | Chart of accounts, retire | no |
| `/books/close` | Closing | A, B, +billing. Close: A | Close; Reopen; Save; <year> package (4) | Close a month | Books (2) → Closing (3) → Close (4) = 4 | Close, accrual, 1099, package | no |
| `/requests` | Purchase requests | All. Decide: A | Ask to buy something → Ask; Decide → Approve / Decline; Save (the threshold) (4) | Ask to buy something | More (1) = Purchase requests for JS/R/JC/CM → Ask to buy something (2) → Ask (3) = 3; A: More (1) → Purchase requests tab (2) → Decide (3) → Approve (4) = 4 | — | no |

## HR hub (no route from the phone bar)

| Route | Title | Roles | Primary actions (n) | Main task | Taps | Hard words | >4 actions |
|---|---|---|---|---|---|---|---|
| `/hr` | HR | A; anybody who manages somebody (sees one card) | 0 | Pick an HR screen | **No phone route**. Desktop: sidebar HR (1) | — | no |
| `/end-of-day/team` | Team end-of-day roll-up | A; managers | 0 (filters, pages) | Read everybody's days | Desktop: HR (1) → roll-up (2); from your own end of day: "The team's days" (3) | Roll-up | no |
| `/admin/people` | People | A (`requireAdmin`) | Add and send invite; Send / Resend invite; Deactivate / Reactivate; Offboard; Mark done; Set rate; Verify; Inspected in person; Delivers job coaching; Transports clients; Add a document; Record it; Log; Remove (≈14, inferred) | Bring on a new person | Desktop: HR (1) → People (2) → Add and send invite (3) = 3 | Onboarding, offboard, I-9, verify, rate, certifications | **yes** |
| `/admin/people?tab=contractors` | Contractors | A | Record payment; Build the <year> run; Copy B; Filing CSV; IRIS CSV; Mark sent; Save; Remove; Change (9) | Run the year-end 1099s | Desktop: HR (1) → Contractors (2) → Build the run (3) = 3 | 1099, Copy B, IRIS CSV, W-9, recipients | **yes** |
| `/admin/people/[id]` | <person name> | A | Show personal details; Save; Give access; End access; Add; Remove (6) | Give someone extra access | People (2) → row (3) → Give access (4) = 4 | Grant, area, "view and edit", engagement, aliases, W-4/W-9/W-8BEN | **yes** |

## Admin group (Admin, and Document inbox for Billing; no route from the phone bar)

| Route | Title | Roles | Primary actions (n) | Main task | Taps | Hard words | >4 actions |
|---|---|---|---|---|---|---|---|
| `/admin/documents` | Document inbox & retention | A; B and +billing **edit** (inbox half only) | That is them; Not a client; New client from this document → Add them; Confirm / Attach the PDF and fill blank dates; Replace <n> with this number; Put it on this authorization; File it against the client; Set aside; Place hold; Lift; Record it; Change the period; I have checked this — confirm; Log the request; Gather it; Read an authorization PDF (≈16) | Review an arrived document (A) | **No phone route**. Desktop: Admin (1, lands here) → document row (2) → File it / Confirm (3) = 3 | Retention, hold, records request, agent runs, proposal, placeholder. Keep: authorization | **yes** |
| `/admin/documents/records-request/[id]` | Records request | A | Gather / mark sent (small, inferred) | Put together a person's full record | Documents (1) → request row (2) → Gather it (3) = 3 | Records request, access log, complete record | no |
| `/admin/settings-hub` | Settings | A | 0 (cards) | Pick a setting | Desktop: Admin (1) → Settings (2) | — | no |
| `/admin/settings-hub/organization` | The practice | A | Save (1) | Edit practice details | Settings (2) → card (3) → Save (4) | dba, EIN, rate schedule, reconcile | no |
| `/admin/settings-hub/notes` | Note headings | A | Save (1) | Edit note headings | as above | Note headings | no |
| `/admin/settings-hub/work` | Work and hours | A | Save (mileage rate, categories) (1–2) | Set work categories | as above | Mileage, period | no |
| `/admin/settings-hub/tax-years` | Tax years | A | Save (1) | Set this year's tax figures | as above | 1099, W-9, W-8BEN, thresholds | no |
| `/admin/settings-hub/website-chat` | Website chat | A | Save (1) | Set the chat's hours | as above | — | no |
| `/admin/settings-hub/mailboxes` | Shared mailboxes | A | Add; Stop reading it (2) | Watch a shared mailbox | as above | Shared mailbox, sync | no |
| `/admin/templates` | Templates | A | Save (template, signature, recipient) (3) | Edit a standard letter | Desktop: Admin (1) → Templates (2) → Save (3) | Template, notice recipient | no |
| `/admin/system` | System | A | Save (settings, note templates, security, tax year, mailboxes); Show (access log); Close it (problem); Take it off (≈6, inferred) | Read the access log; close problem reports | Desktop: Admin (1) → System (2) | Access log, problem reports, sweep, dba | **yes** |
| `/admin/hours` | Hours | A | Approve; Decline → Decline it; Export this period (3) | Approve a clocked-time correction | **No phone route**. Desktop: Admin (1) → Hours (2) → Approve (3) = 3 | Period, corrections, export | no |
| `/admin/consent` | Texting consent | A | Record → Record it (1) | Record how a number agreed to texts | Desktop: Admin (1) → Texting consent (2) → Record (3) → Record it (4) = 4 | Consent | no |
| `/insights/money` | **Money insights** (CLAUDE.md names "Money insight" as a name to avoid) | A, +insights grant | Save; Take it; Show another month; Download CSV; Reconcile (5, inferred) | See what is owed | Desktop: Admin (1) → Money insights (2); A on phone: Home "received this month" card (1) | Earned not invoiced, A/R, aging, reconcile, baseline, rate. Keep: authorization, warrant | **yes** |
| `/insights/referrals` | Referrals | A, +insights | 0 | Where referrals come from | Admin (1) → Referrals (2) | Median, pipeline, "at the front". Keep: counselor | no |
| `/insights/outcomes` | Outcomes | A, +insights | 0 | Results for USOR | Admin (1) → Outcomes (2) | Competitive integrated employment, 90-day retention, WSA, median, eligible | no |
| `/insights/capacity` | Capacity | A only | 0 | Who can take more clients | Admin (1) → Capacity (2) | Capacity, "months of work in hand", untouched. Keep: authorization | no |
| `/insights/reports` | **Reports** (nav label "KPIs") | A, +insights | Show month; Choose a client (2) | Monthly numbers | Admin (1) → KPIs (2) | KPI, A/R, WSA, placement rate, median, eligible | no |

## Account (outside the nav)

| Route | Title | Roles | Primary actions (n) | Main task | Taps | Hard words | >4 actions |
|---|---|---|---|---|---|---|---|
| `/security/two-factor` | Two-step sign-in | All (always reachable; forced when the practice requires it) | Set it up; Turn it on; Let me in; Start again; Go to Home (4) | Set up the second step | Avatar menu (1) → Two-step sign-in (2) → Set it up (3) → Turn it on (4) | Two-step, factor, authenticator | no |

---

## Client portal (`app/portal/**`, the client's own site, a separate audience)

| Route | What it is |
|---|---|
| `/portal/sign-in` | Client sign-in |
| `/portal/verify` | Code check after sign-in |
| `/portal/terms` | Portal terms, accepted on first use |
| `/portal` | The client's home |
| `/portal/messages` | Messages with the practice |
| `/portal/documents` | Documents the practice asked for, and uploads |
| `/portal/resume` | The client's résumé |
| `/portal/consent` | Consents (texting, release of information) |
| `/portal/settings` | Account settings |
| `/portal/a11y/[screen]` | Accessibility versions of portal screens |

The portal was not audited for taps or words. It speaks to the public, so the colleague-voice rules do not apply to it.

---

# Summary

## Totals

- 72 `page.tsx` routes under `app/(app)`. One of them (`/messages`) only redirects to `/team`.
- Counting each `?tab=` view as its own screen, the tables above list **89 staff screens**: the client record's 7 tabs, Clients ×2, Billing ×3, Time & statements ×3, Counselors ×4, Paperwork ×2, People ×2, Texts ×2. `/messages` is folded into `/team`, and the client-record header row is not counted as a screen.
- 10 portal routes.

## Daily tasks per role (phone, starting on Home)

**Job Search (Rei)**

| Task | Shortest path | Taps |
|---|---|---|
| Clock in | Header Clock in | 1 |
| Answer a text | Home Reply → Send | 2 |
| Add a note | + → client → Add note | 3 |
| Log a job application | + → Job → client → employer → Add job | **5** (from the bar: 7) |
| Log an interview | + → Interview → client → job → Add interview | **5** |
| Weekly updates (Fridays) | Communication → Weekly updates → Approve → Send it | **4** per client |
| Log coaching hours | + → Log hours → authorization → Log the hours | **4** |
| End of day | My work → My end of day → Add → Submit day | **4** |

**Reports (Margaret, Intake & Client Reports, with a billing grant)**

| Task | Shortest path | Taps |
|---|---|---|
| Confirm the weekly report | My day → Reports due row → Confirm | 3 (from the bar via Documents: 6) |
| Sign and send the monthly report | My day → row → month → Sign it → Send it → Send | **6** |
| Add a referral | Clients → All clients → Add referral → Save referral | **4** |
| Finish intake | Record (3) → Profile → Open the intake record → Submit intake | **6** (with search: 5) |
| Add a note | + → client → Add note | 3 |
| Send a billing packet (grant) | Home Billing tile → row → Send the packet | 3 |
| Log hours (grant) | Not in her "+". More → Service log → authorization → Log | **4** |

**Billing**

| Task | Shortest path | Taps |
|---|---|---|
| Confirm an authorization | More → Authorizations → Open → Confirm | **4**, and "Open" lands on Overview (bug) |
| Log hours | + → Log hours → authorization → Log the hours | **4** |
| Send the invoice packet | Home Billing tile → row → Send the packet | 3 (4 if a USOR form must be produced first) |
| Record a warrant payment | More → Authorizations → Record payment | 3 |
| Add an authorization | + → Add authorization → client → Save authorization | **4**. The /billing header button lands on Overview. |

**Job Coach**

| Task | Shortest path | Taps |
|---|---|---|
| Clock in | Header | 1 |
| Add a note | + → client → Add note | 3 |
| Log coaching hours | + → Log hours → authorization → Log the hours | **4**. From a past appointment: Log hours → (read-only Billing tab) Log a visit → Log the visit = 3 |
| Worksite check / visit form | My work → Forms and checklists → Fill one in → client → Save it | **5** |
| End of day | My work → My end of day → Add → Submit day | **4** |

**Case Manager**

| Task | Shortest path | Taps |
|---|---|---|
| Add a note | + → client → Add note | 3 |
| Finish a task | Home row Mark complete | 1 |
| Confirm the weekly report (if assigned) | My day → row → Confirm | 3 |
| Answer a text | Home Reply → Send | 2 |
| End of day | My work → My end of day → Add → Submit day | **4** |

**Admin (owner)**

| Task | Shortest path | Taps |
|---|---|---|
| Approve clocked-hours corrections | No phone route. Desktop: Admin → Hours → Approve | 3 on desktop |
| Approve contractor statements | My work → Time & statements → Statement approvals → Approve | **4** |
| Review documents | No phone route. Desktop: Admin → row → File it / Confirm | 3 on desktop |
| Decide a purchase request | More → Purchase requests → Decide → Approve | **4** |
| Check the business | Home | 0 |

## Every daily task over three taps

1. JS: log a job application (5)
2. JS: log an interview (5)
3. JS: Friday weekly updates (4 per client)
4. JS: log coaching hours (4)
5. JS: end of day (4)
6. R: sign and send the monthly report (6)
7. R: add a referral (4)
8. R: finish intake (6, or 5 with search)
9. R: log hours through the grant (4, not in her "+")
10. B: confirm an authorization (4, and the path is broken)
11. B: log hours (4)
12. B: add an authorization (4)
13. JC: log coaching hours (4)
14. JC: worksite check / visit form (5)
15. JC: end of day (4)
16. CM: end of day (4)
17. A: approve contractor statements (4)
18. A: decide a purchase request (4)
19. A: approve hours on a phone (no route)
20. A: review documents on a phone (no route)

## Screens with more than four primary actions (33)

31 screens have more than four on their own. Notes and Billing are also over four, but only because of the record header, which puts 5–8 buttons on every client tab. That makes all 7 client-record tabs count.


- **Home:** `/dashboard`, `/my-day`
- **Clients:** `/clients` Board and All clients
- **Client record:** the header on every tab (5–8 buttons), so all 7 tabs. The worst are Messages (≈17), Profile (≈10), Activity, Jobs and Documents.
- **Client reports and forms:** `/clients/[id]/reports`, `/clients/[id]/reports/[month]`, `/clients/[id]/forms/[formId]`
- **My work:** `/tasks`, `/hours` (Your time), `/end-of-day`, `/paperwork`, `/paperwork/onboarding`
- **Communication:** `/mail`, `/messages/texts?tab=texts`, `/messages/weekly-updates`, `/team`
- **Billing:** `/billing?tab=authorizations`, `/billing/authorizations/[id]` (≈13)
- **Books:** `/books/bills`, `/books/bank/[id]`
- **HR:** `/admin/people`, `/admin/people?tab=contractors`, `/admin/people/[id]`
- **Admin:** `/admin/documents` (≈16), `/admin/system` (inferred), `/insights/money` (inferred)

## Hard words: proposals only

**USOR terms, kept, each needing a one-line explanation:**
- **authorization**: "USOR's go-ahead to provide and bill a service, with hours and dates"
- **counselor**: "the USOR person who sends us the client and reads our reports"
- **warrant**: "the State's payment to us for an invoice"
- **USOR** itself is a proper name. Spell it out once: "Utah State Office of Rehabilitation (USOR)".

**Everything else:**

| Word on screen | Proposed plain word |
|---|---|
| Intake | First meeting / sign-up |
| Referral | New client sent to us |
| Placement / Job Placement | Started a job |
| Stage | Step |
| Caseload | Your clients |
| Assessment (WSA) | Work skills test |
| Job Development | Finding employers |
| Competitive integrated employment (CIE) | A regular paid job |
| 90-day retention | Still working after 90 days |
| Retention (records) | How long we keep it |
| Hold / Place hold / Lift | Keep, do not delete / Stop keeping |
| Records request | Request for a copy of a file |
| Restricted | Private |
| Access log | Who opened what |
| Grant / area / "view and edit" | Extra access |
| Portal | Client website |
| Consent (texting) | OK to text |
| Packet | Bill bundle |
| Submitted | Sent to USOR |
| Bill-by date | Send-by date |
| Delivered | Service done |
| Service log / service entry | Hours worked for a client |
| Billing office | Where the bill goes |
| Short-paid | Paid less than billed |
| Voucher | Payment slip number |
| Carried / carried used | Hours used before |
| Rate schedule | Price list |
| Produce USOR 95 | Fill in form 95 |
| Sign and lock | Sign (no more changes) |
| Assemble it / Read the record again | Build it / Build it again |
| Statement (contractor) | Hours for pay |
| Period | Pay period (two weeks) |
| Work session | Time worked |
| Reconcile | Match up |
| Ledger / Books | Money records |
| Journal entry / Post / Reverse | Manual entry / Save to the books / Undo |
| Settle / posting | Match / money line |
| Chart of accounts | Money categories |
| Accrual | Counted when earned |
| A/R, payables, aging | Owed to us, we owe, how late |
| Vendor | Company we pay |
| Dispose / depreciation | Get rid of / loss of value |
| Forecast / pipeline | Money expected / clients on the way |
| KPI | Numbers we track |
| Median | Middle value |
| Capacity | Room for more clients |
| Onboarding / Offboard | Getting started / Leaving |
| Roll-up | Summary |
| Two-step sign-in / factor | Code from your phone |
| Template | Ready-made wording |
| Sync | Update from Outlook |
| Thread / Archive | Conversation / Put away |
| Spam | Junk |
| Natural supports | Help from co-workers |
| Accommodation | Change that helps them work |
| Guardianship | Legal guardian papers |
| Release of information | OK to share |
| E-delivery consent | OK to get forms by email |
| Tax treaty | Tax deal between countries |
| W-4, W-9, W-8BEN, 1099, I-9, EIN, TIN, IRIS CSV, Copy B | Keep the form names, each with "(tax form)". IRIS CSV → "IRS filing file". |
| Put forward / match | Suggest for a job |
| Proposal / agent runs | Suggested / automatic checks |
| Credential / certification | Certificate |

## Landings that are not the role's own work, and pointers that go wrong

1. **Billing on Home.** The "Your tasks" tile opens `/tasks` and the "My clients" tile opens `/my-clients`. Billing can open neither, so `canReach` sends them back to Home. The appointments and tasks sections are mostly empty for this role.
2. **Job Coach and Case Manager on Home.** The "My clients" tile opens `/my-clients`, which is only for Admin, Job Search and Reports, so it bounces back to Home.
3. **Reports (Margaret) on Home.** Her main work, the weekly and monthly reports due, is not on Home. It appears only on the My day tab ("Reports due").
4. **"More" on a phone.**
   - Job Search, Job Coach, Case Manager, and Reports without the grant land on **Purchase requests**, which is rarely their work.
   - Admin and Billing land on Billing Overview.
   - The **HR and Admin groups cannot be reached from the phone navigation at all**: Hours, Document inbox, People, Settings, Texting consent, Insights. Admin's "approve hours" and "review documents" therefore have no phone route.
5. **Billing's "Add authorization" header button** goes to `/billing#new-authorization`, which renders Overview, so the form is not there. The pending-document "Open" link (`/billing?doc=…`), the "Read the authorization off it" link, and the old `?tab=items|invoices|completions|rates` redirects also land on Overview, not on Authorizations. This is inferred from the code: Overview became the default tab on 9 Nov 2026 and these links were not updated.
6. **Home appointment "Log hours"** opens the client's Billing tab. For Job Search and Job Coach that tab says "Read-only for your role". The control they need is the "Log a visit" button in the record header.
7. **The "Waiting for your reply" tile** opens `/mail`, but its number also counts texts and staff chat.
8. **Names that do not match the navigation:**
   - Home's heading says "the number on Inbox", but the group is called Communication.
   - `/team` is titled "Messages".
   - `/insights/reports` is titled "Reports" but its nav label is "KPIs". `/books/reports` and `/clients/[id]/reports` are also titled "Reports".
   - "Money insights" is a name the house rules list as one to avoid.
   - Onboarding's button says "Go to the dashboard", but the nav calls it Home.
   - The header says "Clock in" while Home and Time clock say "Start work session" for the same timer.
9. **Margaret's "+" ignores her billing grant**: `kindsForRole` looks at the role only, so Log hours and Add authorization are missing for her.
