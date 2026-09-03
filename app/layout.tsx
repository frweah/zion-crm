import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Zion Vocational Rehab CRM",
  description: "Client, billing and reporting system for Zion Vocational Rehabilitation Center.",
  robots: { index: false, follow: false },
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
