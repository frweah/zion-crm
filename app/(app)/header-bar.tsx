"use client";

import { Bell } from "./bell";
import { AvatarMenu } from "./avatar-menu";
import { useUnreadMessages } from "./live-messaging";

/**
 * The right-hand end of the header: what is waiting, and who you are.
 *
 * It reads the same live count the Inbox badge does, so the bell and the
 * sidebar cannot disagree about how much is waiting - which was the whole
 * complaint behind the audit's "83 against 19" (Design language, §1).
 */
export function HeaderBar({ name, role, extra }: { name: string; role: string; extra?: string }) {
  const waiting = useUnreadMessages();
  return (
    <div className="header-right no-print">
      <Bell waiting={waiting} />
      <AvatarMenu name={name} role={role} extra={extra} />
    </div>
  );
}
