"use client";

import { useActionState, useState } from "react";
import Link from "next/link";
import { SERVICE_TYPES } from "@/lib/constants";
import type { FieldKey } from "@/lib/authorization-parse";
import {
  readAuthorization,
  createFromImport,
  emptyImport,
  type ImportState,
} from "./actions";

type Client = { id: string; name: string; agency_id: string | null };

/**
 * Reading an authorization, then confirming it.
 *
 * Two steps, and the second one is the point. The parse produces a proposal
 * with every value showing the line it came from; a person checks it against
 * the PDF in front of them and presses the button. Nothing is created by
 * uploading a file, because a wrong rate on a client's record is expensive
 * and an upload is one click.
 */
export function ImportForm({ clients }: { clients: Client[] }) {
  const [readState, readAction, reading] = useActionState<ImportState, FormData>(
    readAuthorization,
    emptyImport,
  );
  const [createState, createAction, creating] = useActionState<ImportState, FormData>(
    createFromImport,
    emptyImport,
  );

  const parsed = readState.parsed;
  const value = (key: FieldKey) => parsed?.fields?.[key]?.value ?? "";
  const source = (key: FieldKey) => parsed?.fields?.[key]?.source ?? "";

  // Match on the USOR ID first, then on the name — the ID is the thing that
  // does not change when somebody starts going by their middle name.
  const guessClient = () => {
    if (!parsed) return "";
    const id = value("agencyId");
    if (id) {
      const byId = clients.find((c) => (c.agency_id ?? "").trim() === id);
      if (byId) return byId.id;
    }
    const name = value("clientName").toLowerCase().replace(/[^a-z ]/g, "").trim();
    if (!name) return "";
    const exact = clients.find((c) => c.name.toLowerCase() === name);
    if (exact) return exact.id;
    const parts = name.split(" ").filter((p: string) => p.length > 2);
    const partial = clients.find((c) => {
      const n = c.name.toLowerCase();
      return parts.length > 1 && parts.every((p: string) => n.includes(p));
    });
    return partial?.id ?? "";
  };

  const guessService = () => {
    const raw = value("serviceType").toLowerCase();
    if (!raw) return "";
    const exact = SERVICE_TYPES.find((s) => s.toLowerCase() === raw);
    if (exact) return exact;
    return SERVICE_TYPES.find((s) => raw.includes(s.toLowerCase()) || s.toLowerCase().includes(raw)) ?? "";
  };

  const [showLines, setShowLines] = useState(false);
  const matchedClient = guessClient();
  const matchedService = guessService();

  return (
    <>
      <div className="card" style={{ marginBottom: 14 }}>
        <h3 style={{ marginTop: 0 }}>The authorization PDF</h3>
        <p className="sub" style={{ marginTop: 0 }}>
          Read here on our own server — the file is not stored and not sent anywhere. What comes
          back is a proposal for you to check, not an authorization.
        </p>
        {readState.error && <div className="alert bad">{readState.error}</div>}
        <form action={readAction}>
          <div className="row2">
            <label className="field" style={{ flex: 2 }}>
              File
              <input type="file" name="pdf" accept="application/pdf" required />
            </label>
            <button className="btn gold" type="submit" disabled={reading}>
              {reading ? "Reading…" : "Read it"}
            </button>
          </div>
        </form>
      </div>

      {parsed?.scanned && (
        <div className="alert bad" style={{ marginBottom: 14 }}>
          <b>This is a scan.</b> {parsed.warnings[0]} Nothing was read from it, and nothing was
          guessed.{" "}
          <Link href="/billing?tab=authorizations">Add the authorization by hand</Link>.
        </div>
      )}

      {parsed && !parsed.scanned && (
        <>
          {parsed.warnings.map((w) => (
            <div className="alert" key={w}>
              {w}
            </div>
          ))}

          {parsed.missing.length > 0 && (
            <div className="alert" style={{ marginBottom: 14 }}>
              Not found in the file: {parsed.missing.join(", ")}. Fill those in yourself — the
              rules only read labels they know, and USOR forms vary.
            </div>
          )}

          {createState.error && <div className="alert bad">{createState.error}</div>}

          <form action={createAction}>
            <div className="card" style={{ marginBottom: 14 }}>
              <h3 style={{ marginTop: 0 }}>Check this against the PDF</h3>
              <p className="sub" style={{ marginTop: 0 }}>
                Every value shows the line it was read from. Change anything that is wrong — what
                is on this form is what gets saved.
              </p>

              <div className="row2">
                <label className="field" style={{ flex: 2 }}>
                  Client
                  <select name="client_id" defaultValue={matchedClient} required>
                    <option value="">Choose…</option>
                    {clients.map((c) => (
                      <option key={c.id} value={c.id}>
                        {c.name}
                        {c.agency_id ? ` · USOR ID ${c.agency_id}` : ""}
                      </option>
                    ))}
                  </select>
                  <span className="lock">
                    {value("clientName") ? (
                      <>
                        Read as &ldquo;{value("clientName")}&rdquo;
                        {value("agencyId") && `, USOR ID ${value("agencyId")}`}.{" "}
                        {matchedClient
                          ? "Matched to the client above — check it is the right one."
                          : "No client on file matches, so choose them yourself."}
                      </>
                    ) : (
                      "No name was read from the file."
                    )}
                  </span>
                </label>

                <label className="field" style={{ maxWidth: 200 }}>
                  Authorization number
                  <input name="number" defaultValue={value("authNumber")} />
                  <span className="lock">{source("authNumber")}</span>
                </label>
              </div>

              <div className="row2">
                <label className="field" style={{ flex: 2 }}>
                  Service
                  <select name="service_type" defaultValue={matchedService} required>
                    <option value="">Choose…</option>
                    {SERVICE_TYPES.map((s) => (
                      <option key={s}>{s}</option>
                    ))}
                  </select>
                  <span className="lock">
                    {value("serviceType")
                      ? `Read as “${value("serviceType")}”. The service decides which USOR forms have to be finished before an invoice can go.`
                      : "No service was read from the file."}
                  </span>
                </label>

                <label className="field" style={{ maxWidth: 160 }}>
                  Rate type
                  <select name="rate_type" defaultValue={value("rateType") || "Hourly"}>
                    <option>Hourly</option>
                    <option>Flat Fee</option>
                  </select>
                  <span className="lock">{source("rateType")}</span>
                </label>
              </div>

              <div className="row2">
                <label className="field" style={{ maxWidth: 160 }}>
                  Rate or fee
                  <input name="rate" type="number" step="0.01" defaultValue={value("rate")} required />
                  <span className="lock">{source("rate")}</span>
                </label>
                <label className="field" style={{ maxWidth: 160 }}>
                  Authorized hours
                  <input name="total_hours" type="number" step="0.25" defaultValue={value("totalHours")} />
                  <span className="lock">
                    {source("totalHours") || "Leave blank for a flat fee."}
                  </span>
                </label>
                <label className="field" style={{ maxWidth: 170 }}>
                  Start date
                  <input type="date" name="start_date" defaultValue={value("startDate")} />
                  <span className="lock">{source("startDate")}</span>
                </label>
                <label className="field" style={{ maxWidth: 170 }}>
                  End date
                  <input type="date" name="end_date" defaultValue={value("endDate")} />
                  <span className="lock">{source("endDate")}</span>
                </label>
              </div>

              <label className="field">
                Note
                <input
                  name="note"
                  defaultValue={
                    [
                      readState.filename && `From ${readState.filename}`,
                      value("counselorName") && `counselor ${value("counselorName")}`,
                      value("office") && `${value("office")} office`,
                    ]
                      .filter(Boolean)
                      .join(" · ")
                  }
                />
                <span className="lock">
                  The counselor and office are recorded here rather than on the authorization,
                  which has no field for them.
                </span>
              </label>

              <div className="row2" style={{ marginTop: 10 }}>
                <button className="btn gold" type="submit" disabled={creating}>
                  {creating ? "Creating…" : "Create the authorization"}
                </button>
                <span className="lock">
                  Nothing has been saved yet. The database still checks its own rules — hours are
                  required for an hourly authorization, and hours can never be logged past them.
                </span>
              </div>
            </div>
          </form>

          <div className="card">
            <button
              className="btn ghost"
              type="button"
              onClick={() => setShowLines(!showLines)}
            >
              {showLines ? "Hide" : "Show"} what was actually read ({parsed.lines.length} lines,{" "}
              {parsed.pages} {parsed.pages === 1 ? "page" : "pages"})
            </button>
            {showLines && (
              <pre
                style={{
                  marginTop: 12,
                  maxHeight: 300,
                  overflow: "auto",
                  whiteSpace: "pre-wrap",
                  fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace",
                  fontSize: 12,
                  lineHeight: 1.5,
                }}
              >
                {parsed.lines.join("\n")}
              </pre>
            )}
            <p className="lock" style={{ margin: "10px 0 0" }}>
              If a field came out wrong, this is where to look: the rules read labels off these
              lines. A label they do not know is a rule to add, not a guess to make.
            </p>
          </div>
        </>
      )}
    </>
  );
}
