// pdfjs-dist ships types for pdf.mjs but not for its worker. The worker is
// only ever handed to pdf.js as globalThis.pdfjsWorker, so its shape does not
// matter here beyond being a module.
declare module "pdfjs-dist/legacy/build/pdf.worker.mjs";
