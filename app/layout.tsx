import type { Metadata } from "next";
import { Inter, Source_Serif_4 } from "next/font/google";
import "./tokens.css";
import "./globals.css";

// Both open-licence. next/font downloads them at build time and serves them
// from this application - no request to a font service when a page loads -
// subset to Latin and swapped in rather than holding back the text.
const inter = Inter({ subsets: ["latin"], display: "swap", variable: "--font-inter" });
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
