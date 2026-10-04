self.addEventListener("install", () => self.skipWaiting());

self.addEventListener("activate", (event) => {
  event.waitUntil(self.clients.claim());
});

self.addEventListener("push", (event) => {
  let payload = {};
  try {
    payload = event.data ? event.data.json() : {};
  } catch {
    payload = { title: "Évasion Urbaine", body: event.data?.text?.() || "Nouveau ping" };
  }

  const title = payload.title || "Évasion Urbaine — Poitiers";
  const options = {
    body: payload.body || "Nouveau ping",
    tag: payload.tag || "evasion-urbaine-ping",
    renotify: true,
    data: payload,
  };

  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const payload = event.notification.data || {};
  const targetUrl = new URL(payload.url || "./", self.registration.scope).href;

  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    for (const client of windows) {
      if ("navigate" in client) {
        try { await client.navigate(targetUrl); } catch {}
      }
      if ("focus" in client) return client.focus();
    }
    return self.clients.openWindow(targetUrl);
  })());
});
