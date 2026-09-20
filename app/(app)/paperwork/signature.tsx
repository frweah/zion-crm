"use client";

import { useActionState, useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import Image from "next/image";
import { uploadSignature, removeSignature, type SignatureState } from "./signature-actions";

const initial: SignatureState = { error: null, ok: null };

/**
 * Your signature, on file.
 *
 * Uploaded once. From then on it is drawn on the USOR forms you sign, beside
 * your typed name and the moment the database recorded the signing - the
 * image is what the page looks like, the record is what it means.
 */
/**
 * A photograph of a signature, made ready to upload.
 *
 * Whatever the phone produced - a 4 MB HEIC off an iPhone, a 3 MB JPEG off an
 * Android - becomes a small PNG here, in the browser, before anything is
 * sent. Without this the honest limits of the server side (500 KB, PNG or
 * JPEG only) refuse almost every photograph anybody would actually take,
 * which is a rule that reads as a bug.
 *
 * Small matters twice over: the image is embedded in every USOR form the
 * person signs, so a 4 MB signature would be a 4 MB attachment on every
 * claim.
 */
async function readyForUpload(file: File): Promise<File> {
  const url = URL.createObjectURL(file);
  try {
    const image = await new Promise<HTMLImageElement>((resolve, reject) => {
      const img = new window.Image();
      img.onload = () => resolve(img);
      img.onerror = () => reject(new Error("decode"));
      img.src = url;
    });

    const MAX_W = 900;
    const MAX_H = 400;
    const scale = Math.min(1, MAX_W / image.naturalWidth, MAX_H / image.naturalHeight);
    const canvas = document.createElement("canvas");
    canvas.width = Math.max(1, Math.round(image.naturalWidth * scale));
    canvas.height = Math.max(1, Math.round(image.naturalHeight * scale));
    const ctx = canvas.getContext("2d");
    if (!ctx) throw new Error("decode");
    ctx.drawImage(image, 0, 0, canvas.width, canvas.height);

    const blob = await new Promise<Blob | null>((resolve) => canvas.toBlob(resolve, "image/png"));
    if (!blob) throw new Error("decode");
    return new File([blob], "signature.png", { type: "image/png" });
  } finally {
    URL.revokeObjectURL(url);
  }
}

export function SignatureCard({ current }: { current: string | null }) {
  const [state, action, pending] = useActionState(uploadSignature, initial);
  const [removing, setRemoving] = useState(false);
  const [preparing, setPreparing] = useState(false);
  const [trouble, setTrouble] = useState<string | null>(null);
  const router = useRouter();

  useEffect(() => {
    if (state.ok) router.refresh();
  }, [state, router]);

  /** Shrink first, then hand the small PNG to the server action. */
  async function submit(formData: FormData) {
    setTrouble(null);
    const chosen = formData.get("file");
    if (!(chosen instanceof File) || chosen.size === 0) {
      setTrouble("Choose an image of your signature first.");
      return;
    }
    setPreparing(true);
    try {
      formData.set("file", await readyForUpload(chosen));
    } catch {
      setTrouble(
        "This browser could not read that image. If it came off an iPhone it may be a HEIC - open it, choose Share, then Save as JPEG, and upload that.",
      );
      return;
    } finally {
      setPreparing(false);
    }
    await action(formData);
  }

  return (
    <div className="card" style={{ marginTop: 14 }}>
      <h3 style={{ marginTop: 0 }}>Your signature</h3>
      <p className="sub" style={{ marginTop: 0 }}>
        Sign a blank sheet, photograph it, and upload it here. It is stamped on every USOR form you sign from then on,
        beside your name and the time you signed.
      </p>

      {trouble && <div className="alert bad">{trouble}</div>}
      {state.error && <div className="alert bad">{state.error}</div>}
      {state.ok && <div className="alert ok">{state.ok}</div>}

      {current ? (
        <>
          <div
            style={{
              border: "1px solid var(--line)",
              borderRadius: 8,
              padding: 10,
              background: "var(--paper)",
              display: "inline-block",
              marginBottom: 10,
            }}
          >
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img src={current} alt="Your signature as it will appear on a signed form" style={{ maxHeight: 60, display: "block" }} />
          </div>
          <div className="row2" style={{ gap: 8, alignItems: "center" }}>
            <form
              action={async () => {
                setRemoving(true);
                await removeSignature();
                setRemoving(false);
                router.refresh();
              }}
            >
              <button className="btn ghost" type="submit" disabled={removing}>
                {removing ? "Removing…" : "Remove it"}
              </button>
            </form>
            <span className="lock">Replacing it is uploading a new one below.</span>
          </div>
        </>
      ) : (
        <div className="alert warn">
          You have not uploaded a signature. Forms you sign will carry your typed name and the time, which is a valid
          signature — the image simply makes the page look like the paper one.
        </div>
      )}

      <form action={submit} style={{ marginTop: 10 }}>
        <div className="row2" style={{ alignItems: "flex-end", gap: 8 }}>
          <label className="field" style={{ margin: 0, flex: 1 }}>
            {current ? "Replace it" : "Your signature"}
            <input name="file" type="file" accept="image/*" capture="environment" required />
          </label>
          <button className="btn gold" type="submit" disabled={pending || preparing}>
            {preparing ? "Preparing…" : pending ? "Saving…" : "Save signature"}
          </button>
        </div>
        <p className="lock" style={{ margin: "8px 0 0" }}>
          A photograph straight off your phone is fine — it is shrunk here before it is sent, so there is no size to
          worry about. It is kept in the staff tier and nobody else can read it — not Admin either, because holding
          somebody&apos;s signature is the ability to sign as them.
        </p>
      </form>
    </div>
  );
}
