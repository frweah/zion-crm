/**
 * A stand-in for the signed-in shell, so the walk can be tried without a
 * password.
 *
 *   node scripts/idle-fixture.mjs        # then point idle-check at :4331
 *
 * Six groups, each opening its own screens beneath it and closing whichever
 * was open, as NavLinks does; a Team link that opens a shade over the page
 * instead of navigating, as the Team pane does; and an address that changes a
 * beat after the click, as a client navigation does.
 *
 * That last one is why this exists rather than a note saying the walk was
 * tested by hand. The walk measured the network going quiet and read the
 * address afterwards, so for a client navigation it saw the silence *before*
 * the press did anything, called the screen "already open", and timed the
 * next one from the wrong start. On production that lost eleven screens of
 * twenty-seven while looking like it was working. On this fixture it is six
 * screens against seventeen, which is a number a check can hold.
 *
 * check-idle-walk.mjs runs it.
 */
import { createServer } from "node:http";

const GROUPS = [
  { href: "/dashboard", label: "Today", screens: ["/dashboard", "/my-day"] },
  { href: "/clients", label: "Clients", screens: ["/clients", "/clients?tab=jobs"] },
  { href: "/my-work", label: "My work", screens: ["/tasks", "/hours", "/hours?tab=statements", "/time-clock"] },
  { href: "/communication", label: "Communication", screens: ["/mail", "/messages"] },
  { href: "/requests", label: "Requests", screens: ["/requests"] },
  { href: "/admin", label: "Admin", screens: ["/admin/hours", "/admin/people", "/admin/system"] },
];

// How long after the click the address changes. Longer than the walk's
// half-second of silence, which is the whole point of the fixture.
const LATE_MS = Number(process.env.FIXTURE_LATE_MS ?? 900);

const shell = (path) => {
  const open =
    GROUPS.find((g) => g.screens.some((s) => s.split("?")[0] === path)) ??
    GROUPS.find((g) => g.href.split("?")[0] === path) ??
    GROUPS[0];
  return `<!doctype html><html><head><meta charset="utf-8"><title>Zion</title></head><body>
<nav class="side" aria-label="Main">
${GROUPS.map(
  (g) => `  <div class="nav-group">
    <a class="navb" href="${g.href}">${g.label}</a>
${g === open ? `    <div class="nav-sub">${g.screens.map((s) => `<a class="nav-sub-link" href="${s}">${s}</a>`).join("")}</div>` : ""}
  </div>`,
).join("\n")}
  <a class="navb" href="/team" id="team">Team</a>
</nav>
<main><h1>${path}</h1></main>
<script>
  const LATE = ${LATE_MS};
  for (const a of document.querySelectorAll("nav.side a[href]")) {
    a.addEventListener("click", (e) => {
      e.preventDefault();
      if (a.id === "team") {
        const d = document.createElement("div");
        d.className = "pane-shade";
        d.style = "position:fixed;inset:0;z-index:70;background:rgba(0,0,0,.4)";
        document.body.appendChild(d);
        document.addEventListener("keydown", (k) => { if (k.key === "Escape") d.remove(); });
        return;
      }
      // The address changes late, which is the thing being reproduced: the
      // walk used to measure the silence before the navigation and call the
      // screen already open.
      setTimeout(() => location.assign(a.getAttribute("href")), LATE);
    });
  }
</script></body></html>`;
};

const LOGIN = `<!doctype html><html><head><meta charset="utf-8"><title>Sign in</title></head><body>
<form method="GET" action="/dashboard">
  <input type="email" name="e"><input type="password" name="p">
  <button type="submit">Sign in</button>
</form></body></html>`;

const server = createServer((req, res) => {
  const url = new URL(req.url, "http://x");
  if (url.pathname === "/login") {
    res.writeHead(200, { "content-type": "text/html" });
    return res.end(LOGIN);
  }
  if (url.pathname === "/api/version") {
    res.writeHead(200, { "content-type": "application/json" });
    return res.end(JSON.stringify({ commit: "fixture" }));
  }
  res.writeHead(200, { "content-type": "text/html" });
  res.end(shell(url.pathname));
});

const PORT = Number(process.env.FIXTURE_PORT ?? 4331);
server.listen(PORT, () => console.log(`fixture on http://127.0.0.1:${PORT}`));
