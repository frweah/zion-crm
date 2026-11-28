"use client";

/**
 * A phone number somebody can press.
 *
 * It does not hold a telephone of its own. Pressing it says "dial this" into
 * the page, and the one softphone in the shell picks it up - which is why
 * there can be a dozen of these on a client's record without a dozen copies
 * of the SDK, and why a number on a screen is still a number when nobody is
 * signed in to the client line.
 *
 * That is the whole of the indirection: a custom event rather than a prop
 * threaded through six screens, because the alternative is every screen that
 * shows a number having to know about telephones.
 *
 * The number stays visible and stays selectable. Somebody reading a number
 * out to a client, or copying it into their own phone, is the commonest thing
 * done with a number on a screen, and a button that swallowed the text would
 * have made that harder in exchange for one click.
 */
export function Dial({
  phone,
  label,
  children,
}: {
  phone: string | null | undefined;
  /** Whose number it is, for the panel while it rings. */
  label?: string;
  children?: React.ReactNode;
}) {
  const number = (phone ?? "").trim();
  if (!number) return null;

  return (
    <button
      type="button"
      className="btn ghost"
      style={{ padding: "2px 8px", fontSize: "var(--text-sm)" }}
      title={`Call ${number}`}
      onClick={() =>
        window.dispatchEvent(
          new CustomEvent("zion:dial", { detail: { to: number, label: label ?? number } }),
        )
      }
    >
      {children ?? "Call"}
    </button>
  );
}
