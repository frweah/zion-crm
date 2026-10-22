"use client";

import Link from "next/link";
import { useActionState, useEffect, useRef, useState } from "react";
import {
  requestCode,
  verifyCode,
  giveConsent,
  setTexts,
  withdrawConsent,
  sendPortalMessage,
  markPortalRead,
  setNoticeChannel,
  type PortalFormState,
} from "../actions";

/**
 * The portal's forms. Each error is tied to its field (aria-describedby,
 * aria-invalid) and announced when it appears; nothing is signalled by colour
 * alone; and a mistake keeps what was typed.
 */

export function SignInForm({ initial }: { initial?: PortalFormState }) {
  const [state, action, pending] = useActionState(requestCode, initial ?? { error: null });
  const described = ["identifier-hint", state.error ? "identifier-error" : null].filter(Boolean).join(" ");

  return (
    <form action={action} noValidate>
      <div className="portal-field">
        <label htmlFor="identifier">Mobile number or email address</label>
        <p id="identifier-hint" className="portal-hint">
          We will send you a 6-digit code. There is no password to remember.
        </p>
        <input
          key={state.value ?? ""}
          id="identifier"
          name="identifier"
          type="text"
          autoComplete="username"
          autoCapitalize="none"
          spellCheck={false}
          defaultValue={state.value ?? ""}
          aria-describedby={described}
          aria-invalid={state.error ? true : undefined}
        />
        {state.error && (
          <p id="identifier-error" className="portal-error" role="alert">
            {state.error}
          </p>
        )}
      </div>
      <button className="btn" type="submit" disabled={pending}>
        {pending ? "Sending your code…" : "Send my code"}
      </button>
    </form>
  );
}

export function VerifyForm({ via, initial }: { via: "text" | "email"; initial?: PortalFormState }) {
  const [state, action, pending] = useActionState(verifyCode, initial ?? { error: null });
  const described = ["code-hint", state.error ? "code-error" : null].filter(Boolean).join(" ");

  return (
    <form action={action} noValidate>
      <div className="portal-field">
        <label htmlFor="code">6-digit code</label>
        <p id="code-hint" className="portal-hint">
          If that {via === "email" ? "email address" : "number"} is set up for the portal, we just sent a
          code by {via}. It works for 10 minutes.
        </p>
        <input
          id="code"
          name="code"
          type="text"
          className="portal-code"
          inputMode="numeric"
          autoComplete="one-time-code"
          maxLength={7}
          aria-describedby={described}
          aria-invalid={state.error ? true : undefined}
        />
        {state.error && (
          <p id="code-error" className="portal-error" role="alert">
            {state.error}
          </p>
        )}
      </div>
      <div className="portal-actions">
        {state.restart ? (
          <Link className="btn" href="/portal/sign-in">
            Ask for a new code
          </Link>
        ) : (
          <button className="btn" type="submit" disabled={pending}>
            {pending ? "Checking…" : "Sign in"}
          </button>
        )}
      </div>
    </form>
  );
}

export function ConsentForm({
  phoneLast4,
  textsAlready,
  initial,
}: {
  phoneLast4: string | null;
  textsAlready: boolean;
  initial?: PortalFormState;
}) {
  const [state, action, pending] = useActionState(giveConsent, initial ?? { error: null });

  return (
    <form action={action}>
      {textsAlready ? (
        <p>
          You already get text messages from Zion at the number ending in {phoneLast4}. You can stop
          them in Settings at any time.
        </p>
      ) : phoneLast4 ? (
        <div className="portal-check">
          <input type="checkbox" id="texts" name="texts" value="yes" aria-describedby="texts-hint" />
          <div>
            <label htmlFor="texts">Also send me text messages at the number ending in {phoneLast4}.</label>
            <p id="texts-hint" className="portal-hint">
              Optional. You can stop them any time in Settings, or by replying STOP.
            </p>
          </div>
        </div>
      ) : (
        <p className="portal-hint">
          There is no phone number on your record, so Zion cannot text you. Call 385-406-3432 to add one.
        </p>
      )}

      {state.error && (
        <p className="portal-error" role="alert">
          {state.error}
        </p>
      )}

      <div className="portal-actions">
        <button className="btn" type="submit" disabled={pending}>
          {pending ? "Saving…" : "I agree"}
        </button>
      </div>
    </form>
  );
}

export function TextsForm({
  on,
  phoneLast4,
  initial,
}: {
  on: boolean;
  phoneLast4: string | null;
  initial?: PortalFormState;
}) {
  const [state, action, pending] = useActionState(setTexts, initial ?? { error: null });

  return (
    <form action={action}>
      <p>
        {on
          ? `Zion sends you text messages at the number ending in ${phoneLast4 ?? "on your record"}: appointment reminders and short updates.`
          : "Zion does not send you text messages."}
      </p>
      <input type="hidden" name="texts" value={on ? "off" : "on"} />
      {state.error && (
        <p className="portal-error" role="alert">
          {state.error}
        </p>
      )}
      {on || phoneLast4 ? (
        <button className={on ? "btn ghost" : "btn"} type="submit" disabled={pending}>
          {pending ? "Saving…" : on ? "Stop text messages" : `Start text messages to the number ending in ${phoneLast4}`}
        </button>
      ) : (
        <p className="portal-hint">There is no phone number on your record. Call 385-406-3432 to add one.</p>
      )}
    </form>
  );
}

export function WithdrawForm() {
  const [asking, setAsking] = useState(false);
  const [state, setState] = useState<PortalFormState>({ error: null });
  const [pending, setPending] = useState(false);
  const question = useRef<HTMLParagraphElement>(null);
  const opener = useRef<HTMLButtonElement>(null);

  useEffect(() => {
    if (asking) question.current?.focus();
  }, [asking]);

  if (!asking) {
    return (
      <button ref={opener} className="btn ghost" type="button" onClick={() => setAsking(true)}>
        Withdraw my consent
      </button>
    );
  }

  return (
    <div>
      <p ref={question} tabIndex={-1}>
        <strong>Withdraw your consent?</strong> The portal closes for you straight away. Zion keeps
        working with you by phone and in person, and you can agree again any time by signing in.
      </p>
      {state.error && (
        <p className="portal-error" role="alert">
          {state.error}
        </p>
      )}
      <div className="portal-actions">
        <button
          className="btn danger"
          type="button"
          disabled={pending}
          onClick={async () => {
            setPending(true);
            setState(await withdrawConsent());
            setPending(false);
          }}
        >
          {pending ? "Saving…" : "Yes, withdraw my consent"}
        </button>
        <button
          className="btn ghost"
          type="button"
          onClick={() => {
            setAsking(false);
            setTimeout(() => opener.current?.focus(), 0);
          }}
        >
          Keep my consent
        </button>
      </div>
    </div>
  );
}

/** Writing to Zion. What was typed survives an error; a success clears it. */
export function MessageForm({ staff }: { staff: string }) {
  const [state, action, pending] = useActionState(sendPortalMessage, { error: null });
  const form = useRef<HTMLFormElement>(null);
  useEffect(() => {
    if (state.ok) form.current?.reset();
  }, [state]);
  const described = ["body-hint", state.error ? "body-error" : null].filter(Boolean).join(" ");

  return (
    <form ref={form} action={action} noValidate>
      <div className="portal-field">
        <label htmlFor="body">Write to {staff}</label>
        <p id="body-hint" className="portal-hint">
          For anything urgent, call 385-406-3432. Messages are read during office hours.
        </p>
        <textarea
          key={state.ok ? "sent" : (state.value ?? "")}
          id="body"
          name="body"
          rows={5}
          maxLength={2000}
          defaultValue={state.error ? (state.value ?? "") : ""}
          aria-describedby={described}
          aria-invalid={state.error ? true : undefined}
        />
        {state.error && (
          <p id="body-error" className="portal-error" role="alert">
            {state.error}
          </p>
        )}
      </div>
      {state.ok && (
        <p className="portal-notice" role="status">
          {state.ok}
        </p>
      )}
      <div className="portal-actions">
        <button className="btn" type="submit" disabled={pending}>
          {pending ? "Sending…" : "Send message"}
        </button>
      </div>
    </form>
  );
}

/** Marks the thread read once it has been drawn. Draws nothing. */
export function MarkRead({ seq }: { seq: number }) {
  useEffect(() => {
    if (seq > 0) void markPortalRead(seq);
  }, [seq]);
  return null;
}

export function NoticeChannelForm({
  channel,
  canText,
  hasEmail,
}: {
  channel: "Text" | "Email" | null;
  canText: boolean;
  hasEmail: boolean;
}) {
  const [state, action, pending] = useActionState(setNoticeChannel, { error: null });
  const current = channel ?? (hasEmail ? "Email" : canText ? "Text" : null);

  if (!canText && !hasEmail) {
    return (
      <p className="portal-hint">
        We have no email address or text-enabled number for you yet. Call 385-406-3432 to add one.
      </p>
    );
  }

  return (
    <form action={action}>
      <fieldset className="portal-field">
        <legend>When Zion writes to you, tell me by</legend>
        <label className="portal-choice">
          <input type="radio" name="channel" value="Email" defaultChecked={current === "Email"} disabled={!hasEmail} />{" "}
          Email{!hasEmail && " (no email address on your account)"}
        </label>
        <label className="portal-choice">
          <input type="radio" name="channel" value="Text" defaultChecked={current === "Text"} disabled={!canText} />{" "}
          Text message{!canText && " (turn on text messages first)"}
        </label>
        <p className="portal-hint">The message never says what it is about, only that something is waiting.</p>
      </fieldset>
      {state.error && (
        <p className="portal-error" role="alert">
          {state.error}
        </p>
      )}
      {state.ok && (
        <p className="portal-notice" role="status">
          {state.ok}
        </p>
      )}
      <div className="portal-actions">
        <button className="btn" type="submit" disabled={pending}>
          {pending ? "Saving…" : "Save my choice"}
        </button>
      </div>
    </form>
  );
}
