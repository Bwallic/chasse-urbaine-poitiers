import { createClient } from "jsr:@supabase/supabase-js@2";

if (!(Uint8Array as any).fromBase64) {
  (Uint8Array as any).fromBase64 = (input: string, options: any = {}) => {
    let value = input;
    if (options?.alphabet === "base64url") value = value.replace(/-/g, "+").replace(/_/g, "/");
    while (value.length % 4) value += "=";
    const binary = atob(value);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
    return bytes;
  };
}
if (!(Uint8Array.prototype as any).toBase64) {
  (Uint8Array.prototype as any).toBase64 = function(options: any = {}) {
    let binary = "";
    for (let i = 0; i < this.length; i += 1) binary += String.fromCharCode(this[i]);
    let value = btoa(binary);
    if (options?.alphabet === "base64url") value = value.replace(/\+/g, "-").replace(/\//g, "_");
    if (options?.omitPadding) value = value.replace(/=+$/g, "");
    return value;
  };
}

const { generateVapidKey, send, vapidPublicKey } = await import("jsr:@daaku/webpush@0.2.0");

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-dispatch-token",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function getAdminKey(): string {
  const legacy = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (legacy) return legacy;
  const raw = Deno.env.get("SUPABASE_SECRET_KEYS");
  if (!raw) throw new Error("Clé serveur Supabase indisponible");
  const parsed = JSON.parse(raw);
  const candidate = parsed.default ?? Object.values(parsed)[0];
  if (typeof candidate === "string") return candidate;
  if (candidate && typeof candidate === "object") {
    const obj = candidate as Record<string, unknown>;
    const value = obj.key ?? obj.secret ?? obj.value;
    if (typeof value === "string") return value;
  }
  throw new Error("Clé serveur Supabase invalide");
}

async function ensureVapid(supabase: ReturnType<typeof createClient>) {
  const { data, error } = await supabase
    .from("app_private_config")
    .select("key,value")
    .in("key", ["vapid_private_jwk", "vapid_public_key"]);
  if (error) throw error;

  const map = new Map((data ?? []).map((row: any) => [row.key, row.value]));
  let privateJwk = map.get("vapid_private_jwk") as string | undefined;
  let publicKey = map.get("vapid_public_key") as string | undefined;

  if (!privateJwk || !publicKey) {
    const generated = await generateVapidKey();
    publicKey = await vapidPublicKey(generated);
    privateJwk = JSON.stringify(generated);
    const { error: upsertError } = await supabase
      .from("app_private_config")
      .upsert([
        { key: "vapid_private_jwk", value: privateJwk, updated_at: new Date().toISOString() },
        { key: "vapid_public_key", value: publicKey, updated_at: new Date().toISOString() },
      ], { onConflict: "key" });
    if (upsertError) throw upsertError;
  }
  return { privateJwk, publicKey };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabase = createClient(supabaseUrl, getAdminKey(), {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    let body: any = {};
    try { body = await req.json(); } catch { body = {}; }

    if (body?.mode === "public-key") {
      const { publicKey } = await ensureVapid(supabase);
      return json({ publicKey });
    }

    const { data: tokenRow, error: tokenError } = await supabase
      .from("app_private_config")
      .select("value")
      .eq("key", "push_dispatch_token")
      .single();
    if (tokenError) throw tokenError;

    const requestToken = req.headers.get("x-dispatch-token") ?? "";
    if (!requestToken || requestToken !== tokenRow?.value) return json({ error: "Unauthorized" }, 401);

    const { privateJwk } = await ensureVapid(supabase);
    const { data: jobs, error: jobsError } = await supabase.rpc("claim_due_push_jobs");
    if (jobsError) throw jobsError;

    const results: any[] = [];

    for (const job of jobs ?? []) {
      try {
        const [{ data: slot, error: slotError }, { data: participants, error: participantsError }] = await Promise.all([
          supabase.from("ping_slots").select("id,label,ordinal").eq("id", job.slot_id).single(),
          supabase.from("participants").select("id,pseudo,role").eq("event_id", job.event_id).eq("active", true).in("role", ["target", "hunter"]),
        ]);
        if (slotError) throw slotError;
        if (participantsError) throw participantsError;

        const participantIds = (participants ?? []).map((p: any) => p.id);
        let subscriptions: any[] = [];
        let alreadySent: any[] = [];
        if (participantIds.length) {
          const [subsRes, pingsRes] = await Promise.all([
            supabase.from("push_subscriptions").select("participant_id,endpoint,p256dh,auth").in("participant_id", participantIds),
            supabase.from("pings").select("participant_id").eq("slot_id", job.slot_id).in("participant_id", participantIds),
          ]);
          if (subsRes.error) throw subsRes.error;
          if (pingsRes.error) throw pingsRes.error;
          subscriptions = subsRes.data ?? [];
          alreadySent = pingsRes.data ?? [];
        }

        const subscriptionsByParticipant = new Map(subscriptions.map((s: any) => [s.participant_id, s]));
        const sentTargets = new Set(alreadySent.map((p: any) => p.participant_id));
        let failures = 0;

        for (const participant of participants ?? []) {
          if (participant.role === "target" && sentTargets.has(participant.id)) {
            await supabase.from("push_deliveries").upsert({ job_id: job.id, participant_id: participant.id, status: "skipped", updated_at: new Date().toISOString() }, { onConflict: "job_id,participant_id" });
            continue;
          }

          const subscription: any = subscriptionsByParticipant.get(participant.id);
          if (!subscription) {
            await supabase.from("push_deliveries").upsert({ job_id: job.id, participant_id: participant.id, status: "no_subscription", updated_at: new Date().toISOString() }, { onConflict: "job_id,participant_id" });
            continue;
          }

          const isControl = slot.ordinal === 0;
          const isTarget = participant.role === "target";
          const title = isControl ? "Ping 0 — Contrôle départ" : `${slot.label} — Chasse Urbaine`;
          const bodyText = isTarget
            ? (isControl ? "Touchez pour valider votre position de départ." : "Touchez pour ouvrir l'application et envoyer votre position.")
            : (isControl ? "Ouvrez l'application pour vérifier les positions de départ des Cibles." : "De nouvelles positions des Cibles vont être envoyées.");

          const query = new URLSearchParams({ pushJob: job.id, slot: String(slot.ordinal) });
          if (isTarget) query.set("pingAction", "1");
          const payload = JSON.stringify({ title, body: bodyText, tag: `chasse-${job.id}`, jobId: job.id, slotOrdinal: slot.ordinal, url: `?${query.toString()}` });

          try {
            await send({ endpoint: subscription.endpoint, keys: { p256dh: subscription.p256dh, auth: subscription.auth } }, payload, {
              vapid: privateJwk,
              subscriber: "https://bwallic.github.io/chasse-urbaine-poitiers/",
              ttl: isControl ? 300 : 900,
              urgency: "high",
              topic: `ping-${slot.ordinal}`,
            });
            await supabase.from("push_deliveries").upsert({ job_id: job.id, participant_id: participant.id, status: "sent", sent_at: new Date().toISOString(), error: null, updated_at: new Date().toISOString() }, { onConflict: "job_id,participant_id" });
          } catch (error: any) {
            failures += 1;
            await supabase.from("push_deliveries").upsert({ job_id: job.id, participant_id: participant.id, status: "failed", error: String(error?.message ?? error).slice(0, 500), updated_at: new Date().toISOString() }, { onConflict: "job_id,participant_id" });
            if (error?.permanent || error?.statusCode === 404 || error?.statusCode === 410) await supabase.from("push_subscriptions").delete().eq("participant_id", participant.id);
          }
        }

        await supabase.from("push_jobs").update({ status: "sent", sent_at: new Date().toISOString(), locked_at: null, last_error: failures ? `${failures} envoi(s) en erreur` : null }).eq("id", job.id);
        results.push({ jobId: job.id, sent: true, failures });
      } catch (error: any) {
        await supabase.from("push_jobs").update({ status: "pending", locked_at: null, last_error: String(error?.message ?? error).slice(0, 500) }).eq("id", job.id);
        results.push({ jobId: job.id, sent: false, error: String(error?.message ?? error) });
      }
    }

    return json({ ok: true, jobs: results });
  } catch (error: any) {
    console.error(error);
    return json({ error: String(error?.message ?? error) }, 500);
  }
});
