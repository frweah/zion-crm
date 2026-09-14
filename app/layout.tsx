import type { Metadata } from "next";
import localFont from "next/font/local";
import { Source_Serif_4 } from "next/font/google";
import "./tokens.css";
import "./globals.css";

// Inter, hinted, from Inter's own release (v4.1, extras/woff-hinted), kept in
// this application and served from it. The Inter next/font fetches from Google
// is the unhinted variable font - none of its files carry fpgm, prep or cvt -
// and on Windows at 14px it rendered soft. The hinted statics carry the
// instructions that snap stems to whole pixels. Four weights, because those are
// the ones used: 400 body, 500 labels and the sidebar, 600 emphasis, 700 <b>.
// SIL Open Font License; the licence is beside the files.
const inter = localFont({
  src: [
    { path: "./fonts/inter/Inter-Regular.woff2", weight: "400", style: "normal" },
    { path: "./fonts/inter/Inter-Medium.woff2", weight: "500", style: "normal" },
    { path: "./fonts/inter/Inter-SemiBold.woff2", weight: "600", style: "normal" },
    { path: "./fonts/inter/Inter-Bold.woff2", weight: "700", style: "normal" },
  ],
  display: "swap",
  variable: "--font-inter",
});

// Open licence. next/font downloads it at build time and serves it from this
// application - no request to a font service when a page loads - subset to
// Latin and swapped in rather than holding back the text.
const serif = Source_Serif_4({ subsets: ["latin"], display: "swap", variable: "--font-source-serif" });

export const metadata: Metadata = {
  title: "Zion Vocational Rehab CRM",
  description: "Client, billing and reporting system for Zion Vocational Rehabilitation Center.",
  robots: { index: false, follow: false },
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className={`${inter.variable} ${serif.variable}`}>
      <body>{children}</body>
    </html>
  );
}
