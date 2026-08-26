// Rasterises assets/demo.svg one frame at a time for tools/make_demo_video.sh.
//
// It drives the SVG's own SMIL clock over the Chrome DevTools Protocol —
// pauseAnimations(), then setCurrentTime(t) per frame — so every frame is asked
// for by name instead of being sampled off a wall clock. A screen recorder gives
// you whatever Chrome managed to paint; this gives you frame n at exactly n/FPS,
// which is what lets the sound effects land on the frames they were placed on.
//
//   START/END pick a slice of the timeline, so several copies can share the work.
//   FPS, DUR, SCALE, OUT, PORT are the rest of the knobs.
//
// Needs Google Chrome and Node 22+ (for the global WebSocket).
import { spawn } from "node:child_process";
import { readFileSync, writeFileSync, mkdirSync, rmSync } from "node:fs";

const SVG = process.env.SVG || new URL("../assets/demo.svg", import.meta.url).pathname;
const FPS = Number(process.env.FPS || 30);
const DUR = Number(process.env.DUR || 28);
const SCALE = Number(process.env.SCALE || 2);
const OUT = process.env.OUT || "frames";
const PORT = Number(process.env.PORT || 9333);

const svg = readFileSync(SVG, "utf8");
writeFileSync(`/tmp/poe-demo-frame-${PORT}.html`,
  `<!doctype html><meta charset="utf-8"><style>html,body{margin:0;background:#08090E;overflow:hidden}
   svg{display:block;width:1280px;height:820px}</style>${svg}`);

mkdirSync(OUT, { recursive: true });

const START = Number(process.env.START || 0);
const END = Number(process.env.END || Math.round(DUR * FPS));

const chrome = spawn("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", [
  "--headless=new", `--remote-debugging-port=${PORT}`, "--disable-gpu", "--hide-scrollbars",
  "--no-first-run", "--no-default-browser-check", `--user-data-dir=/tmp/poe-chrome-profile-${PORT}`,
  "--window-size=1280,820", "about:blank",
], { stdio: "ignore" });

const sleep = ms => new Promise(r => setTimeout(r, ms));

let ws, id = 0;
const pending = new Map();
const send = (method, params = {}, sessionId) => new Promise((res, rej) => {
  const msg = { id: ++id, method, params, ...(sessionId ? { sessionId } : {}) };
  pending.set(msg.id, { res, rej });
  ws.send(JSON.stringify(msg));
});

// wait for the debugger, then attach to the blank page
let info;
for (let i = 0; i < 60 && !info; i++) {
  try { info = (await (await fetch(`http://127.0.0.1:${PORT}/json/list`)).json()).find(t => t.type === "page"); }
  catch { await sleep(250); }
}
if (!info) throw new Error("Chrome never came up");

ws = new WebSocket(info.webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener("open", r));
ws.addEventListener("message", ev => {
  const m = JSON.parse(ev.data);
  if (m.id && pending.has(m.id)) {
    const { res, rej } = pending.get(m.id);
    pending.delete(m.id);
    m.error ? rej(new Error(m.error.message)) : res(m.result);
  }
});

await send("Page.enable");
await send("Emulation.setDeviceMetricsOverride",
  { width: 1280, height: 820, deviceScaleFactor: SCALE, mobile: false });
await send("Page.navigate", { url: `file:///tmp/poe-demo-frame-${PORT}.html` });
await sleep(1200);

// Stop the clock; from here every frame is asked for by name.
await send("Runtime.evaluate", { expression: "document.querySelector('svg').pauseAnimations()" });

const total = END - START;
const t0 = Date.now();
for (let i = START; i < END; i++) {
  const t = i / FPS;
  await send("Runtime.evaluate", {
    expression: `(async () => {
      const s = document.querySelector('svg');
      s.setCurrentTime(${t});
      await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));
    })()`, awaitPromise: true,
  });
  const { data } = await send("Page.captureScreenshot", { format: "png", captureBeyondViewport: false });
  writeFileSync(`${OUT}/${String(i).padStart(5, "0")}.png`, Buffer.from(data, "base64"));
  if ((i - START) % 60 === 0) {
    const rate = (i - START + 1) / ((Date.now() - t0) / 1000);
    process.stdout.write(`\n${i - START + 1}/${total} frames  ${rate.toFixed(1)} fps  eta ${((END - i) / rate).toFixed(0)}s   `);
  }
}
console.log(`\ncaptured ${total} frames in ${((Date.now() - t0) / 1000).toFixed(0)}s`);
ws.close();
chrome.kill();
