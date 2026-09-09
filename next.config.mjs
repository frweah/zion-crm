/** @type {import('next').NextConfig} */
const nextConfig = {
  // The IRS PDFs are read at runtime; without this they are not deployed.
  outputFileTracingIncludes: {
    "/paperwork": ["./assets/irs-forms/**"],
    "/api/**": ["./assets/irs-forms/**"],
    // pdf.js loads its worker from disk at runtime.
    "/billing/import": [
      "./node_modules/pdfjs-dist/legacy/build/**",
      "./node_modules/pdfjs-dist/standard_fonts/**",
    ],
  },
  // pdf.js reads a worker file from its own package at runtime. Bundling it
  // would leave that file behind, so it stays external and is loaded from
  // node_modules where it can find its own pieces.
  serverExternalPackages: ["pdfjs-dist"],
  reactStrictMode: true,
};

export default nextConfig;
