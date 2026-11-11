/*
 * The phone app's service worker (owner, 11 Nov 2026).
 *
 * It does three things and nothing else:
 *
 *   /phone, opened with no signal, is the copy saved the last time it opened
 *   with one. The page itself keeps the data (IndexedDB, lib/phone/store.ts),
 *   so the copy here is only the screen, never a client.
 *
 *   The application's own scripts and styles, which are named by their
 *   contents and never change, are kept so that copy can run.
 *
 *   The icons and the manifest.
 *
 * Everything else - every other screen, every API call, every sign-in - goes
 * to the network untouched, exactly as it would with no worker at all. A
 * worker that cached the desk screens would show somebody yesterday's
 * caseload as if it were today's.
 *
 * Signing out from the phone sends "forget", and the saved screen goes with
 * everything else.
 */
const CACHE = "zion-phone-v1";
const SHELL = "/phone";

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches
      .open(CACHE)
      .then((c) => c.addAll(["/manifest.webmanifest", "/icons/icon-192.png", "/icons/icon-512.png"]))
      .then(() => self.skipWaiting()),
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) => Promise.all(keys.filter((k) => k.startsWith("zion-phone-") && k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim()),
  );
});

self.addEventListener("message", (event) => {
  if (event.data === "forget") {
    event.waitUntil(caches.delete(CACHE));
  }
});

function isShell(url) {
  return url.pathname === SHELL || url.pathname === SHELL + "/";
}

self.addEventListener("fetch", (event) => {
  const req = event.request;
  if (req.method !== "GET") return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;

  // The phone screen: the network first, the saved copy when there is none.
  if (req.mode === "navigate" && isShell(url)) {
    event.respondWith(
      (async () => {
        try {
          const res = await fetch(req);
          // Only a real answer for /phone is kept. A redirect to sign-in, or
          // to a gate, is not the phone screen and must never be served as it.
          if (res.ok && !res.redirected && isShell(new URL(res.url))) {
            const cache = await caches.open(CACHE);
            await cache.put(SHELL, res.clone());
          }
          return res;
        } catch {
          const saved = await caches.match(SHELL);
          if (saved) return saved;
          return new Response(
            "<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'>" +
              "<title>Zion</title><body style='font:16px system-ui;padding:24px'>" +
              "<p>No signal, and this phone has not opened Zion today. Open it once with signal to use it offline.</p>",
            { status: 503, headers: { "Content-Type": "text/html; charset=utf-8" } },
          );
        }
      })(),
    );
    return;
  }

  // The build's own files: named by their contents, so a saved one is right.
  if (url.pathname.startsWith("/_next/static/") || url.pathname.startsWith("/icons/") || url.pathname === "/manifest.webmanifest") {
    event.respondWith(
      (async () => {
        const saved = await caches.match(req);
        if (saved) return saved;
        const res = await fetch(req);
        if (res.ok) {
          const cache = await caches.open(CACHE);
          await cache.put(req, res.clone());
        }
        return res;
      })(),
    );
  }
  // Anything else: not ours. No respondWith, so the browser does what it
  // would have done.
});
