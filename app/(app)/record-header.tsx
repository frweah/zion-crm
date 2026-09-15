import Link from "next/link";
import type { ReactNode } from "react";

/**
 * The header of a record - a client, a counselor, a member of staff, a job
 * opening, a records request.
 *
 * The same shape on each: the way back, the name in the serif with its status
 * beside it when it is not the ordinary one, a line of what identifies it, a
 * line of who and where it stands, and what you can do to it on the right.
 * A record's own tabs, if it has any, go directly under this; the sidebar's
 * group tabs are not shown on a record, so tabs never stack.
 */
export function RecordHeader({
  back,
  title,
  status,
  identity,
  standing,
  actions,
}: {
  back: { href: string; label: string };
  title: ReactNode;
  /** Shown as a chip beside the name - only when it says something (Closed, Inactive). */
  status?: string | null;
  /** What identifies the record: numbers, agency, contact details. Joined with " · ". */
  identity?: ReactNode[];
  /** Where it stands: who it is with, its stage. */
  standing?: ReactNode;
  actions?: ReactNode;
}) {
  const parts = (identity ?? []).filter((p) => p !== null && p !== undefined && p !== false && p !== "");
  return (
    <header className="record-head">
      <p className="sub record-back no-print">
        <Link href={back.href}>← {back.label}</Link>
      </p>
      <div className="page-head">
        <div>
          <h1 className="h1">
            {title}
            {status && (
              <span className="chip" style={{ marginLeft: 10, verticalAlign: "middle" }}>
                {status}
              </span>
            )}
          </h1>
          {parts.length > 0 && (
            <p className="sub">
              {parts.map((p, i) => (
                <span key={i}>
                  {i > 0 && " · "}
                  {p}
                </span>
              ))}
            </p>
          )}
          {standing && (
            <p className="sub" style={{ marginTop: 4 }}>
              {standing}
            </p>
          )}
        </div>
        {actions && <div className="row2 no-print record-actions">{actions}</div>}
      </div>
    </header>
  );
}
