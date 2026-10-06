/**
 * A zip file, written by hand (ERP brief, E1).
 *
 * The year-end package is a dozen CSVs and the CPA wants one file. That is
 * the only thing the app ever needs to zip, and the stored - uncompressed -
 * form of the format is about sixty lines, so this is sixty lines instead of
 * a dependency the practice would be carrying for one button a year. CSVs are
 * small and a CPA's unzipper does not care that they were not deflated.
 *
 * Stored entries only, no directories, no zip64: a package of text files is
 * nowhere near four gigabytes and never will be.
 */

const CRC_TABLE = (() => {
  const table = new Uint32Array(256);
  for (let i = 0; i < 256; i++) {
    let c = i;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[i] = c >>> 0;
  }
  return table;
})();

function crc32(bytes: Uint8Array): number {
  let c = 0xffffffff;
  for (let i = 0; i < bytes.length; i++) c = CRC_TABLE[(c ^ bytes[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

/** MS-DOS date and time, which is what a zip entry carries. */
function dosStamp(at: Date): { date: number; time: number } {
  const year = Math.max(1980, at.getUTCFullYear());
  return {
    date: ((year - 1980) << 9) | ((at.getUTCMonth() + 1) << 5) | at.getUTCDate(),
    time: (at.getUTCHours() << 11) | (at.getUTCMinutes() << 5) | Math.floor(at.getUTCSeconds() / 2),
  };
}

export type ZipEntry = { name: string; text: string };

/** The entries as one zip file. */
export function zip(entries: ZipEntry[], at: Date = new Date()): Uint8Array {
  const encoder = new TextEncoder();
  const stamp = dosStamp(at);
  const locals: Uint8Array[] = [];
  const centrals: Uint8Array[] = [];
  let offset = 0;

  const u16 = (view: DataView, at: number, v: number) => view.setUint16(at, v, true);
  const u32 = (view: DataView, at: number, v: number) => view.setUint32(at, v, true);

  for (const entry of entries) {
    const name = encoder.encode(entry.name);
    const body = encoder.encode(entry.text);
    const sum = crc32(body);

    const local = new Uint8Array(30 + name.length + body.length);
    const lv = new DataView(local.buffer);
    u32(lv, 0, 0x04034b50);
    u16(lv, 4, 20); // the version that can read it
    u16(lv, 6, 0x0800); // the name is UTF-8
    u16(lv, 8, 0); // stored
    u16(lv, 10, stamp.time);
    u16(lv, 12, stamp.date);
    u32(lv, 14, sum);
    u32(lv, 18, body.length);
    u32(lv, 22, body.length);
    u16(lv, 26, name.length);
    u16(lv, 28, 0);
    local.set(name, 30);
    local.set(body, 30 + name.length);
    locals.push(local);

    const central = new Uint8Array(46 + name.length);
    const cv = new DataView(central.buffer);
    u32(cv, 0, 0x02014b50);
    u16(cv, 4, 20); // written by
    u16(cv, 6, 20); // readable by
    u16(cv, 8, 0x0800);
    u16(cv, 10, 0);
    u16(cv, 12, stamp.time);
    u16(cv, 14, stamp.date);
    u32(cv, 16, sum);
    u32(cv, 20, body.length);
    u32(cv, 24, body.length);
    u16(cv, 28, name.length);
    u16(cv, 30, 0);
    u16(cv, 32, 0);
    u16(cv, 34, 0);
    u16(cv, 36, 0);
    u32(cv, 38, 0);
    u32(cv, 42, offset);
    central.set(name, 46);
    centrals.push(central);

    offset += local.length;
  }

  const centralSize = centrals.reduce((n, c) => n + c.length, 0);
  const end = new Uint8Array(22);
  const ev = new DataView(end.buffer);
  u32(ev, 0, 0x06054b50);
  u16(ev, 4, 0);
  u16(ev, 6, 0);
  u16(ev, 8, entries.length);
  u16(ev, 10, entries.length);
  u32(ev, 12, centralSize);
  u32(ev, 16, offset);
  u16(ev, 20, 0);

  const total = offset + centralSize + end.length;
  const out = new Uint8Array(total);
  let at2 = 0;
  for (const part of [...locals, ...centrals, end]) {
    out.set(part, at2);
    at2 += part.length;
  }
  return out;
}
