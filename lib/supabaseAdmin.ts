import "server-only";

import { createClient } from "@supabase/supabase-js";

const supabaseUrl =
  process.env.NEXT_PUBLIC_SUPABASE_URL ||
  "https://ttogtopkzxxwmlkedumr.supabase.co";
const serviceRoleKey =
  process.env.SUPABASE_SERVICE_ROLE_KEY ||
  process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY ||
  "sb_publishable_geawnrg0CpkOgkzvY5Oe7A_LYiqFpU5";

if (!process.env.NEXT_PUBLIC_SUPABASE_URL) {
  console.warn("NEXT_PUBLIC_SUPABASE_URL is not configured.");
}

if (!process.env.SUPABASE_SERVICE_ROLE_KEY) {
  console.warn("SUPABASE_SERVICE_ROLE_KEY is not configured.");
}

export const supabaseAdmin = createClient(supabaseUrl, serviceRoleKey, {
  auth: {
    persistSession: false,
    autoRefreshToken: false,
    detectSessionInUrl: false,
  },
});

