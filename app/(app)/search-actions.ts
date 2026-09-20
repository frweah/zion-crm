"use server";

import { createClient } from "@/lib/supabase/server";

/**
 * Finding a client from anywhere (Ctrl+K).
 *
 * The matching is the database's (search_clients, 0109) so that what the box
 * finds and what anything else finds are the same thing. With nothing typed
 * it answers with the records this person has had open lately, which is the
 * common case: you are coming back to somebody you were just with.
 */
export type Found = {
  id: string;
  name: string;
  client_no: number | null;
  stage: string | null;
  status: string | null;
  assigned_name: string | null;
  counselor_name: string | null;
  recent: boolean | null;
};

export async function findClients(query: string): Promise<Found[]> {
  const supabase = await createClient();
  const { data } = await supabase.rpc("search_clients", { p_query: query.slice(0, 80), p_limit: 12 });
  return (data ?? []) as Found[];
}
