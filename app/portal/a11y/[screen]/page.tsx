import type { Metadata } from "next";
import { notFound } from "next/navigation";
import type { PortalMe } from "@/lib/portal/session";
import v1 from "../../../../supabase/portal-terms/v1.json";
import {
  SignInView,
  VerifyView,
  ConsentView,
  HomeView,
  SettingsView,
  TermsView,
  MessagesView,
  DocumentsView,
  type Terms,
} from "../../_components/views";

export const dynamic = "force-dynamic";

/**
 * The portal's screens drawn from made-up people, for scripts/check-a11y.mjs.
 *
 * Every screen past sign-in needs a live session to reach, and the build has
 * none, so the check draws the same view components here instead. Answers 404
 * unless the server was started with A11Y_FIXTURES=1, which only the check does.
 *
 * "broken" is deliberately inaccessible. The check fails if it passes: a check
 * that cannot fail is not checking anything.
 */

const terms = v1 as Terms;

const client: PortalMe = {
  account_id: "00000000-0000-4000-8000-000000000001",
  kind: "Client",
  name: "ZZ Example Client",
  relationship: "",
  client_first_name: "ZZ",
  staff_first_name: "ZZStaff",
  terms_version: terms.version,
  electronic: true,
  texts: false,
  phone_last4: "0101",
};
const notYet: PortalMe = { ...client, electronic: false, staff_first_name: null };
const guardian: PortalMe = {
  ...notYet,
  kind: "Guardian",
  name: "ZZ Example Guardian",
  relationship: "Mother",
};

const SCREENS: Record<string, { title: string; draw: () => React.ReactNode }> = {
  "sign-in-error": {
    title: "Sign in",
    draw: () => (
      <SignInView initial={{ error: "Enter a 10-digit mobile number, like 801-555-0123.", value: "801" }} />
    ),
  },
  verify: { title: "Enter your code", draw: () => <VerifyView via="text" /> },
  "verify-error": {
    title: "Enter your code",
    draw: () => (
      <VerifyView
        via="email"
        initial={{ error: "That code has expired. Codes work for 10 minutes. Ask for a new code.", restart: true }}
      />
    ),
  },
  consent: { title: "Portal terms and consent", draw: () => <ConsentView me={notYet} terms={terms} /> },
  "consent-guardian": {
    title: "Portal terms and consent",
    draw: () => <ConsentView me={guardian} terms={terms} initial={{ error: "The portal terms are not in force yet." }} />,
  },
  "consent-withdrawn": {
    title: "Portal terms and consent",
    draw: () => <ConsentView me={{ ...notYet, texts: true }} terms={terms} withdrawn />,
  },
  home: { title: "Home", draw: () => <HomeView me={client} /> },
  "home-unread": { title: "Home", draw: () => <HomeView me={client} unread={2} /> },
  messages: {
    title: "Messages",
    draw: () => (
      <MessagesView
        me={client}
        messages={[
          { seq: 1, mine: false, sender: "ZZStaff", body: "Hi ZZ, can you send me your resume?", created_at: "2026-10-20T16:00:00Z" },
          { seq: 2, mine: true, sender: "You", body: "I do not have one yet.", created_at: "2026-10-20T17:30:00Z" },
        ]}
      />
    ),
  },
  documents: {
    title: "Documents",
    draw: () => (
      <DocumentsView
        me={client}
        requests={[
          { id: "00000000-0000-4000-8000-0000000000a1", name: "Resume", note: "Your most recent one.", due: "2026-11-02", status: "Open", return_reason: "", filename: null, answered_at: null, created_at: "2026-10-20T16:00:00Z" },
          { id: "00000000-0000-4000-8000-0000000000a2", name: "Photo ID", note: "", due: null, status: "Returned", return_reason: "The photo is blurry.", filename: null, answered_at: null, created_at: "2026-10-19T16:00:00Z" },
          { id: "00000000-0000-4000-8000-0000000000a3", name: "Social Security card", note: "", due: null, status: "Answered", return_reason: "", filename: "card.jpg", answered_at: "2026-10-20T18:00:00Z", created_at: "2026-10-18T16:00:00Z" },
        ]}
      />
    ),
  },
  "home-requests": { title: "Home", draw: () => <HomeView me={client} unread={1} openRequests={2} /> },
  "messages-empty": { title: "Messages", draw: () => <MessagesView me={client} messages={[]} /> },
  "settings-alerts": {
    title: "Settings",
    draw: () => <SettingsView me={client} options={{ channel: "Email", can_text: false, has_email: true }} />,
  },
  settings: { title: "Settings", draw: () => <SettingsView me={client} /> },
  "settings-texts-on": {
    title: "Settings",
    draw: () => <SettingsView me={{ ...client, texts: true, kind: "Guardian", relationship: "Father" }} notice="on" />,
  },
  terms: { title: "Portal terms and privacy", draw: () => <TermsView terms={terms} /> },
  "idle-warning": { title: "Home", draw: () => <HomeView me={client} idlePreview /> },
  broken: {
    title: "Broken on purpose",
    draw: () => (
      <main id="main" className="portal-wrap portal-main">
        <h1>Broken on purpose</h1>
        <input type="text" name="unlabelled" />
        <p style={{ color: "var(--line)" }}>Text nobody can read against the page.</p>
        <button type="button" style={{ outline: "none", boxShadow: "none" }} className="a11y-no-focus">
          Focus you cannot see
        </button>
      </main>
    ),
  },
};

export async function generateMetadata({ params }: { params: Promise<{ screen: string }> }): Promise<Metadata> {
  const { screen } = await params;
  return { title: SCREENS[screen]?.title ?? "Not found" };
}

export default async function PortalFixture({ params }: { params: Promise<{ screen: string }> }) {
  if (process.env.A11Y_FIXTURES !== "1") notFound();
  const { screen } = await params;
  const fixture = SCREENS[screen];
  if (!fixture) notFound();
  return (
    <>
      {screen === "broken" && <style>{".a11y-no-focus:focus, .a11y-no-focus:focus-visible { outline: none !important; }"}</style>}
      {fixture.draw()}
    </>
  );
}
