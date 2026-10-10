import { money } from "@/lib/constants";
import { readChart, requireBooks } from "@/lib/books";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { DataTable, type DataRow } from "../../data-table";
import { RecordHeader } from "../../record-header";
import { CorrectEntry, WriteEntry } from "./journal-forms";

/**
 * What has been posted (ERP brief, E1).
 *
 * Newest first, with its two sides and what caused it. Almost everything here
 * is the CRM's own work - an item submitted, a warrant paid, a statement
 * approved - and the few entries somebody writes by hand are the ones worth
 * reading, so each carries its reason in the list rather than behind a click.
 *
 * Nothing on this screen edits anything. A posting is corrected by reversing
 * it and posting again, which is the only way a set of books can be both
 * fixable and trustworthy.
 */
const PAGE = 60;

type Line = {
  debit: number;
  credit: number;
  memo: string;
  ledger_accounts: { code: string; name: string } | null;
};

export default async function Journals({
  searchParams,
}: {
  searchParams: Promise<{ page?: string; reverse?: string }>;
}) {
  await requireBooks();
  const me = await requireStaff();
  const params = await searchParams;
  const page = Math.max(0, Number(params.page ?? 0) || 0);
  const supabase = await createClient();

  const [{ data: entries }, accounts] = await Promise.all([
    supabase
      .from("journals")
      .select(
        "id, entry_date, memo, source_kind, source_event, reason, reverses_id, created_by_name, created_at, " +
          "journal_lines(debit, credit, memo, ledger_accounts(code, name))",
      )
      .order("entry_date", { ascending: false })
      .order("created_at", { ascending: false })
      .range(page * PAGE, page * PAGE + PAGE - 1),
    readChart(supabase),
  ]);

  const rows = (entries ?? []) as unknown as {
    id: string;
    entry_date: string;
    memo: string;
    source_kind: string;
    source_event: string;
    reason: string;
    reverses_id: string | null;
    created_by_name: string;
    journal_lines: Line[];
  }[];

  const reversed = new Set(rows.filter((r) => r.reverses_id).map((r) => r.reverses_id as string));
  const correcting = params.reverse ? rows.find((r) => r.id === params.reverse) ?? null : null;

  return (
    <>
      <RecordHeader
        back={{ href: "/books", label: "Books" }}
        title="Journal entries"
        standing="Newest first"
      />

      {me.role === "Admin" && <WriteEntry accounts={accounts.filter((a) => a.active)} />}
      {me.role === "Admin" && correcting && <CorrectEntry id={correcting.id} memo={correcting.memo} />}

      <DataTable
        label="entries"
        columns={[
          { key: "entry_date", label: "Date" },
          { key: "memo", label: "What it was" },
          { key: "source", label: "From" },
          { key: "debit", label: "Debit" },
          { key: "credit", label: "Credit" },
          { key: "amount", label: "Amount", align: "right" },
          ...(me.role === "Admin" ? [{ key: "act", label: "", sortable: false }] : []),
        ]}
        rows={rows.map((r): DataRow => {
          const debits = r.journal_lines.filter((l) => Number(l.debit) > 0);
          const credits = r.journal_lines.filter((l) => Number(l.credit) > 0);
          const total = debits.reduce((sum, l) => sum + Number(l.debit), 0);
          const name = (l: Line) =>
            l.ledger_accounts ? `${l.ledger_accounts.code} ${l.ledger_accounts.name}` : "";
          const standing = reversed.has(r.id) ? " · reversed" : "";
          return {
            key: r.id,
            cells: {
              entry_date: r.entry_date,
              memo: r.memo + (r.reason ? ` · ${r.reason}` : "") + standing,
              source: r.source_kind + (r.source_event && r.source_event !== "Posted" ? ` · ${r.source_event}` : ""),
              debit: debits.map(name).join(", "),
              credit: credits.map(name).join(", "),
              amount: money(total),
              ...(me.role === "Admin"
                ? {
                    act:
                      !reversed.has(r.id) && !r.reverses_id ? (
                        <a href={`?page=${page}&reverse=${r.id}`}>Correct</a>
                      ) : (
                        ""
                      ),
                  }
                : {}),
            },
            sort: { amount: total },
          };
        })}
        pageSize={PAGE}
        empty="Nothing posted yet — the books open before the first entry appears."
      />

      {(page > 0 || rows.length === PAGE) && (
        <nav className="pager no-print" aria-label="Pages of entries">
          {page > 0 && <a href={`?page=${page - 1}`}>Newer</a>}
          {rows.length === PAGE && <a href={`?page=${page + 1}`}>Older</a>}
        </nav>
      )}
    </>
  );
}
