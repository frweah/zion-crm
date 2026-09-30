"use client";

import { useState, useTransition } from "react";
import { setSidebarNarrow } from "./sidebar-actions";
import { NavIcon } from "./nav-icons";

/**
 * Down to icons, or back.
 *
 * It was a row in the navigation called "Icons only", which read as a place
 * to go rather than a control - and it sat among the screens, which is where
 * the eye looks for work, not for settings (owner, 30 Sept 2026). It is a
 * chevron at the foot of the sidebar now: it points the way the sidebar will
 * move, and it says nothing it does not need to.
 *
 * The page changes at once; the choice is saved for next time in the
 * background. Below 1100px the sidebar is always icons, and this is hidden.
 */
export function SidebarToggle({ initial }: { initial: boolean }) {
  const [narrow, setNarrow] = useState(initial);
  const [, startTransition] = useTransition();

  function toggle(e: React.MouseEvent<HTMLButtonElement>) {
    const next = !narrow;
    setNarrow(next);
    e.currentTarget.closest(".shell")?.classList.toggle("side-narrow", next);
    startTransition(() => setSidebarNarrow(next));
  }

  return (
    <button
      type="button"
      className="side-chevron"
      onClick={toggle}
      aria-pressed={narrow}
      aria-label={narrow ? "Show the sidebar in full" : "Narrow the sidebar to icons"}
      title={narrow ? "Show the sidebar in full" : "Narrow the sidebar to icons"}
    >
      <NavIcon name={narrow ? "side-wide" : "side-narrow"} />
    </button>
  );
}
