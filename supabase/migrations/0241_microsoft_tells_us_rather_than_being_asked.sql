-- Zion Vocational Rehab CRM — 0241 Microsoft tells us rather than being asked
--
-- Mail reaches the CRM when the sweep runs, every fifteen minutes. That is
-- fine for a log and useless for a reply somebody is waiting on: a counselor
-- answers, and for up to a quarter of an hour the client's record says
-- nothing happened (owner, 23 Oct 2026, "new mail appears within a minute").
--
-- Microsoft will say so instead. A change notification subscription on a
-- mailbox's inbox posts to the CRM when something arrives, and the CRM syncs
-- that one mailbox. This table is the record of those subscriptions: which
-- mailbox, Microsoft's id for it, when it expires, and the secret the
-- notification has to carry.
--
-- **The poll stays.** A subscription is a delegated one, tied to a token that
-- can be revoked, and it expires inside three days whatever happens. Anything
-- that depends on a webhook arriving needs something behind it that does not,
-- and the fifteen-minute sweep is that. The subscription makes mail arrive
-- sooner; it is not what makes it arrive.
--
-- `client_state` is per subscription rather than one secret in the
-- environment: a notification that does not carry the exact string this row
-- holds is not about this mailbox, and nothing has to be issued by hand for
-- that to be true.

create table if not exists public.microsoft_subscriptions (
  -- One per mailbox. A person's own mailbox is their staff row; a shared
  -- mailbox is its address, and the person whose token subscribed to it.
  staff_id        uuid not null references public.staff(id) on delete cascade,
  mailbox_address text not null default '',
  subscription_id text not null default '',
  client_state    text not null,
  expires_at      timestamptz,
  created_at      timestamptz not null default now(),
  renewed_at      timestamptz,
  last_notified_at timestamptz,
  notifications   integer not null default 0,
  last_error      text not null default '',
  primary key (staff_id, mailbox_address)
);

comment on table public.microsoft_subscriptions is
  'Microsoft change notification subscriptions, one per mailbox. The fifteen-minute sweep creates, renews and outlives them (0241).';

create unique index if not exists microsoft_subscriptions_by_id
  on public.microsoft_subscriptions (subscription_id)
  where subscription_id <> '';

alter table public.microsoft_subscriptions enable row level security;

-- Nobody signed in reads or writes this. It holds a secret that proves a
-- notification is genuine, and the only thing that needs it is the sweep and
-- the webhook, both of which run as the service role.
drop policy if exists microsoft_subscriptions_admin_read on public.microsoft_subscriptions;
create policy microsoft_subscriptions_admin_read on public.microsoft_subscriptions
  for select using ((select public.is_admin()));

revoke all on table public.microsoft_subscriptions from anon, authenticated;
grant select on table public.microsoft_subscriptions to authenticated;
