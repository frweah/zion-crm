# Zion Vocational Rehab CRM

Client, billing and reporting system for Zion Vocational Rehabilitation Center.
Supabase (Postgres + Auth + Storage + RLS) · Next.js · Vercel.

The approved product spec is `zion-crm-prototype.jsx` in the parent folder. Where
the prototype and `Zion-VocRehab-CRM-Spec-v2.md` disagree, the prototype wins.

**The prototype file and the exported data hold real client records. They stay
outside this folder and are git-ignored. Nothing with client data goes into the
repository, ever.**

---

## Phase 1 — what is here

| Piece | Where |
|---|---|
| Database schema (20 tables) | `supabase/migrations/0001_schema.sql` |
| Identity helpers + the billing and form rules | `supabase/migrations/0002_rules.sql` |
| Row-level security for all four roles | `supabase/migrations/0003_rls.sql` |
| Invite flow + staff, offices, rate schedule, USOR form metadata, SOPs | `supabase/migrations/0004_invite_flow_and_reference_data.sql` |
| Invite-only accounts, enforced in the database | `supabase/migrations/0005_invite_only.sql` |
| Login, invite acceptance, password reset, sign-out | `app/login`, `app/set-password`, `app/auth` |
| Role-correct app shell and navigation | `app/(app)/layout.tsx`, `lib/roles.ts` |
| Staff screen: invite, resend, deactivate | `app/(app)/staff` |
| Data-handling policy to sign | `docs/data-handling-policy.md` |

Phase 2 replaces the placeholder screens with the prototype's components.
Phase 3 loads the client data.

---

## Setup, in order

### 0. Install Node.js

Not currently installed on this machine. Get the LTS installer from
<https://nodejs.org> and run it, then reopen the terminal and check:

```bash
node --version
```

### 1. GitHub

Create an account at <https://github.com>, then a **private** repository named
`zion-crm`. Private is not optional — this is a business system.

### 2. Supabase

Create an account at <https://supabase.com> and a project named `zion-crm`
(region: US West or US Central). From **Project Settings → API**, keep these
three ready:

- Project URL
- `anon` public key
- `service_role` secret key — treat this like a master key; it bypasses all
  security rules. It goes in `.env.local` and in Vercel's environment
  variables, and nowhere else.

Then run the migrations — either paste each file in `supabase/migrations/` into
the dashboard's **SQL Editor** in numerical order, or, with the database
password in `.env.local`:

```bash
node --env-file=.env.local scripts/run-sql.mjs supabase/migrations/*.sql
node --env-file=.env.local scripts/run-sql.mjs supabase/verify_phase1.sql
```

The database password is not the password you log in to Supabase with. It is
under **Project Settings → Database → Database password**, and Supabase shows
it only once when the project is created — if you do not have it, reset it
there.

Then turn **off** new signups: **Authentication → Sign In / Providers → Email**,
and switch off **"Allow new users to sign up"**. Migration 0005 already blocks
any signup whose email has no staff account, so this is the second lock rather
than the only one — but leaving it on means strangers can still make attempts
against your auth endpoint.

In **Authentication → URL Configuration**, set the Site URL to your Vercel
address once you have one, and add both `http://localhost:3000/auth/confirm`
and `https://YOUR-APP/auth/confirm` to the redirect allow-list.

### 3. Run it locally

```bash
npm install
```

Copy `.env.example` to `.env.local` and paste in the three values from step 2.
`.env.local` is git-ignored.

```bash
npm run dev
```

Open <http://localhost:3000>. You will be sent to the login page.

**First login.** Migration 0004 creates the Admin *staff row* for
`frweah@gmail.com`, but not a login — those only exist once someone accepts an
invite. "Email me a password reset link" will not help here: Supabase has
nothing to reset yet. Bootstrap the owner account once, with the service-role
key:

```bash
node --env-file=.env.local scripts/invite.mjs frweah@gmail.com
```

That sends the invite, the link lands on `/auth/confirm`, you choose a
password, and migration 0005's trigger links the new auth user to the Admin
staff row. From then on every other account is invited from the Staff screen,
and this script is never needed again.

### 4. Vercel

Create an account at <https://vercel.com>, connect it to the GitHub repo, and
add the same three environment variables plus `NEXT_PUBLIC_SITE_URL` (your
Vercel URL). Deploy.

### 5. The app's address

Point a DNS record at Vercel from your domain registrar — e.g.
`crm.zionrehabcenter.com`. Vercel shows the exact record to add. Update
`NEXT_PUBLIC_SITE_URL` and the Supabase URL configuration afterwards.

### 6. Email sending (needed from Phase 4)

Sign up at <https://resend.com>, verify `zionvocrehab.com`, so completed forms
go to counselors from `service@zionvocrehab.com`.

---

## Before staff use it for real work

- **Supabase Pro (~$25/mo)** — free projects pause after about 7 days of low
  activity and have no restorable backups. Pro removes pausing and keeps 7 days
  of daily backups.
- **Vercel Pro (~$20/mo, one seat)** — the free Hobby plan is for
  non-commercial personal use only. Only the deploying account needs a seat;
  CRM staff logins are not Vercel users.
- GitHub free is fine.

Upgrade at the start of go-live, not after.

Also: enable daily backups in Supabase, export monthly to storage you control,
and have every staff member sign `docs/data-handling-policy.md`.

---

## How access works

Four roles: **Admin** (owner), **Job Search**, **Reports** (Intake & Reports),
**Billing**.

All four see every client. The `assigned_staff_id` on a client routes tasks and
alerts; it does not restrict access.

The restricted tier — date of birth, address, the whole intake record
(accommodations, emergency contact) and DWS-USOR 94 / 98 form content — is
visible only to Admin, Intake & Reports, or that client's assigned staff
member. This is enforced by row-level security in the database, not by hiding
things in the interface: a hidden field is not a protected field.

Editing rights follow the prototype:

| | Clients, intake, pipeline | Authorizations, service log, invoices | Staff accounts, SOPs |
|---|---|---|---|
| Admin | yes | yes | yes |
| Job Search | yes | no | no |
| Intake & Reports | yes | no | no |
| Billing | no | yes | no |

Notes, tasks, counselor contacts, hours requests and forms can be created by
any active staff member; a note or contact record can only be edited by the
person who wrote it, or by Admin.

**Deactivating an account removes access immediately.** Every security policy
runs through `is_active_staff()`, so the database stops answering for that
person on their very next query — no waiting for a token to expire. Their
active clients must be reassigned before the account can be closed.

## Rules the database enforces

These hold no matter which screen or script does the writing:

- Service hours cannot be logged for a future date.
- A service entry cannot push an authorization past its authorized hours.
- An invoice cannot exceed what its authorization authorizes.
- An invoice cannot be marked Sent until every USOR form required for that
  authorization's service type is out of Draft.
- A completed form is locked — its content cannot be edited and it cannot be
  reopened — and it records who signed it and when.
- An intake cannot be saved without the consent box checked.
- Every pipeline stage change is recorded with who made it and when.

---

## Email (Phase 4)

Completed USOR forms are emailed to the counselor from
`service@zionvocrehab.com`, and every send is written to the counselor contact
log automatically.

1. Sign up at <https://resend.com> (free tier is enough to start).
2. Add the domain `zionvocrehab.com` and add the DNS records Resend gives you
   at your registrar — SPF and DKIM. Without them, mail to a `utah.gov`
   address will land in spam or be rejected outright.
3. Create an API key and put it in `.env.local` as `RESEND_API_KEY`, and in
   Vercel's environment variables.

Until that is done, the Forms screen says so plainly: forms can be filled in
and signed, but the send button reports that email is not configured. A form
is only marked Sent when the mail service actually accepts it — "Sent" has to
mean the counselor has it, because the billing gate depends on it.

## Verification scripts

```bash
node --env-file=.env.local scripts/run-sql.mjs supabase/verify_phase1.sql
node --env-file=.env.local scripts/run-sql.mjs supabase/verify_rls.sql
node --env-file=.env.local scripts/verify-migration.mjs ../zion-crm-prototype.jsx
node --experimental-strip-types --env-file=.env.local scripts/check-form-templates.mjs
```

The last one matters more than it looks: the USOR templates live in code (field
definitions) and in the database (which service types require which form). The
database copy is what refuses to let an invoice be sent, so if the two drift,
staff would be shown a form they must complete while the gate quietly let the
invoice through. Run it after changing either.
