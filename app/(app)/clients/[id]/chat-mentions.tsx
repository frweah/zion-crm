import Link from "next/link";
import { TeamsMeetingButton } from "../../team/meeting-button";

export type Mention = {
  message_id: string | null;
  conversation_id: string | null;
  created_at: string | null;
  sender_label: string | null;
  thread: string | null;
};

/**
 * Mentioned in Team chat (owner, 30 Oct 2026).
 *
 * A link and never the words. Somebody naming a client in a thread is not
 * writing a note about them - the thread is a conversation between colleagues,
 * and what was said there belongs to the people in it until one of them
 * decides it belongs on the record and files it.
 *
 * So this says that a thread named this person, when, and who was talking, and
 * opens the thread for anybody who is in it. The database refuses the thread
 * to anybody who is not, which is why the link can be offered to everybody who
 * can see the record.
 */
export function ChatMentions({
  clientId,
  clientName,
  mentions,
}: {
  clientId: string;
  clientName: string;
  mentions: Mention[];
}) {
  return (
    <section style={{ marginTop: 22 }}>
      <h2 className="h2">Team chat</h2>
      <div className="card" style={{ display: "grid", gap: 8 }}>
        {mentions.length === 0 ? (
          <div className="empty">Not mentioned in a staff thread — start a meeting if you need one.</div>
        ) : (
          <ul style={{ margin: 0, paddingLeft: 18, display: "grid", gap: 4 }}>
            {mentions.map((m) => (
              <li key={m.message_id}>
                <b>{m.sender_label || "A colleague"}</b> in {m.thread || "a thread"} ·{" "}
                {m.created_at?.slice(0, 10)}{" "}
                <Link className="linkish" href={`/team?c=${m.conversation_id}`}>
                  Open the thread
                </Link>
              </li>
            ))}
          </ul>
        )}
        <TeamsMeetingButton clientId={clientId} subject={`Zion Voc Rehab — ${clientName}`} />
      </div>
    </section>
  );
}
