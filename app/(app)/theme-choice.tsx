"use client";

import { useState, useTransition } from "react";
import { setTheme, type Theme } from "./theme-actions";

const CHOICES: { value: Theme; label: string; hint: string }[] = [
  { value: "light", label: "Light", hint: "White page, green sidebar" },
  { value: "dark", label: "Dark", hint: "The green as the page" },
  { value: "system", label: "System", hint: "Follows this machine" },
];

/**
 * Light, dark, or whatever this machine says (owner, 14 Oct 2026).
 *
 * The screen changes on the click rather than on the answer. Stamping
 * data-theme on <html> is the whole of applying a theme - every colour in the
 * app is a token and the tokens are defined against that attribute - so the
 * page is already repainted before the server has been told. The write that
 * follows is what makes it stick, on this machine and the next one.
 *
 * Nothing is undone if that write fails. The person asked for dark and has
 * dark; what they lose is it being remembered, and telling them their theme
 * did not save while they are looking at it in the theme they chose would be
 * a worse screen than the one they asked for.
 */
export function ThemeChoice({ current }: { current: Theme }) {
  const [chosen, setChosen] = useState<Theme>(current);
  const [, start] = useTransition();

  function pick(theme: Theme) {
    setChosen(theme);
    // System is the absence of a stamp: the stylesheet falls back to
    // prefers-color-scheme, which is what the machine says.
    if (theme === "system") delete document.documentElement.dataset.theme;
    else document.documentElement.dataset.theme = theme;
    start(() => {
      void setTheme(theme);
    });
  }

  return (
    <div className="theme-choice" role="group" aria-label="Theme">
      <div className="lock theme-choice-label">Theme</div>
      <div className="theme-choice-row">
        {CHOICES.map((c) => (
          <button
            key={c.value}
            type="button"
            className={c.value === chosen ? "btn theme-on" : "btn ghost"}
            aria-pressed={c.value === chosen}
            title={c.hint}
            onClick={() => pick(c.value)}
          >
            {c.label}
          </button>
        ))}
      </div>
    </div>
  );
}
