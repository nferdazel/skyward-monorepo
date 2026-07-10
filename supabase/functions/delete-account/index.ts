import { createClient } from "jsr:@supabase/supabase-js@2";

// Rate limiting — best-effort in-memory per-IP counter
const RATE_LIMIT_WINDOW = 60 * 1000; // 1 minute
const RATE_LIMIT_MAX = 5; // max 5 delete attempts per minute per IP

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

Deno.serve(async (request) => {
  // Reject requests from unknown origins (skip for preflight)
  const requestOrigin = request.headers.get("origin") || "";
  if (requestOrigin && !isOriginAllowed(requestOrigin)) {
    return new Response("Forbidden", { status: 403 });
  }

  // CORS preflight
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: getCorsHeaders(request) });
  }

  // Rate limiting
  const ip = extractClientIp(request);
  if (!checkRateLimit(ip)) {
    return jsonResponse(429, {
      success: false,
      message: "Too many requests. Please try again later.",
    }, request);
  }

  if (request.method !== "POST") {
    return jsonResponse(405, {
      success: false,
      message: "Method not allowed.",
    }, request);
  }

  const contentLength = parseInt(request.headers.get("content-length") || "0", 10);
  if (contentLength > 4096) {
    return jsonResponse(413, {
      success: false,
      message: "Request body too large.",
    }, request);
  }

  const authHeader = request.headers.get("Authorization");
  if (!authHeader) {
    return new Response(
      JSON.stringify({ success: false, message: "Unauthorized" }),
      { status: 401, headers: { "Content-Type": "application/json", ...getCorsHeaders(request) } },
    );
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;

  // Client scoped to the calling user's JWT (for RPC with auth.uid())
  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authHeader } },
    auth: { autoRefreshToken: false, persistSession: false },
  });

  // Verify the JWT and get the user
  const {
    data: { user },
    error: authError,
  } = await userClient.auth.getUser();

  if (authError || !user) {
    return new Response(
      JSON.stringify({ success: false, message: "Unauthorized" }),
      { status: 401, headers: { "Content-Type": "application/json", ...getCorsHeaders(request) } },
    );
  }

  // Delete all game data via the SECURITY DEFINER RPC
  const { error: rpcError } = await userClient.rpc("delete_account");

  if (rpcError) {
    console.error("delete_account RPC failed:", {
      message: rpcError.message,
      code: rpcError.code ?? null,
    });
    return jsonResponse(500, {
      success: false,
      message: "Failed to delete account data.",
    }, request);
  }

  // Delete the auth user via the Admin API (service role)
  const adminClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  const { error: deleteError } = await adminClient.auth.admin.deleteUser(
    user.id,
  );

  if (deleteError) {
    // Game data is already gone — log the auth failure but don't surface a 500
    // (the user's game account is effectively destroyed; orphan auth user can
    // be cleaned up manually or via a periodic job)
    console.error("auth.admin.deleteUser failed:", {
      message: deleteError.message,
      status: deleteError.status ?? null,
    });
  }

  return jsonResponse(200, {
    success: true,
    message: "Account deleted successfully.",
  }, request);
});
