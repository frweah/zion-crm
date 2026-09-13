/**
 * Where the document inbox keeps its files, and the limits that apply.
 *
 * Shared by the two agent routes so the path a signed upload writes to and the
 * path the file route reads from cannot drift apart. No server-only import:
 * nothing here is secret, and keeping it plain lets a check script use it.
 */

export const INBOX_BUCKET = "client-files";

/**
 * The bucket's own per-file cap (storage.buckets.file_size_limit, 50 MB -
 * raised from 25 MB on 2026-09-13, for a 27.3 MB client scan).
 * Checked before handing out an upload URL so an oversized file is refused
 * with a sentence rather than failing somewhere inside storage.
 */
export const STORAGE_MAX_BYTES = 50 * 1024 * 1024;

/** Under its hash: the same document twice cannot make two copies. */
export function inboxStoragePath(sha256: string): string {
  return `inbox/${sha256.slice(0, 2)}/${sha256}.pdf`;
}

export function isSha256(value: string): boolean {
  return /^[0-9a-f]{64}$/.test(value);
}
