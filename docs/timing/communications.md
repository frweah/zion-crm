# Timing — Communications, before

Two named questions, timed before the client-threads board and again after
(brief, Part 1 step 3 and Part 4). If the after times are worse, the screen
goes back.

**How to time one.** Start on Home, signed in. Start the stopwatch on the
first tap; stop it when the answer is on screen and you could say it out loud
without scrolling further. One practice run first, then the timed run. Write
down anything that made you stop and look.

Taps are counted the way `docs/screen-inventory.md` counts them: one tap each
for a bottom-bar item, a card, a tab, a row, a button or a dropdown. Typing
does not count. The header search box is two taps to a record.

Who you are signed in as changes both answers, so each is timed for the three
people who would ask: the Job Search owner who sends most of the texts, the
Reports manager, and the administrator. A Job Coach and a Case Manager can
read all of this and send none of it, which is the fourth answer and the one
nobody has asked for yet.

## The two questions

### 1. Which clients are waiting on a reply from us?

**Done when** you can name them and say how long each has waited.

| | Today |
|---|---|
| Shortest path | **Communication → Texts** |
| Taps | **2** |
| What it says | 43 rows, one per *thread*, newest first, each with a direction chip and who said it. You read down and judge each row |
| What it answers | "Which thread's last word was theirs" — **22 rows today**. Not the same question: 14 of those 22 were answered by email, by a logged contact or by a note, and that is invisible here |
| What it leaves out | Email entirely. A client who wrote to a counselor's inbox and is waiting is not on this screen at all, and 68 mail items came through this month |
| Per client or per thread | **Per thread.** A client whose partner also texts has two or three rows, and they are not next to each other — they sort by when each number last spoke |
| How long each has waited | Not shown. The column is the timestamp of the last message; the waiting time is yours to work out, row by row |
| The faster route | The **Inbox badge**, and the "Waiting for your reply" figure on Home: **0 taps**, and it counts **unread**, which is a different thing again. 14 of the 22 have been read by somebody, so they are not in it. It says 8 |
| As the administrator | The badge counts everything, assigned or not. Everybody else's counts only threads that are theirs or nobody's |
| The honest answer | **No screen answers this question.** Three screens answer narrower ones, and the three disagree: 22, 8, and — once email and logged contact are allowed to count as an answer — **4** |

**The state it is timing against** (20 November 2026): 20 active clients, 30
with a text thread, 39 text threads and 4 website chats, 6 of the text threads
matched to nobody. 22 threads where the client or the visitor spoke last: 14
read by somebody, 8 unread. By client, 15 have texted more recently than we
have texted back; **4 of those have had nothing on any channel since, and 2 of
the 4 have waited more than two days**. 25 texts are Failed or Not delivered.
2 active clients have no number that has agreed to be texted. Nobody has ever
sent STOP.

### 2. Everything we said to client X this month, any channel

**Done when** you can list the texts, calls and emails of the month without
opening another screen.

| | Today |
|---|---|
| Shortest path | **Clients** → their row → the record opens on Dashboard, with the activity stream → the window dropdown → **Last 30 days** |
| Taps | **4**, and then one more per channel: the stream's chips are one kind at a time — Text (5), Mail (6), Counselor (7) |
| What it gets right | The stream is already cross-channel: Text, Mail, Chat, Website, Counselor, Appointment, Recording and thirteen other kinds, newest first |
| The texts | One line each, no thread. The thread is the **Messages** tab, one more tap — and it shows **one** thread, so for the two clients whose family also texts, the tab is **empty**: the query asks for a single thread and three come back |
| The emails | Only what somebody **filed**. 68 mail items came through this month and **18** are on a client. The rest are in a mailbox, and the record does not know they happened |
| The calls | **Nowhere.** No table holds a call. `contact_log.method` is a list of events — "End of day report", "Stage change", "Appointment" — and not one row in the practice says "Phone" |
| The noise | The Counselor chip is contact-log rows, and **200 of this month's 221 are automatic end-of-day entries**. The 21 that are real contacts are read out of a list that is 90% roll-up |
| As anybody | Same screen, same taps. A note marked Personal is the only thing that varies, and there are 3 of those in the practice |
| The honest answer | **4 to 7 taps, and incomplete in three ways that the screen does not admit to**: the calls were never recorded, half the month's email was never filed, and the texts from a second number are not shown |

**The state it is timing against** (20 November 2026): this month holds 133
texts, 68 mail items (18 of them filed to a client), 221 contact-log rows (200
automatic), 114 notes and 1 recording. **16 of the 20 active clients have
something on two or more channels this month**, so the question is a real one
for four clients in five.

## Record

| Person | Question | Seconds (before) | Seconds (after) | What made you stop |
|---|---|---|---|---|
| | 1 | | | |
| | 2 | | | |
| | 1 | | | |
| | 2 | | | |
| | 1 | | | |
| | 2 | | | |

## Three things the survey found

**The Messages tab is empty for two clients.** The tab asks
`conversations … kind=sms, client_id=<them>` as a single row, and since one
thread per number (0332) a client can have several. Production answers
`PGRST116 … the result contains 3 rows`, the error is dropped, and the tab
renders as though the client had never texted. One client has 3 threads and
one has 2. Their texts are all still on file.

**"Cannot text" on the inbox answers the wrong question.** The row's flag
comes from `client_sms_consent`, which is per *client*; the thread is per
*number*, and `sms_consent_numbers` has the per-number answer that the
sending gate itself uses. So a thread with a contact who has consented can
show "Cannot text", and the opposite can happen too.

**Two roles are offered texting that the database refuses.** `text-actions.ts`
lets anybody in `CAN_EDIT_CLIENTS` write a text — five roles — and the policy
on `sms_messages` admits three (Admin, Job Search, Reports). A Job Coach or a
Case Manager gets as far as the box and is then refused by a row-level policy.

## What the taps were counted from

Read from the code and from production on 20 November 2026, at `83ae464`,
before anything changed: `app/(app)/messages/texts/page.tsx`,
`messages/texts/actions.ts`, `messages/screen.tsx`, `messages/thread.tsx`,
`messages/weekly-updates/*`, `app/(app)/mail/page.tsx`, `mail/actions.ts`,
`app/(app)/team/*`, `app/(app)/clients/[id]/page.tsx`, `messages-tab.tsx`,
`texting-panel.tsx`, `text-actions.ts`, `numbers-actions.ts`,
`mail-section.tsx`, `activity-tab.tsx`, `app/(app)/inbox-count-actions.ts`,
`lib/sms.ts`, `lib/roles.ts`, `app/api/sms/inbound/route.ts`,
`app/api/sms/status/route.ts`, `app/api/cron/{sms,scheduled-texts,messages-digest,week}/route.ts`,
the 14 `cron.job` rows, and the functions and policies behind them:
`record_incoming_sms`, `sms_outgoing_requires_consent`, `sms_into_conversation`,
`text_conversation_for`, `message_inbox`, `report_board_rows`,
`client_numbers`, `client_sms_consent`, `sms_consent_numbers`, `client_activity`.
