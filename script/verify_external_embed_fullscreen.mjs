// Reproduces external-embed fullscreen delegation with fictional origins.
//
// Three loopback origins (different ports) stand in for a Fedibird page, a
// player src origin, and another origin reached by redirect or a nested
// frame. Nothing here is a real publisher. The adopted iframe policy is read
// from the live definition. A shared external_player/frame_props.js wins.
// This file's component object is used only when that shared file is absent.
// A shared file that exists but does not yield the object is an error.
//
// Usage:
//   node script/verify_external_embed_fullscreen.mjs --out /tmp/embed-fullscreen
//
// Requires a display. Headless Chrome does not exercise requestFullscreen.
// Exit 0 when every required expectation matches. Informational rows are
// recorded either way.
//
// This harness builds its own iframes. It does not open the #625 host.
// --read-policy only checks that the object literal can be read. That is not
// a fullscreen pass. On an integrated tree, repeat the redirect,
// nested-missing, no-gesture, parent fullscreen=() and fullscreen=(self),
// and child-denial cases on the live createFrame node. Inline and the fixed
// dock share that node. Attribute equality is not a fullscreen pass.

import { spawn } from 'node:child_process';
import { createRequire } from 'node:module';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { createServer } from 'node:http';
import { join, resolve } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';

const require = createRequire(import.meta.url);
const WebSocket = require('ws');

const root = resolve(new URL('..', import.meta.url).pathname);
const ports = {
  parent: 47110,
  denied: 47113,
  self: 47114,
  cohort: 47115,
  src: 47120,
  other: 47121,
};
const origin = (port) => `http://127.0.0.1:${port}`;

function argValue(name, fallback) {
  const index = process.argv.indexOf(name);
  if (index === -1 || !process.argv[index + 1]) return fallback;
  return process.argv[index + 1];
}

const outDir = argValue('--out', join(tmpdir(), 'embed-fullscreen'));
mkdirSync(outDir, { recursive: true });

const SHARED_FRAME_PROPS = 'app/javascript/mastodon/external_player/frame_props.js';
const COMPONENT_FRAME_PROPS = 'app/javascript/mastodon/components/external_embed_player.js';

function propsFromObjectLiteral(source, label) {
  const block = source.match(/export const externalEmbedFrameProps = \{([\s\S]*?)\n\};/);
  if (!block) {
    throw new Error(`externalEmbedFrameProps was not found in ${label}`);
  }
  const allow = block[1].match(/allow: '([^']+)'/);
  const sandbox = block[1].match(/sandbox: '([^']+)'/);
  const referrerPolicy = block[1].match(/referrerPolicy: '([^']+)'/);
  if (!allow || !sandbox || !referrerPolicy) {
    throw new Error(`iframe policy fields were not found in ${label}`);
  }
  return {
    allow: allow[1],
    sandbox: sandbox[1],
    referrerPolicy: referrerPolicy[1],
    source: label,
  };
}

// The shared module is the definition after #625. Reading the component when
// that file exists would accept a stale object the host no longer uses.
function policyFromSource(treeRoot = root) {
  const shared = join(treeRoot, SHARED_FRAME_PROPS);
  if (existsSync(shared)) {
    return propsFromObjectLiteral(readFileSync(shared, 'utf8'), SHARED_FRAME_PROPS);
  }
  return propsFromObjectLiteral(readFileSync(join(treeRoot, COMPONENT_FRAME_PROPS), 'utf8'), COMPONENT_FRAME_PROPS);
}

const adopted = policyFromSource(argValue('--root', root));
if (process.argv.includes('--read-policy')) {
  process.stdout.write(`${JSON.stringify(adopted)}\n`);
  process.exit(0);
}
const currentAllow = 'fullscreen; encrypted-media; picture-in-picture';

function playerHtml(query) {
  const caseId = query.get('case') || '';
  const immediate = query.get('immediate') === '1';
  return `<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>Fictional player</title>
  <style>
    html, body { margin: 0; height: 100%; background: #14302a; color: #fff; font: 16px sans-serif; }
    button { margin: 12px; padding: 10px 14px; font: 16px sans-serif; }
    #status { margin: 8px 12px; white-space: pre-wrap; }
  </style>
</head>
<body>
  <button id="go" type="button">Enter fullscreen</button>
  <div id="status">Fictional player waiting</div>
  <script>
    const caseId = ${JSON.stringify(caseId)};
    const token = Math.random().toString(36).slice(2);
    let ticks = 0;
    setInterval(() => { ticks += 1; }, 100);
    const status = document.getElementById('status');
    function snapshot(extra) {
      let allowsFeature = null;
      try {
        allowsFeature = !!(document.permissionsPolicy && document.permissionsPolicy.allowsFeature('fullscreen'));
      } catch (error) {
        allowsFeature = null;
      }
      return Object.assign({
        source: 'fictional-player',
        caseId,
        origin: location.origin,
        href: location.href,
        referrer: document.referrer,
        token,
        ticks,
        fullscreenEnabled: !!document.fullscreenEnabled,
        allowsFeature,
        innerFullscreen: !!document.fullscreenElement,
      }, extra);
    }
    function publish(payload) {
      status.textContent = JSON.stringify(payload, null, 2);
      document.body.style.background = payload.ok ? '#0d6b3d' : (payload.kind === 'result' ? '#8a2430' : '#14302a');
      if (window.top) window.top.postMessage(payload, '*');
    }
    publish(snapshot({ kind: 'ready', event: 'ready', ok: null, errorName: null, errorMessage: null }));
    document.getElementById('go').addEventListener('click', () => {
      if (document.fullscreenElement) {
        document.exitFullscreen().catch(() => {});
        return;
      }
      const attempt = document.documentElement.requestFullscreen();
      Promise.resolve(attempt).then(
        () => publish(snapshot({ kind: 'result', event: 'click', ok: true, errorName: null, errorMessage: null })),
        (error) => publish(snapshot({ kind: 'result', event: 'click', ok: false, errorName: error.name, errorMessage: String(error.message) })),
      );
    });
    if (${immediate ? 'true' : 'false'}) {
      const attempt = document.documentElement.requestFullscreen();
      Promise.resolve(attempt).then(
        () => publish(snapshot({ kind: 'result', event: 'immediate', ok: true, errorName: null, errorMessage: null })),
        (error) => publish(snapshot({ kind: 'result', event: 'immediate', ok: false, errorName: error.name, errorMessage: String(error.message) })),
      );
    }
    window.addEventListener('message', (event) => {
      if (!event.data || event.data.source !== 'probe') return;
      if (event.data.command === 'report') {
        publish(snapshot({ kind: 'result', event: 'report', ok: null, errorName: null, errorMessage: null, stillFullscreen: !!document.fullscreenElement }));
      }
    });
  </script>
</body>
</html>`;
}

function nestHtml(query) {
  const caseId = query.get('case') || '';
  const inner = query.get('inner') === 'star'
    ? ' allow="fullscreen *" allowfullscreen'
    : '';
  const src = `${origin(ports.other)}/player?case=${encodeURIComponent(caseId)}`;
  return `<!doctype html>
<html>
<head><meta charset="utf-8"><title>Fictional nest</title></head>
<body style="margin:0;background:#222">
  <iframe src="${src}"${inner} referrerpolicy="no-referrer" style="border:0;width:100%;height:100vh" title="Nested fictional player"></iframe>
</body>
</html>`;
}

function parentHtml() {
  return `<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>External embed fullscreen probe</title>
  <style>
    body { margin: 0; font: 16px sans-serif; background: #f4f1ea; color: #1b1b1b; }
    header { padding: 12px 16px; }
    #timeline { height: 420px; overflow-y: auto; border-top: 1px solid #999; border-bottom: 1px solid #999; background: #fff; }
    @supports (display: grid) {
      #timeline { contain: strict; }
      #timeline.fullscreen { contain: none; }
    }
    #intro { height: 240px; padding: 12px 16px; }
    #below { height: 1200px; padding: 12px 16px; }
    #banner { margin: 12px 16px; font-size: 20px; }
    #detail, #summary { margin: 0 16px 16px; white-space: pre-wrap; }
    iframe { background: #14302a; }
  </style>
</head>
<body>
  <header>
    <strong>Fictional timeline</strong>
    <span id="scroll-label"></span>
  </header>
  <div id="timeline" class="scrollable">
    <div id="intro">Timeline rows above the player.</div>
    <div id="slot"></div>
    <div id="below">Timeline rows below the player.</div>
  </div>
  <h1 id="banner">Waiting</h1>
  <pre id="detail"></pre>
  <pre id="summary"></pre>
  <script>
    const timeline = document.getElementById('timeline');
    const banner = document.getElementById('banner');
    const detail = document.getElementById('detail');
    window.__log = [];
    window.__fullscreenEvents = [];
    window.addEventListener('message', (event) => {
      if (!event.data || event.data.source !== 'fictional-player') return;
      window.__log.push(event.data);
    });
    document.addEventListener('fullscreenchange', () => {
      const active = !!document.fullscreenElement;
      timeline.classList.toggle('fullscreen', active);
      window.__fullscreenEvents.push({
        active,
        scrollTop: timeline.scrollTop,
        className: timeline.className,
      });
    });
    const scrollTarget = 240;
    window.__prepare = () => {
      timeline.scrollTop = scrollTarget;
      timeline.classList.remove('fullscreen');
      document.getElementById('scroll-label').textContent = 'scrollTop ' + timeline.scrollTop;
      return timeline.scrollTop;
    };
    window.__observe = () => ({
      scrollTop: timeline.scrollTop,
      timelineClass: timeline.className,
      fullscreenTag: document.fullscreenElement ? document.fullscreenElement.tagName : null,
      fullscreenId: document.fullscreenElement ? document.fullscreenElement.id : null,
      iframe: !!document.getElementById('player'),
    });
    window.__banner = (title, text) => {
      banner.textContent = title;
      detail.textContent = text || '';
    };
    window.__summary = (text) => {
      document.getElementById('summary').textContent = text;
    };
    window.__mount = (spec) => new Promise((resolve) => {
      const slot = document.getElementById('slot');
      slot.replaceChildren();
      const iframe = document.createElement('iframe');
      iframe.id = 'player';
      iframe.title = 'External video';
      iframe.style.cssText = 'width:640px;height:180px;border:0;display:block';
      if (spec.sandbox) iframe.setAttribute('sandbox', spec.sandbox);
      if (spec.allow) iframe.setAttribute('allow', spec.allow);
      if (spec.allowfullscreen) iframe.setAttribute('allowfullscreen', '');
      iframe.setAttribute('referrerpolicy', spec.referrerPolicy || 'no-referrer');
      iframe.src = spec.src;
      const timer = setTimeout(() => resolve({ timeout: true, caseId: spec.caseId }), 5000);
      const finish = (event) => {
        const data = event.data;
        if (!data || data.source !== 'fictional-player' || data.caseId !== spec.caseId) return;
        if (spec.wait === 'result' && data.kind !== 'result') return;
        if (spec.wait !== 'result' && data.kind !== 'ready') return;
        clearTimeout(timer);
        window.removeEventListener('message', finish);
        resolve(data);
      };
      window.addEventListener('message', finish);
      slot.appendChild(iframe);
    });
    window.__exit = async () => {
      if (document.fullscreenElement && document.exitFullscreen) {
        try { await document.exitFullscreen(); } catch (error) { return { error: String(error) }; }
      }
      return window.__observe();
    };
    window.__remove = () => {
      document.getElementById('slot').replaceChildren();
      return window.__observe();
    };
    window.__ask = () => {
      const frame = document.getElementById('player');
      if (frame && frame.contentWindow) {
        frame.contentWindow.postMessage({ source: 'probe', command: 'report' }, '*');
      }
    };
    window.__prepare();
  </script>
</body>
</html>`;
}

function routePlayer(req, res) {
  const url = new URL(req.url, origin(ports.src));
  if (url.pathname === '/health') {
    res.writeHead(200, { 'content-type': 'text/plain' });
    res.end('ok');
    return;
  }
  if (url.pathname === '/redirect') {
    const dest = new URL(`${origin(ports.other)}/player`);
    dest.search = url.search;
    res.writeHead(302, { location: dest.toString(), 'cache-control': 'no-store' });
    res.end();
    return;
  }
  if (url.pathname === '/nest') {
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
    res.end(nestHtml(url.searchParams));
    return;
  }
  if (url.pathname === '/player') {
    const headers = { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' };
    if (url.searchParams.get('deny') === '1') headers['permissions-policy'] = 'fullscreen=()';
    res.writeHead(200, headers);
    res.end(playerHtml(url.searchParams));
    return;
  }
  res.writeHead(404);
  res.end();
}

function start(port, handler) {
  const server = createServer(handler);
  return new Promise((resolvePromise) => {
    server.listen(port, '127.0.0.1', () => resolvePromise(server));
  });
}

function manualHtml(extraHeader) {
  const cases = [
    ['redirect-current', '1. Redirect, current allow (no star)', `${origin(ports.src)}/redirect?case=manual-redirect-current`, currentAllow],
    ['redirect-adopted', '2. Redirect, adopted fullscreen *', `${origin(ports.src)}/redirect?case=manual-redirect-adopted`, adopted.allow],
    ['nested-missing', '3. Nested frame without allow', `${origin(ports.src)}/nest?case=manual-nested-missing&inner=none`, adopted.allow],
    ['same-adopted', '4. Same final origin, adopted', `${origin(ports.src)}/player?case=manual-same-adopted`, adopted.allow],
  ];
  const buttons = cases.map(([id, label]) => `<button type="button" data-case="${id}">${label}</button>`).join('\n');
  return `<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>Fictional embed fullscreen</title>
  <style>
    body { margin: 0; font: 16px sans-serif; background: #f4f1ea; color: #1b1b1b; }
    header, #controls, #log { padding: 12px 16px; }
    button { display: block; margin: 6px 0; padding: 8px 12px; font: 16px sans-serif; }
    #timeline { height: 360px; overflow-y: auto; background: #fff; border-top: 1px solid #999; border-bottom: 1px solid #999; }
    @supports (display: grid) {
      #timeline { contain: strict; }
      #timeline.fullscreen { contain: none; }
    }
    #intro { height: 240px; padding: 12px 16px; }
    #below { height: 900px; padding: 12px 16px; }
    #log { font: 14px/1.4 monospace; white-space: pre-wrap; }
  </style>
</head>
<body>
  <header>
    <strong>Fictional timeline</strong>
    <span id="scroll-label"></span>
    <div>Parent Permissions-Policy: ${extraHeader || '(none)'}</div>
  </header>
  <div id="timeline" class="scrollable">
    <div id="intro">Timeline rows above the player.</div>
    <div id="slot"></div>
    <div id="below">Timeline rows below the player.</div>
  </div>
  <div id="controls">
    ${buttons}
  </div>
  <pre id="log">Mount a case, then click Enter fullscreen inside the player.</pre>
  <script>
    const cases = ${JSON.stringify(Object.fromEntries(cases.map(([id, , src, allow]) => [id, { src, allow }])))};
    const timeline = document.getElementById('timeline');
    const log = document.getElementById('log');
    const scrollTarget = 240;
    const showScroll = () => {
      document.getElementById('scroll-label').textContent = 'scrollTop ' + timeline.scrollTop;
    };
    timeline.scrollTop = scrollTarget;
    showScroll();
    document.addEventListener('fullscreenchange', () => {
      timeline.classList.toggle('fullscreen', !!document.fullscreenElement);
      showScroll();
      log.textContent += '\\nfullscreenchange parent=' + (document.fullscreenElement ? document.fullscreenElement.id : 'null') + ' class=' + timeline.className + ' scrollTop=' + timeline.scrollTop;
    });
    window.addEventListener('message', (event) => {
      const data = event.data;
      if (!data || data.source !== 'fictional-player' || data.kind !== 'result') return;
      log.textContent += '\\n' + data.caseId + ' ok=' + data.ok + ' enabled=' + data.fullscreenEnabled + ' origin=' + data.origin + ' error=' + (data.errorMessage || '');
    });
    document.getElementById('controls').addEventListener('click', (event) => {
      const button = event.target.closest('button');
      if (!button) return;
      const spec = cases[button.dataset.case];
      const slot = document.getElementById('slot');
      slot.replaceChildren();
      const iframe = document.createElement('iframe');
      iframe.id = 'player';
      iframe.title = 'External video';
      iframe.style.cssText = 'width:640px;height:180px;border:0;display:block';
      iframe.setAttribute('sandbox', ${JSON.stringify(adopted.sandbox)});
      iframe.setAttribute('allow', spec.allow);
      iframe.setAttribute('allowfullscreen', '');
      iframe.setAttribute('referrerpolicy', ${JSON.stringify(adopted.referrerPolicy)});
      iframe.src = spec.src;
      slot.appendChild(iframe);
      log.textContent = 'Mounted ' + button.dataset.case + ' allow=' + spec.allow;
    });
  </script>
</body>
</html>`;
}

function parentHandler(extraHeader) {
  return (req, res) => {
    const url = new URL(req.url, `http://127.0.0.1:${ports.parent}`);
    const headers = { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' };
    if (extraHeader) headers['permissions-policy'] = extraHeader;
    res.writeHead(200, headers);
    res.end(url.pathname === '/manual' ? manualHtml(extraHeader) : parentHtml());
  };
}

function chromePath() {
  return process.env.CHROME_PATH || '/usr/bin/google-chrome-stable';
}

function connect(ws) {
  let seq = 0;
  const pending = new Map();
  ws.on('message', (data) => {
    const msg = JSON.parse(data.toString());
    if (msg.id && pending.has(msg.id)) {
      const { resolve: done, reject } = pending.get(msg.id);
      pending.delete(msg.id);
      if (msg.error) reject(new Error(JSON.stringify(msg.error)));
      else done(msg.result);
    }
  });
  return (method, params = {}) => new Promise((done, reject) => {
    const id = ++seq;
    pending.set(id, { resolve: done, reject });
    ws.send(JSON.stringify({ id, method, params }));
  });
}

const srcServer = await start(ports.src, routePlayer);
const otherServer = await start(ports.other, routePlayer);
const parents = {
  open: await start(ports.parent, parentHandler(null)),
  denied: await start(ports.denied, parentHandler('fullscreen=()')),
  self: await start(ports.self, parentHandler('fullscreen=(self)')),
  cohort: await start(ports.cohort, parentHandler('interest-cohort=()')),
};

if (process.argv.includes('--serve')) {
  process.stdout.write(`manual ${origin(ports.parent)}/manual\n`);
  process.stdout.write(`denied ${origin(ports.denied)}/manual\n`);
  process.stdout.write(`self ${origin(ports.self)}/manual\n`);
  await new Promise(() => {});
}

const profile = join(outDir, 'chrome-profile');
mkdirSync(profile, { recursive: true });
const debugPort = 47119;
const chrome = spawn(chromePath(), [
  '--no-sandbox',
  '--disable-dev-shm-usage',
  '--no-first-run',
  '--no-default-browser-check',
  '--disable-sync',
  '--disable-background-networking',
  `--remote-debugging-port=${debugPort}`,
  `--user-data-dir=${profile}`,
  '--window-size=1280,900',
  '--window-position=40,40',
  'about:blank',
], { stdio: 'ignore' });

async function waitForChrome() {
  for (let i = 0; i < 50; i += 1) {
    try {
      if ((await fetch(`http://127.0.0.1:${debugPort}/json/version`)).ok) return;
    } catch { /* retry */ }
    await delay(100);
  }
  throw new Error('Chrome did not start');
}

function playerSrc(path, caseId, extra = '') {
  return `${origin(ports.src)}${path}?case=${encodeURIComponent(caseId)}${extra}`;
}

const groups = [
  {
    name: 'no-parent-permissions-policy',
    base: origin(ports.parent),
    cases: [
      {
        id: 'same-origin-current',
        src: playerSrc('/player', 'same-origin-current'),
        allow: currentAllow,
        sandbox: adopted.sandbox,
        allowfullscreen: true,
        finalOrigin: origin(ports.src),
        expectOk: true,
        gesture: true,
        shot: true,
      },
      {
        id: 'same-origin-adopted',
        src: playerSrc('/player', 'same-origin-adopted'),
        allow: adopted.allow,
        sandbox: adopted.sandbox,
        allowfullscreen: true,
        referrerPolicy: adopted.referrerPolicy,
        finalOrigin: origin(ports.src),
        expectOk: true,
        gesture: true,
      },
      {
        id: 'redirect-current',
        src: playerSrc('/redirect', 'redirect-current'),
        allow: currentAllow,
        sandbox: adopted.sandbox,
        allowfullscreen: true,
        finalOrigin: origin(ports.other),
        expectOk: false,
        expectError: 'Disallowed by permissions policy',
        gesture: true,
        shot: true,
      },
      {
        id: 'redirect-allowfullscreen-only',
        src: playerSrc('/redirect', 'redirect-allowfullscreen-only'),
        allow: 'encrypted-media; picture-in-picture',
        sandbox: adopted.sandbox,
        allowfullscreen: true,
        finalOrigin: origin(ports.other),
        expectOk: true,
        gesture: true,
      },
      {
        id: 'redirect-explicit-src',
        src: playerSrc('/redirect', 'redirect-explicit-src'),
        allow: `fullscreen ${origin(ports.src)}`,
        sandbox: adopted.sandbox,
        allowfullscreen: true,
        finalOrigin: origin(ports.other),
        expectOk: false,
        expectError: 'Disallowed by permissions policy',
        gesture: true,
      },
      {
        id: 'redirect-explicit-both',
        src: playerSrc('/redirect', 'redirect-explicit-both'),
        allow: `fullscreen ${origin(ports.src)} ${origin(ports.other)}`,
        sandbox: adopted.sandbox,
        allowfullscreen: true,
        finalOrigin: origin(ports.other),
        expectOk: true,
        gesture: true,
      },
      {
        id: 'redirect-adopted',
        src: playerSrc('/redirect', 'redirect-adopted'),
        allow: adopted.allow,
        sandbox: adopted.sandbox,
        allowfullscreen: true,
        referrerPolicy: adopted.referrerPolicy,
        finalOrigin: origin(ports.other),
        expectOk: true,
        gesture: true,
        checkSession: true,
        shot: true,
      },
      {
        id: 'nested-current',
        src: playerSrc('/nest', 'nested-current', '&inner=star'),
        allow: currentAllow,
        sandbox: adopted.sandbox,
        allowfullscreen: true,
        finalOrigin: origin(ports.other),
        expectOk: true,
        gesture: true,
        note: 'outer allowlist is src only; inner frame delegates fullscreen *',
        shot: true,
      },
      {
        id: 'nested-adopted',
        src: playerSrc('/nest', 'nested-adopted', '&inner=star'),
        allow: adopted.allow,
        sandbox: adopted.sandbox,
        allowfullscreen: true,
        finalOrigin: origin(ports.other),
        expectOk: true,
        gesture: true,
        shot: true,
      },
      {
        id: 'nested-inner-missing',
        src: playerSrc('/nest', 'nested-inner-missing', '&inner=none'),
        allow: adopted.allow,
        sandbox: adopted.sandbox,
        allowfullscreen: true,
        finalOrigin: origin(ports.other),
        expectOk: false,
        expectError: 'Disallowed by permissions policy',
        gesture: true,
        shot: true,
      },
      {
        id: 'no-gesture-adopted',
        src: playerSrc('/player', 'no-gesture-adopted', '&immediate=1'),
        allow: adopted.allow,
        sandbox: adopted.sandbox,
        allowfullscreen: true,
        finalOrigin: origin(ports.src),
        expectOk: false,
        expectEnabled: true,
        expectError: 'Permissions check failed',
        gesture: false,
        shot: true,
      },
      {
        id: 'child-denied',
        src: playerSrc('/player', 'child-denied', '&deny=1'),
        allow: adopted.allow,
        sandbox: adopted.sandbox,
        allowfullscreen: true,
        finalOrigin: origin(ports.src),
        expectOk: false,
        expectError: 'Disallowed by permissions policy',
        gesture: true,
        shot: true,
      },
      {
        id: 'remove-while-fullscreen',
        src: playerSrc('/player', 'remove-while-fullscreen'),
        allow: adopted.allow,
        sandbox: adopted.sandbox,
        allowfullscreen: true,
        finalOrigin: origin(ports.src),
        expectOk: true,
        gesture: true,
        remove: true,
        shot: true,
      },
    ],
  },
  {
    name: 'parent-fullscreen-none',
    base: origin(ports.denied),
    cases: [
      {
        id: 'parent-denied',
        src: playerSrc('/player', 'parent-denied'),
        allow: adopted.allow,
        sandbox: adopted.sandbox,
        allowfullscreen: true,
        finalOrigin: origin(ports.src),
        expectOk: false,
        expectError: 'Disallowed by permissions policy',
        gesture: true,
        shot: true,
      },
    ],
  },
  {
    name: 'parent-fullscreen-self',
    base: origin(ports.self),
    cases: [
      {
        id: 'parent-self',
        src: playerSrc('/player', 'parent-self'),
        allow: adopted.allow,
        sandbox: adopted.sandbox,
        allowfullscreen: true,
        finalOrigin: origin(ports.src),
        expectOk: false,
        expectError: 'Disallowed by permissions policy',
        gesture: true,
        shot: true,
      },
    ],
  },
  {
    name: 'parent-interest-cohort-only',
    base: origin(ports.cohort),
    cases: [
      {
        id: 'cohort-adopted',
        src: playerSrc('/player', 'cohort-adopted'),
        allow: adopted.allow,
        sandbox: adopted.sandbox,
        allowfullscreen: true,
        finalOrigin: origin(ports.src),
        expectOk: true,
        gesture: true,
        shot: true,
      },
    ],
  },
];

await waitForChrome();
const version = await (await fetch(`http://127.0.0.1:${debugPort}/json/version`)).json();
const list = await (await fetch(`http://127.0.0.1:${debugPort}/json/list`)).json();
const page = list.find((target) => target.type === 'page');
const ws = new WebSocket(page.webSocketDebuggerUrl);
await new Promise((done, reject) => {
  ws.once('open', done);
  ws.once('error', reject);
});
const send = connect(ws);
await send('Page.enable');
await send('Runtime.enable');
await send('Page.bringToFront');

async function navigate(url) {
  const loaded = new Promise((done) => {
    const onMessage = (data) => {
      const msg = JSON.parse(data.toString());
      if (msg.method === 'Page.loadEventFired') {
        ws.off('message', onMessage);
        done();
      }
    };
    ws.on('message', onMessage);
  });
  await send('Page.navigate', { url });
  await Promise.race([loaded, delay(8000)]);
  await delay(150);
}

async function evaluate(expression, awaitPromise = false) {
  const result = await send('Runtime.evaluate', {
    expression,
    returnByValue: true,
    awaitPromise,
  });
  if (result.exceptionDetails) {
    const text = result.exceptionDetails.text || 'evaluate failed';
    throw new Error(`${text}: ${expression.slice(0, 180)}`);
  }
  return result.result.value;
}

async function shot(name) {
  const image = await send('Page.captureScreenshot', { format: 'png' });
  const file = join(outDir, `${name}.png`);
  writeFileSync(file, Buffer.from(image.data, 'base64'));
  return file;
}

async function clickFrame() {
  const rect = await evaluate(`(() => {
    const frame = document.getElementById('player');
    if (!frame) return null;
    const box = frame.getBoundingClientRect();
    return { x: box.x, y: box.y, width: box.width, height: box.height };
  })()`);
  if (!rect || rect.width < 10 || rect.height < 10) {
    throw new Error(`iframe is not visible: ${JSON.stringify(rect)}`);
  }
  const x = rect.x + 48;
  const y = rect.y + 30;
  await send('Input.dispatchMouseEvent', { type: 'mouseMoved', x, y });
  await send('Input.dispatchMouseEvent', { type: 'mousePressed', x, y, button: 'left', clickCount: 1 });
  await send('Input.dispatchMouseEvent', { type: 'mouseReleased', x, y, button: 'left', clickCount: 1 });
  return { x, y, rect };
}

async function waitForResult(caseId) {
  const started = Date.now();
  while (Date.now() - started < 4000) {
    const log = await evaluate('window.__log');
    const found = (log || []).find((entry) => entry.caseId === caseId && entry.kind === 'result' && entry.event !== 'report');
    if (found) return found;
    await delay(50);
  }
  return null;
}

async function latestReport(caseId) {
  const started = Date.now();
  let seen = await evaluate(`(window.__log || []).filter((entry) => entry.caseId === ${JSON.stringify(caseId)} && entry.event === 'report').length`);
  await evaluate('window.__ask()');
  while (Date.now() - started < 2000) {
    const log = await evaluate('window.__log');
    const reports = (log || []).filter((entry) => entry.caseId === caseId && entry.event === 'report');
    if (reports.length > seen) return reports[reports.length - 1];
    await delay(50);
  }
  return null;
}

const rows = [];

try {
  for (const group of groups) {
    await navigate(`${group.base}/`);
    for (const spec of group.cases) {
      const problems = [];
      const row = { id: spec.id, group: group.name, informational: !!spec.informational };
      try {
        await evaluate('window.__log = []; window.__fullscreenEvents = []; window.__prepare()');
        const preparedScroll = await evaluate('document.getElementById("timeline").scrollTop');
        row.preparedScroll = preparedScroll;
        if (Math.abs(preparedScroll - 240) > 1) problems.push(`could not set scrollTop (${preparedScroll})`);
        const mounted = await evaluate(`window.__mount(${JSON.stringify({
          caseId: spec.id,
          src: spec.src,
          allow: spec.allow,
          sandbox: spec.sandbox,
          allowfullscreen: spec.allowfullscreen,
          referrerPolicy: spec.referrerPolicy,
          wait: spec.gesture ? 'ready' : 'result',
        })})`, true);
        row.mounted = mounted;
        if (!mounted || mounted.timeout) problems.push('iframe did not become ready');
        let result = null;
        if (spec.gesture) {
          row.click = await clickFrame();
          result = await waitForResult(spec.id);
        } else {
          result = mounted && mounted.kind === 'result' ? mounted : await waitForResult(spec.id);
        }
        row.result = result;
        const observed = await evaluate('window.__observe()');
        row.during = observed;
        if (!result) {
          problems.push('no requestFullscreen result');
        } else {
          if (spec.finalOrigin && result.origin !== spec.finalOrigin) {
            problems.push(`final origin ${result.origin} != ${spec.finalOrigin}`);
          }
          if (spec.expectOk !== null && result.ok !== spec.expectOk) {
            problems.push(`requestFullscreen ok ${result.ok} != ${spec.expectOk} (${result.errorName || ''} ${result.errorMessage || ''})`);
          }
          if (spec.expectEnabled != null && result.fullscreenEnabled !== spec.expectEnabled) {
            problems.push(`fullscreenEnabled ${result.fullscreenEnabled} != ${spec.expectEnabled}`);
          }
          if (spec.expectError && !(result.errorMessage || '').includes(spec.expectError)) {
            problems.push(`error ${result.errorName || ''} ${result.errorMessage || ''} does not include ${spec.expectError}`);
          }
          if (result.referrer) problems.push(`referrer was sent: ${result.referrer}`);
          if (spec.expectOk === true) {
            if (observed.fullscreenTag !== 'IFRAME') problems.push(`parent fullscreen element ${observed.fullscreenTag}`);
            if (!result.innerFullscreen) problems.push('inner fullscreenElement was empty');
          }
          if (spec.expectOk === false && observed.fullscreenTag) {
            problems.push(`parent entered fullscreen despite denial (${observed.fullscreenTag})`);
          }
        }
        if (spec.shot && result && result.ok) row.duringShot = await shot(`${spec.id}-during`);
        if (spec.checkSession && result && result.ok) {
          await delay(350);
          const exited = await evaluate('window.__exit()', true);
          row.exited = exited;
          const report = await latestReport(spec.id);
          row.session = report;
          const after = await evaluate('window.__observe()');
          row.after = after;
          if (!report) problems.push('session report missing');
          else {
            if (report.token !== result.token) problems.push('player document was replaced');
            if (report.ticks <= result.ticks) problems.push(`ticks did not advance (${result.ticks} -> ${report.ticks})`);
            if (report.stillFullscreen) problems.push('inner document stayed fullscreen');
          }
          if (after.fullscreenTag) problems.push('parent stayed fullscreen');
          if (after.timelineClass.includes('fullscreen')) problems.push(`timeline class stuck: ${after.timelineClass}`);
          if (Math.abs(after.scrollTop - preparedScroll) > 1) {
            problems.push(`scrollTop ${preparedScroll} -> ${after.scrollTop}`);
          }
          await evaluate(`window.__banner(${JSON.stringify(spec.id + ' exited')}, ${JSON.stringify(JSON.stringify({ after, report }, null, 2))})`);
          row.exitShot = await shot(`${spec.id}-exited`);
        }
        if (spec.remove && result && result.ok) {
          const removed = await evaluate('window.__remove()');
          const started = Date.now();
          let after = removed;
          while ((after.fullscreenTag || (after.timelineClass || '').includes('fullscreen')) && Date.now() - started < 1500) {
            await delay(50);
            after = await evaluate('window.__observe()');
          }
          row.removed = after;
          row.fullscreenEvents = await evaluate('window.__fullscreenEvents');
          if (after.fullscreenTag) problems.push('removing the iframe left fullscreen active');
          if (after.iframe) problems.push('iframe node remained');
          if (after.timelineClass.includes('fullscreen')) problems.push(`timeline class stuck after remove: ${after.timelineClass}`);
          if (Math.abs(after.scrollTop - preparedScroll) > 1) {
            problems.push(`scrollTop after remove ${preparedScroll} -> ${after.scrollTop}`);
          }
        }
        await evaluate(`window.__banner(${JSON.stringify(`${spec.id} ok=${result ? result.ok : 'none'}`)}, ${JSON.stringify(JSON.stringify(result, null, 2))})`);
        if (spec.shot) row.shot = await shot(spec.id);
        if (!spec.checkSession) {
          await evaluate('window.__exit()', true);
          await evaluate('document.getElementById("slot").replaceChildren()');
        }
      } catch (error) {
        problems.push(error.message);
        try { row.shot = await shot(`${spec.id}-error`); } catch { /* no shot */ }
      }
      row.problems = problems;
      row.pass = problems.length === 0;
      rows.push(row);
      process.stdout.write(`${row.pass ? 'PASS' : 'FAIL'} ${spec.id}${spec.informational ? ' (info)' : ''}\n`);
      if (!row.pass) process.stdout.write(`  ${problems.join('\n  ')}\n`);
    }
  }
} finally {
  const summary = rows.map((row) => `${row.pass ? 'PASS' : 'FAIL'} ${row.id}${row.informational ? ' info' : ''}`).join('\n');
  try {
    await evaluate(`window.__summary(${JSON.stringify(summary)})`);
    await evaluate('window.__banner("probe summary", "")');
    await shot('summary');
  } catch { /* page may be closed */ }
  ws.close();
  chrome.kill('SIGTERM');
  await delay(200);
  if (!chrome.killed) chrome.kill('SIGKILL');
  for (const server of [srcServer, otherServer, ...Object.values(parents)]) server.close();
}

const required = rows.filter((row) => !row.informational);
const report = {
  browser: version.Browser,
  adopted,
  currentAllow,
  origins: {
    parent: origin(ports.parent),
    src: origin(ports.src),
    other: origin(ports.other),
  },
  rows,
  passed: required.every((row) => row.pass),
};
writeFileSync(join(outDir, 'report.json'), JSON.stringify(report, null, 2));
process.stdout.write(`${report.passed ? 'PASS' : 'FAIL'} ${required.filter((row) => row.pass).length}/${required.length} required\n`);
process.exit(report.passed ? 0 : 1);
