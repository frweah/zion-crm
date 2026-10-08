"use client";

import Link from "next/link";
import { useActionState, useState } from "react";
import { createForm, type FormState } from "./forms/actions";
import { FORM_TEMPLATES, templateById } from "@/lib/form-templates";
import { fmtStamp, today } from "@/lib/constants";
import { DataTable } from "../../data-table";

const initial: FormState = { error: null, ok: null };

export type FormRow = {
  id: string;
  template_id: string;
  status: string;
  month: string | null;
  auth_id: string | null;
  created_at: string;
  completed_at: string | null;
  completed_by_name: string;
  sent_to: string;
};

export type AuthChoice = { id: string; label: string; serviceType: string };

export function FormsTab({
  clientId,
  forms,
  auths,
  missingForBilling,
}: {
  clientId: string;
  forms: FormRow[];
  auths: AuthChoice[];
  missingForBilling: { authLabel: string; usor: string[] }[];
}) {
  const [state, action, pending] = useActionState(createForm, initial);
  const [templateId, setTemplateId] = useState("");

  const template = templateId ? templateById(templateId) : undefined;

  return (
    <>
      {missingForBilling.length > 0 && (
        <div className="alert">
          <b>Outstanding before billing:</b>
          <ul style={{ margin: "6px 0 0", paddingLeft: 20 }}>
            {missingForBilling.map((m) => (
              <li key={m.authLabel}>
                {m.authLabel} — {m.usor.join(" + ")}
              </li>
            ))}
          </ul>
        </div>
      )}

      {/*
        "Start a form" was here: a list of blank forms to pick from, and three
        questions - which form, which authorization, which month - that the
        authorization already knows the answers to.

        §13.10: forms are generated, not filled. They are produced from the
        authorization that needs them, where the record knows the client, the
        counselor, the month and the hours, and this tab is where they are read
        afterwards. One screen per job (§11): a second way to make a form is a
        second way to make the wrong one.
      */}
      {missingForBilling.length > 0 && (
        <p className="lock" style={{ margin: "0 0 14px" }}>
          Forms are produced from the authorization that needs them, on{" "}
          <Link href="/billing" style={{ color: "var(--teal)" }}>
            Billing
          </Link>
          , filled in from the record and the service log.
        </p>
      )}

      <div className="card" style={{ padding: 0 }}>
        <DataTable
          label="forms"
          columns={[
            { key: "form", label: "Form" },
            { key: "month", label: "Month" },
            { key: "status", label: "Status" },
            { key: "signed", label: "Signed" },
          ]}
          rows={forms.map((f) => {
            const t = templateById(f.template_id);
            const signed =
              f.status === "Draft"
                ? `started ${fmtStamp(f.created_at)}`
                : f.status === "Sent"
                  ? `sent to ${f.sent_to}`
                  : `${f.completed_by_name} · ${fmtStamp(f.completed_at)}`;
            return {
              key: f.id,
              sort: {
                form: t?.usor ?? f.template_id,
                month: f.month,
                status: f.status,
                signed: f.completed_at ?? f.created_at,
              },
              text: [t?.usor, t?.name, f.month, f.status, signed].filter(Boolean).join(" "),
              cells: {
                form: (
                  <>
                    <Link
                      href={`/clients/${clientId}/forms/${f.id}`}
                      style={{ color: "inherit", fontWeight: 600 }}
                    >
                      {t?.usor ?? f.template_id}
                    </Link>
                    <div style={{ fontSize: "var(--text-sm)", color: "var(--muted)" }}>{t?.name}</div>
                  </>
                ),
                month: f.month ?? "—",
                status: (
                  <span
                    className={
                      "chip " + (f.status === "Sent" ? "ok" : f.status === "Completed" ? "gold" : "")
                    }
                  >
                    {f.status}
                  </span>
                ),
                signed: <span style={{ fontSize: "var(--text-sm)", color: "var(--muted)" }}>{signed}</span>,
              },
            };
          })}
          empty="No forms for this client yet."
        />
      </div>
    </>
  );
}
