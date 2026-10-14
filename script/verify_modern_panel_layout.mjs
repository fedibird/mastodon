// Layout regression check for the Modern single-column panes.
//
// Compiles the real stylesheets and measures pane boxes in headless Chrome.
// Usage: node script/verify_modern_panel_layout.mjs

import { spawn } from 'node:child_process';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import * as sass from 'sass';

const require = createRequire(import.meta.url);
const WebSocket = require('ws');

const root = resolve(new URL('..', import.meta.url).pathname);
const widths = [895, 896, 904, 905, 916, 917, 1190, 1191, 1201, 1202, 1319, 1320, 1325, 1330, 1339, 1340, 1350, 1351, 1352, 1600];
const zoomWidths = [1191, 1320, 1340, 1352, 1600];
const zooms = [
  { label: '90%', deviceScaleFactor: 1 / 0.9 },
  { label: '100%', deviceScaleFactor: 1 },
  { label: '110%', deviceScaleFactor: 1 / 1.1 },
];

function compile(entry) {
  return sass.compile(join(root, entry), {
    loadPaths: [join(root, 'app/javascript/styles')],
    style: 'expanded',
    silenceDeprecations: ['import', 'global-builtin', 'color-functions'],
  }).css;
}

const themes = {
  'modern-dark': compile('app/javascript/styles/modern-dark.scss'),
  'modern-light': compile('app/javascript/styles/modern-light.scss'),
  default: compile('app/javascript/styles/application.scss'),
};

const dir = mkdtempSync(join(tmpdir(), 'modern-layout-'));
const pages = {};
for (const [name, css] of Object.entries(themes)) {
  const cssPath = join(dir, `${name}.css`);
  writeFileSync(cssPath, css);
  const htmlPath = join(dir, `${name}.html`);
  writeFileSync(htmlPath, fixture(cssPath, 'single'));
  pages[name] = htmlPath;
}
const multiPath = join(dir, 'modern-dark-multi.html');
writeFileSync(multiPath, fixture(join(dir, 'modern-dark.css'), 'multi'));

function fixture(cssPath, mode) {
  const body = mode === 'multi'
    ? `<body class="app-body layout-multiple-columns">
        <div class="app-holder" id="mastodon"><div><div class="ui">
          <div class="columns-area" id="columns">
            <div class="column" id="col-a"><button id="col-a-btn">Home</button><div style="height:120vh">a</div></div>
            <div class="column" id="col-b"><button id="col-b-btn">Notifications</button><div style="height:120vh">b</div></div>
            <div class="column" id="col-c"><button id="col-c-btn">Federated</button><div style="height:120vh">c</div></div>
          </div>
        </div></div></div>
      </body>`
    : `<body class="app-body layout-single-column">
        <div class="app-holder" id="mastodon"><div><div class="ui">
          <div class="columns-area__panels" id="panels">
            <div class="columns-area__panels__pane columns-area__panels__pane--compositional" id="left">
              <div class="columns-area__panels__pane__inner" id="left-inner">
                <button id="compose">Compose</button>
              </div>
            </div>
            <div class="columns-area__panels__main" id="main">
              <div class="tabs-bar__wrapper" id="tabs">
                <nav class="tabs-bar" id="tabs-bar"><a id="tab-link" href="#home">Home</a></nav>
                <div id="tabs-bar__portal"><button id="header">Home</button></div>
              </div>
              <div class="column"><div class="scrollable" id="timeline" style="height:180vh">Home timeline</div></div>
            </div>
            <div class="columns-area__panels__pane columns-area__panels__pane--start columns-area__panels__pane--navigational" id="right">
              <div class="columns-area__panels__pane__inner" id="right-inner">
                <nav class="navigation-panel"><a id="nav-link" href="#notifications">Notifications</a></nav>
              </div>
            </div>
          </div>
        </div></div></div>
      </body>`;

  return `<!DOCTYPE html><html><head><meta charset="utf-8"><link rel="stylesheet" href="${cssPath}"></head>${body}
<script>
function shown(el) { return !!el && el.getClientRects().length > 0; }
function box(id) {
  const el = document.getElementById(id);
  if (!shown(el)) return { id, shown: false };
  const r = el.getBoundingClientRect();
  const cs = getComputedStyle(el);
  return {
    id, shown: true,
    left: r.left, right: r.right, width: r.width, top: r.top,
    maxWidth: cs.maxWidth, marginLeft: cs.marginLeft,
  };
}
window.__measure = () => {
  const ids = ['left','left-inner','compose','main','tabs','tabs-bar','header','right','right-inner','nav-link','timeline','col-a','col-b','col-c','col-a-btn','columns'];
  const boxes = Object.fromEntries(ids.filter(id => document.getElementById(id)).map(id => [id, box(id)]));
  const client = document.documentElement.clientWidth;
  const visible = Object.values(boxes).filter(b => b.shown);
  const minLeft = visible.length ? Math.min(...visible.map(b => b.left)) : 0;
  const maxRight = visible.length ? Math.max(...visible.map(b => b.right)) : 0;
  return {
    innerWidth: window.innerWidth,
    clientWidth: client,
    devicePixelRatio: window.devicePixelRatio,
    scrollWidth: document.documentElement.scrollWidth,
    minLeft, maxRight,
    boxes,
  };
};
</script></html>`;
}

function chromePath() {
  return process.env.CHROME_PATH || '/usr/bin/google-chrome';
}

const port = 9341;
const chrome = spawn(chromePath(), [
  '--headless=new',
  '--disable-gpu',
  '--no-first-run',
  '--no-default-browser-check',
  '--allow-file-access-from-files',
  `--remote-debugging-port=${port}`,
  `--user-data-dir=${join(dir, 'profile')}`,
  'about:blank',
], { stdio: 'ignore' });

async function waitForChrome() {
  for (let i = 0; i < 50; i += 1) {
    try {
      if ((await fetch(`http://127.0.0.1:${port}/json/version`)).ok) return;
    } catch { /* retry */ }
    await delay(100);
  }
  throw new Error('Chrome did not start');
}

function connect(ws) {
  let seq = 0;
  const pending = new Map();
  ws.on('message', (data) => {
    const msg = JSON.parse(data.toString());
    if (msg.id && pending.has(msg.id)) {
      const { resolve, reject } = pending.get(msg.id);
      pending.delete(msg.id);
      if (msg.error) reject(new Error(JSON.stringify(msg.error)));
      else resolve(msg.result);
    }
  });
  return (method, params = {}) => new Promise((resolve, reject) => {
    const id = ++seq;
    pending.set(id, { resolve, reject });
    ws.send(JSON.stringify({ id, method, params }));
  });
}

function paneState(data) {
  const left = data.boxes.left?.shown;
  const right = data.boxes.right?.shown;
  if (left && right) return 'three';
  if (left) return 'two';
  return 'one';
}

function failsModern(data) {
  const eps = 0.75;
  const problems = [];
  if (data.minLeft < -eps) problems.push(`left ${data.minLeft.toFixed(2)}`);
  if (data.maxRight > data.clientWidth + eps) problems.push(`right ${data.maxRight.toFixed(2)} > ${data.clientWidth}`);
  if (data.scrollWidth > data.clientWidth + 1) problems.push(`scrollWidth ${data.scrollWidth}`);
  const main = data.boxes.main;
  if (main?.shown && main.width > 750.5) problems.push(`main wider than 750 (${main.width})`);
  return problems;
}

await waitForChrome();
const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const page = list.find((target) => target.type === 'page');
const ws = new WebSocket(page.webSocketDebuggerUrl);
await new Promise((resolve, reject) => {
  ws.once('open', resolve);
  ws.once('error', reject);
});
const send = connect(ws);
await send('Page.enable');

async function navigate(url) {
  const loaded = new Promise((resolve) => {
    const onMessage = (data) => {
      const msg = JSON.parse(data.toString());
      if (msg.method === 'Page.loadEventFired') {
        ws.off('message', onMessage);
        resolve();
      }
    };
    ws.on('message', onMessage);
  });
  await send('Page.navigate', { url });
  await Promise.race([loaded, delay(5000)]);
}

async function measure(url, width, deviceScaleFactor = 1) {
  // Apply the viewport before navigation. The timeline max-width transitions,
  // so measuring after a resize would catch the animation mid-way.
  await send('Emulation.setDeviceMetricsOverride', {
    width,
    height: 900,
    deviceScaleFactor,
    mobile: false,
  });
  await navigate(url);
  const result = await send('Runtime.evaluate', {
    expression: 'JSON.stringify(window.__measure())',
    returnByValue: true,
  });
  return JSON.parse(result.result.value);
}

const failures = [];
const report = [];

for (const theme of ['modern-dark', 'modern-light']) {
  const url = `file://${pages[theme]}`;
  for (const width of widths) {
    const data = await measure(url, width);
    const problems = failsModern(data);
    const row = {
      theme,
      width,
      innerWidth: data.innerWidth,
      clientWidth: data.clientWidth,
      dpr: data.devicePixelRatio,
      panes: paneState(data),
      main: data.boxes.main?.shown ? Math.round(data.boxes.main.width * 100) / 100 : null,
      minLeft: Math.round(data.minLeft * 100) / 100,
      maxRight: Math.round(data.maxRight * 100) / 100,
      problems,
    };
    report.push(row);
    if (problems.length) failures.push(`${theme} @ ${width}: ${problems.join(', ')}`);
    if (width === 1600 && row.panes === 'three' && Math.abs(row.main - 750) > 0.75) {
      failures.push(`${theme} @ 1600 main width ${row.main}, expected 750`);
    }
    if (width === 1320 && row.panes === 'three' && row.main >= 750) {
      failures.push(`${theme} @ 1320 still uses the full 750px timeline`);
    }
  }
  for (const zoom of zooms) {
    for (const width of zoomWidths) {
      const data = await measure(url, width, zoom.deviceScaleFactor);
      const problems = failsModern(data);
      report.push({
        theme,
        zoom: zoom.label,
        width,
        innerWidth: data.innerWidth,
        clientWidth: data.clientWidth,
        dpr: Math.round(data.devicePixelRatio * 1000) / 1000,
        panes: paneState(data),
        main: Math.round(data.boxes.main.width * 100) / 100,
        minLeft: Math.round(data.minLeft * 100) / 100,
        maxRight: Math.round(data.maxRight * 100) / 100,
        problems,
      });
      if (problems.length) failures.push(`${theme} ${zoom.label} @ ${width}: ${problems.join(', ')}`);
    }
  }
}

const darkAt = Object.fromEntries(report.filter((row) => row.theme === 'modern-dark' && !row.zoom).map((row) => [row.width, row.main]));
const lightAt = Object.fromEntries(report.filter((row) => row.theme === 'modern-light' && !row.zoom).map((row) => [row.width, row.main]));
for (const width of widths) {
  if (darkAt[width] !== lightAt[width]) failures.push(`light/dark main width differs at ${width}: ${darkAt[width]} vs ${lightAt[width]}`);
}

const plainUrl = `file://${pages.default}`;
for (const width of [895, 1190, 1191, 1320, 1340, 1600]) {
  const data = await measure(plainUrl, width);
  const eps = 0.75;
  const clipped = data.minLeft < -eps || data.maxRight > data.clientWidth + eps;
  const main = data.boxes.main.width;
  report.push({
    theme: 'default',
    width,
    innerWidth: data.innerWidth,
    clientWidth: data.clientWidth,
    panes: paneState(data),
    main: Math.round(main * 100) / 100,
    minLeft: Math.round(data.minLeft * 100) / 100,
    maxRight: Math.round(data.maxRight * 100) / 100,
    clipped,
  });
  if (clipped) failures.push(`default theme clipped at ${width}`);
  if (main > 600.5) failures.push(`default theme main grew past 600 at ${width} (${main})`);
}

const multi = await measure(`file://${multiPath}`, 1600);
const columns = ['col-a', 'col-b', 'col-c'].map((id) => multi.boxes[id]);
report.push({
  theme: 'modern-dark-multi',
  width: 1600,
  columns: columns.map((col) => ({ width: Math.round(col.width * 100) / 100, maxWidth: col.maxWidth, shown: col.shown })),
  buttonsInside: ['col-a-btn', 'col-b-btn', 'col-c-btn'].every((id) => {
    const button = multi.boxes[id];
    return button && button.shown && button.left >= -0.75 && button.right <= multi.clientWidth + 0.75;
  }),
});
if (columns.some((col) => !col.shown || col.width < 300)) {
  failures.push(`multi-column columns collapsed: ${JSON.stringify(report.at(-1).columns)}`);
}
if (columns.some((col) => String(col.maxWidth).includes('var(--tl-width)'))) {
  failures.push('single-column timeline cap leaked into advanced columns');
}

console.log(JSON.stringify({ report, failures }, null, 2));
chrome.kill('SIGKILL');
process.exit(failures.length ? 1 : 0);
