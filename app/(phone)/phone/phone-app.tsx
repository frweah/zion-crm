"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  allItems,
  clientsSeenToday,
  dropItem,
  forgetAll,
  practiceDay,
  putItem,
  recall,
  remember,
  tidy,
  type OutboxItem,
  type OutboxKind,
} from "@/lib/phone/store";
import { retry, syncNow, unstick } from "@/lib/phone/sync";
import { readyDocument } from "../../(app)/paperwork/ready-for-upload";
import { InstallPrompt } from "../../(app)/install-prompt";

/**
 * The phone app (owner, 11 Nov 2026).
 *
 * "Phone home is a short list - Today: next appointment, clients to see, To
 * file count, reports due - and one button: Add (note / photo / recording /
 * hours). Client card on phone: name, phone (tap to call or text), stage,
 * counselor, last three notes, Add. Everything else under More."
 *
 * One page, several views, moved between with the address's #, so the back
 * button works and the whole thing opens from the one copy the service worker
 * keeps. Every view reads from the network when there is one and from what
 * the phone kept when there is not, and says which.
 *
 * Anything pressed is saved on the phone first and sent second. The list of
 * what is waiting is one tap from every view, and a refusal stays on it, in
 * red, with the sentence the practice gave, until somebody deals with it.
 */

type Me = { id: string; name: string; role: string };

type Home = {
  day: string;
  asOf: string;
  next: { title: string; at: string; where: string; client_id: string | null; client_name: string | null } | null;
  see: { id: string; name: string; why: string; at: string | null }[];
  toFile: {
    id: string; source: string; title: string; detail: string; happened_at: string | null;
    client_id: string | null; client_name: string | null; guess_why: string;
  }[];
  toFileCount: number;
  reports: { id: string; client_id: string; name: string; what: string; due: string; late: boolean }[];
  clock: { startedAt: string | null; breakSince: string | null; breakSeconds: number; todayHours: number };
};

type Card = {
  id: string; name: string; phone: string; stage: string; status: string;
  counselor: string; counselorPhone: string;
  notes: { id: string; text: string; type: string; by: string; at: string }[];
  noteCategory: string; noteCategories: string[];
  fileCategories: { key: string; label: string; restricted_by_default: boolean }[];
  canRestrict: boolean;
};

type Thread = { id: string; title: string; at: string | null; unread: number };
type Line = { id: string; who: string; body: string; at: string };

type View =
  | { v: "home" }
  | { v: "clients" }
  | { v: "client"; id: string }
  | { v: "add"; client?: string }
  | { v: "note" | "photo" | "recording"; client?: string }
  | { v: "hours" }
  | { v: "tofile" }
  | { v: "reports" }
  | { v: "team" }
  | { v: "thread"; id: string }
  | { v: "outbox" }
  | { v: "more" };

function parse(hash: string): View {
  const [a, b] = hash.replace(/^#\/?/, "").split("/");
  switch (a) {
    case "clients": return { v: "clients" };
    case "client": return b ? { v: "client", id: b } : { v: "clients" };
    case "add": return { v: "add", client: b || undefined };
    case "note": case "photo": case "recording": return { v: a, client: b || undefined };
    case "hours": return { v: "hours" };
    case "tofile": return { v: "tofile" };
    case "reports": return { v: "reports" };
    case "team": return { v: "team" };
    case "thread": return b ? { v: "thread", id: b } : { v: "team" };
    case "outbox": return { v: "outbox" };
    case "more": return { v: "more" };
    default: return { v: "home" };
  }
}

const go = (hash: string) => {
  window.location.hash = hash;
};

const time = (iso: string | null | undefined) =>
  iso ? new Date(iso).toLocaleTimeString("en-US", { timeZone: "America/Denver", hour: "numeric", minute: "2-digit" }) : "";
const when = (iso: string | null | undefined) =>
  iso
    ? new Date(iso).toLocaleString("en-US", { timeZone: "America/Denver", month: "short", day: "numeric", hour: "numeric", minute: "2-digit" })
    : "";

const newKey = () =>
  typeof crypto !== "undefined" && "randomUUID" in crypto
    ? crypto.randomUUID()
    : "10000000-1000-4000-8000-100000000000".replace(/[018]/g, (c) =>
        (Number(c) ^ (crypto.getRandomValues(new Uint8Array(1))[0] & (15 >> (Number(c) / 4)))).toString(16),
      );

async function sha256(blob: Blob): Promise<string> {
  try {
    const digest = await crypto.subtle.digest("SHA-256", await blob.arrayBuffer());
    return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
  } catch {
    return "";
  }
}

/**
 * Ask the practice, and keep the answer; or say what the phone kept.
 *
 * `stale` is the time of the kept answer when that is what is shown, so the
 * screen can say "as of 8:14" rather than pass off an old answer as a new one.
 */
type Read<T> = { data: T | null; stale: string | null; error: string | null; signedOut: boolean; loading: boolean };

function useRead<T>(me: string, url: string | null, cacheKey: string | null, bump: number): Read<T> {
  const [state, setState] = useState<Read<T>>({ data: null, stale: null, error: null, signedOut: false, loading: true });
  useEffect(() => {
    if (!url || !cacheKey) return;
    let live = true;
    (async () => {
      const kept = await recall<T>(cacheKey, me).catch(() => null);
      if (live && kept) setState({ data: kept.value, stale: kept.savedAt, error: null, signedOut: false, loading: true });
      try {
        const res = await fetch(url, { cache: "no-store", credentials: "same-origin" });
        const json = (res.headers.get("content-type") ?? "").includes("application/json") ? await res.json() : null;
        if (!live) return;
        if (!json || res.status === 401 || (res.redirected && res.url.includes("/login"))) {
          setState((s) => ({ ...s, signedOut: true, loading: false }));
          return;
        }
        if (res.status === 403 && json.gate) {
          window.location.href = json.gate;
          return;
        }
        if (!res.ok) {
          setState((s) => ({ ...s, error: json.error ?? "The practice did not answer.", loading: false }));
          return;
        }
        await remember(cacheKey, me, json).catch(() => undefined);
        setState({ data: json as T, stale: null, error: null, signedOut: false, loading: false });
      } catch {
        if (live) setState((s) => ({ ...s, loading: false, error: s.data ? null : "No signal, and nothing kept from today." }));
      }
    })();
    return () => {
      live = false;
    };
  }, [me, url, cacheKey, bump]);
  return state;
}

export function PhoneApp({ me, canNote, installAnswered }: { me: Me; canNote: boolean; installAnswered: boolean }) {
  const [view, setView] = useState<View>({ v: "home" });
  const [online, setOnline] = useState(true);
  const [items, setItems] = useState<OutboxItem[]>([]);
  const [bump, setBump] = useState(0);
  const [stopped, setStopped] = useState<null | "offline" | "signed out" | "gate">(null);
  const [said, setSaid] = useState<string | null>(null);

  const refreshItems = useCallback(async () => {
    setItems(await allItems().catch(() => []));
  }, []);

  const sync = useCallback(async () => {
    const result = await syncNow(me.id, () => void refreshItems()).catch(() => null);
    await refreshItems();
    if (result) {
      setStopped(result.stopped);
      if (result.sent > 0) setBump((b) => b + 1);
    }
  }, [me.id, refreshItems]);

  // Start: tidy what the phone kept, send what is waiting, follow the address.
  useEffect(() => {
    setView(parse(window.location.hash));
    setOnline(navigator.onLine);
    const onHash = () => {
      setView(parse(window.location.hash));
      window.scrollTo(0, 0);
    };
    const onOnline = () => {
      setOnline(true);
      void sync();
    };
    const onOffline = () => setOnline(false);
    const onVisible = () => {
      if (document.visibilityState === "visible") void sync();
    };
    window.addEventListener("hashchange", onHash);
    window.addEventListener("online", onOnline);
    window.addEventListener("offline", onOffline);
    document.addEventListener("visibilitychange", onVisible);
    (async () => {
      await tidy(me.id).catch(() => undefined);
      await unstick().catch(() => undefined);
      await sync();
    })();
    return () => {
      window.removeEventListener("hashchange", onHash);
      window.removeEventListener("online", onOnline);
      window.removeEventListener("offline", onOffline);
      document.removeEventListener("visibilitychange", onVisible);
    };
  }, [me.id, sync]);

  // While anything is waiting, try again every half minute.
  const waiting = items.filter((i) => i.owner === me.id && i.status !== "refused").length;
  const refused = items.filter((i) => i.owner === me.id && i.status === "refused").length;
  useEffect(() => {
    if (waiting === 0) return;
    const t = setInterval(() => void sync(), 30_000);
    return () => clearInterval(t);
  }, [waiting, sync]);

  /** Save first, send second. The person sees it saved whether or not it sent. */
  const save = useCallback(
    async (kind: OutboxKind, label: string, payload: Record<string, unknown>, blob?: Blob, blobName?: string) => {
      const item: OutboxItem = {
        key: newKey(),
        kind,
        at: new Date().toISOString(),
        owner: me.id,
        label,
        payload,
        blob,
        blobName,
        status: "waiting",
        tries: 0,
      };
      await putItem(item);
      await refreshItems();
      setSaid(navigator.onLine ? "Saved. Sending now." : "Saved on this phone. It sends when there is signal.");
      void sync();
      return item;
    },
    [me.id, refreshItems, sync],
  );

  useEffect(() => {
    if (!said) return;
    const t = setTimeout(() => setSaid(null), 4000);
    return () => clearTimeout(t);
  }, [said]);

  const ctx = { me, online, save, items, bump, canNote, setSaid };

  return (
    <div className="phone-frame">
      <header className="phone-top">
        <span className="phone-title">{TITLES[view.v]}</span>
        <button type="button" className={"phone-status" + (refused ? " bad" : waiting ? " warn" : "")} onClick={() => go("#/outbox")}>
          {refused
            ? `${refused} not sent`
            : waiting
              ? `${waiting} waiting to send`
              : online
                ? "All sent"
                : "No signal"}
        </button>
      </header>

      {stopped === "signed out" && (
        <p className="alert bad phone-pad">
          Signed out — <a href="/login?next=/phone">sign in again</a> to send what is waiting.
        </p>
      )}
      {said && <p className="alert ok phone-pad" role="status">{said}</p>}

      <main className="phone-body">
        {view.v === "home" && <HomeView {...ctx} />}
        {view.v === "clients" && <ClientsView {...ctx} />}
        {view.v === "client" && <ClientView {...ctx} id={view.id} />}
        {view.v === "add" && <AddView client={view.client} canNote={canNote} />}
        {(view.v === "note" || view.v === "photo" || view.v === "recording") && (
          <PickThenDo {...ctx} what={view.v} client={view.client} />
        )}
        {view.v === "hours" && <HoursView {...ctx} />}
        {view.v === "tofile" && <ToFileView {...ctx} />}
        {view.v === "reports" && <ReportsView {...ctx} />}
        {view.v === "team" && <TeamView {...ctx} />}
        {view.v === "thread" && <ThreadView {...ctx} id={view.id} />}
        {view.v === "outbox" && <OutboxView {...ctx} refresh={refreshItems} sync={sync} />}
        {view.v === "more" && <MoreView {...ctx} />}
      </main>

      {view.v !== "add" && (
        <button type="button" className="phone-add" onClick={() => go(view.v === "client" ? `#/add/${view.id}` : "#/add")}>
          Add
        </button>
      )}

      <nav className="phone-nav" aria-label="Phone">
        <a href="#/" className={view.v === "home" ? "on" : ""}>Today</a>
        <a href="#/clients" className={view.v === "clients" || view.v === "client" ? "on" : ""}>Clients</a>
        <a href="#/team" className={view.v === "team" || view.v === "thread" ? "on" : ""}>Team</a>
        <a href="#/more" className={view.v === "more" ? "on" : ""}>More</a>
      </nav>

      <div className="phone-install">
        <InstallPrompt answered={installAnswered} />
      </div>
    </div>
  );
}

const TITLES: Record<View["v"], string> = {
  home: "Today",
  clients: "Clients",
  client: "Client",
  add: "Add",
  note: "Note",
  photo: "Photo",
  recording: "Recording",
  hours: "Hours",
  tofile: "To file",
  reports: "Reports due",
  team: "Team",
  thread: "Team",
  outbox: "Waiting to send",
  more: "More",
};

type Ctx = {
  me: Me;
  online: boolean;
  save: (kind: OutboxKind, label: string, payload: Record<string, unknown>, blob?: Blob, blobName?: string) => Promise<OutboxItem>;
  items: OutboxItem[];
  bump: number;
  canNote: boolean;
  setSaid: (s: string | null) => void;
};

function Kept({ stale, error, signedOut }: { stale: string | null; error: string | null; signedOut: boolean }) {
  if (signedOut) return <p className="phone-kept">Signed out — showing what this phone kept.</p>;
  if (error) return <p className="phone-kept bad">{error}</p>;
  if (stale) return <p className="phone-kept">No signal — as of {time(stale)}.</p>;
  return null;
}

// ── Today ────────────────────────────────────────────────────

/** What a pending clock entry does to the clock, so the screen says what was pressed. */
function clockNow(base: Home["clock"] | undefined, items: OutboxItem[], me: string) {
  let on = Boolean(base?.startedAt);
  let since = base?.startedAt ?? null;
  let onBreak = Boolean(base?.breakSince);
  let breakSince = base?.breakSince ?? null;
  for (const i of items) {
    if (i.kind !== "clock" || i.owner !== me || i.status === "refused") continue;
    const what = String(i.payload.what);
    if (what === "clock in") { on = true; since = i.at; onBreak = false; }
    if (what === "break") { onBreak = true; breakSince = i.at; }
    if (what === "back") { onBreak = false; breakSince = null; }
    if (what === "clock out") { on = false; since = null; onBreak = false; }
  }
  return { on, since, onBreak, breakSince };
}

function HomeView({ me, items, bump }: Ctx) {
  const home = useRead<Home>(me.id, "/api/phone/home", "home", bump);
  const h = home.data;
  const clock = clockNow(h?.clock, items, me.id);
  const filedHere = new Set(items.filter((i) => i.kind === "tofile").map((i) => String(i.payload.item)));
  const toFileLeft = h ? Math.max(0, h.toFileCount - h.toFile.filter((t) => filedHere.has(t.id)).length) : 0;

  return (
    <>
      <Kept stale={home.stale} error={home.error} signedOut={home.signedOut} />
      {!h && home.loading && <p className="phone-kept">Opening today.</p>}

      <a className="phone-row" href="#/hours">
        <span className="phone-row-main">
          {clock.on ? (clock.onBreak ? `On a break since ${time(clock.breakSince)}` : `On the clock since ${time(clock.since)}`) : "Off the clock"}
        </span>
        <span className="phone-row-side">Hours</span>
      </a>

      {h && (
        <>
          <section className="phone-section">
            <h2 className="phone-h">Next appointment</h2>
            {h.next ? (
              <a className="phone-row" href={h.next.client_id ? `#/client/${h.next.client_id}` : "/calendar"}>
                <span className="phone-row-main">
                  <b>{time(h.next.at)}</b> {h.next.title}
                  {h.next.client_name ? ` · ${h.next.client_name}` : ""}
                </span>
                {h.next.where && <span className="phone-row-sub">{h.next.where}</span>}
              </a>
            ) : (
              <p className="phone-empty">Nothing on your calendar this week.</p>
            )}
          </section>

          <section className="phone-section">
            <h2 className="phone-h">Clients to see</h2>
            {h.see.length === 0 ? (
              <p className="phone-empty">Nobody is due today.</p>
            ) : (
              h.see.map((c) => (
                <a key={c.id} className="phone-row" href={`#/client/${c.id}`}>
                  <span className="phone-row-main">
                    {c.at && <b>{time(c.at)} </b>}
                    {c.name}
                  </span>
                  <span className="phone-row-sub">{c.why}</span>
                </a>
              ))
            )}
          </section>

          <section className="phone-section">
            <a className="phone-row" href="#/tofile">
              <span className="phone-row-main">To file</span>
              <span className="phone-count">{toFileLeft}</span>
            </a>
            <a className="phone-row" href="#/reports">
              <span className="phone-row-main">Reports due</span>
              <span className={"phone-count" + (h.reports.some((r) => r.late) ? " bad" : "")}>{h.reports.length}</span>
            </a>
          </section>
        </>
      )}
    </>
  );
}

function ReportsView({ me, bump }: Ctx) {
  const home = useRead<Home>(me.id, "/api/phone/home", "home", bump);
  const list = home.data?.reports ?? [];
  return (
    <>
      <Kept stale={home.stale} error={home.error} signedOut={home.signedOut} />
      {list.length === 0 ? (
        <p className="phone-empty">No reports are due.</p>
      ) : (
        list.map((r) => (
          <a key={r.id} className="phone-row" href={`/clients/${r.client_id}/reports`}>
            <span className="phone-row-main">{r.name}</span>
            <span className={"phone-row-sub" + (r.late ? " bad" : "")}>
              {r.what} · due {r.due}
            </span>
          </a>
        ))
      )}
    </>
  );
}

// ── Clients ──────────────────────────────────────────────────

function ClientsView({ me, online }: Ctx) {
  const [q, setQ] = useState("");
  const [list, setList] = useState<{ id: string; name: string; stage?: string }[]>([]);
  const [note, setNote] = useState<string | null>(null);

  useEffect(() => {
    let live = true;
    const t = setTimeout(async () => {
      if (!navigator.onLine) {
        const seen = await clientsSeenToday(me.id).catch(() => []);
        if (!live) return;
        const want = q.trim().toLowerCase();
        setList(seen.filter((c) => !want || c.name.toLowerCase().includes(want)));
        setNote("No signal — the clients you opened today.");
        return;
      }
      try {
        const res = await fetch(`/api/phone/clients?q=${encodeURIComponent(q)}`, { cache: "no-store" });
        const json = await res.json();
        if (!live) return;
        if (!res.ok) throw new Error(json.error);
        setList(json.clients);
        setNote(json.mine ? "Yours. Type a name for anybody else." : null);
      } catch {
        const seen = await clientsSeenToday(me.id).catch(() => []);
        if (!live) return;
        setList(seen);
        setNote("No answer — the clients you opened today.");
      }
    }, 250);
    return () => {
      live = false;
      clearTimeout(t);
    };
  }, [q, me.id, online]);

  return (
    <>
      <input
        className="phone-input"
        type="search"
        placeholder="Find a client"
        value={q}
        onChange={(e) => setQ(e.target.value)}
        aria-label="Find a client"
      />
      {note && <p className="phone-kept">{note}</p>}
      {list.length === 0 ? (
        <p className="phone-empty">Nobody by that name.</p>
      ) : (
        list.map((c) => (
          <a key={c.id} className="phone-row" href={`#/client/${c.id}`}>
            <span className="phone-row-main">{c.name}</span>
          </a>
        ))
      )}
    </>
  );
}

function ClientView({ me, id, items, bump, online }: Ctx & { id: string }) {
  const card = useRead<Card>(me.id, `/api/phone/client?id=${id}`, `client:${id}`, bump);
  const c = card.data;
  const pending = items.filter((i) => i.kind === "note" && i.payload.client_id === id && i.owner === me.id);

  if (!c) {
    return (
      <>
        <Kept stale={null} error={card.error} signedOut={card.signedOut} />
        {card.loading && <p className="phone-kept">Opening.</p>}
        {!card.loading && !card.error && <p className="phone-empty">Not opened today, so not on this phone.</p>}
      </>
    );
  }

  const digits = c.phone.replace(/[^\d+]/g, "");
  return (
    <>
      <Kept stale={card.stale} error={card.error} signedOut={card.signedOut} />
      <h1 className="phone-name">{c.name}</h1>
      <p className="phone-row-sub">
        {[c.stage, c.status !== "Active" ? c.status : "", c.counselor ? `Counselor ${c.counselor}` : ""].filter(Boolean).join(" · ")}
      </p>

      <div className="phone-actions">
        {digits ? (
          <a className="btn" href={`tel:${digits}`}>
            Call {c.phone}
          </a>
        ) : (
          <span className="phone-row-sub">No phone number on file.</span>
        )}
        {/* Texts go through the practice's own texting, where consent and the
            STOP rules are kept - never from the staff member's own phone. */}
        {digits && online && (
          <a className="btn ghost" href={`/clients/${c.id}?tab=messages`}>
            Text
          </a>
        )}
      </div>

      <section className="phone-section">
        <h2 className="phone-h">Last notes</h2>
        {pending.map((p) => (
          <div key={p.key} className="phone-note">
            <span className="phone-row-sub warn">{p.status === "refused" ? "Not sent" : "Waiting to send"} · {when(p.at)}</span>
            <p>{String(p.payload.text)}</p>
          </div>
        ))}
        {c.notes.length === 0 && pending.length === 0 ? (
          <p className="phone-empty">No notes yet.</p>
        ) : (
          c.notes.map((n) => (
            <div key={n.id} className="phone-note">
              <span className="phone-row-sub">
                {n.type} · {n.by} · {when(n.at)}
              </span>
              <p>{n.text}</p>
            </div>
          ))
        )}
      </section>

      <a className="phone-row" href={`/clients/${c.id}`}>
        <span className="phone-row-main">Full record</span>
      </a>
    </>
  );
}

// ── Add ──────────────────────────────────────────────────────

function AddView({ client, canNote }: { client?: string; canNote: boolean }) {
  const tail = client ? `/${client}` : "";
  return (
    <div className="phone-grid">
      {canNote && (
        <a className="phone-tile" href={`#/note${tail}`}>
          Note
        </a>
      )}
      <a className="phone-tile" href={`#/photo${tail}`}>
        Photo
      </a>
      <a className="phone-tile" href={`#/recording${tail}`}>
        Recording
      </a>
      <a className="phone-tile" href="#/hours">
        Hours
      </a>
    </div>
  );
}

/** Choose the client, if the Add did not come from one, then the form. */
function PickThenDo(props: Ctx & { what: "note" | "photo" | "recording"; client?: string }) {
  const { what, client, me, bump } = props;
  const card = useRead<Card>(me.id, client ? `/api/phone/client?id=${client}` : null, client ? `client:${client}` : null, bump);

  if (!client) {
    return (
      <>
        <p className="phone-kept">Whose is it?</p>
        <PickClient me={me} onPick={(id) => go(`#/${what}/${id}`)} />
      </>
    );
  }
  if (!card.data) {
    return (
      <>
        <Kept stale={null} error={card.error} signedOut={card.signedOut} />
        {card.loading ? <p className="phone-kept">Opening.</p> : <p className="phone-empty">Open the client once with signal first.</p>}
      </>
    );
  }
  if (what === "note") return <NoteForm {...props} card={card.data} />;
  return <FileForm {...props} card={card.data} what={what} />;
}

function PickClient({ me, onPick }: { me: Me; onPick: (id: string) => void }) {
  const [q, setQ] = useState("");
  const [list, setList] = useState<{ id: string; name: string }[]>([]);
  useEffect(() => {
    let live = true;
    const t = setTimeout(async () => {
      try {
        if (!navigator.onLine) throw new Error("offline");
        const res = await fetch(`/api/phone/clients?q=${encodeURIComponent(q)}`, { cache: "no-store" });
        const json = await res.json();
        if (live && res.ok) setList(json.clients);
      } catch {
        const seen = await clientsSeenToday(me.id).catch(() => []);
        const want = q.trim().toLowerCase();
        if (live) setList(seen.filter((c) => !want || c.name.toLowerCase().includes(want)));
      }
    }, 250);
    return () => {
      live = false;
      clearTimeout(t);
    };
  }, [q, me.id]);
  return (
    <>
      <input className="phone-input" type="search" placeholder="Find a client" value={q} onChange={(e) => setQ(e.target.value)} aria-label="Find a client" />
      {list.length === 0 ? (
        <p className="phone-empty">Nobody by that name.</p>
      ) : (
        list.map((c) => (
          <button key={c.id} type="button" className="phone-row" onClick={() => onPick(c.id)}>
            <span className="phone-row-main">{c.name}</span>
          </button>
        ))
      )}
    </>
  );
}

type Recognition = {
  lang: string; interimResults: boolean; continuous: boolean;
  onresult: (e: { results: ArrayLike<ArrayLike<{ transcript: string }>> }) => void;
  onend: () => void; onerror: () => void; start: () => void; stop: () => void;
};

function NoteForm({ card, save, online }: Ctx & { card: Card }) {
  const [text, setText] = useState("");
  const [category, setCategory] = useState(card.noteCategory);
  const [listening, setListening] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const rec = useRef<Recognition | null>(null);

  // Dictation in the browser needs the network on most phones; the keyboard's
  // own microphone key works without it and needs nothing from here.
  const Speech = useMemo(() => {
    if (typeof window === "undefined") return null;
    const w = window as unknown as { SpeechRecognition?: new () => Recognition; webkitSpeechRecognition?: new () => Recognition };
    return w.SpeechRecognition ?? w.webkitSpeechRecognition ?? null;
  }, []);

  const dictate = () => {
    if (!Speech) return;
    if (listening) {
      rec.current?.stop();
      return;
    }
    const r = new Speech();
    r.lang = "en-US";
    r.interimResults = false;
    r.continuous = true;
    r.onresult = (e) => {
      const heard = Array.from(e.results).map((x) => x[0].transcript).join(" ").trim();
      if (heard) setText((t) => (t ? t.trimEnd() + " " : "") + heard);
    };
    r.onend = () => setListening(false);
    r.onerror = () => setListening(false);
    rec.current = r;
    setListening(true);
    r.start();
  };

  return (
    <form
      className="phone-form"
      onSubmit={async (e) => {
        e.preventDefault();
        if (!text.trim()) {
          setError("Write something first.");
          return;
        }
        await save("note", `Note — ${card.name}`, { client_id: card.id, text: text.trim(), type: "General", category });
        go(`#/client/${card.id}`);
      }}
    >
      <p className="phone-row-main">{card.name}</p>
      {error && <p className="alert bad">{error}</p>}
      <label className="field">
        What happened
        <textarea className="phone-input" rows={7} value={text} onChange={(e) => setText(e.target.value)} />
      </label>
      {Speech && online && (
        <button type="button" className="btn ghost" onClick={dictate}>
          {listening ? "Stop dictating" : "Dictate"}
        </button>
      )}
      <label className="field">
        Which service
        <select className="phone-input" value={category} onChange={(e) => setCategory(e.target.value)}>
          {card.noteCategories.map((c) => (
            <option key={c} value={c}>{c}</option>
          ))}
        </select>
      </label>
      <button type="submit" className="btn">Save note</button>
    </form>
  );
}

function FileForm({ card, save, what }: Ctx & { card: Card; what: "photo" | "recording" }) {
  const usable = card.fileCategories.filter((c) => card.canRestrict || !c.restricted_by_default);
  const [category, setCategory] = useState(usable[0]?.key ?? "Other");
  const [blob, setBlob] = useState<Blob | null>(null);
  const [name, setName] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [recording, setRecording] = useState(false);
  const recorder = useRef<MediaRecorder | null>(null);
  const [preview, setPreview] = useState<string | null>(null);

  useEffect(() => () => {
    if (preview) URL.revokeObjectURL(preview);
  }, [preview]);

  const take = async (file: File | undefined) => {
    if (!file) return;
    setError(null);
    const ready = await readyDocument(file);
    if (ready.size > 50 * 1024 * 1024) {
      setError("That photo is over 50 MB — take it again closer to the page.");
      return;
    }
    setBlob(ready);
    setName(ready.name);
    setPreview(URL.createObjectURL(ready));
  };

  const record = async () => {
    if (recording) {
      recorder.current?.stop();
      return;
    }
    setError(null);
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      const type = ["audio/mp4", "audio/webm", "audio/ogg"].find((t) => MediaRecorder.isTypeSupported(t)) ?? "";
      const r = new MediaRecorder(stream, type ? { mimeType: type } : undefined);
      const parts: Blob[] = [];
      r.ondataavailable = (e) => e.data.size && parts.push(e.data);
      r.onstop = () => {
        stream.getTracks().forEach((t) => t.stop());
        const kind = (r.mimeType || type || "audio/webm").split(";")[0];
        const out = new Blob(parts, { type: kind });
        const ext = kind.includes("mp4") ? "m4a" : kind.includes("ogg") ? "ogg" : "webm";
        setBlob(out);
        setName(`recording.${ext}`);
        setPreview(URL.createObjectURL(out));
        setRecording(false);
      };
      recorder.current = r;
      r.start();
      setRecording(true);
    } catch {
      setError("The phone would not give the microphone — allow it in the phone's settings.");
    }
  };

  const restricted = card.fileCategories.find((c) => c.key === category)?.restricted_by_default ?? false;

  return (
    <form
      className="phone-form"
      onSubmit={async (e) => {
        e.preventDefault();
        if (!blob) {
          setError(what === "photo" ? "Take the photo first." : "Record something first.");
          return;
        }
        const label = categoryLabel(card, category);
        const stamp = practiceDay();
        const ext = name.includes(".") ? name.split(".").pop() : "bin";
        await save(
          "file",
          `${what === "photo" ? "Photo" : "Recording"} — ${card.name}`,
          {
            client_id: card.id,
            category,
            restricted,
            mime_type: (blob.type || "").split(";")[0],
            size_bytes: blob.size,
            filename: `${label} ${stamp}.${ext}`,
            document_date: stamp,
            sha256: await sha256(blob),
            note: what === "recording" ? "Recorded on the phone" : "Photographed on the phone",
          },
          blob,
          name,
        );
        go(`#/client/${card.id}`);
      }}
    >
      <p className="phone-row-main">{card.name}</p>
      {error && <p className="alert bad">{error}</p>}
      {what === "photo" ? (
        <label className="btn phone-camera">
          {blob ? "Take it again" : "Take photo"}
          <input type="file" accept="image/*" capture="environment" hidden onChange={(e) => void take(e.target.files?.[0])} />
        </label>
      ) : (
        <button type="button" className="btn" onClick={record}>
          {recording ? "Stop recording" : blob ? "Record again" : "Start recording"}
        </button>
      )}
      {preview && what === "photo" && <img className="phone-preview" src={preview} alt="The photo, before it is saved" />}
      {preview && what === "recording" && <audio className="phone-preview" src={preview} controls />}
      <label className="field">
        What it is
        <select className="phone-input" value={category} onChange={(e) => setCategory(e.target.value)}>
          {usable.map((c) => (
            <option key={c.key} value={c.key}>{c.label}</option>
          ))}
        </select>
      </label>
      {restricted && <p className="phone-row-sub">Goes on the record as restricted.</p>}
      <button type="submit" className="btn">Save to Documents</button>
    </form>
  );
}

const categoryLabel = (card: Card, key: string) => card.fileCategories.find((c) => c.key === key)?.label ?? key;

// ── Hours ────────────────────────────────────────────────────

function HoursView({ me, items, save, bump }: Ctx) {
  const home = useRead<Home>(me.id, "/api/phone/home", "home", bump);
  const clock = clockNow(home.data?.clock, items, me.id);
  const press = (what: "clock in" | "break" | "back" | "clock out", label: string) =>
    save("clock", label, { what });

  return (
    <>
      <Kept stale={home.stale} error={home.error} signedOut={home.signedOut} />
      <p className="phone-name">
        {clock.on ? (clock.onBreak ? `On a break since ${time(clock.breakSince)}` : `On since ${time(clock.since)}`) : "Off the clock"}
      </p>
      {home.data && <p className="phone-row-sub">{home.data.clock.todayHours.toFixed(2)} hours clocked today</p>}
      <div className="phone-actions stack">
        {!clock.on && (
          <button type="button" className="btn" onClick={() => press("clock in", "Clock in")}>
            Clock in
          </button>
        )}
        {clock.on && !clock.onBreak && (
          <button type="button" className="btn ghost" onClick={() => press("break", "Break")}>
            Start break
          </button>
        )}
        {clock.on && clock.onBreak && (
          <button type="button" className="btn" onClick={() => press("back", "Back from break")}>
            End break
          </button>
        )}
        {clock.on && (
          <button type="button" className="btn ghost" onClick={() => press("clock out", "Clock out")}>
            Clock out
          </button>
        )}
      </div>
      <p className="phone-row-sub">Recorded at the time you press it, signal or not.</p>
    </>
  );
}

// ── To file ──────────────────────────────────────────────────

const OUTCOME_SAID: Record<string, string> = {
  happened: "It happened",
  "did not happen": "It did not happen",
  "wrong client": "Wrong client",
};

function ToFileView({ me, items, save, bump }: Ctx) {
  const home = useRead<Home>(me.id, "/api/phone/home", "home", bump);
  const done = new Set(items.filter((i) => i.kind === "tofile" && i.owner === me.id).map((i) => String(i.payload.item)));
  const list = (home.data?.toFile ?? []).filter((t) => !done.has(t.id));
  const [open, setOpen] = useState<string | null>(null);
  const [note, setNote] = useState("");

  return (
    <>
      <Kept stale={home.stale} error={home.error} signedOut={home.signedOut} />
      {list.length === 0 ? (
        <p className="phone-empty">Nothing waiting to be filed.</p>
      ) : (
        list.map((t) => (
          <div key={t.id} className="phone-card">
            <p className="phone-row-main">{t.title}</p>
            <p className="phone-row-sub">
              {t.source} · {when(t.happened_at)}
              {t.detail ? ` · ${t.detail}` : ""}
            </p>
            <p className="phone-row-sub">{t.client_name ? `${t.client_name} — ${t.guess_why}` : "Nobody guessed — say whose on My day"}</p>
            {t.client_id && open !== t.id && (
              <button type="button" className="btn ghost" onClick={() => { setOpen(t.id); setNote(""); }}>
                Confirm
              </button>
            )}
            {open === t.id && (
              <div className="phone-form">
                <label className="field">
                  Anything to add
                  <input className="phone-input" value={note} onChange={(e) => setNote(e.target.value)} />
                </label>
                <div className="phone-actions stack">
                  {(["happened", "did not happen", "wrong client"] as const).map((o) => (
                    <button
                      key={o}
                      type="button"
                      className={o === "happened" ? "btn" : "btn ghost"}
                      onClick={async () => {
                        await save("tofile", `${OUTCOME_SAID[o]} — ${t.title}`, { item: t.id, outcome: o, note });
                        setOpen(null);
                      }}
                    >
                      {OUTCOME_SAID[o]}
                    </button>
                  ))}
                </div>
              </div>
            )}
          </div>
        ))
      )}
    </>
  );
}

// ── Team ─────────────────────────────────────────────────────

function TeamView({ me, bump }: Ctx) {
  const list = useRead<{ threads: Thread[] }>(me.id, "/api/phone/team", "team", bump);
  const threads = list.data?.threads ?? [];
  return (
    <>
      <Kept stale={list.stale} error={list.error} signedOut={list.signedOut} />
      {threads.length === 0 && !list.loading ? (
        <p className="phone-empty">No conversations yet.</p>
      ) : (
        threads.map((t) => (
          <a key={t.id} className="phone-row" href={`#/thread/${t.id}`}>
            <span className="phone-row-main">{t.title}</span>
            {t.unread > 0 && <span className="phone-count">{t.unread}</span>}
          </a>
        ))
      )}
    </>
  );
}

function ThreadView({ me, id, items, save, bump }: Ctx & { id: string }) {
  const thread = useRead<{ lines: Line[] }>(me.id, `/api/phone/team?c=${id}`, `team:${id}`, bump);
  const [body, setBody] = useState("");
  const mine = items.filter((i) => i.kind === "team" && i.payload.conversation_id === id && i.owner === me.id);
  return (
    <>
      <Kept stale={thread.stale} error={thread.error} signedOut={thread.signedOut} />
      <div className="phone-thread">
        {(thread.data?.lines ?? []).map((l) => (
          <div key={l.id} className="phone-note">
            <span className="phone-row-sub">
              {l.who} · {when(l.at)}
            </span>
            <p>{l.body}</p>
          </div>
        ))}
        {mine.map((m) => (
          <div key={m.key} className="phone-note">
            <span className={"phone-row-sub " + (m.status === "refused" ? "bad" : "warn")}>
              {m.status === "refused" ? "Not sent" : "Waiting to send"}
            </span>
            <p>{String(m.payload.body)}</p>
          </div>
        ))}
      </div>
      <form
        className="phone-form"
        onSubmit={async (e) => {
          e.preventDefault();
          if (!body.trim()) return;
          await save("team", "Team message", { conversation_id: id, body: body.trim() });
          setBody("");
        }}
      >
        <textarea className="phone-input" rows={3} value={body} onChange={(e) => setBody(e.target.value)} aria-label="Message" />
        <button type="submit" className="btn">Send</button>
      </form>
    </>
  );
}

// ── Waiting to send ──────────────────────────────────────────

function OutboxView({ me, items, refresh, sync, online }: Ctx & { refresh: () => Promise<void>; sync: () => Promise<void> }) {
  const [confirming, setConfirming] = useState<string | null>(null);
  const others = items.filter((i) => i.owner !== me.id);
  const mine = items.filter((i) => i.owner === me.id);
  return (
    <>
      {mine.length === 0 ? (
        <p className="phone-empty">Everything is sent.</p>
      ) : (
        mine.map((i) => (
          <div key={i.key} className={"phone-card" + (i.status === "refused" ? " bad" : "")}>
            <p className="phone-row-main">{i.label}</p>
            <p className="phone-row-sub">
              {i.status === "refused" ? "Not sent" : i.status === "sending" ? "Sending" : "Waiting to send"} · saved {when(i.at)}
            </p>
            {i.error && <p className={"phone-row-sub " + (i.status === "refused" ? "bad" : "warn")}>{i.error}</p>}
            <div className="phone-actions">
              {i.status === "refused" && (
                <button type="button" className="btn ghost" onClick={async () => { await retry(i); await refresh(); void sync(); }}>
                  Try again
                </button>
              )}
              {confirming === i.key ? (
                <button type="button" className="btn danger" onClick={async () => { await dropItem(i.key); setConfirming(null); await refresh(); }}>
                  Discard
                </button>
              ) : (
                <button type="button" className="btn ghost" onClick={() => setConfirming(i.key)}>
                  Discard it
                </button>
              )}
            </div>
          </div>
        ))
      )}
      {others.length > 0 && (
        <p className="phone-row-sub">{others.length} saved by another sign-in on this phone — they send when that person signs in.</p>
      )}
      {mine.some((i) => i.status !== "refused") && online && (
        <button type="button" className="btn" onClick={() => void sync()}>
          Send now
        </button>
      )}
    </>
  );
}

// ── More ─────────────────────────────────────────────────────

function MoreView({ me, items }: Ctx) {
  const [blocked, setBlocked] = useState<string | null>(null);
  const unsent = items.filter((i) => i.owner === me.id).length;
  const formRef = useRef<HTMLFormElement>(null);

  const signOut = async () => {
    if (unsent > 0 && blocked === null) {
      setBlocked(`${unsent} not sent yet — signing out deletes ${unsent === 1 ? "it" : "them"} from this phone.`);
      return;
    }
    // A client's notes on a phone after the person has signed out of it are
    // notes on a phone anybody can pick up.
    await forgetAll().catch(() => undefined);
    navigator.serviceWorker?.controller?.postMessage("forget");
    formRef.current?.submit();
  };

  return (
    <>
      <a className="phone-row" href="#/outbox">
        <span className="phone-row-main">Waiting to send</span>
        <span className="phone-count">{unsent}</span>
      </a>
      <a className="phone-row" href="#/tofile"><span className="phone-row-main">To file</span></a>
      <a className="phone-row" href="#/reports"><span className="phone-row-main">Reports due</span></a>
      <a className="phone-row" href="/my-day"><span className="phone-row-main">My day</span></a>
      <a className="phone-row" href="/calendar"><span className="phone-row-main">Calendar</span></a>
      <a className="phone-row" href="/messages/texts?tab=texts"><span className="phone-row-main">Texts</span></a>
      <a className="phone-row" href="/mail"><span className="phone-row-main">Mail</span></a>
      <a className="phone-row" href="/time-clock"><span className="phone-row-main">Time clock</span></a>
      <a className="phone-row" href="/end-of-day"><span className="phone-row-main">My end of day</span></a>
      <a className="phone-row" href="/sops"><span className="phone-row-main">Knowledge base</span></a>
      <a className="phone-row" href="/dashboard"><span className="phone-row-main">Everything else</span></a>

      <p className="phone-row-sub">{me.name}</p>
      {blocked && <p className="alert bad">{blocked}</p>}
      <form ref={formRef} action="/auth/signout" method="post">
        <button type="button" className={blocked ? "btn danger" : "btn ghost"} onClick={signOut}>
          {blocked ? "Sign out anyway" : "Sign out"}
        </button>
      </form>
    </>
  );
}
