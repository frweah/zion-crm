/**
 * Both tables added this week carry the house rule (0295).
 *
 * No automated account may write. `inbox_scan_requests` (0382) and
 * `agent_heartbeat` (0383) were both written with their own policies and
 * neither called `apply_system_read_only`, which `verify_system_account.sql`
 * found by asking the catalog rather than the author: every table with row
 * level security has the three `system_read_only_*` policies, and two did
 * not.
 *
 * Neither was reachable in practice - the heartbeat refuses every write from
 * anybody signed in, and asking for a pass needs Admin or a billing edit
 * grant, which no automated account has - so this is the rule being written
 * where the next reader looks for it rather than a hole being closed. It is
 * also the second time a new table has needed this, which is why the check
 * asks the catalog.
 *
 * Tolerates the old code: three restrictive policies that refuse writes from
 * an account nothing deployed signs in as.
 */

select public.apply_system_read_only('public.inbox_scan_requests'::regclass);
select public.apply_system_read_only('public.agent_heartbeat'::regclass);
