# Timing — the portal's week, before

Two named questions, timed before the weekly "Your week" screens and again
after (brief, Part 1 step 3). If the after times are worse, the screens go
back.

**How to time one.** Both of these are timed differently from the others in
this folder, because neither is a staff member tapping through screens. The
first is a clock on a chain of events that mostly has not happened yet, so it
is measured from what the database recorded rather than with a stopwatch. The
second is timed the usual way, signed in as the Job Search staff member who
would ask it.

Measured on 23 November 2026, against production.

## The two questions

### 1. How long from the Friday draft to the client seeing their week?

**Done when** the client has looked at what the practice did for them that
week, on a screen, and could tell somebody what was on it.

| | Today |
|---|---|
| Shortest path | There is none |
| Clock | **Never.** No client has seen it |

The chain has four links and three of them are not joined:

1. **The draft exists.** `draft_weekly_updates` runs at 2pm Friday and does
   what it says: 20 drafts on 9 November at 18:56 local, 20 on 20 November at
   14:00 local. 18 of each 20 are to the client, 2 to a contact with no
   number on file.
2. **Nothing has been sent.** All 40 are `state = 'Not sent'`. Both weeks
   were drafted, nobody clicked, and the Monday sweep closed them. The text
   that is meant to carry the portal link has never gone to anybody.
3. **There is nobody to send it to.** `portal_accounts` holds **0 rows**. No
   client and no guardian has been invited, so a link in the text would open
   a sign-in that cannot issue a code.
4. **There would be nothing on the screen.** `job_status_history` recorded
   81 to 202 application events a month from July to October and then
   stopped: one event in November, on the 2nd, and none in the last three
   weeks. "The places you applied for this week" is empty for all eleven
   active Job Search clients, this week and last.

So the honest figure is not a number of minutes. It is that each of the last
two Fridays produced 20 drafts and 0 sends, and the client-facing end of the
chain does not exist yet.

**What to measure after**: draft written (2pm Friday) → somebody clicks send →
carrier accepts → the client asks for a code → the first screen. The first
two are in `weekly_updates.drafted_at` and `.sent_at`; the last two are in
`portal_login_codes` and `portal_sessions.created_at`.

### 2. How does Rei learn that a client does not want a place?

**Done when** the assigned Job Search staff member knows the client does not
want to work somewhere, and it is on the record rather than in somebody's
memory.

| | Today |
|---|---|
| Shortest path | The client says so by text or on the phone, and somebody writes it down |
| Clock | **A median of 23 days after applying**, on the 7 occasions it has been recorded at all |

Out of 273 applications, `Client withdrew` has been recorded 7 times, and the
median gap between the application and that entry is 23 days. Every other
application reads: Applied 273, No response 202, Declined by employer 49,
Interview scheduled 8, Interviewed 6, Hired 3. Nothing anywhere records "the
client would rather not work here", before or after applying, because there
is no field for it and no screen that asks.

The practice does hear it — a client says it in a text, or at an appointment,
and the staff member remembers and does not apply there again. What it costs
is that the knowledge lives with whoever heard it, and the number above is
how long it takes to reach the record when it reaches it at all.

**What to measure after**: the client taps 👎 on a card → the rating is on the
application and in the activity stream → the next person starting an
application to that employer is warned. The first two are one write; the
third is the only one worth a stopwatch.

## What this says about the plan

Neither question is slow today. Both are unanswered: the first has never
happened, and the second happens 7 times in 273 by accident of conversation.
That is a different thing from a screen being slow, and it is the argument
for the portal pages - not that they would be quicker, but that they would
make two facts exist that currently do not.

It is also the argument against sending the invitation this Friday. A client
invited on 27 November would sign in, accept the terms, and find an empty
week, because the last application anybody logged was on 2 November.
