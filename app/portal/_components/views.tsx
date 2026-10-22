import Link from "next/link";
import type { PortalMe } from "@/lib/portal/session";
import type { PortalFormState } from "../actions";
import {
  SignInForm,
  VerifyForm,
  ConsentForm,
  TextsForm,
  WithdrawForm,
  MessageForm,
  MarkRead,
  NoticeChannelForm,
  UploadForm,
} from "./forms";
import { IdleWarning } from "./idle-warning";
import { ResumeBuilder } from "./resume-builder";
import type { ResumeData } from "@/lib/portal/resume";

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
  current: "home" | "messages" | "documents" | "resume" | "settings" | "consent";
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
                  <Link href="/portal/messages" aria-current={current === "messages" ? "page" : undefined}>
                    Messages
                  </Link>
                </li>
                <li>
                  <Link href="/portal/documents" aria-current={current === "documents" ? "page" : undefined}>
                    Documents
                  </Link>
                </li>
                <li>
                  <Link href="/portal/resume" aria-current={current === "resume" ? "page" : undefined}>
                    Resume
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
      <h1>Client portal sign-in</h1>
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
        <h1>Portal terms and consent</h1>
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
                I do not agree, sign me out
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

export function HomeView({
  me,
  unread = 0,
  openRequests = 0,
  idlePreview = false,
}: {
  me: PortalMe;
  unread?: number;
  openRequests?: number;
  idlePreview?: boolean;
}) {
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

        <section className="portal-card" aria-labelledby="messages-heading">
          <h2 id="messages-heading">Messages</h2>
          <p>
            {unread > 0
              ? `You have ${unread} new ${unread === 1 ? "message" : "messages"} from Zion.`
              : "No new messages."}{" "}
            <Link href="/portal/messages">{unread > 0 ? "Read your messages" : "Write to Zion"}</Link>
          </p>
        </section>

        <section className="portal-card" aria-labelledby="documents-heading">
          <h2 id="documents-heading">Documents</h2>
          <p>
            {openRequests > 0
              ? `Zion has asked you for ${openRequests} ${openRequests === 1 ? "document" : "documents"}.`
              : "Zion is not waiting on any documents from you."}{" "}
            {openRequests > 0 && <Link href="/portal/documents">Upload them</Link>}
          </p>
        </section>

        <section className="portal-card" aria-labelledby="resume-heading">
          <h2 id="resume-heading">Resume</h2>
          <p>
            No resume yet? Build one here, a step at a time.{" "}
            <Link href="/portal/resume">Build or update your resume</Link>
          </p>
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

export type NoticeOptions = { channel: "Text" | "Email" | null; can_text: boolean; has_email: boolean };

export function SettingsView({
  me,
  notice,
  options,
}: {
  me: PortalMe;
  notice?: string;
  options?: NoticeOptions | null;
}) {
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

        <section className="portal-card" aria-labelledby="notices-heading">
          <h2 id="notices-heading">New message alerts</h2>
          <NoticeChannelForm
            channel={options?.channel ?? null}
            canText={options?.can_text ?? false}
            hasEmail={options?.has_email ?? false}
          />
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
      <h1>Portal terms and privacy</h1>
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

export type PortalMessage = { seq: number; mine: boolean; sender: string; body: string; created_at: string };

function when(at: string): string {
  return new Date(at).toLocaleString("en-US", {
    timeZone: "America/Denver",
    weekday: "short",
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
  });
}

export function MessagesView({ me, messages }: { me: PortalMe; messages: PortalMessage[] }) {
  const staff = me.staff_first_name ?? "Zion";
  const last = messages.length > 0 ? Number(messages[messages.length - 1].seq) : 0;
  return (
    <>
      <SignedInBar me={me} current="messages" />
      <main id="main" className="portal-wrap portal-main">
        <h1>Messages</h1>
        {messages.length === 0 ? (
          <p>No messages yet. You can write to {staff} below.</p>
        ) : (
          <ol className="portal-thread" aria-label="Your messages with Zion, oldest first">
            {messages.map((m) => (
              <li key={m.seq} className={m.mine ? "mine" : undefined}>
                <p className="portal-from">
                  {m.sender}, <time dateTime={m.created_at}>{when(m.created_at)}</time>
                </p>
                <p className="portal-said">{m.body}</p>
              </li>
            ))}
          </ol>
        )}
        <MarkRead seq={last} />
        <section className="portal-card" aria-labelledby="write-heading">
          <h2 id="write-heading">New message</h2>
          <MessageForm staff={staff} />
        </section>
      </main>
    </>
  );
}

export type PortalRequest = {
  id: string;
  name: string;
  note: string;
  due: string | null;
  status: string;
  return_reason: string;
  filename: string | null;
  answered_at: string | null;
  created_at: string;
};

function dueText(due: string): string {
  return new Date(`${due}T12:00:00`).toLocaleDateString("en-US", { weekday: "long", month: "long", day: "numeric" });
}

export function DocumentsView({ me, requests }: { me: PortalMe; requests: PortalRequest[] }) {
  const waiting = requests.filter((r) => r.status === "Open" || r.status === "Returned");
  const sent = requests.filter((r) => r.status === "Answered" || r.status === "Accepted");
  return (
    <>
      <SignedInBar me={me} current="documents" />
      <main id="main" className="portal-wrap portal-main">
        <h1>Documents</h1>
        {waiting.length === 0 && <p>Zion is not waiting on any documents from you.</p>}
        {waiting.map((r) => (
          <section key={r.id} className="portal-card" aria-labelledby={`req-${r.id}`}>
            <h2 id={`req-${r.id}`}>{r.name}</h2>
            {r.status === "Returned" && (
              <p className="portal-notice">
                <strong>Zion needs this again:</strong> {r.return_reason}
              </p>
            )}
            {r.note && <p>{r.note}</p>}
            {r.due && <p>Please send it by {dueText(r.due)}.</p>}
            <UploadForm requestId={r.id} name={r.name} />
          </section>
        ))}
        {sent.length > 0 && (
          <section className="portal-card" aria-labelledby="sent-heading">
            <h2 id="sent-heading">Sent to Zion</h2>
            <ul>
              {sent.map((r) => (
                <li key={r.id}>
                  {r.name}: {r.status === "Accepted" ? "received" : "waiting for Zion to look at it"}
                  {r.filename ? ` (${r.filename})` : ""}
                </li>
              ))}
            </ul>
          </section>
        )}
      </main>
    </>
  );
}

export function ResumeView({
  me,
  resume,
  step,
  status,
  returnNote,
}: {
  me: PortalMe;
  resume: ResumeData;
  step: number;
  status: "None" | "Draft" | "Returned" | "Submitted" | "Approved";
  returnNote: string;
}) {
  return (
    <>
      <SignedInBar me={me} current="resume" />
      <main id="main" className="portal-wrap portal-main">
        <h1>Resume</h1>
        <ResumeBuilder initial={resume} initialStep={status === "Draft" || status === "Returned" ? step : 0} status={status} returnNote={returnNote} />
      </main>
    </>
  );
}
