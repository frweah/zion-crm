"use client";

import { useActionState, useState } from "react";
import { usePathname } from "next/navigation";
import { reportProblem, type ProblemState } from "./report-problem-actions";

const initial: ProblemState = { error: null, ok: null };

/**
 * "Something is wrong here", from any screen.
 *
 * In the avatar menu, which is the one thing on every screen that is about
 * the person rather than about the work. It records the screen they were on
 * when they pressed it, so nobody has to describe where they were — half of
 * what anybody reports is "this page".
 *
 * It opens in place rather than on a screen of its own: a person who has just
 * hit something wrong should not have to leave the thing that is wrong to say
 * so, and come back to find out what they had typed.
 */
export function ReportProblem({ onDone }: { onDone: () => void }) {
  const [state, action, pending] = useActionState(reportProblem, initial);
  const [open, setOpen] = useState(false);
  const pathname = usePathname();

  if (state.ok) {
    return (
      <div className="avatar-note">
        <p className="lock">{state.ok}</p>
        <button
          type="button"
          role="menuitem"
          onClick={() => {
            setOpen(false);
            onDone();
          }}
        >
          Close
        </button>
      </div>
    );
  }

  if (!open) {
    return (
      <button type="button" role="menuitem" onClick={() => setOpen(true)}>
        Report a problem
      </button>
    );
  }

  return (
    <form action={action} className="avatar-note">
      <input type="hidden" name="screen" value={pathname} />
      <label className="field" htmlFor="problem-what">
        What is wrong
        <textarea
          id="problem-what"
          name="what"
          rows={3}
          required
          placeholder="What you expected, and what happened"
        />
      </label>
      <p className="lock">This goes to the administrator with the screen you are on.</p>
      {state.error && <p className="lock">{state.error}</p>}
      <div className="row2" style={{ gap: 6 }}>
        <button className="btn gold" type="submit" disabled={pending}>
          {pending ? "Sending…" : "Send it"}
        </button>
        <button className="btn ghost" type="button" onClick={() => setOpen(false)}>
          Not now
        </button>
      </div>
    </form>
  );
}
