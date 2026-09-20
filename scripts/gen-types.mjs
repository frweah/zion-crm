/**
 * Generates lib/database.types.ts from the live schema.
 *
 *   node --env-file=.env.local scripts/gen-types.mjs
 *
 * The Supabase CLI's `gen types` wants a container runtime, which this machine
 * does not have. This reads information_schema over the same connection the
 * migrations use and emits the same shape supabase-js expects, so
 * createClient<Database>() gives typed rows everywhere.
 *
 * Re-run it after any migration that changes a table.
 */
import { writeFile } from "node:fs/promises";
import pg from "pg";

const TYPE_MAP = {
  uuid: "string",
  text: "string",
  varchar: "string",
  bpchar: "string",
  int2: "number",
  int4: "number",
  int8: "number",
  numeric: "number",
  float4: "number",
  float8: "number",
  bool: "boolean",
  date: "string",
  timestamp: "string",
  timestamptz: "string",
  time: "string",
  json: "Json",
  jsonb: "Json",
};

function tsType(udt) {
  if (udt.startsWith("_")) {
    const inner = TYPE_MAP[udt.slice(1)] ?? "string";
    return `${inner}[]`;
  }
  return TYPE_MAP[udt] ?? "string";
}

const client = new pg.Client({
  host: process.env.SUPABASE_DB_HOST,
  port: Number(process.env.SUPABASE_DB_PORT ?? 5432),
  user: process.env.SUPABASE_DB_USER ?? "postgres",
  password: process.env.SUPABASE_DB_PASSWORD,
  database: "postgres",
  ssl: { rejectUnauthorized: false },
});

await client.connect();

const { rows } = await client.query(`
  select c.table_name, c.column_name, c.udt_name, c.is_nullable,
         (c.column_default is not null) as has_default,
         c.is_generated, t.table_type
    from information_schema.columns c
    join information_schema.tables t
      on t.table_schema = c.table_schema and t.table_name = c.table_name
   where c.table_schema = 'public' and t.table_type in ('BASE TABLE', 'VIEW')
   order by c.table_name, c.ordinal_position
`);

// Functions the app calls through supabase.rpc(). Listed explicitly rather
// than swept up wholesale: trigger functions and internal helpers are not part
// of the client API and should not be typed as if they were.
const RPC_FUNCTIONS = [
  "current_staff_id",
  "current_staff_role",
  "is_active_staff",
  "is_admin",
  "can_see_restricted",
  "generate_notifications",
  "period_start",
  "period_end",
  "sign_tax_form",
  "get_tax_form_sensitive",
  "form_1099_candidates",
  "generate_1099_run",
  "set_checklist_item",
  "set_staff_pay",
  "delete_staff_pay",
  "pay_rate_on",
  "set_microsoft_tokens",
  "refresh_microsoft_tokens",
  "get_microsoft_tokens_for_sync",
  "set_microsoft_tokens_for_sync",
  "log_mail_message",
  "log_mail_message_for_sync",
  "log_shared_mail_message",
  "exclude_mail_thread",
  "get_microsoft_tokens",
  "set_microsoft_error",
  // The sweep has no session, so it reports a refused refresh its own way (0108).
  "set_microsoft_error_for_sync",
  "set_statement_adjustment",
  "staff_activity",
  "record_1099_delivery",
  "set_e_delivery_consent",
  "get_contractor_tin",
  "set_contractor_tin",
  "get_employer_details",
  "set_employer_details",
  "fmt_hours",
  "job_status_rank",
  "answer_reminder",
  "practice_today",
  "timer_elapsed_hours",
  "set_sms_consent",
  "normalize_phone",
  // Called only by the inbound webhook, as the service role — typed here so
  // that call is checked like any other.
  "record_incoming_sms",
  // The only doors to the restricted tier — every call is a log entry.
  "read_client_private",
  "read_client_intake",
  "save_intake",
  "note_tax_form_access",
  "note_staff_file_access",
  "offboard_staff",
  "mileage_rate_on",
  "match_inbox_folder",
  "note_template_for",
  "record_disposition",
  "records_request_bundle",
  "confirm_authorization_document",
  "inbox_seen",
  "file_document_as_note",
  "link_document_to_authorization",
  "correct_authorization",
  "replace_placeholder_authorization",
  "reconcile_warrant_line",
  "reconcile_warrant_page",
  "dismiss_warrant_line",
  // What to reconcile with a CRP billing office (0091).
  "billing_office_reconciliation",
  // Access given to one person beyond their role (0092).
  "staff_has_area",
  "role_has_area",
  "grant_staff_access",
  "revoke_staff_access",
  "move_counselor_office",
  "onboarding_step_done",
  "onboarding_open_steps",
  "policy_signature_due",
  "inbox_document_open_to_me",
  "start_direct_conversation",
  "post_message",
  "mark_read",
  "my_unread",
  "presence_heartbeat",
  "staff_presence_status",
  "is_conversation_participant",
  // Staff chat (0106).
  "start_group_conversation",
  "add_conversation_participant",
  "leave_conversation",
  "archive_conversation",
  "edit_message",
  "remove_message",
  "search_messages",
  "can_staff_see_restricted",
  "messages_digest_due",
  "messages_digest_sent",
  "next_text_window",
  // The inbox holds texts and website chats, so these lost "text" (0107).
  "message_inbox",
  "assign_conversation",
  "match_conversation",
  "referral_from_conversation",
  "mark_conversation_spam",
  // The website chat (0107). The visitor's four are the service role's.
  "web_chat_config",
  "web_chat_live",
  "web_chat_thread",
  "web_chat_session",
  "start_web_chat",
  "post_visitor_message",
  "post_web_reply",
  "practice_now",
  "record_identity_inspection",
  "submit_own_credential",
  "verify_credential",
  "confirm_onboarding_certifications",
  "sign_staff_policy",
  "refresh_onboarding",
  "note_staff_personal_access",
  // The client record at the centre (0109, 0110).
  "note_client_opened",
  "search_clients",
  "client_next_actions",
  "set_my_signature",
  "clear_my_signature",
  "have_my_signature",
  "billing_gate_met",
  "draft_invoice_for_authorization",
];

const { rows: fns } = await client.query(
  `select p.proname,
          pg_get_function_result(p.oid) as result,
          pg_get_function_arguments(p.oid) as args
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = any($1)
    order by p.proname`,
  [RPC_FUNCTIONS],
);

/** "TABLE(dob date, address text)" into the row shape it returns. */
function tableRowType(result) {
  const inner = (result ?? "").replace(/^TABLE\(/i, "").replace(/\)$/, "");
  const fields = inner
    .split(",")
    .map((column) => {
      const parts = column.trim().split(/\s+/);
      const name = parts[0];
      const sqlType = parts.slice(1).join(" ").toLowerCase();
      const ts = /^bool/.test(sqlType)
        ? "boolean"
        : /^(int|bigint|numeric|smallint|real|double)/.test(sqlType)
          ? "number"
          : "string";
      return name + ": " + ts + " | null";
    })
    .join("; ");
  return "{ " + fields + " }[]";
}

/** "d date, p_client_id uuid" -> { d: string; p_client_id: string } */
function argsType(args) {
  const trimmed = (args ?? "").trim();
  if (!trimmed) return "Record<string, never>";
  const fields = trimmed.split(",").map((a) => {
    const parts = a.trim().split(/\s+/);
    const name = parts[0];
    const declared = parts.slice(1).join(" ").toLowerCase();
    // An argument the function gives a default to is one the caller may leave
    // out, and the type says so - otherwise every call restates the default.
    // The default itself is not part of the type: "jsonb default '[]'::jsonb"
    // is a jsonb, and reading the whole phrase would make it a list.
    const optional = / default /.test(declared) ? "?" : "";
    const sqlType = declared.split(" default ")[0].trim();
    const base = /^jsonb?(\[\])?$/.test(sqlType)
      ? "Json"
      : /int|numeric|real|double|serial/.test(sqlType)
        ? "number"
        : /bool/.test(sqlType)
          ? "boolean"
          : "string";
    // uuid[] is a list of uuids, not a uuid. Without this an array argument
    // types as a single string and every call to it needs a cast.
    const ts = /\[\]$/.test(sqlType) && base !== "Json" ? `${base}[]` : base;
    // Every SQL parameter accepts null, so the argument types say so. Without
    // it a caller passing a genuinely optional value has to cast, and a cast
    // would also hide the one case where the mismatch was real.
    return `${name}${optional}: ${ts} | null`;
  });
  return `{ ${fields.join("; ")} }`;
}

await client.end();

const tables = new Map();
const views = new Map();
for (const r of rows) {
  const target = r.table_type === "VIEW" ? views : tables;
  if (!target.has(r.table_name)) target.set(r.table_name, []);
  target.get(r.table_name).push(r);
}

const out = [];
out.push("// Generated by scripts/gen-types.mjs from the live schema. Do not edit by hand.");
out.push("// Re-run after any migration that changes a table.");
out.push("");
out.push("export type Json = string | number | boolean | null | { [key: string]: Json } | Json[];");
out.push("");
out.push("export type Database = {");
out.push("  public: {");
out.push("    Tables: {");

for (const [table, cols] of [...tables].sort((a, b) => a[0].localeCompare(b[0]))) {
  out.push(`      ${table}: {`);

  out.push("        Row: {");
  for (const c of cols) {
    const nullable = c.is_nullable === "YES" ? " | null" : "";
    out.push(`          ${c.column_name}: ${tsType(c.udt_name)}${nullable};`);
  }
  out.push("        };");

  out.push("        Insert: {");
  for (const c of cols) {
    const optional = c.has_default || c.is_nullable === "YES" || c.is_generated === "ALWAYS";
    const nullable = c.is_nullable === "YES" ? " | null" : "";
    out.push(`          ${c.column_name}${optional ? "?" : ""}: ${tsType(c.udt_name)}${nullable};`);
  }
  out.push("        };");

  out.push("        Update: {");
  for (const c of cols) {
    const nullable = c.is_nullable === "YES" ? " | null" : "";
    out.push(`          ${c.column_name}?: ${tsType(c.udt_name)}${nullable};`);
  }
  out.push("        };");

  // supabase-js requires this key to resolve its table generics; without it
  // every insert and update collapses to `never`.
  out.push("        Relationships: [];");

  out.push("      };");
}

out.push("    };");
// Views are readable only — no Insert/Update, which is what they are.
if (views.size === 0) {
  out.push("    Views: { [_ in never]: never };");
} else {
  out.push("    Views: {");
  for (const [view, cols] of [...views].sort((a, b) => a[0].localeCompare(b[0]))) {
    out.push(`      ${view}: {`);
    out.push("        Row: {");
    for (const c of cols) {
      const nullable = c.is_nullable === "YES" ? " | null" : "";
      out.push(`          ${c.column_name}: ${tsType(c.udt_name)}${nullable};`);
    }
    out.push("        };");
    out.push("        Relationships: [];");
    out.push("      };");
  }
  out.push("    };");
}
out.push("    Functions: {");
for (const f of fns) {
  out.push(`      ${f.proname}: {`);
  out.push(`        Args: ${argsType(f.args)};`);
  // A function returning TABLE(...) hands back rows, not a scalar. Calling it
  // "string" typechecked and was a lie — the callers that needed the columns
  // had to cast their way out of it, which is the opposite of what these
  // types are for. The column types are approximate; the shape is not.
  // The same lesson as TABLE(...) above, one type later: a function returning
  // jsonb was being typed "string", which typechecked and was false, and the
  // caller had to cast through unknown to read a single field out of it. A
  // type that has to be lied about to be used is not doing its job.
  const returns = /^TABLE\(/i.test(f.result ?? "")
    ? tableRowType(f.result)
    : f.result === "boolean"
      ? "boolean"
      : ["json", "jsonb"].includes(f.result)
        ? "Json"
        : f.result === "void"
          ? "undefined"
          : ["integer", "bigint", "numeric", "smallint", "real", "double precision"].includes(f.result)
            ? "number"
            : "string";
  out.push(`        Returns: ${returns};`);
  out.push("      };");
}
out.push("    };");
out.push("    Enums: { [_ in never]: never };");
out.push("    CompositeTypes: { [_ in never]: never };");
out.push("  };");
out.push("};");
out.push("");
out.push("export type Tables<T extends keyof Database[\"public\"][\"Tables\"]> =");
out.push("  Database[\"public\"][\"Tables\"][T][\"Row\"];");
out.push("export type Insert<T extends keyof Database[\"public\"][\"Tables\"]> =");
out.push("  Database[\"public\"][\"Tables\"][T][\"Insert\"];");
out.push("export type Update<T extends keyof Database[\"public\"][\"Tables\"]> =");
out.push("  Database[\"public\"][\"Tables\"][T][\"Update\"];");
out.push("");

await writeFile("lib/database.types.ts", out.join("\n"), "utf8");
console.log(`lib/database.types.ts — ${tables.size} tables, ${rows.length} columns, ${fns.length} functions`);
