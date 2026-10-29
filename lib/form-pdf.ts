import "server-only";
import { formToText, type FormContext } from "@/lib/form-text";
import { templateById } from "@/lib/form-templates";
import { Pen, type Finished, type Signature } from "@/lib/pdf-page";

/**
 * A completed USOR form as a PDF, to attach to the billing email.
 *
 * The content is not rendered again here: it is `formToText`, the one
 * renderer, laid out on pages. A second renderer would drift from the first,
 * and the copy USOR receives would stop matching the copy the CRM shows -
 * which is the one kind of disagreement a billing document cannot have.
 *
 * Courier throughout the body, because formToText lays its tables out with
 * spaces and a proportional face would pull the columns apart.
 *
 * The page, the folding and the signature block are `lib/pdf-page.ts`, shared
 * with the monthly report for the same reason the renderer is shared with the
 * screen: the attestation under a form and the attestation under a report are
 * the same sentence about the same practice, and two copies of it would be
 * two things it says it is certifying.
 */
export type SignedForm = Finished;

export async function signedFormPdf({
  templateId,
  data,
  ctx,
  signature,
}: {
  templateId: string;
  data: Record<string, unknown>;
  ctx: FormContext;
  signature: Signature;
}): Promise<SignedForm> {
  const tpl = templateById(templateId);
  const pen = await Pen.open(`${tpl?.usor ?? "USOR form"} - ${ctx.clientName}`);

  // The body, exactly as the CRM and the email show it, minus the text
  // signature line - the block below says the same thing with more in it.
  const lines = formToText(templateId, data, ctx, { omitSignature: true }).split("\n");
  lines.forEach((line, i) => pen.text(line, i < 2 ? pen.monoBold : pen.mono));

  await pen.signature({
    certification:
      "I understand that I am electronically signing this form, and I certify that the information on it is correct to the best of my knowledge.",
    signature,
  });

  return pen.finish();
}
