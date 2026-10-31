import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const reply = (status: number, value: Record<string, unknown>) => new Response(JSON.stringify(value), {
  status, headers: { ...cors, "Content-Type": "application/json" },
});

Deno.serve(async (request: Request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (request.method !== "POST") return reply(405, { ok: false, error: "Method not allowed." });

  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceKey) return reply(500, { ok: false, error: "Supabase function secrets are not configured." });
  const token = (request.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  if (!token) return reply(401, { ok: false, error: "Sign in with the verified Staff account first." });

  const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: authData, error: authError } = await admin.auth.getUser(token);
  const user = authData.user;
  if (authError || !user) return reply(401, { ok: false, error: "Your Supabase session is invalid or expired." });
  if (!user.email_confirmed_at) return reply(403, { ok: false, error: "Verify your Supabase email before finishing Staff setup." });

  const { data: pending, error: pendingError } = await admin
    .from("pending_staff_accounts").select("user_id,email,full_name,role_title,account_type,professional_title,task")
    .eq("user_id", user.id).maybeSingle();
  if (pendingError) return reply(500, { ok: false, error: pendingError.message });

  // Existing Staff accounts that were already finalized can continue to log in.
  if (!pending) {
    const { data: profile, error: profileError } = await admin.from("profiles")
      .select("role").eq("id", user.id).maybeSingle();
    if (profileError) return reply(500, { ok: false, error: profileError.message });
    const { data: staff, error: staffError } = await admin.from("staff")
      .select("id").eq("user_id", user.id).maybeSingle();
    if (staffError) return reply(500, { ok: false, error: staffError.message });
    if (profile?.role === "staff" && staff) return reply(200, { ok: true, alreadyComplete: true });
    return reply(404, { ok: false, error: "No pending Staff invitation was found for this account." });
  }

  if (String(user.email || "").toLowerCase() !== String(pending.email || "").toLowerCase()) {
    return reply(403, { ok: false, error: "The verified email does not match the Staff invitation." });
  }

  const { error: profileSaveError } = await admin.from("profiles").upsert({
    id: user.id, full_name: pending.full_name, role: "staff", active: true,
  }, { onConflict: "id" });
  if (profileSaveError) return reply(400, { ok: false, error: profileSaveError.message });

  const staffRow = {
    id: user.id, user_id: user.id, name: pending.full_name, email: pending.email,
    role_title: pending.role_title, account_type: pending.account_type,
    professional_title: pending.professional_title, task: pending.task,
    available: true, schedule: "Mon-Sat", active: true,
  };
  const { error: staffSaveError } = await admin.from("staff").upsert(staffRow, { onConflict: "id" });
  if (staffSaveError) return reply(400, { ok: false, error: staffSaveError.message });

  const { error: deleteError } = await admin.from("pending_staff_accounts")
    .delete().eq("user_id", user.id);
  if (deleteError) return reply(500, { ok: false, error: deleteError.message });

  return reply(200, { ok: true });
});
