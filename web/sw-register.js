// installable on phones (Add to Home Screen) and a friendly page when offline
if ("serviceWorker" in navigator && !window.OMW_SERVER) addEventListener("load", () => navigator.serviceWorker.register("/sw.js").catch(() => {}));
