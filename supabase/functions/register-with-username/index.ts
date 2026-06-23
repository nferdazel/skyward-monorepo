import { createClient } from "jsr:@supabase/supabase-js@2";

type RegisterPayload = {
  username?: string;
  password?: string;
  companyName?: string;
  ceoName?: string;
};

// Rate limiting — simple in-memory per-IP counter
const RATE_LIMIT_WINDOW = 60 * 1000; // 1 minute
const RATE_LIMIT_MAX = 5; // max 5 registrations per minute per IP

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
const allowedOrigins = [
  Deno.env.get("APP_URL") || "",
  "http://localhost:3000",
  "http://localhost:5173",
].filter(Boolean);

function getCorsHeaders(req: Request): Record<string, string> {
  const origin = req.headers.get("origin") || "";
  const corsOrigin = allowedOrigins.includes(origin) ? origin : "";
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
  if (requestOrigin && !allowedOrigins.includes(requestOrigin)) {
    return new Response("Forbidden", { status: 403 });
  }

  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: getCorsHeaders(request) });
  }

  // Rate limiting
  const ip = request.headers.get("x-forwarded-for") ||
    request.headers.get("x-real-ip") || "unknown";
  if (!checkRateLimit(ip)) {
    return jsonResponse(429, {
      success: false,
      message: "Too many registration attempts. Please try again later.",
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

  let payload: RegisterPayload;
  try {
    payload = await request.json();
  } catch {
    return jsonResponse(400, {
      success: false,
      message: "Invalid JSON payload.",
    }, request);
  }

  const username = normalizeUsername(payload.username ?? "");
  const password = payload.password?.trim() ?? "";
  const companyName = payload.companyName?.trim() ?? "";
  const ceoName = payload.ceoName?.trim() ?? "";

  if (!username || username.length < 4) {
    return jsonResponse(400, {
      success: false,
      message: "Username must be at least 4 characters.",
    }, request);
  }

  if (!password || password.length < 6) {
    return jsonResponse(400, {
      success: false,
      message: "Password must be at least 6 characters.",
    }, request);
  }

  if (!companyName) {
    return jsonResponse(400, {
      success: false,
      message: "Company name is required.",
    }, request);
  }

  if (!ceoName) {
    return jsonResponse(400, {
      success: false,
      message: "CEO name is required.",
    }, request);
  }

  const authEmail = buildSyntheticAuthEmail(username);
  const supabase = createClient(supabaseUrl, serviceRoleKey, {
    auth: {
      autoRefreshToken: false,
      persistSession: false,
    },
  });

  const { data, error } = await supabase.auth.admin.createUser({
    email: authEmail,
    password,
    email_confirm: true,
    user_metadata: {
      username,
      company_name: companyName,
      ceo_name: ceoName,
    },
  });

  if (error) {
    console.error("register-with-username createUser failed", {
      message: error.message,
      name: error.name,
      status: error.status ?? null,
      code: "code" in error ? error.code : null,
      cause: "cause" in error ? error.cause : null,
    });
    const status = /already|registered|exists/i.test(error.message) ? 409 : 400;
    return jsonResponse(status, {
      success: false,
      message: error.message || "Registration failed. Please try again.",
    }, request);
  }

  return jsonResponse(200, {
    success: true,
    auth_user_id: data.user?.id ?? null,
    username,
    auth_email: authEmail,
  }, request);
});
