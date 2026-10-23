import "server-only";

/**
 * Subscribing a mailbox to Microsoft's change notifications (0241).
 *
 * The sweep runs every fifteen minutes and that is what makes mail arrive. A
 * subscription makes it arrive sooner: Microsoft posts to the CRM when
 * something lands in an inbox, and the webhook syncs that one mailbox.
 *
 * Three things this file is careful about, each of which has its own failure:
 *
 *   A subscription expires. Delegated mail subscriptions last at most three
 *   days, and Microsoft is strict about the maximum - ask for longer and the
 *   whole request is refused. So the expiry asked for is just under the
 *   limit, and the sweep renews anything inside its last few hours.
 *
 *   A subscription is tied to the token that made it. When somebody
 *   disconnects Outlook, or their refresh token is revoked, the subscription
 *   stops delivering and Microsoft eventually drops it. Nothing here treats
 *   that as an error worth shouting about - the poll covers it.
 *
 *   Microsoft validates the endpoint before creating the subscription, by
 *   posting a token the endpoint must echo back within ten seconds. If the
 *   deploy is not live yet, or the route is behind the session middleware,
 *   creation fails with a message about validation - which is a deploy
 *   problem and not a mail problem, and is recorded as such.
 */

const GRAPH = "https://graph.microsoft.com/v1.0";

/**
 * Just under Microsoft's maximum for a delegated mail subscription (4230
 * minutes). Asking for the maximum exactly has been known to be refused on
 * clock skew alone, so this leaves half an hour.
 */
const MINUTES = 4200;

export type Subscription = { id: string; expiresAt: string };

const expiry = () => new Date(Date.now() + MINUTES * 60 * 1000).toISOString();

/**
 * Where Microsoft posts. Public, and so it proves itself rather than being
 * trusted.
 *
 * The same address the Microsoft sign-in already redirects to, because it is
 * the same question - where does this deployment live - and a second answer
 * to it is a second thing to get wrong. Nothing is subscribed from a local
 * machine: Microsoft cannot reach localhost, and a subscription pointing at
 * one would be created and then silently never deliver.
 */
export function notifyUrl(): string {
  const base = (process.env.NEXT_PUBLIC_SITE_URL ?? "").replace(/\/$/, "");
  if (!base || /localhost|127\.0\.0\.1/.test(base)) return "";
  return `${base}/api/graph/notify`;
}

async function graph<T>(token: string, path: string, init: RequestInit): Promise<T> {
  const response = await fetch(`${GRAPH}${path}`, {
    ...init,
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json", ...(init.headers ?? {}) },
    cache: "no-store",
  });
  if (!response.ok) {
    let detail = response.statusText;
    try {
      const data = (await response.json()) as { error?: { message?: string } };
      detail = data.error?.message ?? detail;
    } catch {
      // the status says enough
    }
    throw new Error(`Microsoft refused (${response.status}): ${detail}`);
  }
  return (response.status === 204 ? (null as T) : ((await response.json()) as T));
}

/**
 * Subscribe to a mailbox's inbox.
 *
 * `mailbox` empty means the token's own mailbox. A shared one is named, and
 * works only where Exchange has given this person access to it - the same
 * access the Mail screen already checks before reading it.
 */
export async function subscribe(
  token: string,
  mailbox: string,
  clientState: string,
): Promise<Subscription> {
  const url = notifyUrl();
  if (!url) throw new Error("There is no public address for Microsoft to post to, so nothing was subscribed.");

  const resource = mailbox
    ? `/users/${encodeURIComponent(mailbox)}/mailFolders('inbox')/messages`
    : "/me/mailFolders('inbox')/messages";

  const made = await graph<{ id: string; expirationDateTime: string }>(token, "/subscriptions", {
    method: "POST",
    body: JSON.stringify({
      changeType: "created",
      notificationUrl: url,
      resource,
      expirationDateTime: expiry(),
      clientState,
      // Nothing about the message itself is asked for. The notification says
      // a mailbox changed and the CRM goes and looks, which is the only shape
      // that keeps "nothing is stored unless filed" true: a payload with the
      // message in it would be a message body arriving uninvited.
      includeResourceData: false,
    }),
  });

  return { id: made.id, expiresAt: made.expirationDateTime };
}

/** Push an existing subscription's expiry out again. */
export async function renew(token: string, subscriptionId: string): Promise<Subscription> {
  const done = await graph<{ id: string; expirationDateTime: string }>(
    token,
    `/subscriptions/${encodeURIComponent(subscriptionId)}`,
    { method: "PATCH", body: JSON.stringify({ expirationDateTime: expiry() }) },
  );
  return { id: done.id, expiresAt: done.expirationDateTime };
}

/** Let one go, when a mailbox is disconnected. */
export async function unsubscribe(token: string, subscriptionId: string): Promise<void> {
  await graph<null>(token, `/subscriptions/${encodeURIComponent(subscriptionId)}`, { method: "DELETE" });
}
