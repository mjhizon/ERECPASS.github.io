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
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !anonKey || !serviceKey) return reply(500, { ok: false, error: "Supabase function secrets are not configured." });

  const token = (request.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  if (!token) return reply(401, { ok: false, error: "Sign in as an Admin first." });
  const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: authData, error: authError } = await admin.auth.getUser(token);
  if (authError || !authData.user) return reply(401, { ok: false, error: "Your Admin session is invalid or expired." });
  const { data: caller, error: callerError } = await admin.from("profiles")
    .select("role,active").eq("id", authData.user.id).maybeSingle();
  if (callerError) return reply(500, { ok: false, error: callerError.message });
  if (!caller || caller.role !== "admin" || caller.active === false) {
    return reply(403, { ok: false, error: "Only an active Admin can create Staff accounts." });
  }

  let body: Record<string, unknown>;
  try { body = await request.json(); }
  catch { return reply(400, { ok: false, error: "Invalid request body." }); }
  const fullName = String(body.fullName || "").trim();
  const email = String(body.email || "").trim().toLowerCase();
  const password = String(body.password || "");
  const accountType = String(body.accountType || "").trim().toLowerCase();
  const professionalTitle = String(body.professionalTitle || "").trim();
  const roleTitle = accountType === "nurse" ? "Nurse" : accountType === "doctor" ? "Doctor" : "Staff";
  const task = String(body.task || "General Duty").trim();
  // Default to the safer verified flow. An Admin can temporarily turn off
  // Staff-only email confirmation with STAFF_EMAIL_VERIFICATION_REQUIRED=false.
  const requireEmailVerification = (Deno.env.get("STAFF_EMAIL_VERIFICATION_REQUIRED") || "true").trim().toLowerCase() !== "false";
  if (!fullName || !email || !password) return reply(400, { ok: false, error: "Name, email, and password are required." });
  if (!["nurse", "doctor", "other"].includes(accountType)) return reply(400, { ok: false, error: "Choose Nurse, Doctor, or Other Staff." });
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return reply(400, { ok: false, error: "Enter a valid Staff email address." });
  if (password.length < 8 || !/[#!?]/.test(password)) return reply(400, { ok: false, error: "Password must be at least 8 characters and contain one of these symbols: # ! ?" });

  const { data: created, error: createError } = await admin.auth.admin.createUser({
    email, password, email_confirm: !requireEmailVerification,
    user_metadata: { full_name: fullName, role: "staff" },
  });
  if (createError || !created.user) return reply(400, { ok: false, error: createError?.message || "Staff account could not be created." });

  const userId = created.user.id;
  if (!requireEmailVerification) {
    const { error: profileError } = await admin.from("profiles").upsert({
      id: userId, full_name: fullName, role: "staff", active: true,
    }, { onConflict: "id" });
    if (profileError) {
      await admin.auth.admin.deleteUser(userId);
      return reply(400, { ok: false, error: profileError.message });
    }
    const { error: staffError } = await admin.from("staff").upsert({
      id: userId, user_id: userId, name: fullName, email,
      account_type: accountType, professional_title: professionalTitle,
      role_title: roleTitle, task, available: true, schedule: "Mon-Sat", active: true,
    }, { onConflict: "id" });
    if (staffError) {
      await admin.auth.admin.deleteUser(userId);
      return reply(400, { ok: false, error: staffError.message });
    }
    return reply(200, { ok: true, confirmationSent: false, verificationRequired: false, staff: {
      id: userId, user_id: userId, name: fullName, email,
      role: roleTitle, account_type: accountType, professional_title: professionalTitle,
      task, available: true, schedule: "Mon-Sat", active: true,
    } });
  }

  const { error: pendingError } = await admin.from("pending_staff_accounts").insert({
    user_id: userId, email, full_name: fullName, role_title: roleTitle,
    account_type: accountType, professional_title: professionalTitle, task,
  });
  if (pendingError) {
    await admin.auth.admin.deleteUser(userId);
    return reply(400, { ok: false, error: pendingError.message });
  }

  // Sending through Supabase Auth keeps the account unconfirmed until the user
  // enters the one-time signup code. Staff/public data is finalized after verified login.
  const mailClient = createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { error: mailError } = await mailClient.auth.resend({
    type: "signup", email,
  });
  if (mailError) {
    await admin.from("pending_staff_accounts").delete().eq("user_id", userId);
    await admin.auth.admin.deleteUser(userId);
    return reply(502, { ok: false, error: "Supabase could not send the verification email: " + mailError.message });
  }

  return reply(200, { ok: true, confirmationSent: true, staff: {
    id: userId, user_id: userId, name: fullName, email,
    role: roleTitle, task, available: true, schedule: "Mon-Sat", active: true,
  } });
});
