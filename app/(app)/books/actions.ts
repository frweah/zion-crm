"use server";

import { revalidatePath } from "next/cache";
import { canReach } from "@/lib/roles";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { parseStatement } from "@/lib/bank-file";

export type BooksState = { error: string | null; ok: string | null };

/**
 * Everything somebody does to the books (ERP brief, E1).
 *
 * Every one of these is Admin's. The database says so too - each function
 * below calls one that checks is_admin() for itself - so this is the message
 * rather than the rule: a check in one place only is a check somebody routes
 * around, and a rule with no message is an error page.
 *
 * A statement file is read here and the rows are handed to the database.
 * Parsing it in SQL would be a party trick, and parsing it in the browser
 * would mean trusting the browser about what the bank said.
 */
const MAX_STATEMENT_BYTES = 8 * 1024 * 1024;

async function admin(): Promise<{ supabase: Awaited<ReturnType<typeof createClient>>; error: string | null }> {
  const me = await requireStaff();
  if (!canReach(me, "/books")) return { supabase: await createClient(), error: "Not yours." };
  if (me.role !== "Admin") return { supabase: await createClient(), error: "Only an Admin changes the books." };
  return { supabase: await createClient(), error: null };
}

/** The entity the books belong to. There is one, and it is seeded (0141). */
async function entityId(supabase: Awaited<ReturnType<typeof createClient>>): Promise<string> {
  const { data } = await supabase.from("ledger_entities").select("id").eq("is_default", true).single();
  if (!data) throw new Error("These books have no entity, which means the ledger was never set up.");
  return data.id;
}

const uuid = (v: FormDataEntryValue | null) => {
  const s = String(v ?? "");
  return /^[0-9a-f-]{36}$/.test(s) ? s : null;
};
const day = (v: FormDataEntryValue | null) => {
  const s = String(v ?? "");
  return /^\d{4}-\d{2}-\d{2}$/.test(s) ? s : null;
};

// ── the chart ──────────────────────────────────────────────
export async function addAccount(_prev: BooksState, formData: FormData): Promise<BooksState> {
  const { supabase, error: denied } = await admin();
  if (denied) return { error: denied, ok: null };

  const code = String(formData.get("code") ?? "").trim();
  const name = String(formData.get("name") ?? "").trim();
  const kind = String(formData.get("kind") ?? "");
  if (!/^\d{3,6}$/.test(code)) return { error: "A code is three to six digits.", ok: null };
  if (!name) return { error: "An account needs a name.", ok: null };
  if (!["Asset", "Liability", "Equity", "Revenue", "Expense"].includes(kind)) {
    return { error: "Say what kind of account it is.", ok: null };
  }

  const { error } = await supabase.from("ledger_accounts").insert({
    entity_id: await entityId(supabase),
    code,
    name,
    kind,
    note: String(formData.get("note") ?? "").trim(),
  });
  if (error) return { error: error.message, ok: null };

  revalidatePath("/books/chart");
  return { error: null, ok: `${code} ${name} added.` };
}

/** Retiring an account, which is what deleting one means once it holds postings. */
export async function setAccountActive(formData: FormData): Promise<void> {
  const { supabase, error: denied } = await admin();
  if (denied) return;
  const id = uuid(formData.get("id"));
  if (!id) return;
  await supabase
    .from("ledger_accounts")
    .update({ active: formData.get("active") === "true" })
    .eq("id", id);
  revalidatePath("/books/chart");
}

/** Which revenue account a service bills to, and which account a claim lands in. */
export async function mapAccount(formData: FormData): Promise<void> {
  const { supabase, error: denied } = await admin();
  if (denied) return;
  const account = uuid(formData.get("account_id"));
  const service = String(formData.get("service") ?? "");
  const category = String(formData.get("category") ?? "");
  if (!account) return;
  if (service) await supabase.from("ledger_revenue_map").upsert({ service, account_id: account });
  if (category) await supabase.from("ledger_expense_map").upsert({ category, account_id: account });
  revalidatePath("/books/chart");
}

// ── a journal by hand ──────────────────────────────────────
export async function writeJournal(_prev: BooksState, formData: FormData): Promise<BooksState> {
  const { supabase, error: denied } = await admin();
  if (denied) return { error: denied, ok: null };

  const date = day(formData.get("entry_date"));
  const memo = String(formData.get("memo") ?? "").trim();
  const reason = String(formData.get("reason") ?? "").trim();
  if (!date) return { error: "An entry needs a date.", ok: null };
  if (!memo) return { error: "Say what the entry is.", ok: null };
  if (!reason) return { error: "Say why. Somebody will read this who was not here.", ok: null };

  const lines: { account: string; debit?: number; credit?: number; memo: string }[] = [];
  for (let i = 0; i < 6; i++) {
    const account = uuid(formData.get(`account_${i}`));
    if (!account) continue;
    const debit = Number(String(formData.get(`debit_${i}`) ?? "").replace(/[$,\s]/g, "")) || 0;
    const credit = Number(String(formData.get(`credit_${i}`) ?? "").replace(/[$,\s]/g, "")) || 0;
    if (debit <= 0 && credit <= 0) continue;
    if (debit > 0 && credit > 0) {
      return { error: "A line is a debit or a credit, not both.", ok: null };
    }
    lines.push({ account, ...(debit > 0 ? { debit } : { credit }), memo: String(formData.get(`memo_${i}`) ?? "") });
  }

  if (lines.length < 2) return { error: "An entry debits something and credits something.", ok: null };
  const debits = lines.reduce((s, l) => s + (l.debit ?? 0), 0);
  const credits = lines.reduce((s, l) => s + (l.credit ?? 0), 0);
  if (Math.round(debits * 100) !== Math.round(credits * 100)) {
    return { error: `Debits come to ${debits.toFixed(2)} and credits to ${credits.toFixed(2)}.`, ok: null };
  }

  const { error } = await supabase.rpc("post_manual_journal", {
    p_entry_date: date,
    p_memo: memo,
    p_reason: reason,
    p_lines: lines,
    p_attachment: null,
  });
  if (error) return { error: error.message, ok: null };

  revalidatePath("/books/journals");
  return { error: null, ok: "Posted." };
}

/** A correction: the mirror of an entry, with a reason. */
export async function reverseEntry(_prev: BooksState, formData: FormData): Promise<BooksState> {
  const { supabase, error: denied } = await admin();
  if (denied) return { error: denied, ok: null };
  const id = uuid(formData.get("journal_id"));
  const reason = String(formData.get("reason") ?? "").trim();
  if (!id) return { error: "No entry was named.", ok: null };
  if (!reason) return { error: "A correction needs a reason.", ok: null };

  const { error } = await supabase.rpc("reverse_journal", { p_journal: id, p_reason: reason });
  if (error) return { error: error.message, ok: null };

  revalidatePath("/books/journals");
  return { error: null, ok: "Reversed." };
}

// ── the bank ───────────────────────────────────────────────
export async function addBankAccount(_prev: BooksState, formData: FormData): Promise<BooksState> {
  const { supabase, error: denied } = await admin();
  if (denied) return { error: denied, ok: null };

  const name = String(formData.get("name") ?? "").trim();
  const account = uuid(formData.get("account_id"));
  const last4 = String(formData.get("last4") ?? "").replace(/\D/g, "").slice(-4);
  if (!name || !account) return { error: "A name and a ledger account.", ok: null };

  const { error } = await supabase
    .from("bank_accounts")
    .insert({ entity_id: await entityId(supabase), account_id: account, name, last4 });
  if (error) return { error: error.message, ok: null };

  revalidatePath("/books/bank");
  return { error: null, ok: `${name} added.` };
}

export async function importStatement(_prev: BooksState, formData: FormData): Promise<BooksState> {
  const { supabase, error: denied } = await admin();
  if (denied) return { error: denied, ok: null };

  const bank = uuid(formData.get("bank_account_id"));
  const from = day(formData.get("period_start"));
  const to = day(formData.get("period_end"));
  const file = formData.get("file");
  if (!bank) return { error: "Say which account this is.", ok: null };
  if (!from || !to) return { error: "Say what the statement covers.", ok: null };
  if (!(file instanceof File) || file.size === 0) return { error: "Choose the file the bank gave you.", ok: null };
  if (file.size > MAX_STATEMENT_BYTES) {
    return { error: "That file is over 8MB, which is far larger than any statement.", ok: null };
  }

  const parsed = parseStatement(file.name, await file.text());
  if (parsed.lines.length === 0) {
    return { error: parsed.problems[0] ?? "Nothing in that file looked like a transaction.", ok: null };
  }

  const opening = Number(String(formData.get("opening") ?? "0").replace(/[$,\s]/g, "")) || 0;
  const typed = String(formData.get("closing") ?? "").replace(/[$,\s]/g, "");
  const closing = typed ? Number(typed) : parsed.closing;
  if (closing === null || !Number.isFinite(closing)) {
    return { error: "The closing balance on the statement, so the ledger can be held to it.", ok: null };
  }

  const { data, error } = await supabase.rpc("import_bank_statement", {
    p_bank_account: bank,
    p_period_start: from,
    p_period_end: to,
    p_opening: opening,
    p_closing: closing,
    p_rows: parsed.lines,
  });
  if (error) return { error: error.message, ok: null };

  revalidatePath("/books/bank");
  if (data) revalidatePath(`/books/bank/${data}`);
  return { error: null, ok: `${parsed.lines.length} lines read from ${file.name}.` };
}

/** Settling a line: post it, match it to a posting that exists, or set it aside. */
export async function settleLine(_prev: BooksState, formData: FormData): Promise<BooksState> {
  const { supabase, error: denied } = await admin();
  if (denied) return { error: denied, ok: null };

  const id = uuid(formData.get("transaction_id"));
  const statement = uuid(formData.get("statement_id"));
  const how = String(formData.get("how") ?? "");
  if (!id) return { error: "No line was named.", ok: null };

  let error: { message: string } | null = null;
  if (how === "post") {
    const account = uuid(formData.get("account_id"));
    if (!account) return { error: "Say what this line was.", ok: null };
    ({ error } = await supabase.rpc("post_bank_transaction", {
      p_transaction: id,
      p_account: account,
      p_memo: String(formData.get("memo") ?? ""),
    }));
  } else if (how === "match") {
    const journal = uuid(formData.get("journal_id"));
    if (!journal) return { error: "Say which posting this is.", ok: null };
    ({ error } = await supabase.rpc("match_bank_transaction", { p_transaction: id, p_journal: journal }));
  } else if (how === "ignore") {
    const reason = String(formData.get("reason") ?? "").trim();
    if (!reason) return { error: "Say why this line is being set aside.", ok: null };
    ({ error } = await supabase.rpc("ignore_bank_transaction", { p_transaction: id, p_reason: reason }));
  } else {
    return { error: "Say what to do with the line.", ok: null };
  }
  if (error) return { error: error.message, ok: null };

  if (statement) revalidatePath(`/books/bank/${statement}`);
  return { error: null, ok: "Settled." };
}

export async function reconcileStatement(_prev: BooksState, formData: FormData): Promise<BooksState> {
  const { supabase, error: denied } = await admin();
  if (denied) return { error: denied, ok: null };
  const id = uuid(formData.get("statement_id"));
  if (!id) return { error: "No statement was named.", ok: null };

  const { error } = await supabase.rpc("reconcile_bank_statement", { p_statement: id });
  if (error) return { error: error.message, ok: null };

  revalidatePath(`/books/bank/${id}`);
  revalidatePath("/books/bank");
  return { error: null, ok: "Reconciled." };
}

// ── closing ────────────────────────────────────────────────
export async function closeMonth(_prev: BooksState, formData: FormData): Promise<BooksState> {
  const { supabase, error: denied } = await admin();
  if (denied) return { error: denied, ok: null };
  const month = day(formData.get("month"));
  if (!month) return { error: "Say which month.", ok: null };

  const { error } = await supabase.rpc("close_ledger_month", {
    p_month: month,
    p_note: String(formData.get("note") ?? ""),
  });
  if (error) return { error: error.message, ok: null };

  revalidatePath("/books/close");
  return { error: null, ok: "Closed." };
}

export async function reopenMonth(_prev: BooksState, formData: FormData): Promise<BooksState> {
  const { supabase, error: denied } = await admin();
  if (denied) return { error: denied, ok: null };
  const month = day(formData.get("month"));
  const reason = String(formData.get("reason") ?? "").trim();
  if (!month) return { error: "Say which month.", ok: null };
  if (!reason) return { error: "Reopening a closed month needs a reason.", ok: null };

  const { error } = await supabase.rpc("reopen_ledger_month", { p_month: month, p_reason: reason });
  if (error) return { error: error.message, ok: null };

  revalidatePath("/books/close");
  return { error: null, ok: "Reopened, and written down." };
}

/** The day the books open, and which basis the reports default to. */
export async function setBooksSettings(_prev: BooksState, formData: FormData): Promise<BooksState> {
  const { supabase, error: denied } = await admin();
  if (denied) return { error: denied, ok: null };

  const start = day(formData.get("books_start"));
  const basis = String(formData.get("basis") ?? "");
  if (!start) return { error: "Say the day the books open.", ok: null };
  if (!["Cash", "Accrual"].includes(basis)) return { error: "Cash or accrual.", ok: null };

  // The books open once. Once anything is posted the start date is a fact
  // about the past, so only the basis is still a choice.
  const { data: posted } = await supabase.from("journals").select("id").limit(1);
  const opened = (posted ?? []).length > 0;

  const { error } = await supabase
    .from("ledger_settings")
    .update(opened ? { basis } : { books_start: start, basis })
    .eq("entity_id", await entityId(supabase));
  if (error) return { error: error.message, ok: null };

  revalidatePath("/books");
  revalidatePath("/books/close");
  return {
    error: null,
    ok: opened ? "Basis saved. The start date is settled: entries are already posted." : "Saved.",
  };
}

// ── the budget, and when to warn (E2) ──────────────────────
/**
 * One account's twelve months.
 *
 * An empty month is no budget at all, which is not the same as a budget of
 * zero: an account nobody budgeted is never reported as over budget, and an
 * account budgeted at zero is over the moment it costs anything. Clearing a
 * month therefore deletes the row rather than writing a nought into it.
 */
export async function setBudget(_prev: BooksState, formData: FormData): Promise<BooksState> {
  const { supabase, error: denied } = await admin();
  if (denied) return { error: denied, ok: null };

  const account = uuid(formData.get("account_id"));
  const year = Number(formData.get("year"));
  if (!account) return { error: "Say which account.", ok: null };
  if (!Number.isInteger(year) || year < 2000 || year > 2100) {
    return { error: "Say which year.", ok: null };
  }

  const amount = (v: FormDataEntryValue | null) => {
    const text = String(v ?? "").replace(/[$,\s]/g, "");
    if (text === "") return null;
    const n = Number(text);
    return Number.isFinite(n) ? n : null;
  };
  const even = amount(formData.get("even"));

  const entity = await entityId(supabase);
  const keep: { entity_id: string; account_id: string; month: string; amount: number }[] = [];
  const clear: string[] = [];
  for (let m = 1; m <= 12; m++) {
    const month = `${year}-${String(m).padStart(2, "0")}-01`;
    const value = even ?? amount(formData.get(`month_${m}`));
    if (value === null) clear.push(month);
    else keep.push({ entity_id: entity, account_id: account, month, amount: value });
  }

  if (keep.length > 0) {
    const { error } = await supabase.from("ledger_budgets").upsert(keep);
    if (error) return { error: error.message, ok: null };
  }
  if (clear.length > 0) {
    const { error } = await supabase
      .from("ledger_budgets")
      .delete()
      .eq("entity_id", entity)
      .eq("account_id", account)
      .in("month", clear);
    if (error) return { error: error.message, ok: null };
  }

  revalidatePath("/books/budget");
  return { error: null, ok: `${keep.length} month(s) budgeted for ${year}.` };
}

/** The cash floor and the budget tolerance: both off until somebody sets them. */
export async function setAlertThresholds(_prev: BooksState, formData: FormData): Promise<BooksState> {
  const { supabase, error: denied } = await admin();
  if (denied) return { error: denied, ok: null };

  const floorText = String(formData.get("cash_floor") ?? "").replace(/[$,\s]/g, "");
  const floor = floorText === "" ? null : Number(floorText);
  if (floor !== null && !Number.isFinite(floor)) return { error: "A cash floor is a number.", ok: null };

  const tolerance = Number(String(formData.get("budget_tolerance") ?? "").replace(/[%\s]/g, ""));
  if (!Number.isFinite(tolerance) || tolerance < 0 || tolerance > 999) {
    return { error: "A tolerance is a percentage between 0 and 999.", ok: null };
  }

  const { error } = await supabase
    .from("ledger_settings")
    .update({ cash_floor: floor, budget_tolerance: tolerance })
    .eq("entity_id", await entityId(supabase));
  if (error) return { error: error.message, ok: null };

  revalidatePath("/books/forecast");
  return {
    error: null,
    ok: floor === null ? "Saved. No cash warning while the floor is empty." : "Saved.",
  };
}

// ── vendors and bills (E3) ─────────────────────────────────
/**
 * These are not Admin's alone.
 *
 * Entering a bill and chasing it is the billing job; approving it is what the
 * threshold decides, and that is decided in the database by
 * approve_vendor_bill. So the gate here is "may read the books", and the one
 * action with real authority asks the database rather than this file.
 */
async function books(): Promise<{ supabase: Awaited<ReturnType<typeof createClient>>; error: string | null }> {
  const me = await requireStaff();
  const supabase = await createClient();
  if (!canReach(me, "/books")) return { supabase, error: "Not yours." };
  return { supabase, error: null };
}

const amountOf = (v: FormDataEntryValue | null) => {
  const text = String(v ?? "").replace(/[$,\s]/g, "");
  if (text === "") return null;
  const n = Number(text);
  return Number.isFinite(n) && n > 0 ? Math.round(n * 100) / 100 : null;
};

export async function saveVendor(_prev: BooksState, formData: FormData): Promise<BooksState> {
  const { supabase, error: denied } = await books();
  if (denied) return { error: denied, ok: null };

  const name = String(formData.get("name") ?? "").trim();
  if (!name) return { error: "A vendor needs a name.", ok: null };

  const last4 = String(formData.get("tin_last4") ?? "").replace(/\D/g, "").slice(-4);
  const tinType = String(formData.get("tin_type") ?? "");
  const w9On = formData.get("w9_on_file") === "on";
  const w9Date = day(formData.get("w9_received_on"));
  if (w9On && !w9Date) {
    return { error: "A W-9 on file has a day it arrived.", ok: null };
  }

  const row = {
    name,
    contact_name: String(formData.get("contact_name") ?? "").trim(),
    email: String(formData.get("email") ?? "").trim(),
    phone: String(formData.get("phone") ?? "").trim(),
    note: String(formData.get("note") ?? "").trim(),
    expense_account_id: uuid(formData.get("expense_account_id")),
    terms_days: formData.get("terms_days") ? Number(String(formData.get("terms_days"))) || null : null,
    gets_1099: formData.get("gets_1099") === "on",
    w9_on_file: w9On,
    w9_received_on: w9Date,
    tin_type: tinType === "EIN" || tinType === "SSN" ? tinType : null,
    tin_last4: /^\d{4}$/.test(last4) ? last4 : null,
  };

  const id = uuid(formData.get("id"));
  const { error } = id
    ? await supabase
        .from("vendors")
        .update({ ...row, active: formData.get("active") === "on" })
        .eq("id", id)
    : await supabase.from("vendors").insert({ ...row, entity_id: await entityId(supabase) });
  if (error) return { error: error.message, ok: null };

  revalidatePath("/books/vendors");
  return { error: null, ok: `${name} saved.` };
}

export async function addBill(_prev: BooksState, formData: FormData): Promise<BooksState> {
  const { supabase, error: denied } = await books();
  if (denied) return { error: denied, ok: null };

  const vendor = uuid(formData.get("vendor_id"));
  const date = day(formData.get("bill_date"));
  const amount = amountOf(formData.get("amount"));
  if (!vendor) return { error: "Say which vendor.", ok: null };
  if (!date) return { error: "Say the day the bill is dated.", ok: null };
  if (!amount) return { error: "An amount, above zero.", ok: null };

  const { data: v } = await supabase
    .from("vendors")
    .select("name, expense_account_id, terms_days")
    .eq("id", vendor)
    .single();
  const account = uuid(formData.get("account_id")) ?? v?.expense_account_id ?? null;
  if (!account) {
    return { error: "Say which account this posts to; this vendor has no usual one.", ok: null };
  }

  // The due date the vendor's terms imply, where nobody typed one.
  const due =
    day(formData.get("due_date")) ??
    (v?.terms_days === null || v?.terms_days === undefined
      ? null
      : new Date(new Date(date + "T00:00:00Z").getTime() + v.terms_days * 86400000)
          .toISOString()
          .slice(0, 10));

  const { error } = await supabase.from("vendor_bills").insert({
    entity_id: await entityId(supabase),
    vendor_id: vendor,
    number: String(formData.get("number") ?? "").trim(),
    bill_date: date,
    due_date: due,
    amount,
    account_id: account,
    description: String(formData.get("description") ?? "").trim(),
    created_by: (await requireStaff()).id,
  });
  if (error) return { error: error.message, ok: null };

  revalidatePath("/books/bills");
  return { error: null, ok: `${v?.name ?? "The bill"} entered, awaiting approval.` };
}

/** Approve, schedule, pay or void. One form per thing, one place that does it. */
export async function settleBill(_prev: BooksState, formData: FormData): Promise<BooksState> {
  const { supabase, error: denied } = await books();
  if (denied) return { error: denied, ok: null };

  const id = uuid(formData.get("bill_id"));
  const how = String(formData.get("how") ?? "");
  if (!id) return { error: "No bill was named.", ok: null };

  if (how === "approve") {
    const { error } = await supabase.rpc("approve_vendor_bill", { p_bill: id });
    if (error) return { error: error.message, ok: null };
    revalidatePath("/books/bills");
    return { error: null, ok: "Approved." };
  }

  if (how === "schedule") {
    const when = day(formData.get("scheduled_for"));
    if (!when) return { error: "Say which day it will be paid.", ok: null };
    const { error } = await supabase
      .from("vendor_bills")
      .update({ status: "Scheduled", scheduled_for: when })
      .eq("id", id)
      .in("status", ["Approved", "Scheduled"]);
    if (error) return { error: error.message, ok: null };
    revalidatePath("/books/bills");
    return { error: null, ok: `Scheduled for ${when}.` };
  }

  if (how === "pay") {
    const when = day(formData.get("paid_on"));
    const method = String(formData.get("method") ?? "");
    if (!when) return { error: "Say the day it was paid.", ok: null };
    if (!["Check", "ACH", "Card", "Cash", "Other"].includes(method)) {
      return { error: "Say how it was paid.", ok: null };
    }
    const { error } = await supabase
      .from("vendor_bills")
      .update({
        status: "Paid",
        paid_on: when,
        method,
        reference: String(formData.get("reference") ?? "").trim(),
      })
      .eq("id", id)
      .in("status", ["Approved", "Scheduled"]);
    if (error) return { error: error.message, ok: null };
    revalidatePath("/books/bills");
    return { error: null, ok: "Marked paid." };
  }

  if (how === "void") {
    const reason = String(formData.get("void_reason") ?? "").trim();
    if (!reason) return { error: "Say why it is being voided.", ok: null };
    const { error } = await supabase
      .from("vendor_bills")
      .update({ status: "Void", void_reason: reason })
      .eq("id", id)
      .neq("status", "Void");
    if (error) return { error: error.message, ok: null };
    revalidatePath("/books/bills");
    return { error: null, ok: "Voided, and whatever was posted is reversed." };
  }

  return { error: "Say what to do with it.", ok: null };
}

export async function addSchedule(_prev: BooksState, formData: FormData): Promise<BooksState> {
  const { supabase, error: denied } = await admin();
  if (denied) return { error: denied, ok: null };

  const vendor = uuid(formData.get("vendor_id"));
  const account = uuid(formData.get("account_id"));
  const amount = amountOf(formData.get("amount"));
  const next = day(formData.get("next_due"));
  const every = Number(formData.get("every_months")) || 1;
  if (!vendor || !account) return { error: "A vendor and an account.", ok: null };
  if (!amount) return { error: "An amount, above zero.", ok: null };
  if (!next) return { error: "Say when the first one is due.", ok: null };

  const { error } = await supabase.from("vendor_bill_schedules").insert({
    entity_id: await entityId(supabase),
    vendor_id: vendor,
    account_id: account,
    amount,
    every_months: every,
    day_of_month: Math.min(28, Number(next.slice(8, 10))),
    next_due: next,
    description: String(formData.get("description") ?? "").trim(),
    created_by: (await requireStaff()).id,
  });
  if (error) return { error: error.message, ok: null };

  revalidatePath("/books/bills");
  return { error: null, ok: "Added. Each one arrives awaiting approval." };
}

// ── asking before spending (E3) ────────────────────────────
export async function askToBuy(_prev: BooksState, formData: FormData): Promise<BooksState> {
  const me = await requireStaff();
  const supabase = await createClient();

  const what = String(formData.get("what") ?? "").trim();
  const amount = amountOf(formData.get("amount"));
  if (!what) return { error: "Say what it is.", ok: null };
  if (!amount) return { error: "Say roughly what it costs.", ok: null };

  const { error } = await supabase.from("purchase_requests").insert({
    staff_id: me.id,
    what,
    why: String(formData.get("why") ?? "").trim(),
    amount,
    status: "Requested",
  });
  if (error) return { error: error.message, ok: null };

  revalidatePath("/requests");
  return { error: null, ok: "Asked. An Admin will decide." };
}

export async function decideRequest(_prev: BooksState, formData: FormData): Promise<BooksState> {
  const me = await requireStaff();
  if (me.role !== "Admin") return { error: "Only an Admin decides these.", ok: null };
  const supabase = await createClient();

  const id = uuid(formData.get("request_id"));
  const decision = String(formData.get("decision") ?? "");
  if (!id) return { error: "No request was named.", ok: null };
  if (!["Approved", "Declined"].includes(decision)) return { error: "Approve it or decline it.", ok: null };

  const { error } = await supabase
    .from("purchase_requests")
    .update({
      status: decision,
      decided_by: me.id,
      decided_at: new Date().toISOString(),
      decision_note: String(formData.get("note") ?? "").trim(),
    })
    .eq("id", id)
    .eq("status", "Requested");
  if (error) return { error: error.message, ok: null };

  revalidatePath("/requests");
  return { error: null, ok: decision === "Approved" ? "Approved." : "Declined." };
}

/** The amount above which somebody asks first. Null switches it off. */
export async function setPurchaseThreshold(_prev: BooksState, formData: FormData): Promise<BooksState> {
  const { supabase, error: denied } = await admin();
  if (denied) return { error: denied, ok: null };

  const text = String(formData.get("purchase_request_over") ?? "").replace(/[$,\s]/g, "");
  const over = text === "" ? null : Number(text);
  if (over !== null && !(Number.isFinite(over) && over >= 0)) {
    return { error: "An amount, or empty to switch it off.", ok: null };
  }
  const limitText = String(formData.get("bill_approval_limit") ?? "").replace(/[$,\s]/g, "");
  const limit = limitText === "" ? null : Number(limitText);
  if (limit !== null && !(Number.isFinite(limit) && limit >= 0)) {
    return { error: "An approval limit is an amount, or empty for Admin only.", ok: null };
  }

  const { error } = await supabase
    .from("ledger_settings")
    .update({ purchase_request_over: over, bill_approval_limit: limit })
    .eq("entity_id", await entityId(supabase));
  if (error) return { error: error.message, ok: null };

  revalidatePath("/requests");
  revalidatePath("/books/bills");
  return { error: null, ok: over === null ? "Saved. Nobody has to ask." : "Saved." };
}
