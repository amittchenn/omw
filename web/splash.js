// the splash stays until we know whether you're signed in, and at least a moment so it doesn't just flash
(() => {
  const shown = Date.now(), done = () => setTimeout(() => document.body.classList.add("splash-done"), Math.max(0, 300 - (Date.now() - shown)));
  if (!document.body.classList.contains("checking")) return done();
  const watch = new MutationObserver(() => { if (!document.body.classList.contains("checking")) { watch.disconnect(); done(); } });
  watch.observe(document.body, { attributes: true, attributeFilter: ["class"] });
})();
