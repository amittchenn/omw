if (window.Capacitor && window.Capacitor.isNativePlatform && window.Capacitor.isNativePlatform()) document.documentElement.classList.add("native");
// requests to omw!'s server ("/plan", "/places/...") carry your sign-in, so only signed-in people can use it (security.py).
// In the iPhone app the screens are inside the app (mobile/build-web.mjs), so they go to the server's address.
{
  const send = window.fetch.bind(window);
  window.fetch = async (url, opts = {}) => {
    if (typeof url === "string" && url.startsWith("/") && !url.startsWith("/static/")) {
      if (window.OMW_SERVER) url = window.OMW_SERVER + url;
      const user = window.currentUser, headers = opts.headers || {};
      if (user && !headers.Authorization) {
        try { opts = { ...opts, headers: { ...headers, Authorization: `Bearer ${await user.getIdToken()}` } }; } catch { /* offline: try without */ }
      }
    }
    return send(url, opts);
  };
}

// a photo that won't load: data-fail="remove" drops it, data-fail="gone" hides it (instead of inline onerror="…",
// which the Content-Security-Policy blocks)
addEventListener("error", e => {
  const how = e.target?.dataset?.fail;
  if (how === "remove") e.target.remove(); else if (how === "gone") e.target.classList.add("gone");
}, true);
