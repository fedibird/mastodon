// Cross-origin check for the external player host.
// Two local origins. The fixture counts document loads, mints a token per
// document, and advances an in-page tick. The parent records postMessage
// samples. Element identity is logged and is not the pass condition.

import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const fixturePath = join(root, 'spec/fixtures/external_bridge/player_session.html');
const require = createRequire(import.meta.url);

const wav = () => {
  const sampleRate = 8000;
  const seconds = 2;
  const samples = sampleRate * seconds;
  const data = Buffer.alloc(44 + samples * 2);
  data.write('RIFF', 0);
  data.writeUInt32LE(36 + samples * 2, 4);
  data.write('WAVE', 8);
  data.write('fmt ', 12);
  data.writeUInt32LE(16, 16);
  data.writeUInt16LE(1, 20);
  data.writeUInt16LE(1, 22);
  data.writeUInt32LE(sampleRate, 24);
  data.writeUInt32LE(sampleRate * 2, 28);
  data.writeUInt16LE(2, 32);
  data.writeUInt16LE(16, 34);
  data.write('data', 36);
  data.writeUInt32LE(samples * 2, 40);
  return data;
};

const listen = (handler) => new Promise((resolve) => {
  const server = createServer(handler);
  server.listen(0, '127.0.0.1', () => resolve(server));
});

const fixtureHtml = readFileSync(fixturePath);

const bundleSession = async (dir) => {
  const outfile = join(dir, 'session_bundle.js');
  await new Promise((resolve, reject) => {
    const child = spawn('npx', [
      '--yes',
      'esbuild',
      join(root, 'app/javascript/mastodon/external_player/session.js'),
      '--bundle',
      '--format=iife',
      '--global-name=ExternalPlayer',
      `--outfile=${outfile}`,
    ], { stdio: 'inherit' });
    child.on('exit', (code) => (code === 0 ? resolve() : reject(new Error(`esbuild exited ${code}`))));
  });
  return readFileSync(outfile);
};

const harnessHtml = (fixtureOrigin) => `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>External player check</title>
  <style>
    body { font: 16px/1.4 sans-serif; margin: 16px; }
    #column { height: 180px; overflow: auto; border: 1px solid #999; }
    #anchor { height: 180px; background: #ddd; }
    #spacer { height: 900px; }
    #dock { position: fixed; right: 12px; bottom: 12px; width: 320px; background: #fff; border: 1px solid #333; }
    #slot { height: 180px; }
    button { min-height: 44px; margin: 4px; }
    #log { white-space: pre-wrap; }
  </style>
</head>
<body>
  <div id="column"><div id="anchor"></div><div id="spacer"></div></div>
  <div id="dock"><p>Fixed player</p><div id="slot"></div></div>
  <button id="load" type="button">Load</button>
  <button id="pin" type="button">Pop out</button>
  <button id="back" type="button">Return to the post</button>
  <button id="close" type="button">Close</button>
  <button id="play" type="button">Play audio</button>
  <button id="pause" type="button">Pause audio</button>
  <pre id="log"></pre>
  <script src="/session_bundle.js"></script>
  <script>
    const P = ExternalPlayer;
    const fixture = ${JSON.stringify(fixtureOrigin + '/player_session.html')};
    const audioUrl = ${JSON.stringify(fixtureOrigin + '/tone.wav')};
    const samples = [];
    window.addEventListener('message', (event) => {
      if (!event.data || event.data.source !== 'fedibird-player-fixture') return;
      samples.push(Object.assign({ at: Date.now() }, event.data));
    });
    const log = (text) => { document.getElementById('log').textContent += text + '\\n'; };
    let session = null;
    let anchorId = null;
    document.getElementById('load').addEventListener('click', () => {
      session = P.openSession({ statusId: 'status-1', mediaId: 'media-1', kind: 'iframe', url: fixture });
      anchorId = P.registerAnchor({
        key: session.key,
        element: document.getElementById('anchor'),
        prefer: true,
        releaseMode: () => 'detach',
      });
      P.registerDockSlot(document.getElementById('slot'));
      P.layoutExternalPlayers();
      log('opened parent=' + session.node.parentElement.id);
    });
    document.getElementById('pin').addEventListener('click', () => {
      P.pinSession(session.key);
      P.layoutExternalPlayers();
      log('pinned parent=' + session.node.parentElement.id + ' sameNode=' + (session.node.parentElement.id === 'external-player-host'));
    });
    document.getElementById('back').addEventListener('click', () => {
      const result = P.unpinSession(session.key);
      P.layoutExternalPlayers();
      log('returned ' + JSON.stringify(result) + ' parent=' + (session.node && session.node.parentElement && session.node.parentElement.id));
    });
    document.getElementById('close').addEventListener('click', () => {
      P.closeSession(session.key);
      log('closed');
    });
    let audio = null;
    document.getElementById('play').addEventListener('click', async () => {
      audio = P.openSession({ statusId: 'status-2', mediaId: 'talk-1', kind: 'audio', url: audioUrl });
      P.registerAnchor({
        key: audio.key,
        element: document.getElementById('anchor'),
        prefer: true,
        releaseMode: () => 'detach',
      });
      await audio.node.play();
      log('audio playing paused=' + audio.node.paused + ' t=' + audio.node.currentTime);
    });
    document.getElementById('pause').addEventListener('click', () => {
      audio.node.pause();
      log('audio paused=' + audio.node.paused + ' t=' + audio.node.currentTime);
    });
    window.__samples = () => samples.slice();
    window.__sessionNode = () => session && session.node;
    window.__audioNode = () => audio && audio.node;
    window.__api = P;
  </script>
</body>
</html>`;

const latest = (samples) => samples[samples.length - 1];

const waitFor = async (page, predicate, timeout = 4000) => {
  const start = Date.now();
  while (Date.now() - start < timeout) {
    const value = await page.evaluate(predicate);
    if (value) return value;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error('timed out waiting for fixture messages');
};

const run = async () => {
  const dir = mkdtempSync(join(tmpdir(), 'external-player-'));
  const bundle = await bundleSession(dir);
  const tone = wav();
  const fixtureServer = await listen((req, res) => {
    if (req.url.startsWith('/tone.wav')) {
      res.writeHead(200, { 'content-type': 'audio/wav', 'access-control-allow-origin': '*' });
      res.end(tone);
      return;
    }
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
    res.end(fixtureHtml);
  });
  const fixturePort = fixtureServer.address().port;
  const fixtureOrigin = `http://127.0.0.1:${fixturePort}`;
  const pageHtml = harnessHtml(fixtureOrigin);
  const harnessServer = await listen((req, res) => {
    if (req.url.startsWith('/session_bundle.js')) {
      res.writeHead(200, { 'content-type': 'text/javascript; charset=utf-8' });
      res.end(bundle);
      return;
    }
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
    res.end(pageHtml);
  });
  const harnessPort = harnessServer.address().port;

    const puppeteer = require('puppeteer-core');
  const browser = await puppeteer.launch({
    executablePath: '/usr/bin/google-chrome',
    headless: 'new',
    args: ['--no-sandbox', '--disable-dev-shm-usage'],
  });
  const page = await browser.newPage();
  const report = { browser: 'Chromium', mobile: null, iframe: null, reloadDetected: null, audio: null };
  try {
    await page.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true });
    await page.goto(`http://127.0.0.1:${harnessPort}/`, { waitUntil: 'domcontentloaded' });
    await page.click('#load');
    const first = await waitFor(page, () => {
      const samples = window.__samples();
      return samples.length ? samples[samples.length - 1] : null;
    });
    await new Promise((resolve) => setTimeout(resolve, 350));
    await page.click('#pin');
    const column = await page.$('#column');
    await column.evaluate((node) => { node.scrollTop = node.scrollHeight; });
    await new Promise((resolve) => setTimeout(resolve, 400));
    await page.evaluate(() => { document.getElementById('column').scrollTop = 0; });
    await page.click('#back');
    await new Promise((resolve) => setTimeout(resolve, 350));
    const after = await page.evaluate(() => {
      const samples = window.__samples();
      const node = window.__sessionNode();
      return {
        last: samples[samples.length - 1],
        count: samples.length,
        parentId: node && node.parentElement && node.parentElement.id,
        src: node && node.getAttribute('src'),
        sandbox: node && node.getAttribute('sandbox'),
        allow: node && node.getAttribute('allow'),
        referrer: node && node.getAttribute('referrerpolicy'),
        log: document.getElementById('log').textContent,
      };
    });
    report.iframe = {
      first,
      after: after.last,
      messageCount: after.count,
      parentId: after.parentId,
      sandbox: after.sandbox,
      allow: after.allow,
      referrer: after.referrer,
      preserved: first.token === after.last.token && first.loads === 1 && after.last.loads === 1 && after.last.ticks > first.ticks,
    };
    await page.screenshot({ path: '/opt/cursor/artifacts/external-player-preserved.png', fullPage: true });

    await page.evaluate(() => {
      const node = window.__sessionNode();
      node.src = node.src;
    });
    await waitFor(page, () => {
      const samples = window.__samples();
      const last = samples[samples.length - 1];
      return last && last.loads > 1 ? last : null;
    });
    const reloaded = await page.evaluate(() => window.__samples().slice(-1)[0]);
    report.reloadDetected = {
      loads: reloaded.loads,
      tokenChanged: reloaded.token !== first.token,
    };

    await page.evaluate(() => { document.getElementById('column').scrollTop = 0; });
    await page.click('#play');
    await new Promise((resolve) => setTimeout(resolve, 500));
    const playing = await page.evaluate(() => {
      const node = window.__audioNode();
      window.__api.layoutExternalPlayers();
      return node ? { paused: node.paused, currentTime: node.currentTime, parentId: node.parentElement && node.parentElement.id } : null;
    });
    await page.evaluate(() => {
      document.getElementById('column').scrollTop = document.getElementById('column').scrollHeight;
      window.__api.layoutExternalPlayers();
    });
    await new Promise((resolve) => setTimeout(resolve, 300));
    const continued = await page.evaluate(() => {
      const node = window.__audioNode();
      return node ? {
        paused: node.paused,
        currentTime: node.currentTime,
        parentId: node.parentElement && node.parentElement.id,
        pinned: window.__api.getPinnedKey(),
      } : null;
    });
    await page.click('#pause');
    const paused = await page.evaluate(() => {
      const node = window.__audioNode();
      return { paused: node.paused, currentTime: node.currentTime, pinned: window.__api.getPinnedKey() };
    });
    report.audio = { playing, continued, paused };
    report.mobile = { viewport: await page.viewport(), buttons: await page.$$eval('button', (nodes) => nodes.map((node) => ({ text: node.textContent, height: node.getBoundingClientRect().height }))) };
    await page.screenshot({ path: '/opt/cursor/artifacts/external-player-audio.png', fullPage: true });
    report.browser = await browser.version();
  } finally {
    await browser.close();
    fixtureServer.close();
    harnessServer.close();
  }

  writeFileSync('/opt/cursor/artifacts/external-player-browser.json', JSON.stringify(report, null, 2));
  const ok = report.iframe && report.iframe.preserved && report.reloadDetected && report.reloadDetected.tokenChanged && report.reloadDetected.loads > 1 && report.audio && report.audio.playing.paused === false && report.audio.continued.paused === false && report.audio.continued.currentTime > 0 && report.audio.paused.paused === true;
  if (!ok) {
    console.error(JSON.stringify(report, null, 2));
    process.exit(1);
  }
  console.log(JSON.stringify(report, null, 2));
};

run().catch((error) => {
  console.error(error);
  process.exit(1);
});
