import { createClient } from "jsr:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

Deno.serve(async (request) => {
  // CORS preflight
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const authHeader = request.headers.get("Authorization");
  if (!authHeader) {
    return new Response(
      JSON.stringify({ success: false, message: "Unauthorized" }),
      { status: 401, headers: { "Content-Type": "application/json", ...corsHeaders } },
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
      { status: 401, headers: { "Content-Type": "application/json", ...corsHeaders } },
    );
  }

  // Delete all game data via the SECURITY DEFINER RPC
  const { error: rpcError } = await userClient.rpc("delete_account");

  if (rpcError) {
    console.error("delete_account RPC failed:", rpcError);
    return new Response(
      JSON.stringify({ success: false, message: "Failed to delete account data" }),
      { status: 500, headers: { "Content-Type": "application/json", ...corsHeaders } },
    );
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
    console.error("auth.admin.deleteUser failed:", deleteError);
  }

  return new Response(
    JSON.stringify({ success: true, message: "Account deleted successfully" }),
    { status: 200, headers: { "Content-Type": "application/json", ...corsHeaders } },
  );
});
