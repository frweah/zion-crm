/** @type {import('next').NextConfig} */
const nextConfig = {
  // The IRS PDFs are read at runtime; without this they are not deployed.
  outputFileTracingIncludes: {
    "/paperwork": ["./assets/irs-forms/**"],
    "/api/**": ["./assets/irs-forms/**"],
    // pdf.js's worker and fonts. The worker no longer depends on this entry:
    // lib/pdf-text.ts imports it with a literal specifier, which is what gets
    // it traced. This entry never delivered it - the build trace for
    // /billing/import listed neither the worker nor any font - and it is kept
    // only as a marker until the fonts are shipped some other way.
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
   * Screens that moved. Anything anybody bookmarked, linked in an email, or
   * wrote into a note still lands in the right place. Two rounds: the screens
   * moved into groups, then the consolidation (September 2026) put Admin's nine
   * screens on three pages and Revenue and Referrals in Insights. Each old path
   * goes straight to where it is now, never through a second redirect.
   *
   * Not permanent: a 308 is cached by the browser for good, and being unable
   * to reuse a path because of a redirect somebody set once is a bad trade for
   * a saving nobody measures.
   */
  async redirects() {
    const moved = {
      "/needs": "/dashboard/needs",
      "/forms": "/billing/forms",
      "/revenue": "/insights/money",
      "/reports": "/insights/reports",
      "/outcomes": "/insights/outcomes",
      "/capacity": "/insights/capacity",
      "/staff": "/admin/people",
      "/contractors": "/admin/people#contractors",
      "/exports": "/billing/export",
      "/referrals": "/insights/referrals",
      "/billing/revenue": "/insights/money",
      "/billing/position": "/billing?tab=invoices#paid-and-outstanding",
      "/admin/staff": "/admin/people",
      "/admin/contractors": "/admin/people#contractors",
      "/admin/inbox": "/admin/documents",
      "/admin/retention": "/admin/documents#retention",
      "/admin/records-request": "/admin/documents#records-requests",
      "/admin/records-request/:id": "/admin/documents/records-request/:id",
      "/admin/settings": "/admin/system",
      "/admin/note-templates": "/admin/system#note-headings",
      "/admin/access": "/admin/system#access-log",
      "/admin/exports": "/billing/export",
      // Paths that never had a page but were typed or linked anyway (punch
      // list #14, 20 Sept 2026): Admin opens on People, and the documents
      // inbox is Admin -> Documents wherever somebody went looking for it.
      "/admin": "/admin/people",
      "/documents": "/admin/documents",
      "/billing/admin": "/admin/documents",
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
