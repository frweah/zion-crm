import { ORG } from "@/lib/roles";
import { templateById, isHeading, type Field } from "@/lib/form-templates";

export type FormContext = {
  clientName: string;
  clientNo: number | null;
  agencyId: string;
  counselorName: string;
  authNumber: string;
  authServiceType: string;
  completedBy: string;
  completedAt: string | null;
};

type YesNo = { v?: string; x?: string };
type TableRow = Record<string, string | number>;

function isEmpty(v: unknown): boolean {
  return (
    v === undefined ||
    v === "" ||
    v === false ||
    v === null ||
    (Array.isArray(v) && v.length === 0)
  );
}

/**
 * Renders a completed form as the plain text that goes to the counselor.
 *
 * The header carries what USOR needs to identify the submission: client,
 * counselor, authorization number, and our vendor number.
 */
export function formToText(
  templateId: string,
  data: Record<string, unknown>,
  ctx: FormContext,
): string {
  const tpl = templateById(templateId);
  if (!tpl) return "Unknown form.";

  const L: string[] = [
    `STATE OF UTAH — DEPARTMENT OF WORKFORCE SERVICES — ${tpl.usor}`,
    tpl.name.toUpperCase(),
    "",
    `Client Name: ${ctx.clientName}${ctx.clientNo ? `   (Client #${ctx.clientNo})` : ""}${
      ctx.agencyId ? `   USOR ID ${ctx.agencyId}` : ""
    }`,
    `VR Counselor: ${ctx.counselorName || "—"}   Authorization #: ${ctx.authNumber || "—"}${
      ctx.authServiceType ? ` (${ctx.authServiceType})` : ""
    }`,
    `CRP Company: ${ORG.name}   Vendor #: ${ORG.vendor}`,
    `${ORG.address}   Phone: ${ORG.phone}   ${ORG.email}   ${ORG.web}`,
    "",
  ];

  for (const f of tpl.fields as Field[]) {
    if (isHeading(f)) {
      L.push("");
      L.push(f.heading.toUpperCase());
      continue;
    }

    const v = data[f.k];
    if (isEmpty(v)) continue;

    if (f.t === "table" && f.cols) {
      L.push(`${f.l}:`);
      L.push("  " + f.cols.map((c) => c[1]).join(" | "));
      for (const row of v as TableRow[]) {
        L.push("  " + f.cols.map((c) => String(row[c[0]] ?? "")).join(" | "));
      }
    } else if (f.t === "checks") {
      L.push(`${f.l}: ${(v as string[]).join("; ")}`);
    } else if (f.t === "check") {
      L.push(`${f.l}: Yes`);
    } else if (f.t === "yesno") {
      const yn = v as YesNo;
      if (yn.v) L.push(`${f.l} — ${yn.v}${yn.x ? `\n   Explanation: ${yn.x}` : ""}`);
    } else if (f.t === "rating") {
      L.push(`  ${f.l}: ${v}/10`);
    } else if (f.t === "textarea") {
      L.push(`${f.l}:`);
      L.push(`  ${String(v).replace(/\n/g, "\n  ")}`);
    } else {
      L.push(`${f.l}: ${v}`);
    }
  }

  L.push("");
  L.push(
    ctx.completedAt
      ? `I understand that I am electronically signing this form, and I certify that the information on this form is correct to the best of my knowledge.\nCRP Signature: /s/ ${ctx.completedBy}    Date: ${ctx.completedAt.slice(0, 10)}`
      : "DRAFT — not signed",
  );

  return L.join("\n");
}
