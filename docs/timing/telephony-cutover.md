# Telephony cutover — GoHighLevel to Twilio

The client line **385-406-3432** moves from GoHighLevel to Twilio. This is the
list the owner runs, in order. Nothing in it is automated, and nothing in the
application changes while it is being run: the move itself is one row in
`org_settings`, set from **Admin → System → Client line**, and set back the
same way.

Written 27 November 2026, against the `twilio` branch.

## What the switch is

`org_settings.sms_provider` is `ghl` or `twilio`, and it governs texting and
calls together — a practice half on one carrier is a practice whose client
line rings in two places. One file reads it, `lib/text-provider.ts`, and
everything above that file records the message and asks the database's
permission without knowing which company carries it.

Two things follow that are worth knowing before the day:

- **Putting it back is one click.** Admin → System → Client line, choose
  GoHighLevel, "Move the line". No deploy, no build, no wait.
- **The screen refuses a carrier whose keys are not set.** Moving the line to
  Twilio before the API key is in Vercel is refused with the names of the
  missing variables, rather than accepted and then failing on every text.

## The environment variables

The owner enters all of these in Vercel. Nothing here ever reads or prints
them, and **none of their values is written down in this repository** — not
even the account and messaging-service identifiers, which are not secret but
are the kind of thing that stops being not-secret once it is in a git history
somebody can read. GitHub's own push protection refuses them, which is the
right answer; the values are in Vercel and in the owner's own notes.

| | what it is for |
|---|---|
| `TWILIO_ACCOUNT_SID` | the Zion subaccount |
| `TWILIO_MESSAGING_SERVICE_SID` | the messaging service that carries the number, the campaign and the opt-out list |
| `TWILIO_API_KEY_SID` | signs outbound REST calls; scoped, and can be destroyed without touching the account |
| `TWILIO_API_KEY_SECRET` | its secret |
| `TWILIO_AUTH_TOKEN` | **not interchangeable with the API key.** Twilio signs its webhooks with this and there is no choice about it: a request arriving at `/api/twilio/*` can only be proved to be Twilio's by recomputing the signature with it |
| `TWILIO_TWIML_APP_SID` | the voice app, for part B |
| `TWILIO_FROM_NUMBER` | the client line, once it has arrived |

`NEXT_PUBLIC_SITE_URL` has to be set for delivery statuses to come back. It
already is. Without it no `StatusCallback` is asked for, the quarter-hourly
catch-up settles each status instead, and nothing breaks — it is just slower.

## The checklist

1. **The campaign is approved.** A2P 10DLC, on the Zion subaccount. Nothing
   below is worth starting until it is: traffic from an unregistered number is
   filtered rather than delivered, and a filtered text reads on our side as
   sent.
2. **The number arrives from GoHighLevel.** A hosted-number or port request
   for 385-406-3432. While it is in flight the line still rings and texts at
   GoHighLevel, and the switch stays on `ghl`.
3. **Attach the number** to the messaging service named by
   `TWILIO_MESSAGING_SERVICE_SID`, and to the approved campaign.
4. **Set the webhooks on it.** Both are POST, and the path has to match
   character for character — the URL is part of what Twilio signs, so a
   trailing slash or a different host means every request is refused.
   - Messaging service, inbound: `https://crm.zionvocrehab.com/api/twilio/sms`
   - Voice, on the number: `https://crm.zionvocrehab.com/api/twilio/voice`
     *(part B; leave the number's voice webhook at GoHighLevel until part B is
     live)*
   - Delivery status needs no setting here: every message is sent with
     `StatusCallback` pointing at `/api/twilio/status`.
5. **Turn on Advanced Opt-Out** on the messaging service, and leave it on.
   It answers STOP itself and refuses to deliver to a number that has opted
   out. Our own consent table is the practice's record and is what the sending
   gate asks before any text is written, so a message needs both to say yes.
   They cannot disagree in the direction that matters: if either says no,
   nothing goes.
6. **Set `TWILIO_FROM_NUMBER`** in Vercel and redeploy.
7. **Move the line.** Admin → System → Client line → Twilio → "Move the line".
8. **Prove it, in this order**, and stop at the first one that does not work:
   - one text out to your own phone, and watch it reach **Delivered** on the
     client's Messages tab rather than staying on Sent;
   - one reply in, and see it on the thread;
   - text **STOP** from that phone, and check consent is withdrawn on the
     client's record; then **START**, and check it comes back;
   - text `3 YES` against a weekly update that listed three applications, and
     check the rating lands on the third one on the Jobs tab;
   - one call in, answered in the browser;
   - one call in, unanswered, and check the voicemail, its transcript and the
     contact-log line appear on the client.
9. **Release the test number**, once the real one is carrying traffic.
10. **Remove `GHL_API_KEY`** and the other GHL variables from Vercel, in a
    follow-up commit, after a week on Twilio with nothing to go back for.

## What this does not move, and what to take out afterwards

**`lib/portal/deliver.ts`** still calls GoHighLevel directly, and is left that
way on purpose. It sends the client portal's sign-in code and its "something
is waiting" notice, and it bypasses the recorded door because that door would
refuse a code to somebody who has just typed their own number in. The portal
is no longer planned, so:

> **Remove once the portal is retired:** `lib/portal/deliver.ts`,
> `lib/portal/notify.ts`, and the `portal_claim_notice` / `portal_note_notice`
> path behind them. Until then they are the one remaining direct caller of
> GoHighLevel, and after step 10 they will fail with "Texting is not set up",
> which is the right answer for a retired feature.

`clients.ghl_id` is **left in place**. It is the cached GoHighLevel contact id
for 67 of the clients who came across from there, Twilio never learns one, and
it is exactly what a move back would need.

## Where the opt-out notice lives, in each

Neither carrier's STOP line comes from this repository, which means it can be
switched off somewhere nobody here would see:

- **GoHighLevel:** the sub-account's periodic opt-out setting — first message
  to a contact, then once every thirty days.
- **Twilio:** Advanced Opt-Out on the messaging service — step 5 above.

If it is ever switched off at whichever carrier is live, nothing carries the
notice at all, and the sentence has to come back into `reminderText` in
`lib/sms.ts`, where there is a comment saying so.

## What the move changes about the rules: nothing

Consent per number, 8am–9pm Mountain, English only, the Friday update going
only when somebody clicks it, and no automated text to a client beyond what
exists today. All of them are the database's, on the way in, and
`verify_the_provider_is_a_setting.sql` asks them again with the switch on
Twilio — because a cutover that quietly started texting people who had said no
would be the worst way to find out they were per-provider rules.
