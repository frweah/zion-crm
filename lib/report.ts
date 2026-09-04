import "server-only";
import { createClient } from "@/lib/supabase/server";
import { ORG } from "@/lib/roles";
import { money, fmtStamp, today } from "@/lib/constants";

/**
 * Client activity report, ported from the prototype's buildReport / reportText.
 *
 * The notes that reach here are already filtered by row-level security, so a
 * report never contains anything the person running it could not read on the
 * client record itself.
 */
export type ReportPeriod = "Weekly" | "Monthly";

export async function buildReportText(
  clientId: string,
  kind: ReportPeriod,
  start: string,
  end: string,
): Promise<{ text: string; noteCount: number; hours: number }> {
  const supabase = await createClient();

  const { data: client } = await supabase
    .from("clients")
    .select(
      "id, name, client_no, agency_id, funding_source, referring_office, stage, counselor_id",
    )
    .eq("id", clientId)
    .maybeSingle();

  if (!client) return { text: "Client not found.", noteCount: 0, hours: 0 };

  const [
    counselorResult,
    notesResult,
    authsResult,
    stagesResult,
    tasksResult,
    placementsResult,
    contactsResult,
  ] = await Promise.all([
    client.counselor_id
      ? supabase.from("counselors").select("name").eq("id", client.counselor_id).maybeSingle()
      : Promise.resolve({ data: null }),
    supabase
      .from("notes")
      .select("text, type, ts, at, staff_name")
      .eq("client_id", clientId)
      .gte("at", start)
      .lte("at", end)
      .order("ts"),
    supabase
      .from("authorizations")
      .select("id, number, service_type")
      .eq("client_id", clientId),
    supabase
      .from("client_stage_history")
      .select("stage, at")
      .eq("client_id", clientId)
      .gte("at", start)
      .lte("at", end)
      .order("at"),
    supabase
      .from("tasks")
      .select("title, done_at")
      .eq("client_id", clientId)
      .eq("status", "Done")
      .gte("done_at", start)
      .lte("done_at", end),
    supabase.from("placements").select("*").eq("client_id", clientId),
    supabase
      .from("contact_log")
      .select("date, method, topic, outcome")
      .eq("client_id", clientId)
      .gte("date", start)
      .lte("date", end)
      .order("date"),
  ]);

  const auths = authsResult.data ?? [];
  const authIds = auths.map((a) => a.id);
  const authById = new Map(auths.map((a) => [a.id, a]));

  const [entriesResult, invoicesResult] = await Promise.all([
    authIds.length
      ? supabase
          .from("service_entries")
          .select("auth_id, date, hours, non_billable, notes")
          .in("auth_id", authIds)
          .gte("date", start)
          .lte("date", end)
          .order("date")
      : Promise.resolve({ data: [] }),
    authIds.length
      ? supabase
          .from("invoices")
          .select("number, date, amount, status, paid_date")
          .in("auth_id", authIds)
          .gte("date", start)
          .lte("date", end)
          .order("date")
      : Promise.resolve({ data: [] }),
  ]);

  const notes = notesResult.data ?? [];
  const entries = entriesResult.data ?? [];
  const stages = stagesResult.data ?? [];
  const tasksDone = tasksResult.data ?? [];
  const contacts = contactsResult.data ?? [];
  const invoices = invoicesResult.data ?? [];

  const inRange = (d: string | null) => Boolean(d && d >= start && d <= end);
  const placements = (placementsResult.data ?? []).filter(
    (p) =>
      inRange(p.start_date) || inRange(p.check30) || inRange(p.check60) || inRange(p.check90),
  );

  const billable = entries.filter((e) => !e.non_billable);
  const hours = billable.reduce((t, e) => t + Number(e.hours), 0);
  const nonBillable = entries.length - billable.length;

  const byType: Record<string, number> = {};
  for (const n of notes) byType[n.type || "General"] = (byType[n.type || "General"] ?? 0) + 1;

  const L: string[] = [];
  L.push(`${ORG.name.toUpperCase()} — ${kind.toUpperCase()} CLIENT PROGRESS REPORT`);
  L.push(`${ORG.address} · ${ORG.phone} · ${ORG.email} · ${ORG.web}`);
  L.push(
    `Client: ${client.name}${client.client_no ? `  (Client #${client.client_no})` : ""}${
      client.agency_id ? `  USOR ID ${client.agency_id}` : ""
    }`,
  );
  L.push(
    `Counselor: ${counselorResult.data?.name ?? "—"}    Office: ${
      client.referring_office || "—"
    }    Funding: ${client.funding_source}`,
  );
  L.push(
    `Period: ${start} to ${end}    Current stage: ${client.stage}    Prepared: ${today()}`,
  );
  L.push("");
  L.push("SUMMARY");
  L.push(
    `- ${notes.length} activity note${notes.length === 1 ? "" : "s"}${
      Object.keys(byType).length
        ? " (" +
          Object.entries(byType)
            .map(([k, v]) => `${k}: ${v}`)
            .join(", ") +
          ")"
        : ""
    }`,
  );
  L.push(
    `- ${hours} billable service hour${hours === 1 ? "" : "s"} logged${
      nonBillable ? ` (+${nonBillable} non-billable entries)` : ""
    }`,
  );
  if (stages.length) {
    L.push(
      `- Stage change${stages.length === 1 ? "" : "s"}: ${stages
        .map((h) => `${h.stage} (${h.at})`)
        .join(" → ")}`,
    );
  }
  if (placements.length) {
    L.push(
      `- Placement activity: ${placements
        .map(
          (p) =>
            `${p.employer || "employer TBD"}${p.start_date ? " started " + p.start_date : ""}${
              p.check30 ? ", 30-day check " + p.check30 : ""
            }${p.check60 ? ", 60-day check " + p.check60 : ""}${
              p.check90 ? ", 90-day check " + p.check90 : ""
            }`,
        )
        .join("; ")}`,
    );
  }
  if (contacts.length) {
    L.push(`- ${contacts.length} counselor contact${contacts.length === 1 ? "" : "s"}`);
  }
  if (tasksDone.length) {
    L.push(`- ${tasksDone.length} task${tasksDone.length === 1 ? "" : "s"} completed`);
  }

  L.push("");
  L.push("ACTIVITY LOG");
  if (!notes.length) L.push("(no notes in this period)");
  for (const n of notes) {
    L.push(`${n.ts ? fmtStamp(n.ts) : n.at} — ${n.type || "General"} — ${n.staff_name || "—"}`);
    L.push(`   ${n.text}`);
  }

  if (entries.length) {
    L.push("");
    L.push("SERVICE HOURS");
    for (const e of entries) {
      const a = authById.get(e.auth_id);
      L.push(
        `${e.date} — ${e.hours} hr${e.non_billable ? " (non-billable)" : ""} — ${
          a?.service_type ?? ""
        } ${a?.number ?? ""}${e.notes ? " — " + e.notes : ""}`,
      );
    }
  }

  if (contacts.length) {
    L.push("");
    L.push("COUNSELOR CONTACTS");
    for (const c of contacts) {
      L.push(`${c.date} — ${c.method} — ${c.topic}${c.outcome ? " — " + c.outcome : ""}`);
    }
  }

  if (tasksDone.length) {
    L.push("");
    L.push("TASKS COMPLETED");
    for (const t of tasksDone) L.push(`- ${t.title}`);
  }

  if (invoices.length) {
    L.push("");
    L.push("BILLING IN PERIOD");
    for (const i of invoices) {
      L.push(
        `${i.date} — ${i.number} — ${money(i.amount)} — ${i.status}${
          i.paid_date ? " " + i.paid_date : ""
        }`,
      );
    }
  }

  L.push("");
  L.push("NEXT STEPS");
  L.push("(staff to complete)");

  return { text: L.join("\n"), noteCount: notes.length, hours };
}
