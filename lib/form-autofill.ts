import "server-only";
import { createClient } from "@/lib/supabase/server";
import { ORG } from "@/lib/roles";
import { today } from "@/lib/constants";

/**
 * Pre-populates a new form from what the CRM already knows.
 *
 * This is the point of keeping the service log and notes: staff should not
 * retype a month of coaching hours onto USOR 95 when the system recorded them
 * as they happened. Everything filled in here is editable before signing.
 */
export async function autofillForm(
  templateId: string,
  clientId: string,
  authId: string | null,
  month: string,
): Promise<Record<string, unknown>> {
  const supabase = await createClient();

  const { data: client } = await supabase
    .from("clients")
    .select("id, name, phone, target_jobs, wsa_tier, assigned_staff_id")
    .eq("id", clientId)
    .maybeSingle();
  if (!client) return {};

  const { data: auth } = authId
    ? await supabase
        .from("authorizations")
        .select("id, number, service_type, total_hours, carried_used")
        .eq("id", authId)
        .maybeSingle()
    : { data: null };

  const latestPlacement = async () => {
    const { data } = await supabase
      .from("placements")
      .select("employer, title, start_date, wage, hours_week")
      .eq("client_id", clientId)
      .order("start_date", { ascending: false, nullsFirst: false })
      .limit(1)
      .maybeSingle();
    return data;
  };

  switch (templateId) {
    case "usor60": {
      const p = await latestPlacement();
      if (!p) return {};
      return {
        employer: p.employer,
        title: p.title,
        start: p.start_date ?? "",
        wage: p.wage ? `$${p.wage}/hr` : "",
        hours: p.hours_week ?? "",
      };
    }

    case "usor92": {
      const p = await latestPlacement();
      return { date: today(), employer: p?.employer ?? "" };
    }

    case "usor93": {
      const p = await latestPlacement();
      return { month, date: today(), employer: p?.employer ?? "" };
    }

    case "usor95": {
      const [entriesInMonth, allEntries, staffRows, placement] = await Promise.all([
        supabase
          .from("service_entries")
          .select("date, hours, staff_id, primary_code, secondary_code")
          .eq("auth_id", authId ?? "")
          .eq("non_billable", false)
          .gte("date", `${month}-01`)
          .lte("date", `${month}-31`)
          .order("date"),
        supabase
          .from("service_entries")
          .select("hours")
          .eq("auth_id", authId ?? "")
          .eq("non_billable", false),
        supabase.from("staff").select("id, name"),
        latestPlacement(),
      ]);

      const staffName = new Map((staffRows.data ?? []).map((s) => [s.id, s.name]));
      const rows = (entriesInMonth.data ?? []).map((e) => ({
        day: e.date,
        coach: e.staff_id ? (staffName.get(e.staff_id) ?? "") : "",
        hours: Number(e.hours),
        primary: e.primary_code,
        secondary: e.secondary_code,
      }));

      const coachingHours = rows.reduce((t, r) => t + r.hours, 0);
      const usedAll =
        Number(auth?.carried_used ?? 0) +
        (allEntries.data ?? []).reduce((t, e) => t + Number(e.hours), 0);
      const authorized = auth?.total_hours == null ? "" : Number(auth.total_hours);

      return {
        month,
        employer: placement?.employer ?? "",
        coachingHours,
        authorized,
        used: usedAll,
        remaining: authorized === "" ? "" : Number(authorized) - usedAll,
        rows,
      };
    }

    case "usor96": {
      const activityTypes = ["Job search", "Application submitted", "Interview", "Employer contact"];
      const { data: notes } = await supabase
        .from("notes")
        .select("at, ts, type, text")
        .eq("client_id", clientId)
        .gte("at", `${month}-01`)
        .lte("at", `${month}-31`)
        .in("type", activityTypes)
        .order("at");

      return {
        month,
        goal: client.target_jobs ?? "",
        rows: (notes ?? []).map((n) => ({
          day: n.at,
          hours: "",
          activity: n.type,
          outcome: n.text,
          next: "",
        })),
        contactPhone: ORG.phone,
        contactEmail: ORG.email,
      };
    }

    case "usor148": {
      const { data: entries } = await supabase
        .from("service_entries")
        .select("date, hours, notes")
        .eq("auth_id", authId ?? "")
        .eq("non_billable", false)
        .order("date");

      return {
        goal: client.target_jobs ?? "",
        totalHours: (entries ?? []).reduce((t, e) => t + Number(e.hours), 0),
        rows: (entries ?? []).map((e) => ({
          day: e.date,
          hours: Number(e.hours),
          activity: e.notes,
          obs: "",
        })),
        contactPhone: ORG.phone,
        contactEmail: ORG.email,
      };
    }

    case "wsa": {
      // The counselor's USOR 98 referral carries most of the client profile.
      // Copying it forward means the team is not asked the same questions
      // twice, and the two forms cannot disagree.
      const { data: referral } = await supabase
        .from("forms")
        .select("data, status")
        .eq("client_id", clientId)
        .eq("template_id", "usor98")
        .order("status")
        .limit(1)
        .maybeSingle();

      const shared = [
        "guardianship", "guardian", "extended", "extendedDetail", "insurance", "ss",
        "benefitsPlanning", "benefitsDate", "benefitsSummary", "otherServices", "skills",
        "needs", "jobs", "interpersonal", "at", "commNeeds", "behavioral", "adls",
        "family", "criminal", "school", "specialist", "acre",
      ];
      const refData = (referral?.data ?? {}) as Record<string, unknown>;
      const fromRef = Object.fromEntries(
        shared.filter((k) => refData[k] !== undefined).map((k) => [k, refData[k]]),
      );

      // Address is restricted; a staff member without access simply gets blanks.
      const { data: priv } = await supabase
        .from("client_private")
        .select("address")
        .eq("client_id", clientId)
        .maybeSingle();

      const parts = (priv?.address ?? "").split(",").map((x) => x.trim());
      const { data: staffRow } = client.assigned_staff_id
        ? await supabase.from("staff").select("name").eq("id", client.assigned_staff_id).maybeSingle()
        : { data: null };

      const tier =
        client.wsa_tier === 2
          ? "Tier 2 (incl. situational assessment)"
          : client.wsa_tier === 1
            ? "Tier 1"
            : auth?.service_type === "WSA Tier 2"
              ? "Tier 2 (incl. situational assessment)"
              : auth?.service_type === "WSA Tier 1"
                ? "Tier 1"
                : "";

      return {
        ...fromRef,
        address: parts[0] ?? "",
        city: parts[1] ?? "",
        state: parts[2] ?? "",
        zip: parts[3] ?? "",
        phone: client.phone ?? "",
        tier,
        jobs: fromRef.jobs ?? client.target_jobs ?? "",
        specialist: fromRef.specialist ?? staffRow?.name ?? "",
      };
    }

    default:
      return {};
  }
}
