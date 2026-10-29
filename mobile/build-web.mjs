// Packs the app's screens (../web) into www/, which goes inside the iPhone app. So the app opens instantly and works
// offline instead of loading the website; only data (plans, places, AI) comes from the server below.
// Runs before every `npm run sync`. Set OMW_SERVER to use another server, e.g. OMW_SERVER=https://getomw.com npm run sync
import { cpSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";

const SERVER = (process.env.OMW_SERVER || "https://omw-bzq4.onrender.com").replace(/\/$/, "");
const SKIP = ["avatar.zip", "sw.js"];  // not needed in the app

rmSync("www", { recursive: true, force: true });
mkdirSync("www/static", { recursive: true });
cpSync("../web", "www/static", { recursive: true, filter: f => !SKIP.some(s => f.endsWith(s)) });
const html = readFileSync("../web/index.html", "utf8")
  .replace("<head>", `<head>\n  <script>window.OMW_SERVER = ${JSON.stringify(SERVER)};</script>`);
if (!html.includes("window.OMW_SERVER")) throw new Error("couldn't find <head> in web/index.html");
writeFileSync("www/index.html", html);
console.log(`www/ ready: the app talks to ${SERVER}`);
