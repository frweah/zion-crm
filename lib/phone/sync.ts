/**
 * Sending what the phone saved (owner, 11 Nov 2026).
 *
 * "Synced when back online, shown as 'waiting to send' until then; a sync
 * that fails is shown, never silent."
 *
 * One item at a time, oldest first, because order matters: a break taken
 * before a clock-in has been sent would be refused for no reason. Each item
 * ends in one of three places, and the list on the phone shows which:
 *
 *   sent      - off the phone. "Already done" counts: the first attempt
 *               arrived and its answer did not.
 *   waiting   - no signal, or the practice did not answer. Tried again by
 *               itself, with the reason shown in the meantime.
 *   refused   - the practice said no, with the sentence why. Not tried
 *               again by itself, because the same thing sent again would be
 *               refused again; the person can try again or discard it.
 *
 * Signed out, or a gate (a second factor to enter): everything stays and the
 * phone says what to do. That is the "could not get an answer is not no"
 * rule (CLAUDE.md) - nothing is thrown away because a session lapsed.
 *
 * One run at a time, across tabs, with a Web Lock where the browser has one.
 */
import { createClient } from "@/lib/supabase/client";
import { allItems, putItem, dropItem, type OutboxItem } from "./store";

export type SyncOutcome = {
  sent: number;
  /** Set when nothing more can be sent until the person does something. */
  stopped: null | "offline" | "signed out" | "gate";
  gate?: string;
};

type Answer =
  | { kind: "sent" }
  | { kind: "refused"; error: string }
  | { kind: "later"; error: string }
  | { kind: "signed out" }
  | { kind: "gate"; gate: string };

const NO_ANSWER = "Not sent yet — no signal, or the practice did not answer.";

async function post(body: Record<string, unknown>): Promise<Answer> {
  let res: Response;
  try {
    res = await fetch("/api/phone/sync", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
      credentials: "same-origin",
      cache: "no-store",
    });
  } catch {
    return { kind: "later", error: NO_ANSWER };
  }
  // The gate in front of the app answers a lapsed session with the sign-in
  // page, not with a 401. HTML where JSON was expected is that.
  const type = res.headers.get("content-type") ?? "";
  if (res.redirected && new URL(res.url).pathname.startsWith("/login")) return { kind: "signed out" };
  if (!type.includes("application/json")) {
    return res.status >= 500 ? { kind: "later", error: NO_ANSWER } : { kind: "signed out" };
  }
  const json = (await res.json().catch(() => ({}))) as { ok?: string; error?: string; gate?: string };
  if (res.ok) return { kind: "sent" };
  if (res.status === 401) return { kind: "signed out" };
  if (res.status === 403 && json.gate) return { kind: "gate", gate: json.gate };
  if (res.status === 422 || res.status === 400 || res.status === 404) {
    return { kind: "refused", error: json.error ?? "The practice refused that." };
  }
  return { kind: "later", error: json.error ? `Not sent yet — ${json.error}` : NO_ANSWER };
}

/** Put the bytes up under the item's key, once. */
async function upload(item: OutboxItem): Promise<Answer | { kind: "up"; path: string }> {
  if (item.uploaded) return { kind: "up", path: item.uploaded };
  if (!item.blob) return { kind: "refused", error: "The photo or recording is no longer on this phone." };
  const clientId = String(item.payload.client_id ?? "");
  const ext = (item.blobName ?? "").includes(".") ? (item.blobName ?? "").split(".").pop() : "bin";
  const path = `clients/${clientId}/${item.key}.${ext}`;
  // The bucket compares the bare type: "audio/webm;codecs=opus" is refused
  // where "audio/webm" is taken.
  const type = (item.blob.type || "application/octet-stream").split(";")[0];
  try {
    const { error } = await createClient().storage.from("client-files").upload(path, item.blob, { contentType: type, upsert: false });
    if (error) {
      const m = error.message.toLowerCase();
      // Up already - an earlier attempt got this far and no further.
      if (m.includes("exists") || m.includes("duplicate")) return { kind: "up", path };
      if (m.includes("mime") || m.includes("type")) return { kind: "refused", error: `${type} is not a file the record takes.` };
      if (m.includes("jwt") || m.includes("auth") || m.includes("unauthor")) return { kind: "signed out" };
      if (m.includes("row-level") || m.includes("policy")) {
        return { kind: "refused", error: "The record would not take that file from you — ask whoever works this client." };
      }
      return { kind: "later", error: `Not sent yet — ${error.message}` };
    }
  } catch {
    return { kind: "later", error: NO_ANSWER };
  }
  return { kind: "up", path };
}

async function sendOne(item: OutboxItem): Promise<Answer> {
  if (item.kind === "file") {
    const up = await upload(item);
    if (up.kind !== "up") return up;
    if (!item.uploaded) {
      item.uploaded = up.path;
      await putItem(item);
    }
    return post({ key: item.key, kind: item.kind, at: item.at, ...item.payload, storage_path: up.path });
  }
  return post({ key: item.key, kind: item.kind, at: item.at, ...item.payload });
}

async function runOnce(me: string, onChange: () => void): Promise<SyncOutcome> {
  const outcome: SyncOutcome = { sent: 0, stopped: null };
  if (typeof navigator !== "undefined" && navigator.onLine === false) {
    outcome.stopped = "offline";
    return outcome;
  }

  let clockHeld = false;
  for (const item of await allItems()) {
    if (item.owner !== me || item.status === "refused") {
      if (item.kind === "clock" && item.status === "refused") clockHeld = true;
      continue;
    }
    // A clock entry after one the practice refused would be refused for the
    // same reason. It waits for that one to be dealt with.
    if (item.kind === "clock" && clockHeld) {
      item.error = "Waiting on the clock entry before it.";
      await putItem(item);
      onChange();
      continue;
    }

    item.status = "sending";
    item.tries += 1;
    await putItem(item);
    onChange();

    const answer = await sendOne(item);
    if (answer.kind === "sent") {
      await dropItem(item.key);
      outcome.sent += 1;
      onChange();
      continue;
    }
    if (answer.kind === "refused") {
      item.status = "refused";
      item.error = answer.error;
      await putItem(item);
      if (item.kind === "clock") clockHeld = true;
      onChange();
      continue;
    }
    item.status = "waiting";
    item.error =
      answer.kind === "later"
        ? answer.error
        : answer.kind === "signed out"
          ? "Not sent yet — sign in again to send it."
          : "Not sent yet — finish signing in to send it.";
    await putItem(item);
    onChange();
    outcome.stopped = answer.kind === "later" ? "offline" : answer.kind;
    if (answer.kind === "gate") outcome.gate = answer.gate;
    break;
  }
  return outcome;
}

/** Send whatever is waiting. Safe to call as often as anything changes. */
export async function syncNow(me: string, onChange: () => void): Promise<SyncOutcome> {
  const locks = typeof navigator !== "undefined" ? (navigator as Navigator & { locks?: LockManager }).locks : undefined;
  if (!locks) return runOnce(me, onChange);
  let result: SyncOutcome = { sent: 0, stopped: null };
  await locks.request("zion-phone-sync", { ifAvailable: true }, async (lock) => {
    if (!lock) return; // Another tab is sending; it will tell its own list.
    result = await runOnce(me, onChange);
  });
  return result;
}

/** Back to waiting, for "Try again" on a refused item - after the person has fixed what was wrong. */
export async function retry(item: OutboxItem): Promise<void> {
  item.status = "waiting";
  item.error = undefined;
  await putItem(item);
}

/**
 * An item left "sending" by a page that went to sleep mid-send.
 *
 * Safe to send again - that is what the key is for - so it goes back to
 * waiting rather than sitting as "sending" for ever.
 */
export async function unstick(): Promise<void> {
  for (const item of await allItems()) {
    if (item.status === "sending") {
      item.status = "waiting";
      await putItem(item);
    }
  }
}
