/**
 * Reading the carrier switch, as a rule rather than a call.
 *
 * No imports, no environment, no database client: it takes what the database
 * answered and says what to do about it. That is the whole reason it is its
 * own file - `scripts/check-twilio.mjs` can run it over every way of not
 * getting an answer, which a check that greps for a sentence cannot.
 *
 * The first version of that check did grep for the sentence, and a fault that
 * added a fallback *above* the refusal passed it: the words were still in the
 * file, in a branch nothing could reach. The rule is what an unreadable
 * switch does, not which words are written near it.
 *
 * And what it does is refuse. The practice has been caught twice by code
 * reading a failure as an answer - middleware that read an auth error as
 * "revoked", `getCurrentStaff` that read a failed query as "no access" and
 * signed the whole practice out. The version of it here would be worse than
 * either: a default would text a client from whichever number the practice is
 * not using, and their reply would arrive somewhere nobody is watching.
 */

export type Carrier = "ghl" | "twilio";

export type Which = { ok: true; carrier: Carrier } | { ok: false; error: string };

/** What the switch said, and whether it is an answer. */
export type Answer = { data: unknown; error: { message: string } | null };

/**
 * One refusal for every way of not knowing, because they are the same thing.
 *
 * An error, a row that could not be read, and a word this does not recognise
 * all mean the carrier is unknown, and none of them means "send it through the
 * usual one". `sms_provider()` answers null rather than a default (0393)
 * exactly so that this can be one branch.
 */
export function readSwitch(answer: Answer): Which {
  const said = typeof answer.data === "string" ? answer.data : null;

  if (answer.error || (said !== "ghl" && said !== "twilio")) {
    return {
      ok: false,
      error:
        "Could not read which texting provider is in use, so nothing was sent. " +
        (answer.error?.message ?? `The switch answered ${said === null ? "nothing" : said}.`),
    };
  }
  return { ok: true, carrier: said };
}

/** The name this carrier goes by in `sms_messages.provider`. */
export function carrierName(carrier: Carrier): string {
  return carrier === "twilio" ? "Twilio" : "GoHighLevel";
}
