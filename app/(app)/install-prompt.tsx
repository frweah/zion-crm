"use client";

import { useEffect, useState } from "react";
import { dismissHint } from "./hint-actions";

type InstallEvent = Event & { prompt: () => Promise<void>; userChoice: Promise<{ outcome: string }> };

/**
 * "Add to home screen", once per person (owner, 11 Nov 2026).
 *
 * Shown on a phone, to somebody who has not answered it, in a browser that
 * can install the app. Either answer is final: it is stored against the
 * person (staff_prefs, as every hint is), so Rei putting it away on her phone
 * does not ask her again on her tablet, and it does not ask Margaret's
 * question for her.
 *
 * Android's browsers offer the install themselves, which is what "Add" opens.
 * An iPhone has no such offer; it is done from the Share menu, so on an
 * iPhone the line says where instead of offering a button that cannot work.
 *
 * Also the one place the service worker is registered, because the worker is
 * what makes the app installable and what lets the phone screen open with no
 * signal. It is registered on every page so the phone screen is ready before
 * the first time it is needed offline.
 */
export function InstallPrompt({ answered }: { answered: boolean }) {
  const [offer, setOffer] = useState<InstallEvent | null>(null);
  const [iphone, setIphone] = useState(false);
  const [gone, setGone] = useState(answered);

  useEffect(() => {
    if ("serviceWorker" in navigator) {
      navigator.serviceWorker.register("/sw.js").catch(() => {
        // No worker means no offline phone screen; everything else works as
        // it did. Nothing for the person to do about it.
      });
    }
    if (answered) return;

    const installed =
      window.matchMedia("(display-mode: standalone)").matches ||
      (navigator as Navigator & { standalone?: boolean }).standalone === true;
    if (installed) return;

    const small = window.matchMedia("(max-width: 760px)").matches;
    const ios = /iphone|ipad|ipod/i.test(navigator.userAgent);
    if (ios && small) setIphone(true);

    const take = (e: Event) => {
      e.preventDefault();
      if (window.matchMedia("(max-width: 760px)").matches) setOffer(e as InstallEvent);
    };
    window.addEventListener("beforeinstallprompt", take);
    return () => window.removeEventListener("beforeinstallprompt", take);
  }, [answered]);

  if (gone || (!offer && !iphone)) return null;

  const answer = async () => {
    setGone(true);
    const fd = new FormData();
    fd.set("key", "install-app");
    await dismissHint({ error: null, ok: null }, fd).catch(() => undefined);
  };

  return (
    <div className="install-bar no-print" role="region" aria-label="Add to home screen">
      <span>
        {iphone ? "Put Zion on your home screen: Share, then Add to Home Screen" : "Put Zion on your home screen"}
      </span>
      {offer && (
        <button
          type="button"
          className="btn"
          onClick={async () => {
            await offer.prompt().catch(() => undefined);
            await answer();
          }}
        >
          Add
        </button>
      )}
      <button type="button" className="btn ghost" onClick={answer}>
        {iphone ? "Done" : "Not now"}
      </button>
    </div>
  );
}
