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
  /**
   * The screens moved into groups. Anything anybody bookmarked, linked in an
   * email, or wrote into a note still lands in the right place.
   *
   * Not permanent: a 308 is cached by the browser for good, and being unable
   * to reuse a path because of a redirect somebody set once is a bad trade for
   * a saving nobody measures.
   */
  async redirects() {
    const moved = {
      "/needs": "/dashboard/needs",
      "/forms": "/billing/forms",
      "/revenue": "/billing/revenue",
      "/reports": "/insights/reports",
      "/outcomes": "/insights/outcomes",
      "/capacity": "/insights/capacity",
      "/staff": "/admin/staff",
      "/contractors": "/admin/contractors",
      "/exports": "/admin/exports",
    };
    return Object.entries(moved).map(([source, destination]) => ({
      source,
      destination,
      permanent: false,
    }));
  },

  reactStrictMode: true,
};

export default nextConfig;
