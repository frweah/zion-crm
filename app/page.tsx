import { redirect } from "next/navigation";
import { getCurrentStaff } from "@/lib/session";

/**
 * Where a person lands.
 *
 * Somebody with a caseload lands on their caseload: Job Search and Intake &
 * Client Reports start the day asking who they are seeing and what those
 * people need, not what is happening across the practice. Admin and Billing
 * land on the dashboard, which is the practice-wide view they do want.
 */
export default async function Home() {
  const me = await getCurrentStaff();
  redirect(me && (me.role === "Job Search" || me.role === "Reports") ? "/my-clients" : "/dashboard");
}
