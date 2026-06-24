import { createClient } from "jsr:@supabase/supabase-js@2";

type ResetPayload = {
  username?: string;
  newPassword?: string;
  companyName?: string;
  ceoName?: string;
  hqAirportIata?: string;
};

// Rate limiting — simple in-memory per-IP counter
const RATE_LIMIT_WINDOW = 60 * 1000; // 1 minute
const RATE_LIMIT_MAX = 5; // max 5 reset attempts per minute per IP

const rateLimitMap = new Map<string, { count: number; resetAt: number }>();

function checkRateLimit(ip: string): boolean {
  const now = Date.now();
  const entry = rateLimitMap.get(ip);

  if (!entry || now > entry.resetAt) {
    rateLimitMap.set(ip, { count: 1, resetAt: now + RATE_LIMIT_WINDOW });
    return true;
  }

  if (entry.count >= RATE_LIMIT_MAX) {
    return false;
  }

  entry.count++;
  return true;
}

// CORS — restrict to allowed origins
// NOTE: APP_URL must be set as a Supabase secret (e.g. "https://skyward.sachiel.id")
// for production CORS to work. Without it, only localhost origins are allowed.
const allowedOrigins = [
  Deno.env.get("APP_URL") || "",
  "http://localhost:3000",
  "http://localhost:5173",
].filter(Boolean);

function isOriginAllowed(origin: string): boolean {
  if (allowedOrigins.includes(origin)) return true;
  if (/^http:\/\/localhost:\d+$/.test(origin)) return true;
  return false;
}

function getCorsHeaders(req: Request): Record<string, string> {
  const origin = req.headers.get("origin") || "";
  const corsOrigin = isOriginAllowed(origin) ? origin : "";
  return {
    "Access-Control-Allow-Origin": corsOrigin,
    "Access-Control-Allow-Headers":
      "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
  };
}

function jsonResponse(
  status: number,
  body: Record<string, unknown>,
  req?: Request,
) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...(req ? getCorsHeaders(req) : {}),
      "Content-Type": "application/json",
    },
  });
}

function extractClientIp(req: Request): string {
  const xff = req.headers.get("x-forwarded-for") || "";
  const parts = xff.split(",").map((s) => s.trim()).filter(Boolean);
  return parts.length > 0
    ? parts[parts.length - 1]
    : req.headers.get("x-real-ip") || "unknown";
}

function normalizeUsername(username: string): string {
  return username
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9._-]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

function buildSyntheticAuthEmail(username: string): string {
  return `${normalizeUsername(username)}@skyward.sachiel.id`;
}

function resolveServiceRoleKey(): string | null {
  const explicitServiceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (explicitServiceRoleKey) {
    return explicitServiceRoleKey;
  }

  const bundledSecretKeys = Deno.env.get("SUPABASE_SECRET_KEYS");
  if (!bundledSecretKeys) {
    return null;
  }

  try {
    const parsed = JSON.parse(bundledSecretKeys) as Record<string, string>;
    const firstSecretKey = Object.values(parsed).find((value) => !!value);
    return firstSecretKey ?? null;
  } catch {
    return null;
  }
}

Deno.serve(async (request) => {
  // Reject requests from unknown origins (skip for preflight)
  const requestOrigin = request.headers.get("origin") || "";
  if (requestOrigin && !isOriginAllowed(requestOrigin)) {
    return new Response("Forbidden", { status: 403 });
  }

  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: getCorsHeaders(request) });
  }

  // Rate limiting
  const ip = extractClientIp(request);
  if (!checkRateLimit(ip)) {
    return jsonResponse(429, {
      success: false,
      message: "Too many reset attempts. Please try again later.",
    }, request);
  }

  if (request.method !== "POST") {
    return jsonResponse(405, {
      success: false,
      message: "Method not allowed.",
    }, request);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = resolveServiceRoleKey();

  if (!supabaseUrl || !serviceRoleKey) {
    return jsonResponse(500, {
      success: false,
      message: "Supabase server credentials are not configured for this function.",
    }, request);
  }

  let payload: ResetPayload;
  try {
    payload = await request.json();
  } catch {
    return jsonResponse(400, {
      success: false,
      message: "Invalid JSON payload.",
    }, request);
  }

  const username = normalizeUsername(payload.username ?? "");
  const newPassword = payload.newPassword?.trim() ?? "";
  const companyName = payload.companyName?.trim() ?? "";
  const ceoName = payload.ceoName?.trim() ?? "";
  const hqAirportIata = payload.hqAirportIata?.trim().toUpperCase() ?? "";

  // Validate inputs
  if (!username || username.length < 4) {
    return jsonResponse(400, {
      success: false,
      message: "Username must be at least 4 characters.",
    }, request);
  }

  if (!newPassword || newPassword.length < 8) {
    return jsonResponse(400, {
      success: false,
      message: "New password must be at least 8 characters.",
    }, request);
  }

  const MAX_PASSWORD_LENGTH = 128;
  if (newPassword.length > MAX_PASSWORD_LENGTH) {
    return jsonResponse(400, {
      success: false,
      message: "Password must not exceed 128 characters.",
    }, request);
  }

  // Must provide at least 2 verification fields
  const verificationFields = [companyName, ceoName, hqAirportIata].filter(
    (v) => v.length > 0,
  );
  if (verificationFields.length < 2) {
    return jsonResponse(400, {
      success: false,
      message: "Please provide at least 2 verification fields.",
    }, request);
  }

  const supabase = createClient(supabaseUrl, serviceRoleKey, {
    auth: {
      autoRefreshToken: false,
      persistSession: false,
    },
  });

  // Step 1: Look up the user profile
  const { data: userProfile, error: lookupError } = await supabase
    .from("users")
    .select("id, auth_user_id, company_name, ceo_name, hq_airport_iata")
    .eq("username", username)
    .maybeSingle();

  if (lookupError) {
    console.error("reset-password lookup failed", { message: lookupError.message });
    return jsonResponse(500, {
      success: false,
      message: "Failed to look up account.",
    }, request);
  }

  if (!userProfile) {
    // Don't reveal whether username exists — return generic error
    return jsonResponse(400, {
      success: false,
      message: "Verification failed. Please check your answers.",
    }, request);
  }

  if (!userProfile.auth_user_id) {
    return jsonResponse(400, {
      success: false,
      message: "This account does not have authentication enabled.",
    }, request);
  }

  // Step 2: Verify at least 2 of 3 fields
  let matchCount = 0;
  if (
    companyName &&
    companyName.toLowerCase() ===
      (userProfile.company_name ?? "").toLowerCase()
  ) {
    matchCount++;
  }
  if (
    ceoName &&
    ceoName.toLowerCase() === (userProfile.ceo_name ?? "").toLowerCase()
  ) {
    matchCount++;
  }
  if (
    hqAirportIata &&
    hqAirportIata === (userProfile.hq_airport_iata ?? "").toUpperCase()
  ) {
    matchCount++;
  }

  if (matchCount < 2) {
    return jsonResponse(400, {
      success: false,
      message: "Verification failed. Please check your answers.",
    }, request);
  }

  // Step 3: Update password via Admin API
  const { error: updateError } = await supabase.auth.admin.updateUserById(
    userProfile.auth_user_id,
    { password: newPassword },
  );

  if (updateError) {
    console.error("reset-password updateUserById failed", {
      message: updateError.message,
    });
    return jsonResponse(500, {
      success: false,
      message: "Failed to update password. Please try again.",
    }, request);
  }

  return jsonResponse(200, {
    success: true,
    message: "Password updated successfully.",
  }, request);
});
