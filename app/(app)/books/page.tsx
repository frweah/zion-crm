import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { readSettings, requireBooks } from "@/lib/books";
import { PageHead } from "../page-head";

/**
 * The books (ERP brief, E1).
 *
 * A hub, like every other part of the app: the reports on one side and the
 * things somebody does on the other. The brief's list of seven reports is one
 * screen rather than seven, because a report is chosen and a period is chosen
 * and that is the same two controls every time - seven near-identical pages
 * would be seven places to fix the date picker.
 */
const PAGES: { href: string; label: string; note: string }[] = [
  {
    href: "/books/reports",
    label: "Reports",
    note: "Profit & Loss, balance sheet, cash flow, trial balance, aging, revenue, the ledger.",
  },
  {
    href: "/books/budget",
    label: "Budget",
    note: "What the practice meant to earn and spend, against what it did.",
  },
  {
    href: "/books/forecast",
    note: "Ninety days of cash, and what is expected in and out.",
    label: "Forecast",
  },
  {
    href: "/books/vendors",
    label: "Vendors",
    note: "Who the practice pays, and who gets a 1099.",
  },
  {
    href: "/books/bills",
    label: "Bills",
    note: "What has been billed, what is approved, and what is due.",
  },
  {
    href: "/books/assets",
    label: "Equipment",
    note: "What the practice owns, who has it, and what it is worth now.",
  },
  {
    href: "/books/bank",
    label: "Bank statements",
    note: "Import a statement, match what it shows, reconcile it.",
  },
  {
    href: "/books/journals",
    label: "Journal entries",
    note: "What has been posted, and an entry written by hand.",
  },
  {
    href: "/books/chart",
    label: "Chart of accounts",
    note: "The accounts, and which service or claim each one takes.",
  },
  {
    href: "/books/close",
    label: "Closing",
    note: "Shut a finished month, and the year-end package for the CPA.",
  },
];

export default async function Books() {
  await requireBooks();
  const supabase = await createClient();
  const settings = await readSettings(supabase);
  const open = settings ? new Date(settings.books_start + "T00:00:00Z") <= new Date() : false;

  return (
    <>
      <PageHead
        title="Books"
        context={
          settings
            ? `${settings.basis} basis, open from ${settings.books_start}`
            : "Not set up yet"
        }
      />
      {!open && settings && (
        <p className="lock">
          The books open on {settings.books_start}. Everything the CRM records is already wired to
          post; until that day nothing is posted, so these screens are empty on purpose.
        </p>
      )}
      <div className="hub-cards">
        {PAGES.map((p) => (
          <Link key={p.href} href={p.href} className="hub-card">
            <span className="hub-card-label">{p.label}</span>
            <span className="hub-card-note">{p.note}</span>
          </Link>
        ))}
      </div>
    </>
  );
}
