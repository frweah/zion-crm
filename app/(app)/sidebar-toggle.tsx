"use client";

import { useState, useTransition } from "react";
import { setSidebarNarrow } from "./sidebar-actions";
import { NavIcon } from "./nav-icons";

/**
 * Down to icons, or back. The page changes at once; the choice is saved for
 * next time in the background. Below 1100px the sidebar is always icons, and
 * this is not shown.
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
      className="navb side-toggle"
      onClick={toggle}
      aria-pressed={narrow}
      title={narrow ? "Show the sidebar in full" : "Keep the sidebar to icons"}
    >
      <NavIcon name={narrow ? "side-wide" : "side-narrow"} />
      <span className="side-label">Icons only</span>
    </button>
  );
}
