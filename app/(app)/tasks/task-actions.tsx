"use client";

import { useActionState, useState } from "react";
import { removeTask, restoreTask, setTaskStatus, type TaskState } from "./actions";

/**
 * One control, everywhere a task is listed (owner, 6 Nov 2026).
 *
 * The pair below was on Today and on Tasks. The client's record had its own:
 * a button drawn as a circle that filled in when you pressed it, which said
 * nothing to anybody not using a screen reader - the exact thing
 * check-task-actions forbids on Today, enforced on one screen and not on the
 * four others. My day and the lists behind the Home counters had neither
 * action at all, so a task finished while reading the day had to be found
 * again somewhere else.
 *
 * So: this file is the only place a task's two actions are drawn, and
 * tasks/actions.ts is the only place a task's status is written. A second
 * control is how one of them ends up doing something slightly different from
 * the other.
 */

const initial: TaskState = { error: null, ok: null };

/**
 * The two actions every task carries (owner, 5 Nov 2026).
 *
 * Mark complete is what Done has always meant. Remove takes it off the list
 * for everybody and records who did it, which is the thing "Hide until
 * tomorrow" could never do - that one is per-person and comes back in the
 * morning, and it stays where it belongs, on alerts.
 *
 * One component, used on Today and on Tasks. Two copies of a pair of buttons
 * is how one of them ends up doing something slightly different from the
 * other, and this pair writes to the practice's record.
 *
 * Removing asks why in the same breath rather than in a dialog of its own: a
 * dialog over a list costs a press to open and a press to dismiss, and the
 * reason is optional, so most of the time there is nothing to say.
 */
export function TaskActions({ taskId, compact = false }: { taskId: string; compact?: boolean }) {
  const [doneState, markDone, marking] = useActionState(setTaskStatus, initial);
  const [removeState, remove, removing] = useActionState(removeTask, initial);
  const [asking, setAsking] = useState(false);

  const small = compact ? { padding: "1px 9px", lineHeight: 1.4 } : undefined;

  if (asking) {
    return (
      <form action={remove} className="task-remove">
        <input type="hidden" name="task_id" value={taskId} />
        <label className="field" htmlFor={`why-${taskId}`}>
          Why
          <input id={`why-${taskId}`} name="reason" type="text" maxLength={200} autoFocus />
        </label>
        <button className="btn" type="submit" disabled={removing} style={small}>
          Remove
        </button>
        <button className="btn ghost" type="button" onClick={() => setAsking(false)} style={small}>
          Keep it
        </button>
        {removeState.error && <span className="task-remove-error">{removeState.error}</span>}
      </form>
    );
  }

  return (
    <span className="task-actions">
      <form action={markDone} style={{ display: "inline" }}>
        <input type="hidden" name="task_id" value={taskId} />
        <input type="hidden" name="open" value="true" />
        <button className="btn ghost" type="submit" disabled={marking} style={small}>
          Mark complete
        </button>
      </form>
      <button className="btn ghost" type="button" onClick={() => setAsking(true)} style={small}>
        Remove
      </button>
      {doneState.error && <span className="task-remove-error">{doneState.error}</span>}
    </span>
  );
}

/**
 * A task that is finished, opened again.
 *
 * Shown where finished tasks are shown, which is the client's record and
 * Tasks with the done ones turned on. Separate from "Put it back" below
 * because they are different facts: one was done, the other should never have
 * been on the list, and a single button for both would make the record say
 * whichever of them was easier to draw.
 */
export function TaskReopen({ taskId }: { taskId: string }) {
  const [state, reopen, pending] = useActionState(setTaskStatus, initial);
  return (
    <form action={reopen} style={{ display: "inline" }}>
      <input type="hidden" name="task_id" value={taskId} />
      {/* "open" is what it is now, not what it will be: false means it is
          finished, so this reopens it. */}
      <input type="hidden" name="open" value="false" />
      <button className="btn ghost" type="submit" disabled={pending} style={{ padding: "1px 9px", lineHeight: 1.4 }}>
        Reopen
      </button>
      {state.error && <span className="task-remove-error">{state.error}</span>}
    </form>
  );
}

/**
 * And back on, for a removal that was a mistake.
 *
 * Shown only where removed tasks are shown, which is Tasks with the finished
 * ones turned on. Nothing on Today offers it: Today is what is in front of
 * somebody now, and a task taken off the list is not.
 */
export function TaskRestore({ taskId }: { taskId: string }) {
  const [state, restore, pending] = useActionState(restoreTask, initial);
  return (
    <form action={restore} style={{ display: "inline" }}>
      <input type="hidden" name="task_id" value={taskId} />
      <button className="btn ghost" type="submit" disabled={pending} style={{ padding: "1px 9px", lineHeight: 1.4 }}>
        Put it back
      </button>
      {state.error && <span className="task-remove-error">{state.error}</span>}
    </form>
  );
}
