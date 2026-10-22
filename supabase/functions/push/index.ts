// Haps – sender push-beskeder: haps, kommentarer, tags, venneanmodninger og nye måltider fra venner.
// Kaldes kun af databasen (trigger) med en hemmelig header.
import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2";

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
let cfg: Record<string, string> | null = null;

async function config() {
  if (!cfg) {
    const { data, error } = await sb.rpc("get_push_config");
    if (error) throw error;
    cfg = data as Record<string, string>;
    webpush.setVapidDetails("mailto:" + cfg.push_contact, cfg.vapid_public, cfg.vapid_private);
  }
  return cfg;
}

async function nameOf(id: string) {
  const { data } = await sb.from("profiles").select("username,display_name").eq("id", id).maybeSingle();
  return (data && (data.display_name || data.username)) || "En ven";
}
async function mealTitle(id: string) {
  const { data } = await sb.from("meals").select("title").eq("id", id).maybeSingle();
  return data?.title || "mad";
}
const short = (t: string, n = 120) => { t = String(t || "").trim(); return t.length > n ? t.slice(0, n - 1) + "…" : t; };

Deno.serve(async (req) => {
  try {
    const c = await config();
    if (req.headers.get("x-push-secret") !== c.push_hook_secret) return new Response("forbidden", { status: 403 });
    const ev = await req.json();
    const r = ev.record || {};
    let targets: string[] = [], title = "Haps", body = "", url = "./", tag: string | undefined;

    if (ev.table === "notifications") {
      const who = await nameOf(r.actor);
      targets = [r.user_id];
      if (r.kind === "haps") {
        const t = await mealTitle(r.meal_id), dish = /^[A-ZÆØÅ][a-zæøå]/.test(t) ? t[0].toLowerCase() + t.slice(1) : t;
        title = "Haps!"; body = `${who} kunne hapse din ${dish}`; url = "./#meal-" + r.meal_id; tag = "haps-" + r.meal_id;
      } else if (r.kind === "comment") {
        const { data: cm } = await sb.from("comments").select("body").eq("id", r.comment_id).maybeSingle();
        title = `${who} kommenterede ${await mealTitle(r.meal_id)}`; body = short(cm?.body || ""); url = "./#meal-" + r.meal_id;
      } else if (r.kind === "comment_haps") {
        title = "Haps!"; body = `${who} kunne hapse din kommentar`; url = "./#meal-" + r.meal_id; tag = "chaps-" + r.comment_id;
      } else if (r.kind === "tag") {
        if (r.comment_id) {
          const { data: cm } = await sb.from("comments").select("body").eq("id", r.comment_id).maybeSingle();
          title = `${who} har tagget dig i en kommentar`; body = short(cm?.body || "");
        } else {
          title = `${who} har tagget dig`; body = await mealTitle(r.meal_id);
        }
        url = "./#meal-" + r.meal_id;
      } else if (r.kind === "friend_request") {
        title = "Ny venneanmodning"; body = `${who} vil være venner med dig`; url = "./#venner";
      } else if (r.kind === "friend_accept") {
        title = "I er nu venner"; body = `${who} har godkendt din venneanmodning`; url = "./#feed";
      }
    } else if (ev.table === "meals") {
      const { data } = await sb.from("friendships").select("requester,addressee")
        .eq("status", "accepted").or(`requester.eq.${r.user_id},addressee.eq.${r.user_id}`);
      targets = (data || []).map((f) => (f.requester === r.user_id ? f.addressee : f.requester));
      const t = String(r.title || "mad").trim(), dish = /^[A-ZÆØÅ][a-zæøå]/.test(t) ? t[0].toLowerCase() + t.slice(1) : t;
      title = `${await nameOf(r.user_id)} hapser ${dish}`;
      body = r.rating === "anbefales" ? "Kan anbefales" : "Spiseligt";
      url = "./#meal-" + r.id;
    }

    if (!targets.length) return new Response("no targets");
    const { data: subs } = await sb.from("push_subscriptions").select("*").in("user_id", targets);
    const payload = JSON.stringify({ title, body, url, tag });
    let sent = 0;
    await Promise.all((subs || []).map(async (s) => {
      try {
        await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload, { TTL: 60 * 60 * 24 });
        sent++;
      } catch (e) {
        const code = (e as { statusCode?: number }).statusCode;
        if (code === 404 || code === 410) await sb.from("push_subscriptions").delete().eq("id", s.id);
        else console.error("push failed", code, (e as Error).message);
      }
    }));
    return new Response("sent " + sent);
  } catch (e) {
    console.error(e);
    return new Response("error", { status: 500 });
  }
});
