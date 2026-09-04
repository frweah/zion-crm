/**
 * Loads the merged Voc Rehab Workbook + GoHighLevel dataset into Supabase.
 *
 *   node --env-file=.env.local scripts/migrate-data.mjs ../zion-crm-prototype.jsx
 *
 * The data is read straight out of the prototype's DATA constant, so no file
 * of client records is ever created on disk or in this repository. The script
 * itself holds no client data and is safe to commit.
 *
 * Idempotent: every row carries its original id in legacy_id and is upserted
 * on that, so re-running corrects rows rather than duplicating them.
 *
 * Runs in one transaction — it either loads completely or changes nothing.
 */
import { readFile } from "node:fs/promises";
import pg from "pg";

const source = process.argv[2] ?? "../zion-crm-prototype.jsx";

const src = await readFile(source, "utf8");
const match = src.match(/const DATA = (\{.*?\});\r?\n/s);
if (!match) {
  console.error(`Could not find the DATA constant in ${source}`);
  process.exit(1);
}
const DATA = JSON.parse(match[1]);

/** Empty strings in the workbook mean "not recorded", not "empty value". */
const d = (v) => (v === "" || v == null ? null : v);
const s = (v) => (v == null ? "" : String(v));
const n = (v) => (v === "" || v == null ? null : Number(v));

const client = new pg.Client({
  host: process.env.SUPABASE_DB_HOST,
  port: Number(process.env.SUPABASE_DB_PORT ?? 5432),
  user: process.env.SUPABASE_DB_USER ?? "postgres",
  password: process.env.SUPABASE_DB_PASSWORD,
  database: "postgres",
  ssl: { rejectUnauthorized: false },
  statement_timeout: 120000,
});

await client.connect();

/** Bulk upsert keyed on legacy_id. */
async function load(table, columns, rows, conflict = "legacy_id") {
  if (rows.length === 0) return 0;
  const cols = columns.join(", ");
  const updates = columns
    .filter((c) => c !== conflict)
    .map((c) => `${c} = excluded.${c}`)
    .join(", ");

  let count = 0;
  const CHUNK = 200;
  for (let i = 0; i < rows.length; i += CHUNK) {
    const slice = rows.slice(i, i + CHUNK);
    const values = [];
    const params = [];
    slice.forEach((row, r) => {
      values.push(`(${columns.map((_, c) => `$${r * columns.length + c + 1}`).join(", ")})`);
      params.push(...row);
    });
    const sql = `insert into public.${table} (${cols}) values ${values.join(", ")}
                 on conflict (${conflict}) do update set ${updates}`;
    const result = await client.query(sql, params);
    count += result.rowCount;
  }
  return count;
}

const report = [];

try {
  await client.query("begin");

  // The stage-history trigger writes a row for every client it sees. The
  // workbook already carries the real history, so keep the trigger quiet and
  // load what actually happened.
  await client.query("alter table public.clients disable trigger clients_stage_history");

  // ── counselors ────────────────────────────────────────────
  report.push([
    "counselors",
    await load(
      "counselors",
      ["legacy_id", "name", "agency", "office", "phone", "fax", "email", "notes"],
      DATA.counselors.map((k) => [
        k.id,
        k.name,
        k.agency || "Utah State Office of Rehabilitation",
        d(k.office),
        d(k.phone),
        d(k.fax),
        d(k.email),
        s(k.notes),
      ]),
    ),
  ]);

  const counselorMap = new Map(
    (await client.query("select legacy_id, id from public.counselors where legacy_id is not null"))
      .rows.map((r) => [r.legacy_id, r.id]),
  );
  const staffMap = new Map(
    (await client.query("select legacy_id, id from public.staff where legacy_id is not null"))
      .rows.map((r) => [r.legacy_id, r.id]),
  );

  // The Billing member is not named yet, so the workbook's tasks for 's4' have
  // no account to land on. They go to the owner, who reassigns once Billing is
  // hired — better than an unassigned task nobody sees.
  const adminId = staffMap.get("s1") ?? null;
  const staffFor = (legacy) => staffMap.get(legacy) ?? adminId;
  const unmappedStaff = new Set();
  const staffForTracked = (legacy) => {
    if (legacy && !staffMap.has(legacy)) unmappedStaff.add(legacy);
    return staffFor(legacy);
  };

  // ── clients ───────────────────────────────────────────────
  report.push([
    "clients",
    await load(
      "clients",
      [
        "legacy_id", "client_no", "ghl_id", "name", "agency_id", "funding_source",
        "caseload", "unit", "counselor_id", "counselor_contact", "referring_office",
        "phone", "email", "gender", "schedule", "target_jobs", "ce", "wsa_tier",
        "wsa_completed", "wsa_submitted", "wsa_paid", "status", "assigned_staff_id",
        "stage", "import_review", "created_at",
      ],
      DATA.clients.map((c) => [
        c.id, n(c.clientNo), d(c.ghlId), c.name, s(c.agencyId), c.fundingSource || "Utah VR",
        s(c.caseload), s(c.unit), c.counselorId ? counselorMap.get(c.counselorId) ?? null : null,
        s(c.counselorContact), s(c.referringOffice), s(c.phone), s(c.email), s(c.gender),
        s(c.schedule), s(c.targetJobs), Boolean(c.ce), n(c.wsaTier),
        d(c.wsaCompleted), d(c.wsaSubmitted), d(c.wsaPaid), c.status || "Active",
        staffForTracked(c.assignedStaffId), c.stage || "Referral", s(c.importReview),
        d(c.createdAt) ?? new Date().toISOString().slice(0, 10),
      ]),
    ),
  ]);

  const clientMap = new Map(
    (await client.query("select legacy_id, id from public.clients where legacy_id is not null"))
      .rows.map((r) => [r.legacy_id, r.id]),
  );

  // ── restricted tier ───────────────────────────────────────
  const privateRows = DATA.clients
    .filter((c) => d(c.dob) || s(c.address))
    .map((c) => [clientMap.get(c.id), d(c.dob), s(c.address)]);
  report.push([
    "client_private",
    await load("client_private", ["client_id", "dob", "address"], privateRows, "client_id"),
  ]);

  // ── pipeline history ──────────────────────────────────────
  const clientIds = [...clientMap.values()];
  await client.query("delete from public.client_stage_history where client_id = any($1)", [
    clientIds,
  ]);
  const historyRows = [];
  for (const c of DATA.clients) {
    for (const h of c.stageHistory ?? []) {
      historyRows.push([clientMap.get(c.id), h.stage, d(h.at) ?? c.createdAt]);
    }
  }
  let historyCount = 0;
  for (let i = 0; i < historyRows.length; i += 200) {
    const slice = historyRows.slice(i, i + 200);
    const values = slice
      .map((_, r) => `($${r * 3 + 1}, $${r * 3 + 2}, $${r * 3 + 3})`)
      .join(", ");
    const result = await client.query(
      `insert into public.client_stage_history (client_id, stage, at) values ${values}`,
      slice.flat(),
    );
    historyCount += result.rowCount;
  }
  report.push(["client_stage_history", historyCount]);

  // ── notes ─────────────────────────────────────────────────
  report.push([
    "notes",
    await load(
      "notes",
      ["legacy_id", "client_id", "staff_id", "staff_name", "text", "type", "at", "ts", "visible_roles"],
      DATA.notes.map((x) => [
        x.id, clientMap.get(x.clientId), staffForTracked(x.staffId), s(x.staffName),
        x.text, x.type || "General", d(x.at), d(x.ts) ?? d(x.at),
        x.roles?.length ? x.roles : ["Admin", "Job Search", "Reports", "Billing"],
      ]),
    ),
  ]);

  // ── authorizations ────────────────────────────────────────
  report.push([
    "authorizations",
    await load(
      "authorizations",
      [
        "legacy_id", "client_id", "number", "service_type", "funding_source", "total_hours",
        "carried_used", "rate_type", "rate", "start_date", "end_date", "status",
        "requires_forms", "note",
      ],
      DATA.authorizations.map((a) => [
        a.id, clientMap.get(a.clientId), s(a.number), a.serviceType,
        a.fundingSource || "Utah VR", n(a.totalHours), n(a.carriedUsed) ?? 0,
        a.rateType, n(a.rate) ?? 0, d(a.start), d(a.end), a.status || "Open",
        s(a.requiresForms), s(a.note),
      ]),
    ),
  ]);

  const authMap = new Map(
    (await client.query("select legacy_id, id from public.authorizations where legacy_id is not null"))
      .rows.map((r) => [r.legacy_id, r.id]),
  );

  // ── invoices ──────────────────────────────────────────────
  report.push([
    "invoices",
    await load(
      "invoices",
      [
        "legacy_id", "auth_id", "number", "date", "amount", "status", "sent_date",
        "paid_date", "warrant", "voucher", "payee", "service_type",
      ],
      DATA.invoices.map((i) => [
        i.id, authMap.get(i.authId), s(i.number), d(i.date), n(i.amount) ?? 0,
        i.status || "Draft", d(i.sentDate), d(i.paidDate), s(i.warrant), s(i.voucher),
        s(i.payee), s(i.serviceType),
      ]),
    ),
  ]);

  // ── placements ────────────────────────────────────────────
  report.push([
    "placements",
    await load(
      "placements",
      [
        "legacy_id", "client_id", "employer", "title", "start_date", "wage", "hours_week",
        "check30", "check60", "check90", "jp_submitted", "jp_paid", "notes",
      ],
      DATA.placements.map((p) => [
        p.id, clientMap.get(p.clientId), s(p.employer), s(p.title), d(p.start),
        n(p.wage), n(p.hoursWeek), d(p.check30), d(p.check60), d(p.check90),
        d(p.jpSubmitted), d(p.jpPaid), s(p.notes),
      ]),
    ),
  ]);

  // ── completions ───────────────────────────────────────────
  report.push([
    "completions",
    await load(
      "completions",
      ["legacy_id", "auth_id", "start_date", "completion", "notes", "billed"],
      DATA.completions
        .filter((c) => authMap.has(c.authId))
        .map((c) => [c.id, authMap.get(c.authId), d(c.start), d(c.completion), s(c.notes), Boolean(c.billed)]),
    ),
  ]);

  // ── tasks ─────────────────────────────────────────────────
  report.push([
    "tasks",
    await load(
      "tasks",
      ["legacy_id", "client_id", "assigned_staff_id", "title", "due", "status", "system_generated"],
      DATA.tasks.map((t) => [
        t.id, t.clientId ? clientMap.get(t.clientId) ?? null : null,
        staffForTracked(t.assignedStaffId), t.title, d(t.due), t.status || "Open",
        t.createdBy === "system",
      ]),
    ),
  ]);

  // ── counselor contact log ─────────────────────────────────
  report.push([
    "contact_log",
    await load(
      "contact_log",
      ["legacy_id", "counselor_id", "client_id", "date", "method", "topic", "outcome", "follow_up", "staff_id"],
      DATA.contactLog.map((c) => [
        c.id, c.counselorId ? counselorMap.get(c.counselorId) ?? null : null,
        c.clientId ? clientMap.get(c.clientId) ?? null : null, d(c.date),
        c.method || "Phone call", s(c.topic), s(c.outcome), d(c.followUp),
        staffForTracked(c.staffId),
      ]),
    ),
  ]);

  await client.query("alter table public.clients enable trigger clients_stage_history");
  await client.query("commit");

  console.log("\nLoaded:");
  for (const [table, count] of report) console.log(`  ${String(count).padStart(4)}  ${table}`);

  if (unmappedStaff.size > 0) {
    console.log(
      `\nNote: no account exists for ${[...unmappedStaff].join(", ")} — those rows were assigned to the owner.`,
    );
  }
} catch (err) {
  await client.query("rollback");
  console.error(`\nMigration failed and nothing was changed: ${err.message}`);
  if (err.detail) console.error(`  ${err.detail}`);
  process.exitCode = 1;
} finally {
  await client.end();
}
