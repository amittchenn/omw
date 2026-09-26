// omw! as an installed app. Everything still comes live from the server (plans, maps and chat need the internet anyway);
// this only shows a friendly page instead of the browser's error when there's no connection.
const OFFLINE = `<!doctype html><meta name="viewport" content="width=device-width, initial-scale=1">
<title>omw!</title><body style="margin:0;height:100vh;display:grid;place-items:center;background:#FFE600;font-family:-apple-system,Helvetica,Arial,sans-serif;text-align:center">
<div><img src="/static/icon-192.png" width="96" height="96" alt="" style="border-radius:22px"><h2 style="margin:18px 0 6px">You're offline</h2>
<p style="margin:0 0 18px;color:#333">omw! needs the internet for plans, maps and chat.</p>
<button onclick="location.reload()" style="font:inherit;font-weight:700;border:0;border-radius:999px;padding:12px 22px;background:#111;color:#fff">Try again</button></div>`;

self.addEventListener("install", e => {
  e.waitUntil(caches.open("omw-offline").then(c => c.add("/static/icon-192.png")));
  self.skipWaiting();
});
self.addEventListener("activate", e => e.waitUntil(self.clients.claim()));

self.addEventListener("fetch", e => {
  if (new URL(e.request.url).pathname === "/static/icon-192.png")  // the offline page's logo
    return e.respondWith(fetch(e.request).catch(() => caches.match("/static/icon-192.png")));
  if (e.request.mode !== "navigate") return;  // everything else goes straight to the network as usual
  e.respondWith(fetch(e.request).catch(() => new Response(OFFLINE, { headers: { "Content-Type": "text/html; charset=utf-8" } })));
});
