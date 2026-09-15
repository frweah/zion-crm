import Link from "next/link";
import type { PortalMe } from "@/lib/portal/session";
import type { PortalFormState } from "../actions";
import { SignInForm, VerifyForm, ConsentForm, TextsForm, WithdrawForm } from "./forms";
import { IdleWarning } from "./idle-warning";

/**
 * Every portal screen, drawn from what it is given. The pages fetch; these
 * draw. The accessibility check draws the same components from made-up data
 * (app/portal/a11y), so what it checks is what a client sees.
 */

export type TermsBlock = { type: "h2" | "h3" | "li" | "strong" | "em" | "p"; text: string };
export type Terms = { version: string; title: string; body: TermsBlock[] };

const CLIENT_LINE = "385-406-3432";
const telLink = <a href="tel:+13854063432">{CLIENT_LINE}</a>;

function first(name: string): string {
  return name.trim().split(/\s+/)[0] || name;
}

// ── the frame once signed in ───────────────────────────────
export function SignedInBar({
  me,
  current,
  idlePreview = false,
}: {
  me: PortalMe;
  current: "home" | "settings" | "consent";
  idlePreview?: boolean;
}) {
  return (
    <div className="portal-signed-in">
      <div className="portal-wrap">
        <p className="portal-who">
          Signed in as <strong>{me.name}</strong>
          {me.kind === "Guardian" &&
            `, ${me.relationship.toLowerCase()} and guardian of ${me.client_first_name}`}
        </p>
        <nav aria-label="Portal" className="portal-nav">
          <ul>
            {me.electronic && (
              <>
                <li>
                  <Link href="/portal" aria-current={current === "home" ? "page" : undefined}>
                    Home
                  </Link>
                </li>
                <li>
                  <Link href="/portal/settings" aria-current={current === "settings" ? "page" : undefined}>
                    Settings
                  </Link>
                </li>
              </>
            )}
            <li>
              <form action="/portal/sign-out" method="post">
                <button className="btn ghost" type="submit">
                  Sign out
                </button>
              </form>
            </li>
          </ul>
        </nav>
      </div>
      <IdleWarning previewOpen={idlePreview} />
    </div>
  );
}

// ── the terms, word for word ───────────────────────────────
/** Each paragraph as stored; consecutive list items become one list. */
export function TermsBody({ terms }: { terms: Terms }) {
  const out: React.ReactNode[] = [];
  let list: string[] = [];
  const flush = (key: number) => {
    if (list.length === 0) return;
    out.push(
      <ul key={`ul-${key}`}>
        {list.map((text, i) => (
          <li key={i}>{text}</li>
        ))}
      </ul>,
    );
    list = [];
  };

  terms.body.forEach((block, i) => {
    if (block.type === "li") {
      list.push(block.text);
      return;
    }
    flush(i);
    if (block.type === "h2") out.push(<h2 key={i}>{block.text}</h2>);
    else if (block.type === "h3") out.push(<h3 key={i}>{block.text}</h3>);
    else if (block.type === "strong") out.push(<p key={i}><strong>{block.text}</strong></p>);
    else if (block.type === "em") out.push(<p key={i}><em>{block.text}</em></p>);
    else out.push(<p key={i}>{block.text}</p>);
  });
  flush(terms.body.length);

  return (
    <article className="portal-terms" aria-label={`${terms.title}, version ${terms.version}`}>
      {out}
    </article>
  );
}

// ── screens ────────────────────────────────────────────────
const ENDED: Record<string, string> = {
  idle: "You were signed out because nothing happened for 30 minutes. This keeps your information private. Sign in again to carry on.",
  "signed-out": "You are signed out.",
  declined:
    "You are signed out. You do not have to use the portal: Zion will keep working with you by phone and in person.",
  ended: "Your session has ended. Please sign in again.",
  code: "Please ask for a new code.",
};

export function SignInView({ ended, initial }: { ended?: string; initial?: PortalFormState }) {
  const notice = ended ? ENDED[ended] : undefined;
  return (
    <main id="main" className="portal-wrap portal-main">
      <h1>Sign in to your client portal</h1>
      {notice && (
        <p className="portal-notice" role="status">
          {notice}
        </p>
      )}
      <div className="portal-card">
        <SignInForm initial={initial} />
      </div>
      <p>
        The portal is for Zion clients and their guardians who have been invited. If you need access,
        call Zion at {telLink}.
      </p>
      <p>
        <Link href="/portal/terms">Read the terms of use and privacy notice</Link>
      </p>
    </main>
  );
}

export function VerifyView({ via, initial }: { via: "text" | "email"; initial?: PortalFormState }) {
  return (
    <main id="main" className="portal-wrap portal-main">
      <h1>Enter your code</h1>
      <div className="portal-card">
        <VerifyForm via={via} initial={initial} />
      </div>
      <h2>No code?</h2>
      <ul>
        <li>Codes can take a minute to arrive.</li>
        <li>
          <Link href="/portal/sign-in">Ask for a new code</Link>, or try your {via === "email" ? "mobile number" : "email address"} instead.
        </li>
        <li>Call Zion at {telLink} and we will help you sign in.</li>
      </ul>
    </main>
  );
}

export function ConsentView({
  me,
  terms,
  withdrawn = false,
  initial,
}: {
  me: PortalMe;
  terms: Terms | null;
  withdrawn?: boolean;
  initial?: PortalFormState;
}) {
  return (
    <>
      <SignedInBar me={me} current="consent" />
      <main id="main" className="portal-wrap portal-main">
        <h1>Before you use the portal</h1>
        {withdrawn && (
          <p className="portal-notice" role="status">
            You withdrew your consent, so the portal is closed. Zion keeps working with you by phone and in
            person. You can agree again below at any time.
          </p>
        )}
        {me.kind === "Guardian" && (
          <p className="portal-notice">
            You are agreeing as {me.name}, {me.relationship.toLowerCase()} and guardian of{" "}
            {me.client_first_name}. What you choose here is recorded as your choice, made for{" "}
            {me.client_first_name}.
          </p>
        )}
        {terms ? (
          <>
            <p>
              Please read the terms of use and privacy notice below, or ask someone you trust to read them
              with you. You can also call Zion at {telLink} to have them explained.
            </p>
            <TermsBody terms={terms} />
            <h2>Your choice</h2>
            <ConsentForm phoneLast4={me.phone_last4} textsAlready={me.texts} initial={initial} />
            <form action="/portal/sign-out?reason=declined" method="post" className="portal-actions">
              <button className="btn ghost" type="submit">
                I do not agree. Sign me out.
              </button>
            </form>
          </>
        ) : (
          <p className="portal-notice">
            The portal is not open yet. Please call Zion at {telLink}.
          </p>
        )}
      </main>
    </>
  );
}

export function HomeView({ me, idlePreview = false }: { me: PortalMe; idlePreview?: boolean }) {
  const staff = me.staff_first_name;
  return (
    <>
      <SignedInBar me={me} current="home" idlePreview={idlePreview} />
      <main id="main" className="portal-wrap portal-main">
        <h1>Hello, {me.kind === "Guardian" ? first(me.name) : me.client_first_name}</h1>
        <p>
          {me.kind === "Guardian"
            ? `This is ${me.client_first_name}'s Zion client portal.`
            : "This is your Zion client portal."}
        </p>

        <section className="portal-card" aria-labelledby="contact-heading">
          <h2 id="contact-heading">Your Zion contact</h2>
          <p>
            {staff ? `${staff} is your Zion staff member. ` : ""}To reach Zion, call {telLink}, Monday to
            Friday.
          </p>
        </section>

        <section className="portal-card" aria-labelledby="soon-heading">
          <h2 id="soon-heading">Coming to your portal</h2>
          <ul>
            <li>Documents Zion asks you for, which you can upload here</li>
            <li>Updates on your services</li>
            <li>Messages with {staff ?? "your Zion staff member"}</li>
          </ul>
        </section>

        <section className="portal-card" aria-labelledby="choices-heading">
          <h2 id="choices-heading">Your choices</h2>
          <p>
            Text messages from Zion are {me.texts ? "on" : "off"}.{" "}
            <Link href="/portal/settings">Change your choices in Settings</Link>
          </p>
        </section>
      </main>
    </>
  );
}

const TEXT_NOTICE: Record<string, string> = {
  on: "Text messages are on.",
  off: "Text messages are off. Zion will not text you.",
  "not-saved": "You agreed to the terms, but your choice about text messages was not saved. Please choose again below.",
};

export function SettingsView({ me, notice }: { me: PortalMe; notice?: string }) {
  const message = notice ? TEXT_NOTICE[notice] : undefined;
  return (
    <>
      <SignedInBar me={me} current="settings" />
      <main id="main" className="portal-wrap portal-main">
        <h1>Settings</h1>
        {message && (
          <p className="portal-notice" role="status">
            {message}
          </p>
        )}

        <section className="portal-card" aria-labelledby="texts-heading">
          <h2 id="texts-heading">Text messages</h2>
          <TextsForm on={me.texts} phoneLast4={me.phone_last4} />
        </section>

        <section className="portal-card" aria-labelledby="consent-heading">
          <h2 id="consent-heading">Terms and consent</h2>
          <p>
            You agreed to version {me.terms_version} of the terms.{" "}
            <Link href="/portal/terms">Read the terms again</Link>
          </p>
          <WithdrawForm />
        </section>
      </main>
    </>
  );
}

export function TermsView({ terms }: { terms: Terms | null }) {
  return (
    <main id="main" className="portal-wrap portal-main">
      <h1>Terms of use and privacy notice</h1>
      {terms ? (
        <>
          <p className="portal-meta">Version {terms.version}</p>
          <TermsBody terms={terms} />
        </>
      ) : (
        <p className="portal-notice">The terms are not available just now. Please call Zion at {telLink}.</p>
      )}
      <p style={{ marginTop: "1.5rem" }}>
        <Link href="/portal/sign-in">Go to sign in</Link>
      </p>
    </main>
  );
}
