// Waiter PIN verifier.
//
// Verifies a numeric passcode against the shared POS `user` table WITHOUT ever
// shipping the AES key to the browser. The web client sends only `{ passcode }`
// and receives back the matched user's identity + access level, or 401.
//
// Password format mirrors the POS `UserService` (kwikpos_lite):
//   stored value = "<cipherBase64>:<ivBase64>"
//   cipher = AES-256 in SIC/CTR mode over the UTF-8 passcode, PKCS7-padded,
//   key = UTF-8 bytes of a 32-char passphrase.
// So decryption here = AES-256-CTR (full 16-byte block counter) + strip PKCS7.
//
// Secrets (set via `supabase secrets set`):
//   WAITER_PIN_AES_KEY          - the 32-char passphrase used by the POS
//   SUPABASE_URL                - injected automatically
//   SUPABASE_SERVICE_ROLE_KEY   - injected automatically (server-side read)
//
// Deploy: supabase functions deploy verify-waiter-pin

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function base64ToBytes(b64: string): Uint8Array {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

// Remove PKCS7 padding. The POS `encrypt` package pads even in SIC mode, so the
// raw AES-CTR output ends with `n` bytes each equal to `n`. Validate before
// stripping; return the bytes unchanged if padding is not well-formed.
function stripPkcs7(bytes: Uint8Array): Uint8Array {
  if (bytes.length === 0) return bytes;
  const pad = bytes[bytes.length - 1];
  if (pad < 1 || pad > 16 || pad > bytes.length) return bytes;
  for (let i = bytes.length - pad; i < bytes.length; i++) {
    if (bytes[i] !== pad) return bytes;
  }
  return bytes.subarray(0, bytes.length - pad);
}

async function decryptPassword(
  stored: string,
  key: CryptoKey,
): Promise<string | null> {
  const parts = stored.split(":");
  if (parts.length !== 2) return null;
  try {
    const cipher = base64ToBytes(parts[0]);
    const iv = base64ToBytes(parts[1]);
    if (iv.length !== 16) return null;
    const plainBuf = await crypto.subtle.decrypt(
      { name: "AES-CTR", counter: iv, length: 128 },
      key,
      cipher,
    );
    const plain = stripPkcs7(new Uint8Array(plainBuf));
    return new TextDecoder().decode(plain);
  } catch (_) {
    return null;
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return json({ error: "Method not allowed" }, 405);
  }

  let passcode: unknown;
  try {
    passcode = (await req.json())?.passcode;
  } catch (_) {
    return json({ error: "Invalid JSON body" }, 400);
  }
  if (typeof passcode !== "string" || passcode.trim().length === 0) {
    return json({ error: "passcode is required" }, 400);
  }

  const keyString = Deno.env.get("WAITER_PIN_AES_KEY") ?? "";
  if (keyString.length !== 32) {
    return json({ error: "Server key not configured" }, 500);
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  // Active users. NOTE: `user.access_level_id` has no FK to
  // `users_access_level` in the POS schema, so PostgREST cannot embed the two.
  // We fetch users plainly and look the access level up separately on a match.
  const { data: users, error } = await supabase
    .from("user")
    .select("id, name, password, status, access_level_id")
    .eq("status", 1);

  if (error) {
    console.error("verify-waiter-pin user lookup failed:", error);
    return json({ error: "Lookup failed", detail: error.message }, 500);
  }

  const cryptoKey = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(keyString),
    { name: "AES-CTR" },
    false,
    ["decrypt"],
  );

  const target = passcode.trim();
  for (const row of users ?? []) {
    const stored = row.password as string | null;
    if (!stored) continue;
    const decrypted = await decryptPassword(stored, cryptoKey);
    if (decrypted !== null && decrypted === target) {
      // Fetch the access-level row for this user (permission flags for TBD use).
      const { data: access, error: accessErr } = await supabase
        .from("users_access_level")
        .select("*")
        .eq("id", row.access_level_id)
        .maybeSingle();
      if (accessErr) {
        console.error("verify-waiter-pin access lookup failed:", accessErr);
      }
      return json({
        user: {
          id: row.id,
          name: row.name,
          access_level_id: row.access_level_id,
          access_level: access ?? null,
        },
      });
    }
  }

  return json({ user: null }, 401);
});
