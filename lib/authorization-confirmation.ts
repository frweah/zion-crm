/**
 * What confirming an authorization's PDF did, in a sentence.
 *
 * Shared by the inbox and the Authorizations tab so both say the same thing
 * about the same outcome — in particular that a date already on file was
 * kept, which is the part somebody needs to know about and would otherwise
 * assume had been updated.
 */
export type Confirmation =
  | {
      auth_number: string | null;
      created: boolean | null;
      start_filled: boolean | null;
      end_filled: boolean | null;
      conflicts: string | null;
    }
  | null
  | undefined;

export function describeConfirmation(result: Confirmation): string {
  if (!result) return "Done.";

  const parts = [
    result.created
      ? `Created authorization ${result.auth_number} with this PDF.`
      : `Attached to authorization ${result.auth_number}.`,
  ];

  const filled = [result.start_filled && "start date", result.end_filled && "end date"].filter(Boolean);
  if (!result.created && filled.length) parts.push(`Filled the blank ${filled.join(" and ")}.`);

  if (result.conflicts) parts.push(`Kept what was on file: ${result.conflicts}.`);

  return parts.join(" ");
}
