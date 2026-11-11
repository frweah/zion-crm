/**
 * What the phone keeps, in the phone (owner, 11 Nov 2026).
 *
 * Two things, and both are in IndexedDB rather than in memory, because a
 * phone puts a page to sleep the moment somebody answers a call:
 *
 *   The outbox - what somebody pressed with no signal, waiting to be sent.
 *   It is theirs: it stays until it is sent, or until they discard it, and
 *   every item says which. Nothing is ever dropped quietly.
 *
 *   The cache - the last answer for the home, each client opened today, and
 *   Team. It is the practice's: it is thrown away at the end of the day, when
 *   somebody else signs in on the phone, and when the person signs out from
 *   the phone. A client record on a phone overnight is a record on a phone
 *   that can be lost, and the brief asked for "a client already viewed
 *   today", not a copy of the caseload.
 *
 * No database library: four object stores and a handful of calls.
 */

export type OutboxKind = "note" | "file" | "clock" | "tofile" | "team";

export type OutboxItem = {
  /** Made once, when the button was pressed; the server's key for "already done". */
  key: string;
  kind: OutboxKind;
  /** When it was pressed, which is not when it is sent. */
  at: string;
  /** Who pressed it. Only their own items are sent under their session. */
  owner: string;
  /** One line for the list: "Note — Ana Ruiz". */
  label: string;
  payload: Record<string, unknown>;
  /** A photo or a recording, kept as bytes until it is up. */
  blob?: Blob;
  blobName?: string;
  /** The storage path once the bytes are up, so a retry does not upload twice. */
  uploaded?: string;
  status: "waiting" | "sending" | "refused";
  /** The last thing that went wrong, in a sentence. */
  error?: string;
  tries: number;
};

type CacheEntry = { key: string; day: string; owner: string; savedAt: string; value: unknown };

const DB = "zion-phone";
const VERSION = 1;

function practiceDay(d = new Date()): string {
  return d.toLocaleDateString("en-CA", { timeZone: "America/Denver" });
}

let opening: Promise<IDBDatabase> | null = null;

function open(): Promise<IDBDatabase> {
  if (opening) return opening;
  opening = new Promise((resolve, reject) => {
    const req = indexedDB.open(DB, VERSION);
    req.onupgradeneeded = () => {
      const db = req.result;
      if (!db.objectStoreNames.contains("outbox")) db.createObjectStore("outbox", { keyPath: "key" });
      if (!db.objectStoreNames.contains("cache")) db.createObjectStore("cache", { keyPath: "key" });
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => {
      opening = null;
      reject(req.error ?? new Error("The phone would not open its storage."));
    };
  });
  return opening;
}

function run<T>(store: string, mode: IDBTransactionMode, fn: (s: IDBObjectStore) => IDBRequest<T> | void): Promise<T | undefined> {
  return open().then(
    (db) =>
      new Promise<T | undefined>((resolve, reject) => {
        const tx = db.transaction(store, mode);
        const req = fn(tx.objectStore(store));
        tx.oncomplete = () => resolve(req ? (req.result as T) : undefined);
        tx.onerror = () => reject(tx.error ?? new Error("The phone could not save that."));
        tx.onabort = () => reject(tx.error ?? new Error("The phone could not save that."));
      }),
  );
}

// ── the outbox ───────────────────────────────────────────────

export async function putItem(item: OutboxItem): Promise<void> {
  await run("outbox", "readwrite", (s) => s.put(item));
}

export async function dropItem(key: string): Promise<void> {
  await run("outbox", "readwrite", (s) => s.delete(key));
}

export async function allItems(): Promise<OutboxItem[]> {
  const rows = ((await run<OutboxItem[]>("outbox", "readonly", (s) => s.getAll() as IDBRequest<OutboxItem[]>)) ?? []);
  return rows.sort((a, b) => a.at.localeCompare(b.at) || a.key.localeCompare(b.key));
}

// ── the cache ────────────────────────────────────────────────

export async function remember(key: string, owner: string, value: unknown): Promise<void> {
  const entry: CacheEntry = { key, owner, day: practiceDay(), savedAt: new Date().toISOString(), value };
  await run("cache", "readwrite", (s) => s.put(entry));
}

/** Today's answer for this person, or nothing. Yesterday's is never shown. */
export async function recall<T>(key: string, owner: string): Promise<{ value: T; savedAt: string } | null> {
  const entry = await run<CacheEntry>("cache", "readonly", (s) => s.get(key) as IDBRequest<CacheEntry>);
  if (!entry || entry.owner !== owner || entry.day !== practiceDay()) return null;
  return { value: entry.value as T, savedAt: entry.savedAt };
}

/** The clients opened today, for the list the phone can show with no signal. */
export async function clientsSeenToday(owner: string): Promise<{ id: string; name: string; stage: string }[]> {
  const rows = ((await run<CacheEntry[]>("cache", "readonly", (s) => s.getAll() as IDBRequest<CacheEntry[]>)) ?? []);
  return rows
    .filter((r) => r.key.startsWith("client:") && r.owner === owner && r.day === practiceDay())
    .map((r) => r.value as { id: string; name: string; stage: string })
    .sort((a, b) => a.name.localeCompare(b.name));
}

/**
 * The cache, kept honest: anything from another day or another person goes.
 * Run every time the phone screens open.
 */
export async function tidy(owner: string): Promise<void> {
  const day = practiceDay();
  const rows = ((await run<CacheEntry[]>("cache", "readonly", (s) => s.getAll() as IDBRequest<CacheEntry[]>)) ?? []);
  const stale = rows.filter((r) => r.day !== day || r.owner !== owner).map((r) => r.key);
  if (stale.length) await run("cache", "readwrite", (s) => stale.forEach((k) => s.delete(k)));
}

/** Everything the practice put on the phone, for signing out. The outbox is checked first by the caller. */
export async function forgetAll(): Promise<void> {
  await run("cache", "readwrite", (s) => s.clear());
  await run("outbox", "readwrite", (s) => s.clear());
}

export { practiceDay };
