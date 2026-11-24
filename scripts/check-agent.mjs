/**
 * The documents agent: its two schedules, and the words that describe them.
 *
 * The agent runs on one machine that nothing here can reach, so the only
 * thing checkable before a build is that the files agree with each other -
 * and they are four files that each say when it runs: the installer that
 * registers the tasks, the script that decides what a run does, the batch
 * file somebody double-clicks, and the card in the CRM that tells the owner
 * whether it is alive.
 *
 * On 23 November 2026 the folder walk moved from every fifteen minutes to
 * 10:00 and 19:00, and the photo pass stayed quarter-hourly. Four files had
 * to change together. This is what stops the fifth change from leaving one of
 * them saying the old thing - which is the same failure as a screen naming a
 * hub that has moved, and the card is read by the person deciding whether to
 * worry.
 */
import { readFileSync } from "node:fs";

const problems = [];
const bad = (line) => problems.push(line);
const read = (p) => readFileSync(new URL(`../${p}`, import.meta.url), "utf8");

const installer = read("agent/install.ps1");
const script = read("agent/zion-agent.ps1");
const cmd = read("agent/install.cmd");
const card = read("app/(app)/admin/inbox/agent-status.tsx");

// ── the hours, from the installer, which is what registers them ──
const hours = installer.match(/\$ScanHours\s*=\s*@\(([^)]*)\)/)?.[1];
const scanHours = hours ? hours.split(",").map((h) => Number(h.trim())).filter((h) => Number.isFinite(h)) : [];
if (scanHours.length === 0) {
  bad("the installer names no hours for the full pass, so nothing says when the folders are read");
}
for (const h of scanHours) {
  if (h < 0 || h > 23) bad(`${h} is not an hour of the day`);
}

/** 10 → "10:00", 19 → "19:00", which is how every file writes them. */
const written = scanHours.map((h) => `${String(h).padStart(2, "0")}:00`);

// ── the two tasks exist, and only one of them passes -Scan ──
if (!/\$TaskName\s*=\s*'Zion CRM document agent'/.test(installer)) {
  bad("the full-pass task has lost its name");
}
if (!/\$PhotoTask\s*=\s*'Zion CRM document agent \(photos\)'/.test(installer)) {
  bad("the quarter-hourly task has lost its name");
}
/**
 * The argument, to the end of its line.
 *
 * Not `"([^"]+)"`: the argument embeds escaped quotes around the script's
 * path, so that pattern stopped at the first one and reported the full pass
 * as not passing -Scan when it does.
 */
const argumentAfter = (name) => {
  const line = installer
    .split("\n")
    .find((l, i, all) => l.includes(`-Argument`) && (all[i - 1] ?? '').includes(`${name}`));
  return line ?? '';
};
const scanAction = argumentAfter("scanAction");
const lightAction = argumentAfter("lightAction");
if (!scanAction.trim().endsWith(`-Scan"`)) {
  bad("the full pass does not pass -Scan, so it would do the light work twice a day and nothing else");
}
if (/-Scan/.test(lightAction)) {
  bad("the quarter-hourly task passes -Scan, which is the folder walk back every fifteen minutes");
}

// ── the triggers say what the hours say ──
for (const h of scanHours) {
  if (!new RegExp(`AddHours\\(\\$h\\)`).test(installer) && !installer.includes(`AddHours(${h})`)) {
    bad(`nothing registers a trigger for ${h}:00`);
  }
}
if (!/-RepetitionInterval \(New-TimeSpan -Minutes 15\)/.test(installer)) {
  bad("the quarter-hourly trigger is gone, so photos wait for the next full pass");
}
if (!/-AtLogOn/.test(installer)) {
  bad("nothing runs at logon, so a machine that was off overnight waits for a schedule");
}
if (!/-StartWhenAvailable/.test(installer)) {
  bad("a missed 10:00 is never made up, because StartWhenAvailable is not set");
}

// ── the script knows the switch, and a light pass stops early ──
if (!/\[switch\] \$Scan/.test(script)) bad("the agent has no -Scan switch for the installer to pass");
if (!/\$DidScan\s*=/.test(script)) bad("the agent never decides whether this is a full pass");
if (!/if \(-not \$DidScan\) \{[\s\S]{0,400}?exit 0/.test(script)) {
  bad("a light pass does not stop before the folder walk, so nothing moved twice a day");
}
if (!/Save-FailedOcr/.test(script)) {
  bad("the failed-OCR memory is not saved by name, so one of the two passes will forget it");
}
// The light pass must save it: it is the pass that reads photos.
const light = script.match(/if \(-not \$DidScan\) \{([\s\S]{0,400}?)exit 0/)?.[1] ?? "";
if (!/Save-FailedOcr/.test(light)) {
  bad("a light pass exits without saving what failed, so a photo it cannot read is retried every wake");
}
if (!/scanRequests\s*=\s*@\(\$ScanRequests\)/.test(script)) {
  bad("the manifest does not carry the extra passes it answers, so Run now would ask for ever");
}

// ── the quarter-hourly pass says it ran, and the card says when ──
//
// The folder walk leaves a row in `inbox_runs`; the light pass leaves nothing
// unless it stamps one, which makes this the half of the agent that can stop
// without anybody seeing. Three files have to agree: the script that stamps,
// the route that writes the row, and the card that judges the time.
const route = read("app/api/agent/light-pass/route.ts");

if (!/api\/agent\/light-pass/.test(script)) {
  bad("the agent never stamps a heartbeat, so a stopped photo task looks like a quiet week");
}
/**
 * Where it stamps, which is the whole of the rule.
 *
 * Below the `-not $DidScan` exit it would only ever be reached by a full
 * pass - the one pass that already leaves a row - so the line would be there
 * and the heartbeat would still never be written by the task it is about.
 */
const exitAt = script.search(/if \(-not \$DidScan\) \{/);
const stampAt = script.search(/api\/agent\/light-pass/);
if (stampAt >= 0 && exitAt >= 0 && stampAt > exitAt) {
  bad("the heartbeat is stamped below the light pass's exit, so only a full pass would ever send it");
}
/**
 * And after the photos, not before them.
 *
 * A stamp sent on the way in says the pass started. The run that then hangs
 * on a page Tesseract cannot read would be reported as a healthy one, which
 * is the single thing this row exists to not do.
 */
const photosAt = script.search(/\$photosRead\+\+/);
if (stampAt >= 0 && photosAt >= 0 && stampAt < photosAt) {
  bad("the heartbeat is stamped before the photos are read, so a run that hangs still reports itself healthy");
}
/** And only by the quarter-hourly task: $Scan is what the daily one passes. */
const stampBlock = script.slice(Math.max(0, stampAt - 400), stampAt);
if (stampAt >= 0 && !/if \(-not \$Scan\) \{/.test(stampBlock)) {
  bad("a full pass stamps the photo heartbeat too, so the card cannot say which task stopped");
}
if (!/\$photosRead/.test(script.slice(stampAt, stampAt + 400))) {
  bad("the heartbeat does not carry what the pass read, so the card can only say that it ran");
}

if (!/kind:\s*"light pass"/.test(route)) {
  bad("the route does not stamp the light pass, so the card would read a row nothing writes");
}
if (!/onConflict:\s*"kind"/.test(route)) {
  bad("the route does not upsert on the kind, so a pass every fifteen minutes leaves a row");
}

if (!/from\("agent_heartbeat"\)/.test(card)) {
  bad("the agent card does not read the heartbeat, so the stamp is written and shown to nobody");
}
if (!/eq\("kind",\s*"light pass"\)/.test(card)) {
  bad("the agent card does not ask for the light pass by name");
}
/**
 * And the card's patience is the schedule's.
 *
 * A card that calls the photos stale after one missed wake cries wolf on a
 * machine that was busy; one that waits six hours is not watching. The
 * installer's interval is the authority, as it is for the hours.
 */
const everyMin = Number(installer.match(/-RepetitionInterval \(New-TimeSpan -Minutes (\d+)\)/)?.[1]);
const stale = Number(card.match(/(\d+)\s*\*\s*60\s*\*\s*1000/)?.[1]);
if (!Number.isFinite(stale)) {
  bad("the agent card has no threshold for a photo pass that has stopped");
} else if (Number.isFinite(everyMin)) {
  if (stale < everyMin * 2) {
    bad(`the card calls the photos stale after ${stale} minutes, which is under two ${everyMin}-minute wakes`);
  }
  if (stale > everyMin * 6) {
    bad(`the card waits ${stale} minutes before saying the photo pass stopped, which is most of a morning`);
  }
}

// ── and every file that names the hours names the same ones ──
const sayings = [
  ["agent/install.ps1", installer],
  ["agent/install.cmd", cmd],
  ["agent/zion-agent.ps1", script],
  ["the agent card", card],
];
for (const [name, text] of sayings) {
  for (const hour of written) {
    if (!text.includes(hour)) bad(`${name} does not say ${hour}, and that is when the folders are read`);
  }
  if (/every (?:15|fifteen) minutes/i.test(text) === false) {
    bad(`${name} does not mention the quarter-hourly pass at all`);
  }
}
// The card must not still promise a quarter-hourly folder walk.
if (/It runs every fifteen minutes/.test(card)) {
  bad("the agent card still tells the owner the folders are read every fifteen minutes");
}

if (problems.length) {
  for (const p of problems) console.error(`  - ${p}`);
  console.error(`\n  FAILED  ${problems.length} problem(s) with the documents agent`);
  process.exit(1);
}
console.log(
  `  ok  the agent reads the folders at ${written.join(" and ")}, the photos every 15 minutes, and four files say so`,
);
