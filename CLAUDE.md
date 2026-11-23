# Zion Vocational Rehab CRM

Notes for anybody — person or agent — working on this codebase.

The long-form record of what was built and why is `BUILD-LOG.md`, newest at
the bottom. This file is the short version of the rules that outlived their
briefs.

## Writing and screen standard

The practice has one voice on screen. These are the rules it follows, and
`scripts/check-copy.mjs` and `scripts/check-words.mjs` hold it to them before
every build, so the standard is checked rather than remembered.

### The voice

**Write to a colleague, not to a user.** "Say why it is being reopened", not
"Please provide a reason". The house voice is direct and assumes competence.
No *please*, no *sorry*, **no exclamation marks anywhere**.

**No sales words.** *Seamless, effortless, powerful, smart, magic, AI-powered,
journey.* None of them says anything a staff member can act on, and a screen
that describes itself that way is a screen that is not sure what it does.

**Say what happened and what to do about it.** An error is **one sentence**
naming the thing and the next move: *"That file is over 3MB — scan it at a
lower resolution, or put it on the client's record and read it from there."*
It does not apologise and it does not blame.

**A button names the action.** "Take it down", "Say it", "Do not send",
"Place hold". Never "OK", "Submit" or "Yes". **A confirmation is one or two
words** — "Remove", "Take it down" — not a question about whether somebody is
sure.

**A person reads about their work, not about ours.** No RLS, no RPC, no
Postgres, no stack traces. Where the database refuses something it refuses it
in a sentence somebody can act on, and the screen passes that sentence through
unchanged — which is why so many actions return `error.message` directly.

**Sentence case everywhere**, except names that are capitalised anyway: Admin,
Billing, USOR, I-9, Job Coach. No full stop at the end of a label or a button.

**Feature names are plain nouns.** Money, Reports, Assistant, Clients, Hours.
Not "Money insight", not "Co-pilot", not "KPI dashboard". If a name needs a
qualifier to make sense, the screen is probably two screens.

### Titles and helper text

**A title is a noun, never a sentence.** "Access log", "Document inbox",
"Problems reported". Not "What this does not cover" and not "Still to do
before you are fully set up". A heading over four words with a verb in it is
a sentence wearing a heading's clothes, and `check-copy` fails it.

**No helper prose unless it changes what the person does next.** Under a
heading, in an empty state, in a dialog — if the sentence would not alter a
single action, it is decoration and it goes. What survives is **twelve words
or fewer**; anything longer belongs in the one-time hint or the knowledge
base, or is a sign the screen needs changing rather than explaining.

**An empty state is one sentence.** Two means the screen is apologising. Join
the second clause on rather than deleting it: *"Nothing yet — add the first
job this client has applied for."*

### What a screen is made of

**One typeface.** The scale is `--text-*` in `tokens.css` and nothing else
sets a size.

**No decoration that carries no information.** No eyebrow labels above
headings, no gradients, no sparkles, no emoji. Colour means something —
good, warning, critical, the accent — or it is not used.

**One header, one tab strip, one table.** The title, the line of context and
the actions come from `PageHead`. A filter or a period is `.segmented`; tabs
stacked under tabs is how a screen stops being findable.

**Tables for lists. Cards only when an item needs more than one line of
context.** A list of records is `DataTable` — sortable, filterable, with a
sentence when it is empty. A table laying out something that is not a list
says so with `data-layout="why"`.

**A screen named in copy has to exist.** "My work → Tasks", "Admin → Money".
The navigation has been regrouped three times and the sentences pointing at
screens were not regrouped with them, so some were still sending staff to
"Dashboard → Tasks" and "Billing → Invoices" — a screen that had been
deleted. `check-copy` reads every such reference against the live navigation.

### What the rules do not cover

The **public website chat** speaks to a member of the public, not to a
colleague. Courtesy to a stranger is not padding, so "Please start a new one"
stands and `check-copy` exempts it.

**Billing, authorizations, forms and warrants** are exempt from the length
rules, as the design-language brief exempts them. Judging screens by a rule
the brief says to leave alone would be rewriting what was asked to stay put.

**Comments** are never judged as screen copy. The house style is long comments
explaining *why*, and a rule written for a button applied to one of those is
nonsense.

## Checks

Everything in `prebuild` runs before every build and gates the deploy. Add a
check rather than a convention whenever a rule is worth keeping: a rule that
is only written down is a rule that drifts.

**A check outside `prebuild` is a check that rots.** `check-quick-add` named
the six kinds the "+" offered and the number each role got; three kinds were
added over the following month and every assertion went stale at once. Nobody
found out, because nothing ran it. Ask the rule rather than the roster, and
put it in `prebuild`.

Two checks need database credentials and so are run by hand rather than in
`prebuild`, which runs on Vercel:

- `node --env-file=.env.local scripts/run-sql.mjs supabase/verify_*.sql` — the
  verification suite. Every enforced rule has a rollback-wrapped script.
- `node --env-file=.env.local scripts/check-hours-race.mjs` and
  `scripts/check-end-of-day.mjs` — behaviour that needs two connections or a
  real transaction.

**A check that asks a question merely near the rule passes the bug it was
written for.** This has happened often enough to be the first thing to
suspect: `check-nav` asserted a hub *had a page* when the rule was whether
anybody could *open* one; `check-upload-limits` compared a promise against a
limit it was already equal to; the first `check-copy` read spread operators as
ellipses. Put the fault back and watch the check fail before trusting it.

**When a check cannot get an answer, that is not the same as getting the
answer "no."** The middleware read an auth error as "revoked"; `getCurrentStaff`
read a failed query as "no access" and signed the whole practice out. Both now
tell the two apart.

## Definition of done

**"Deployed" means production reached READY and somebody checked.** The
production deployment at `crm.zionvocrehab.com` is serving the commit, and
that was confirmed rather than assumed. A commit that is pushed and not yet
live is reported as **"pushed, not live"**, with both hashes. A commit whose
deploy failed is reported as failed, with the reason.

**Every report states the live production hash.** Not the local one, not the
one that was pushed — the one the site is actually serving.

**One push at a time.** Never push while a deploy check is running on
production: wait for the verdict. Four commits went out in half an hour on
20 November and three of their runs overlapped, each deploy swapping
production under the browser the run before it was driving. Two of those runs
failed and neither failure was about the code — a sidebar that stopped
expanding mid-walk, a 404 on a path four identical requests in the same run
had just got 200 for — so every job passed on that code and no single run was
ever green on it, which left the owner deciding by hand which failures to
believe. Two things hold the rule now: `concurrency` in the deploy-check
workflow, so the runs queue instead of overlapping and the one in flight is
never cancelled, and `.githooks/pre-push`, which refuses the push that would
start the second one. The rule is `scripts/push-guard.mjs`, the answer comes
from `wait-for-deploy.mjs --before-push`, and `check-push-guard` asks both.
When production is broken and the fix cannot wait for a check with twenty
minutes left to run: `ZION_PUSH_ANYWAY=1 git push`.

**A reply is a reply on any channel.** On the client threads board, a client
needs a reply when they spoke last and nothing outbound has happened since —
a text out, an email filed on their record, a contact-log line or a note
dated on or after the day they wrote. "Quiet 14+ days" reads the same way.
The rule is `client_threads_board` and `verify_the_threads_board.sql`, not a
query on a screen, because the three screens that answered this question
before gave three different numbers: 22 text threads whose last word was
theirs, 8 conversations with something unread, and 4 clients who had actually
had no answer. Fourteen of the twenty-two had been answered another way and
no screen could see it.

**A call is a note that says how it happened.** `notes.method` — in person,
phone, video, text — is required on a hand-written contact note, derived for
a Phone call, and left empty where a document is the record of how it
happened. `contact_log.method` is a different column answering a different
question: what the line *is*. A contact-log line counts towards a client's
month only if it says Call, Text, Email, Appointment or In person — never
"End of day report", which was 200 of November's 221 lines. The two
vocabularies live in `lib/contact-methods.ts` and in migration 0378, and
`check-threads` holds them to each other.

**One failure is not a finding; two in a row is.** A screen that fails in the
deploy check is asked once more ten seconds later, and only a screen that
fails both times fails the run. The rule exists because of what the first
failure can be: the run that rolled production back on 20 November got a 404
on a path four identical requests in the same run had already got 200 for. A
cold function, a dropped connection, a read that took nine seconds instead of
two — none of them is a broken screen, and putting production back on the
previous deployment is the most expensive thing this check does.

The dangerous half is the other one, so it is the half that is held: a screen
that failed once and opened the second time is marked in the log, listed at
the end of the run, and raises a warning on the run page. It is green, and it
is visible. A flaky screen nothing shows is the same screen every week with
nobody counting. Three things are not asked twice, because their answer cannot
change in ten seconds — a session the check signed itself out of, a redirect
to /login or the dashboard, and a redirect loop — and twelve second looks is
all one run will pay for, because a job cancelled on its timeout opens no
issue and rolls nothing back. The rule is `scripts/retry-screen.mjs` and
`check-retry` asks it; the action posts are not retried, because posting twice
is writing twice.

**What only Admin can see, the owner checks by hand.** No automated account
may be Admin (0295), so every Admin-only control is outside the deploy check's
reach by construction: today that is Approve, Decline and the Stage-change
requests tile on Clients → Board, and the twelve HR and Admin screens nothing
times. A change that touches one of them is not done when the deploy check is
green — it is done when the owner has opened it as Admin and said so. The
database half of such a rule is still a verify script, which is where the
evidence lives; the hand check is about the screen.

The question is one HTTP GET:

```
node scripts/check-deployed.mjs
```

It asks `crm.zionvocrehab.com/api/version` what commit is live and compares it
with HEAD. `scripts/wait-for-deploy.mjs <short-sha>` waits for one to land and
reports what the deploy checks made of it.

This is a rule because the alternative happened. Eight consecutive production
deployments failed and all eight were reported as deployed: a check written on
Windows compared paths that `path.join` spells differently on Linux, so it
passed every local run and failed every build, and nobody read the build log.
`wait-for-deploy.mjs` had been in the repository for a month and had never been
run. For two days production served code from before a release against a
schema from after it.

**A build cannot tell you whether it worked**, which is why this one check
cannot live in `prebuild` — prebuild runs inside the deployment it would be
asking about. It is in `check-checks`'s list of checks that cannot, with that
reason, and it is the last thing to run before the word "deployed" is written.
