import "server-only";
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";
import { groupIntoLines, type PdfLine, type PdfWord } from "./pdf-lines";

/**
 * The text inside a PDF, with the geometry kept.
 *
 * Deterministic and local: pdf.js reads the text layer the PDF already
 * carries. Nothing is sent anywhere, no service sees a client's authorization,
 * and the same file parses the same way every time — which is the whole
 * argument for doing it this way rather than asking a model what it sees.
 *
 * Words come back grouped into lines because a form is a layout, not a
 * paragraph: "Total hours" and "40" are two items that mean nothing apart and
 * everything together, and pairing them by position is the only reliable way.
 * That grouping lives in pdf-lines.ts, where it can be checked without a PDF.
 *
 * A scan has no text layer. That is not a failure to parse — it is a
 * different kind of document, and it is reported as such so the screen can
 * say so instead of showing an empty form.
 */

export type { PdfLine };

export type PdfText = {
  lines: PdfLine[];
  /** Every line joined, one per row — what the pattern rules read. */
  plain: string;
  pages: number;
  /** True when the file carries no extractable text at all. */
  scanned: boolean;
};

export async function extractPdfText(bytes: Uint8Array): Promise<PdfText> {
  // Imported here rather than at module load: pdf.js is large, and most
  // requests to this application never touch a PDF.
  const pdfjs = await import("pdfjs-dist/legacy/build/pdf.mjs");

  // pdf.js insists on a worker path even when it will only load a fake one
  // in-process. Resolved from the package rather than guessed, so it keeps
  // working wherever node_modules ends up — and pdfjs-dist is left out of the
  // bundle in next.config for the same reason.
  // The specifier is assembled at runtime so the bundler leaves it alone: a
  // literal here makes webpack try to follow an ESM file it cannot inline,
  // and the build fails rather than the page.
  const require_ = createRequire(import.meta.url);
  const workerSpec = ["pdfjs-dist", "legacy", "build", "pdf.worker.mjs"].join("/");
  pdfjs.GlobalWorkerOptions.workerSrc = pathToFileURL(require_.resolve(workerSpec)).href;

  // Where pdf.js finds the fonts it standardises on. Without this every read
  // logs two warnings per document, and a log nobody can read is a log nobody
  // reads when something real goes wrong.
  const fontDir =
    pathToFileURL(
      require_.resolve(["pdfjs-dist", "package.json"].join("/")).replace(/package\.json$/, ""),
    ).href + "standard_fonts/";

  const doc = await pdfjs.getDocument({
    data: bytes,
    standardFontDataUrl: fontDir,
    isEvalSupported: false,
    useSystemFonts: false,
    // A form that asks to run JavaScript or fetch something when it opens is
    // not doing that here.
    disableAutoFetch: true,
    disableStream: true,
  }).promise;

  const lines: PdfLine[] = [];

  for (let p = 1; p <= doc.numPages; p++) {
    const page = await doc.getPage(p);
    const viewport = page.getViewport({ scale: 1 });
    const content = await page.getTextContent();

    const words: PdfWord[] = [];
    for (const raw of content.items) {
      const item = raw as { str?: string; transform?: number[] };
      const text = (item.str ?? "").replace(/\s+/g, " ");
      if (!text.trim() || !item.transform) continue;
      words.push({
        x: item.transform[4],
        // pdf.js measures from the bottom; people read from the top.
        y: viewport.height - item.transform[5],
        text,
      });
    }

    lines.push(...groupIntoLines(words, p));
  }

  const plain = lines.map((l) => l.text).join("\n");

  return {
    lines,
    plain,
    pages: doc.numPages,
    // A scan often yields a stray character or two from a stamp, so "almost
    // nothing" counts as nothing.
    scanned: plain.replace(/\s/g, "").length < 40,
  };
}
