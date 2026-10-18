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
No *please*, no *sorry*, no exclamation marks.

**Say what happened and what to do about it.** An error names the thing and
the next move: *"That file is over 3MB — larger than any authorization. Scan
it at a lower resolution, or put it on the client's record and read it from
there."* It does not apologise and it does not blame.

**A button says what pressing it does.** "Take it down", "Say it", "Do not
send", "Place hold". Never "OK", "Submit" or "Yes". A confirmation names the
thing — "Remove this line?" — rather than asking whether somebody is sure.

**A person reads about their work, not about ours.** No RLS, no RPC, no
Postgres, no stack traces. Where the database refuses something, it refuses it
in a sentence somebody can act on, and the screen passes that sentence
through unchanged — which is why so many actions return `error.message`
directly, and why the messages in the migrations are written as prose.

**Sentence case everywhere**, except names that are capitalised anyway: Admin,
Billing, USOR, I-9, Job Coach. No full stop at the end of a label or a button.

### The screen

**An empty state is one sentence.** Two means the screen is apologising. Join
the second clause on rather than deleting it: *"Nothing yet — add the first
job this client has applied for."*

**No paragraph on a working screen.** 200 characters of explanation is the
limit. Longer belongs in the one-time hint, in the knowledge base, or it is a
sign the screen itself needs changing.

**One header, one tab strip, one table.** The title, the line of context and
the actions come from `PageHead`. A filter or a period is `.segmented`; tabs
stacked under tabs is how a screen stops being findable. A list of records is
`DataTable` — sortable, filterable, with a sentence when it is empty. A table
laying out something that is not a list says so with `data-layout="why"`.

**A screen named in copy has to exist.** "Work → Tasks", "Admin → Money". The
navigation has been regrouped twice and the sentences pointing at screens were
not regrouped with them, so four of them were still sending staff to
"Dashboard → Tasks" and "Billing → Invoices" — a screen that had been deleted.
Nothing was broken, which is why nobody noticed. `check-copy` now reads every
such reference against the navigation.

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
