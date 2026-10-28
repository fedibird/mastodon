// Fullscreen through the real createFrame path.
// Two fictional origins. One player redirects to the other, then requests
// fullscreen. The iframe is the one openSession creates. Headed Chrome is
// required because headless requestFullscreen does not exercise the feature.

import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { mkdtempSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import { writeFileSync } from 'node:fs';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const require = createRequire(import.meta.url);

const playerHtml = (caseId) => `<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><title>Fictional player</title></head>
<body style="margin:0;background:#14302a;color:#fff;font:16px sans-serif">
  <button id="go" type="button" style="margin:12px;min-height:44px">Enter fullscreen</button>
  <pre id="status"></pre>
  <script>
    const caseId = ${JSON.stringify(caseId)};
    const token = Math.random().toString(36).slice(2);
    let ticks = 0;
    setInterval(() => { ticks += 1; }, 100);
    function snapshot(extra) {
      let allowsFeature = null;
      try { allowsFeature = !!(document.permissionsPolicy && document.permissionsPolicy.allowsFeature('fullscreen')); } catch (error) { allowsFeature = null; }
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
      document.getElementById('status').textContent = JSON.stringify(payload);
      parent.postMessage(payload, '*');
    }
    publish(snapshot({ kind: 'ready', event: 'ready' }));
    document.getElementById('go').addEventListener('click', () => {
      const attempt = document.documentElement.requestFullscreen();
      Promise.resolve(attempt).then(
        () => publish(snapshot({ kind: 'result', event: 'click', ok: true, errorName: null, errorMessage: null })),
        (error) => publish(snapshot({ kind: 'result', event: 'click', ok: false, errorName: error.name, errorMessage: String(error.message) })),
      );
    });
    window.addEventListener('message', (event) => {
      if (!event.data || event.data.command !== 'report') return;
      publish(snapshot({ kind: 'result', event: 'report', stillFullscreen: !!document.fullscreenElement }));
    });
  </script>
</body>
</html>`;

const listen = (handler) => new Promise((resolve) => {
  const server = createServer(handler);
  server.listen(0, '127.0.0.1', () => resolve(server));
});

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const bundleSession = async (dir) => {
  const outfile = join(dir, 'session_bundle.js');
  await new Promise((resolve, reject) => {
    const child = spawn('npx', ['--yes', 'esbuild', join(root, 'app/javascript/mastodon/external_player/session.js'), '--bundle', '--format=iife', '--global-name=ExternalPlayer', `--outfile=${outfile}`], { stdio: 'inherit' });
    child.on('exit', (code) => (code === 0 ? resolve() : reject(new Error(`esbuild exited ${code}`))));
  });
  return readFileSync(outfile);
};

const run = async () => {
  const dir = mkdtempSync(join(tmpdir(), 'external-player-fullscreen-'));
  const bundle = await bundleSession(dir);
  const other = await listen((req, res) => {
    const url = new URL(req.url, 'http://127.0.0.1');
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
    res.end(playerHtml(url.searchParams.get('case') || 'direct'));
  });
  const otherOrigin = `http://127.0.0.1:${other.address().port}`;
  const src = await listen((req, res) => {
    if (req.url.startsWith('/redirect')) {
      res.writeHead(302, { location: `${otherOrigin}/player?case=redirect` });
      res.end();
      return;
    }
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
    res.end(playerHtml('direct'));
  });
  const srcOrigin = `http://127.0.0.1:${src.address().port}`;
  const parentHtml = `<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><title>Fullscreen probe</title>
<style>
  #column { height: 360px; overflow: auto; border: 1px solid #999; }
  #anchor { height: 180px; }
  #timeline.fullscreen { outline: 4px solid #0d6b3d; }
</style></head>
<body>
  <div id="timeline">
    <div id="column"><div id="anchor"></div><div style="height:800px"></div></div>
  </div>
  <script src="/session_bundle.js"></script>
  <script>
    const samples = [];
    window.addEventListener('message', (event) => {
      if (!event.data || event.data.source !== 'fictional-player') return;
      samples.push(event.data);
    });
    const P = ExternalPlayer;
    window.__samples = () => samples.slice();
    window.__clearSamples = () => { samples.length = 0; };
    window.__close = () => {
      if (window.__session) P.closeSession(window.__session.key);
      window.__session = null;
    };
    window.__open = (url) => {
      window.__close();
      const session = P.openSession({ statusId: 'status-1', mediaId: url, kind: 'iframe', url });
      window.__session = session;
      if (!session || !session.node) return { error: 'no-session', keys: Object.keys(P) };
      const node = session.node;
      const before = {
        connected: node.isConnected,
        parent: node.parentElement && node.parentElement.id,
        allow: node.getAttribute('allow'),
      };
      P.registerAnchor({ key: session.key, element: document.getElementById('anchor'), prefer: true, releaseMode: () => 'detach' });
      P.layoutExternalPlayers();
      return {
        before,
        allow: node.getAttribute('allow'),
        sandbox: node.getAttribute('sandbox'),
        referrer: node.getAttribute('referrerpolicy'),
        allowfullscreen: node.hasAttribute('allowfullscreen'),
        parentId: node.parentElement && node.parentElement.id,
        connected: node.isConnected,
      };
    };
    window.__node = () => document.querySelector('#external-player-host iframe');
    document.addEventListener('fullscreenchange', () => {
      document.getElementById('timeline').classList.toggle('fullscreen', !!document.fullscreenElement);
    });
    window.__observe = () => ({
      fullscreenTag: document.fullscreenElement ? document.fullscreenElement.tagName : null,
      timelineClass: document.getElementById('timeline').className,
      scrollTop: document.getElementById('column').scrollTop,
    });
  </script>
</body></html>`;
  const parent = await listen((req, res) => {
    if (req.url.startsWith('/session_bundle.js')) {
      res.writeHead(200, { 'content-type': 'text/javascript; charset=utf-8' });
      res.end(bundle);
      return;
    }
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
    res.end(parentHtml);
  });

  const puppeteer = require('puppeteer-core');
  const browser = await puppeteer.launch({
    executablePath: '/usr/bin/google-chrome',
    headless: false,
    args: ['--no-sandbox', '--disable-dev-shm-usage'],
  });
  const report = { browser: await browser.version(), cases: [] };
  try {
    const page = await browser.newPage();
    await page.setViewport({ width: 900, height: 800 });
    await page.goto(`http://127.0.0.1:${parent.address().port}/`, { waitUntil: 'domcontentloaded' });

    const attempt = async (name, url) => {
      await page.evaluate('window.__close && window.__close()');
      await page.evaluate('window.__clearSamples()');
      const created = await page.evaluate((target) => window.__open(target), url);
      if (!created.connected) throw new Error(`iframe was not inserted: ${JSON.stringify(created)}`);
      await sleep(500);
      const ready = await page.evaluate(() => window.__samples().filter((item) => item.event === 'ready').pop());
      const box = await page.evaluate(() => {
        const iframe = window.__node();
        const rect = iframe.getBoundingClientRect();
        return { x: rect.x + 40, y: rect.y + 24, width: rect.width, height: rect.height };
      });
      await page.mouse.click(box.x, box.y);
      await sleep(600);
      const during = await page.evaluate(() => ({
        result: window.__samples().filter((item) => item.event === 'click').pop(),
        observed: window.__observe(),
      }));
      if (during.observed.fullscreenTag) {
        await page.evaluate(() => document.exitFullscreen());
        await sleep(300);
      }
      await page.evaluate(() => {
        const iframe = window.__node();
        if (iframe && iframe.contentWindow) iframe.contentWindow.postMessage({ command: 'report' }, '*');
      });
      await sleep(300);
      const after = await page.evaluate(() => ({
        report: window.__samples().filter((item) => item.event === 'report').pop(),
        observed: window.__observe(),
        allow: window.__node() && window.__node().getAttribute('allow'),
      }));
      const row = { name, created, ready, during, after };
      row.pass = !!(
        created.connected === true &&
        created.before.connected === true &&
        created.allow === 'fullscreen *; encrypted-media; picture-in-picture' &&
        created.allowfullscreen === true &&
        created.referrer === 'no-referrer' &&
        ready && ready.referrer === '' &&
        during.result && during.result.ok === true &&
        (name !== 'redirect' || (ready && ready.origin !== new URL(url).origin)) &&
        during.observed.fullscreenTag === 'IFRAME' &&
        after.report && after.report.token === ready.token && after.report.ticks >= ready.ticks &&
        after.report.stillFullscreen === false &&
        after.observed.fullscreenTag === null &&
        !after.observed.timelineClass.includes('fullscreen')
      );
      report.cases.push(row);
      return row;
    };

    await attempt('direct', `${srcOrigin}/player?case=direct`);
    await page.screenshot({ path: '/opt/cursor/artifacts/external-player-fullscreen-direct.png', fullPage: true });
    await attempt('redirect', `${srcOrigin}/redirect?case=redirect`);
    await page.screenshot({ path: '/opt/cursor/artifacts/external-player-fullscreen-redirect.png', fullPage: true });
    report.pass = report.cases.every((row) => row.pass);
  } finally {
    await browser.close();
    other.close();
    src.close();
    parent.close();
  }

  writeFileSync('/opt/cursor/artifacts/external-player-fullscreen.json', JSON.stringify(report, null, 2));
  if (!report.pass) {
    console.error(JSON.stringify(report, null, 2));
    process.exit(1);
  }
  console.log(JSON.stringify(report, null, 2));
};

run().catch((error) => {
  console.error(error);
  process.exit(1);
});
