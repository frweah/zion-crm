/** @type {import('next').NextConfig} */
const nextConfig = {
  // The IRS PDFs are read at runtime; without this they are not deployed.
  outputFileTracingIncludes: {
    "/paperwork": ["./assets/irs-forms/**"],
    "/api/**": ["./assets/irs-forms/**"],
  },
  reactStrictMode: true,
};

export default nextConfig;
