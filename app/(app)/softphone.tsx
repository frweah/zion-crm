"use client";

import { useCallback, useEffect, useRef, useState } from "react";

/**
 * The practice line, in the browser (owner, 27 November 2026, part B).
 *
 * Mounted once in the shell, so a call arriving reaches whoever is signed in
 * wherever they are rather than only on one screen. It is deliberately the
 * only thing on these screens that is fixed to the viewport besides the team
 * bubble: a telephone that can be missed because somebody was scrolled down
 * a client list is not a telephone.
 *
 * Three things it does, and two things it refuses to do.
 *
 * **The SDK is loaded only when somebody is allowed to take calls.** It is
 * about a hundred kilobytes of JavaScript, and a seat that does not answer
 * the client line should not pay for it on every page. So the token is asked
 * for first, and the import happens after the answer.
 *
 * **Asking for a token is how somebody says they are at their desk.** The
 * same request does both, every minute, because two things that have to agree
 * are better as one call than as two that can drift. `voice_presence_seconds`
 * in the database is how long one answer is trusted for.
 *
 * **It never asks for the microphone until a call is accepted.** A permission
 * prompt on page load, on every page, is how somebody clicks Block once and
 * then cannot answer the telephone for a week. Answering is a deliberate act
 * and it is the right moment to ask.
 *
 * It does not dial on its own, and it does not hang up on its own. Everything
 * here happens because somebody pressed something.
 */

type Token = { token: string; identity: string; expiresAt: number; refreshMs: number };

type Ringing = {
  /** The Twilio Call object. Typed loosely: the SDK is imported at run time. */
  call: { accept: () => void; reject: () => void; disconnect: () => void; mute: (on: boolean) => void };
  who: string;
  clientId: string | null;
  direction: "in" | "out";
};

/** What the panel is doing, in the words the screen uses. */
type State = "off" | "ready" | "ringing" | "on a call" | "no microphone";

export function Softphone() {
  const [state, setState] = useState<State>("off");
  const [live, setLive] = useState<Ringing | null>(null);
  const [muted, setMuted] = useState(false);
  const [seconds, setSeconds] = useState(0);
  const [trouble, setTrouble] = useState<string | null>(null);

  /** The SDK's Device, once there is one. */
  const device = useRef<{
    register: () => Promise<void>;
    destroy: () => void;
    updateToken: (t: string) => void;
    connect: (o: { params: Record<string, string> }) => Promise<unknown>;
    on: (e: string, fn: (...a: unknown[]) => void) => void;
  } | null>(null);

  const ask = useCallback(async (): Promise<Token | null> => {
    try {
      const res = await fetch("/api/twilio/voice-token", { cache: "no-store" });
      if (!res.ok) return null;
      return (await res.json()) as Token;
    } catch {
      return null;
    }
  }, []);

  // ── the telephone ──────────────────────────────────────────
  useEffect(() => {
    let alive = true;
    let beat: ReturnType<typeof setInterval> | null = null;

    (async () => {
      const first = await ask();
      if (!alive || !first?.token) return;

      let Device: new (t: string, o?: unknown) => NonNullable<typeof device.current>;
      try {
        ({ Device } = (await import("@twilio/voice-sdk")) as never);
      } catch {
        // No telephone rather than a broken page. Everything else on these
        // screens goes on working.
        return;
      }
      if (!alive) return;

      const d = new Device(first.token, { logLevel: "error", closeProtection: true });
      device.current = d;

      d.on("error", (...args: unknown[]) => {
        const err = args[0] as { message?: string; code?: number } | undefined;
        // 31401 is the microphone: Twilio reports it as a device error rather
        // than a permission one, and it is the single most likely thing to go
        // wrong on a desk that has never taken a call before.
        if (err?.code === 31401) {
          setState("no microphone");
          return;
        }
        setTrouble(err?.message ?? "The telephone stopped working. Reload the page.");
      });

      d.on("incoming", (...args: unknown[]) => {
        const call = args[0] as Ringing["call"] & {
          customParameters?: Map<string, string>;
          parameters?: Record<string, string>;
          on: (e: string, fn: () => void) => void;
        };
        const who =
          call.customParameters?.get("caller") ||
          call.parameters?.From ||
          "Unknown caller";
        const clientId = call.customParameters?.get("clientId") || null;

        call.on("disconnect", () => {
          setLive(null);
          setState("ready");
          setSeconds(0);
          setMuted(false);
        });
        call.on("cancel", () => {
          setLive(null);
          setState("ready");
        });
        call.on("accept", () => setState("on a call"));

        setLive({ call, who, clientId: clientId || null, direction: "in" });
        setState("ringing");
      });

      try {
        await d.register();
        if (alive) setState("ready");
      } catch {
        if (alive) setState("off");
        return;
      }

      /**
       * Still here, every minute.
       *
       * The same request refreshes the token and the presence row, which is
       * why there is one timer and not two. A beat that fails leaves the row
       * to expire on its own after ninety seconds, which takes this desk off
       * the phones rather than ringing it when nobody is there.
       */
      beat = setInterval(
        async () => {
          const next = await ask();
          if (next?.token && device.current) device.current.updateToken(next.token);
        },
        first.refreshMs || 60_000,
      );
    })();

    return () => {
      alive = false;
      if (beat) clearInterval(beat);
      try {
        device.current?.destroy();
      } catch {
        // Nothing to do about a telephone that will not put itself down.
      }
      device.current = null;
      // Off the phones now rather than in ninety seconds, so a closed tab
      // does not ring an empty desk. keepalive, because the page is going.
      try {
        void fetch("/api/twilio/voice-token", { method: "DELETE", keepalive: true });
      } catch {
        // The row expires on its own.
      }
    };
  }, [ask]);

  // ── the timer, while somebody is talking ───────────────────
  useEffect(() => {
    if (state !== "on a call") return;
    const tick = setInterval(() => setSeconds((s) => s + 1), 1000);
    return () => clearInterval(tick);
  }, [state]);

  // ── dialling, from anywhere on the screen ──────────────────
  useEffect(() => {
    const dial = async (event: Event) => {
      const { to, label } = (event as CustomEvent<{ to: string; label?: string }>).detail ?? {};
      if (!to || !device.current) return;
      try {
        const call = (await device.current.connect({ params: { To: to } })) as Ringing["call"] & {
          on: (e: string, fn: () => void) => void;
        };
        call.on("disconnect", () => {
          setLive(null);
          setState("ready");
          setSeconds(0);
          setMuted(false);
        });
        call.on("accept", () => setState("on a call"));
        setLive({ call, who: label || to, clientId: null, direction: "out" });
        setState("on a call");
      } catch {
        setState("no microphone");
      }
    };
    window.addEventListener("zion:dial", dial as EventListener);
    return () => window.removeEventListener("zion:dial", dial as EventListener);
  }, []);

  if (state === "off") return null;

  const clock = `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;

  return (
    <div
      className="card"
      role="region"
      aria-label="Client line"
      style={{
        position: "fixed",
        right: 16,
        bottom: 84,
        zIndex: 60,
        width: "min(320px, calc(100vw - 32px))",
        padding: 12,
      }}
    >
      {trouble && <div className="alert bad">{trouble}</div>}

      {state === "no microphone" && (
        <div className="alert warn">Calls off — allow the microphone</div>
      )}

      {state === "ready" && (
        <div className="lock">Client line, ready</div>
      )}

      {(state === "ringing" || state === "on a call") && live && (
        <>
          <div style={{ display: "flex", alignItems: "baseline", gap: 8 }}>
            <b>{live.who}</b>
            {state === "ringing" ? (
              <span className="chip warn">{live.direction === "in" ? "ringing" : "calling"}</span>
            ) : (
              <span className="chip ok" style={{ fontVariantNumeric: "tabular-nums" }}>
                {clock}
              </span>
            )}
          </div>

          <div style={{ display: "flex", gap: 8, marginTop: 10, flexWrap: "wrap" }}>
            {state === "ringing" && live.direction === "in" && (
              <>
                <button
                  className="btn"
                  type="button"
                  onClick={() => {
                    try {
                      live.call.accept();
                    } catch {
                      setState("no microphone");
                    }
                  }}
                >
                  Answer
                </button>
                <button className="btn ghost" type="button" onClick={() => live.call.reject()}>
                  Decline
                </button>
              </>
            )}

            {state === "on a call" && (
              <>
                <button
                  className="btn ghost"
                  type="button"
                  onClick={() => {
                    const next = !muted;
                    live.call.mute(next);
                    setMuted(next);
                  }}
                >
                  {muted ? "Unmute" : "Mute"}
                </button>
                <button className="btn" type="button" onClick={() => live.call.disconnect()}>
                  Hang up
                </button>
              </>
            )}

            {live.clientId && (
              <a className="btn ghost" href={`/clients/${live.clientId}?tab=notes`}>
                Open their record
              </a>
            )}
          </div>
        </>
      )}
    </div>
  );
}
