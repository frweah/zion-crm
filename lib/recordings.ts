import "server-only";

import { CONTACT_KINDS, type Summary } from "@/lib/recordings-shape";

/**
 * Reading a recording: Azure Speech for the words, Azure OpenAI for the draft.
 *
 * Item F. Two services, both the practice's own resources, both read from the
 * environment and never from anything in this repository.
 *
 * Why batch and not streaming: a meeting is twenty minutes to an hour, it is
 * recorded and then uploaded, and nobody is waiting at a microphone for the
 * words to appear. Batch transcription takes a URL to the audio, runs
 * somewhere else, and is asked about later - which is also what makes the
 * cost guard possible, because the practice knows the length of the audio
 * before it reads the next one.
 *
 * Every failure here comes back as Azure's own words. The two services report
 * a rejected request precisely and this practice has lost days to a wrapper
 * that turned "the diarization property is not valid for this version" into
 * "the recording could not be read".
 */

const SPEECH_KEY = () => process.env.AZURE_SPEECH_KEY ?? "";
const SPEECH_REGION = () => process.env.AZURE_SPEECH_REGION ?? "";
const OPENAI_ENDPOINT = () => (process.env.AZURE_OPENAI_ENDPOINT ?? "").replace(/\/$/, "");
const OPENAI_KEY = () => process.env.AZURE_OPENAI_KEY ?? "";
const OPENAI_DEPLOYMENT = () => process.env.AZURE_OPENAI_DEPLOYMENT ?? "";

/** The one place that decides whether the feature is on at all. */
export function recordingsEnabled(): boolean {
  return (process.env.RECORDINGS_ENABLED ?? "").toLowerCase() === "true";
}

/** What is missing, said plainly, so a screen can say it rather than fail. */
export function recordingsNotReady(): string | null {
  if (!recordingsEnabled()) return "Recordings are switched off.";
  const missing = [
    !SPEECH_KEY() && "AZURE_SPEECH_KEY",
    !SPEECH_REGION() && "AZURE_SPEECH_REGION",
    !OPENAI_ENDPOINT() && "AZURE_OPENAI_ENDPOINT",
    !OPENAI_KEY() && "AZURE_OPENAI_KEY",
    !OPENAI_DEPLOYMENT() && "AZURE_OPENAI_DEPLOYMENT",
  ].filter(Boolean);
  return missing.length ? `Not set: ${missing.join(", ")}.` : null;
}

export type Turn = { speaker: number; at: number; text: string };

export type Reading = {
  turns: Turn[];
  transcript: string;
  minutes: number;
};

export type { Summary } from "@/lib/recordings-shape";

type Fail = { ok: false; error: string };
type Ok<T> = { ok: true; data: T };
export type Result<T> = Ok<T> | Fail;

const fail = (error: string): Fail => ({ ok: false, error: error.slice(0, 500) });

/** Azure's own answer, as far as it can be read. */
async function said(res: Response): Promise<string> {
  const text = await res.text().catch(() => "");
  try {
    const body = JSON.parse(text) as { error?: { message?: string; code?: string }; message?: string };
    return (
      body.error?.message ??
      body.message ??
      (body.error?.code || text.slice(0, 300))
    );
  } catch {
    return text.slice(0, 300) || `HTTP ${res.status}`;
  }
}

/**
 * Start a batch transcription, with diarization.
 *
 * **Both diarization properties are sent on purpose.** Microsoft's own docs
 * for v3.2 disagree with each other: the how-to pages describe a boolean
 * `diarizationEnabled`, and the REST reference describes an object
 * `diarization.speakers` with a minimum and a maximum. One of the two is
 * ignored by whichever the service accepts, and sending both means the first
 * recording this practice ever submits is read rather than refused on a
 * detail in a document. If the service rejects the body outright, its words
 * end up on the recording for somebody to read.
 */
export async function startReading(params: {
  audioUrl: string;
  label: string;
}): Promise<Result<string>> {
  const notReady = recordingsNotReady();
  if (notReady) return fail(notReady);

  const url = `https://${SPEECH_REGION()}.api.cognitive.microsoft.com/speechtotext/v3.2/transcriptions`;
  const body = {
    contentUrls: [params.audioUrl],
    locale: "en-US",
    displayName: params.label.slice(0, 200),
    properties: {
      diarizationEnabled: true,
      diarization: { speakers: { minCount: 1, maxCount: 6 } },
      punctuationMode: "DictatedAndAutomatic",
      // A conversation about somebody's life is not cleaned up for them. The
      // transcript is what was said.
      profanityFilterMode: "None",
      wordLevelTimestampsEnabled: false,
    },
  };

  let res: Response;
  try {
    res = await fetch(url, {
      method: "POST",
      headers: {
        "Ocp-Apim-Subscription-Key": SPEECH_KEY(),
        "Content-Type": "application/json",
      },
      body: JSON.stringify(body),
    });
  } catch (err) {
    return fail(`Azure Speech could not be reached: ${(err as Error).message}`);
  }

  if (!res.ok) return fail(`Azure Speech refused the recording: ${await said(res)}`);

  const made = (await res.json().catch(() => null)) as { self?: string } | null;
  if (!made?.self) return fail("Azure Speech accepted the recording but named no job to ask about.");
  return { ok: true, data: made.self };
}

/**
 * Ask about a job.
 *
 * Three answers worth telling apart: still running, read, and failed. A
 * fourth - the job is gone - is treated as a failure, because a job Azure has
 * forgotten is not going to answer.
 */
export async function askAboutReading(
  jobUrl: string,
): Promise<Result<{ done: boolean; reading?: Reading; failure?: string }>> {
  const notReady = recordingsNotReady();
  if (notReady) return fail(notReady);

  let res: Response;
  try {
    res = await fetch(jobUrl, { headers: { "Ocp-Apim-Subscription-Key": SPEECH_KEY() } });
  } catch (err) {
    return fail(`Azure Speech could not be reached: ${(err as Error).message}`);
  }
  if (res.status === 404) return { ok: true, data: { done: true, failure: "Azure no longer has that job." } };
  if (!res.ok) return fail(`Azure Speech would not say: ${await said(res)}`);

  const job = (await res.json().catch(() => null)) as
    | { status?: string; properties?: { error?: { message?: string } }; links?: { files?: string } }
    | null;
  const status = job?.status ?? "";
  if (status === "NotStarted" || status === "Running") return { ok: true, data: { done: false } };
  if (status !== "Succeeded") {
    return {
      ok: true,
      data: { done: true, failure: job?.properties?.error?.message ?? `Azure said ${status || "nothing"}.` },
    };
  }

  const files = job?.links?.files;
  if (!files) return fail("Azure says the job succeeded but offers no result to read.");

  let listRes: Response;
  try {
    listRes = await fetch(files, { headers: { "Ocp-Apim-Subscription-Key": SPEECH_KEY() } });
  } catch (err) {
    return fail(`Azure Speech could not be reached: ${(err as Error).message}`);
  }
  if (!listRes.ok) return fail(`Azure Speech would not list the result: ${await said(listRes)}`);

  const list = (await listRes.json().catch(() => null)) as
    | { values?: { kind?: string; links?: { contentUrl?: string } }[] }
    | null;
  const transcriptFile = (list?.values ?? []).find((f) => f.kind === "Transcription");
  const contentUrl = transcriptFile?.links?.contentUrl;
  if (!contentUrl) {
    return { ok: true, data: { done: true, failure: "Azure returned no transcript for that job." } };
  }

  // The result itself is behind a signed URL and needs no key.
  let contentRes: Response;
  try {
    contentRes = await fetch(contentUrl);
  } catch (err) {
    return fail(`The transcript could not be fetched: ${(err as Error).message}`);
  }
  if (!contentRes.ok) return fail(`The transcript could not be fetched: HTTP ${contentRes.status}`);

  const result = (await contentRes.json().catch(() => null)) as
    | {
        durationMilliseconds?: number;
        duration?: string;
        combinedRecognizedPhrases?: { display?: string }[];
        recognizedPhrases?: {
          speaker?: number;
          offsetMilliseconds?: number;
          nBest?: { display?: string }[];
        }[];
      }
    | null;
  if (!result) return fail("The transcript came back as something other than a reading.");

  const turns: Turn[] = (result.recognizedPhrases ?? [])
    .map((p) => ({
      speaker: Number(p.speaker ?? 0),
      at: Math.round(Number(p.offsetMilliseconds ?? 0) / 1000),
      text: (p.nBest?.[0]?.display ?? "").trim(),
    }))
    .filter((t) => t.text !== "");

  const transcript =
    (result.combinedRecognizedPhrases ?? []).map((p) => (p.display ?? "").trim()).filter(Boolean).join("\n") ||
    turns.map((t) => t.text).join(" ");

  const ms = Number(result.durationMilliseconds ?? 0);
  return {
    ok: true,
    data: {
      done: true,
      reading: { turns, transcript, minutes: Math.round((ms / 60000) * 100) / 100 },
    },
  };
}

/**
 * The draft summary, in the fixed shape.
 *
 * Four fields, and they are the four things the practice already keeps about
 * a meeting: the contact log's topic, outcome and follow-up, and the note
 * that goes on the record. A fifth field would be a new kind of thing for
 * somebody to read and nowhere for it to go.
 *
 * The prompt says what not to write as well as what to write, because a
 * transcript of a meeting with a client contains things that have no business
 * being summarised onto a record - a diagnosis mentioned in passing, what
 * somebody's benefits are worth, what an employer said about another
 * employee. The model is told to leave them out, and then **a person reads
 * the draft before any of it counts**, which is the part that actually holds.
 */
export async function draftSummary(params: {
  transcript: string;
  clientFirstName: string;
}): Promise<Result<Summary>> {
  const notReady = recordingsNotReady();
  if (notReady) return fail(notReady);
  if (params.transcript.trim() === "") return fail("There are no words in that recording to summarise.");

  const url =
    `${OPENAI_ENDPOINT()}/openai/deployments/${OPENAI_DEPLOYMENT()}/chat/completions` +
    `?api-version=2024-10-21`;

  const system = [
    "You summarise a recorded meeting between a vocational rehabilitation practice and a client.",
    "Answer as JSON with exactly these keys: kind, present, discussed, decisions, next, question.",
    "kind: exactly one of \"Job site visit\", \"Planning meeting\", \"Phone\" — whichever the recording is of.",
    "present: who was in the conversation, named as they were named in it.",
    "discussed: what was discussed, in one or two sentences.",
    "decisions: what was decided. Empty if nothing was.",
    "next: the next steps and who is doing them, with a day only where one was said in those words.",
    "Never work out a date and never guess one.",
    "question: one thing worth asking at the next contact. Empty if nothing is.",
    "The whole answer is 100 words or fewer across all six. It is read before a meeting, not instead of the recording.",
    "Minimum necessary: nothing about the client's health, any diagnosis or medication, nothing legal,",
    "nothing about benefits or money the state pays them, and nothing about their family.",
    "Leave those out even when they were discussed — the staff member adds what belongs on the record.",
    "Leave out anything an employer said in confidence about their business or another employee.",
    "Write only what was said. Never infer, never advise, never add encouragement. No exclamation marks.",
  ].join(" ");

  let res: Response;
  try {
    res = await fetch(url, {
      method: "POST",
      headers: { "api-key": OPENAI_KEY(), "Content-Type": "application/json" },
      body: JSON.stringify({
        messages: [
          { role: "system", content: system },
          {
            role: "user",
            content:
              `The client's first name is ${params.clientFirstName || "unknown"}.\n\n` +
              `Transcript:\n${params.transcript.slice(0, 60000)}`,
          },
        ],
        temperature: 0.2,
        max_tokens: 700,
        response_format: { type: "json_object" },
      }),
    });
  } catch (err) {
    return fail(`Azure OpenAI could not be reached: ${(err as Error).message}`);
  }
  if (!res.ok) return fail(`Azure OpenAI refused the transcript: ${await said(res)}`);

  const answer = (await res.json().catch(() => null)) as
    | { choices?: { message?: { content?: string } }[] }
    | null;
  const content = answer?.choices?.[0]?.message?.content ?? "";
  if (!content) return fail("Azure OpenAI answered with nothing.");

  let parsed: Record<string, unknown>;
  try {
    parsed = JSON.parse(content) as Record<string, unknown>;
  } catch {
    return fail("Azure OpenAI answered with something that is not the shape asked for.");
  }

  const line = (k: string) => String(parsed[k] ?? "").replace(/\s+/g, " ").trim();
  const kind = line("kind");
  const summary: Summary = {
    // A type of contact that is not one of the three is no type of contact.
    // The person chooses on the form either way; an answer off the list would
    // only preselect something the database then refuses.
    kind: (CONTACT_KINDS as readonly string[]).includes(kind) ? kind : "",
    present: line("present"),
    discussed: line("discussed"),
    decisions: line("decisions"),
    next: line("next"),
    question: line("question"),
  };
  if (!summary.discussed && !summary.decisions && !summary.next) {
    return fail("Azure OpenAI answered with no summary in it.");
  }
  return { ok: true, data: summary };
}
