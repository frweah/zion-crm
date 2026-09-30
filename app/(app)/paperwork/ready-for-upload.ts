/**
 * A photograph, made ready to upload.
 *
 * Whatever the phone produced - a 4 MB HEIC off an iPhone, a 3 MB JPEG off an
 * Android - becomes a small image here, in the browser, before anything is
 * sent. Without this, a signature or an ID photographed on a phone is several
 * megabytes of camera resolution for something that is read at the size of a
 * business card.
 *
 * This lived inside the signature card until 30 Sept 2026, when Melanie's
 * onboarding upload failed three times from an Android phone: the file forms
 * on the onboarding walkthrough had no such step, so the photograph went up
 * at full size and the request was refused before it reached any of our code
 * (413, "Body exceeded 1 MB limit", digest 3565919249). What she saw was
 * "Application error: a server-side exception has occurred" - and the screen
 * had told her the limit was 25MB.
 *
 * A PDF is returned untouched: it is already a document, and re-drawing one
 * through a canvas would be a way of losing pages.
 */
export const MAX_UPLOAD_BYTES = 25 * 1024 * 1024;

/** The longest edge a scan or photograph of a document needs. */
const DOCUMENT_MAX = 2000;

/** A signature is drawn small on a form, and is embedded in every one. */
const SIGNATURE_MAX_W = 900;
const SIGNATURE_MAX_H = 400;

async function shrink(file: File, maxW: number, maxH: number, type: "image/png" | "image/jpeg"): Promise<File> {
  const url = URL.createObjectURL(file);
  try {
    const image = await new Promise<HTMLImageElement>((resolve, reject) => {
      const img = new window.Image();
      img.onload = () => resolve(img);
      img.onerror = () => reject(new Error("decode"));
      img.src = url;
    });

    const scale = Math.min(1, maxW / image.naturalWidth, maxH / image.naturalHeight);
    const canvas = document.createElement("canvas");
    canvas.width = Math.max(1, Math.round(image.naturalWidth * scale));
    canvas.height = Math.max(1, Math.round(image.naturalHeight * scale));
    const ctx = canvas.getContext("2d");
    if (!ctx) throw new Error("decode");
    // A JPEG has no transparency, and an unpainted canvas behind one turns
    // black - a photographed page would arrive as a dark rectangle. This is
    // the colour of paper rather than a colour of the CRM: it is never drawn
    // on a screen, it is the backing of an image of a document, so it is not
    // a token and will not follow the theme.
    if (type === "image/jpeg") {
      ctx.fillStyle = "white";
      ctx.fillRect(0, 0, canvas.width, canvas.height);
    }
    ctx.drawImage(image, 0, 0, canvas.width, canvas.height);

    const blob = await new Promise<Blob | null>((resolve) =>
      canvas.toBlob(resolve, type, type === "image/jpeg" ? 0.85 : undefined),
    );
    if (!blob) throw new Error("decode");
    const name = type === "image/png" ? "signature.png" : "document.jpg";
    return new File([blob], name, { type });
  } finally {
    URL.revokeObjectURL(url);
  }
}

/** A signature: small, and on a transparent background. */
export function readySignature(file: File): Promise<File> {
  return shrink(file, SIGNATURE_MAX_W, SIGNATURE_MAX_H, "image/png");
}

/**
 * A scan or photograph of a document. PDFs pass through untouched; an image
 * that cannot be decoded is sent as it is, and the size check below catches
 * it if it is too big to send.
 */
export async function readyDocument(file: File): Promise<File> {
  if (!file.type.startsWith("image/")) return file;
  try {
    return await shrink(file, DOCUMENT_MAX, DOCUMENT_MAX, "image/jpeg");
  } catch {
    return file;
  }
}

/**
 * Whether this can be sent at all, in the words somebody holding a phone can
 * act on. Asked in the browser so that a file too big to send is a sentence
 * on the screen rather than a request that dies on the way.
 */
export function tooBig(file: File): string | null {
  if (file.size <= MAX_UPLOAD_BYTES) return null;
  const mb = (file.size / (1024 * 1024)).toFixed(1);
  return `That file is ${mb} MB, and the limit is 25 MB. Photograph the page on its own, or scan it at a lower resolution.`;
}
