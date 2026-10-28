// Position follow-through for the production player components.
// This page does not call layoutExternalPlayers. A content warning, an
// expanded body, and an image above the player change the list size, and
// the host iframe has to move on its own. Pin and return keep the same
// cross-origin document.

import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { deflateSync } from 'node:zlib';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const require = createRequire(import.meta.url);
const fixtureHtml = readFileSync(join(root, 'spec/fixtures/external_bridge/player_session.html'));

const crcTable = (() => {
  const table = new Uint32Array(256);
  for (let index = 0; index < 256; index += 1) {
    let crc = index;
    for (let bit = 0; bit < 8; bit += 1) {
      crc = (crc & 1) ? (0xedb88320 ^ (crc >>> 1)) : (crc >>> 1);
    }
    table[index] = crc;
  }
  return table;
})();

const crc32 = (buffer) => {
  let crc = 0xffffffff;
  for (const byte of buffer) crc = crcTable[(crc ^ byte) & 0xff] ^ (crc >>> 8);
  return (crc ^ 0xffffffff) >>> 0;
};

const png = (width, height) => {
  const signature = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8;
  ihdr[9] = 2;
  const stride = width * 3 + 1;
  const raw = Buffer.alloc(stride * height, 40);
  for (let y = 0; y < height; y += 1) raw[y * stride] = 0;
  const idat = deflateSync(raw);
  const chunk = (type, data) => {
    const body = Buffer.concat([Buffer.from(type), data]);
    const out = Buffer.alloc(8 + body.length);
    out.writeUInt32BE(data.length, 0);
    body.copy(out, 4);
    out.writeUInt32BE(crc32(body), 4 + body.length);
    return out;
  };
  return Buffer.concat([signature, chunk('IHDR', ihdr), chunk('IDAT', idat), chunk('IEND', Buffer.alloc(0))]);
};

const runCommand = (command, args) => new Promise((resolve, reject) => {
  const child = spawn(command, args, { cwd: root, stdio: 'inherit' });
  child.on('exit', (code) => (code === 0 ? resolve() : reject(new Error(`${command} exited ${code}`))));
});

const listen = (handler) => new Promise((resolve) => {
  const server = createServer(handler);
  server.listen(0, '127.0.0.1', () => resolve(server));
});

const pageHtml = (fixtureUrl) => `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>External player layout</title>
  <link rel="stylesheet" href="/app.css">
  <style>
    html, body { margin: 0; height: 100%; }
    #app { height: 100%; }
    #column.scrollable { height: 1400px; overflow: auto; }
    #warning-body, #post-body { margin: 0; height: 160px; }
    button { min-height: 44px; }
  </style>
</head>
<body>
  <div id="app"></div>
  <script>window.__PLAYER_FIXTURE__ = ${JSON.stringify(fixtureUrl)}; window.__PLAYER_IMAGE__ = '/above.png';</script>
  <script src="/layout_bundle.js"></script>
</body>
</html>`;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const run = async () => {
  const dir = mkdtempSync(join(tmpdir(), 'external-player-layout-'));
  const cssPath = join(dir, 'app.css');
  const scssPath = join(dir, 'app.scss');
  writeFileSync(scssPath, `@import 'mastodon/mixins';\n@import 'mastodon/variables';\n@import 'mastodon/statuses';\n@import 'mastodon/components';\n`);
  await runCommand(join(root, 'node_modules/.bin/sass'), ['--quiet', '--load-path=app/javascript/styles', scssPath, cssPath]);
  const bundlePath = join(dir, 'layout_bundle.js');
  await runCommand('npx', [
    '--yes',
    'esbuild',
    'script/external_player_layout_entry.js',
    '--bundle',
    `--outfile=${bundlePath}`,
    '--format=iife',
    '--loader:.js=jsx',
    `--alias:mastodon=${join(root, 'app/javascript/mastodon')}`,
    '--define:process.env.NODE_ENV="development"',
  ]);
  const css = readFileSync(cssPath);
  const bundle = readFileSync(bundlePath);
  const image = png(320, 140);
  const fixture = await listen((req, res) => {
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
    res.end(fixtureHtml);
  });
  const fixtureUrl = `http://127.0.0.1:${fixture.address().port}/player_session.html`;
  const harness = await listen((req, res) => {
    if (req.url.startsWith('/app.css')) {
      res.writeHead(200, { 'content-type': 'text/css; charset=utf-8' });
      res.end(css);
      return;
    }
    if (req.url.startsWith('/layout_bundle.js')) {
      res.writeHead(200, { 'content-type': 'text/javascript; charset=utf-8' });
      res.end(bundle);
      return;
    }
    if (req.url.startsWith('/above.png')) {
      res.writeHead(200, { 'content-type': 'image/png' });
      res.end(image);
      return;
    }
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
    res.end(pageHtml(fixtureUrl));
  });

  const puppeteer = require('puppeteer-core');
  const browser = await puppeteer.launch({
    executablePath: '/usr/bin/google-chrome',
    headless: 'new',
    args: ['--no-sandbox', '--disable-dev-shm-usage'],
  });
  const report = { browser: await browser.version() };
  try {
    const page = await browser.newPage();
    const samples = [];
    page.on('console', (message) => {
      if (message.type() === 'error') samples.push(message.text());
    });
    await page.exposeFunction('__pushSample', (sample) => samples.push(sample));
    await page.evaluateOnNewDocument(() => {
      window.addEventListener('message', (event) => {
        if (!event.data || event.data.source !== 'fedibird-player-fixture') return;
        window.__pushSample(event.data);
      });
    });
    const pageErrors = [];
    page.on('pageerror', (error) => pageErrors.push(String(error)));
    await page.setViewport({ width: 900, height: 1500 });
    await page.goto(`http://127.0.0.1:${harness.address().port}/`, { waitUntil: 'networkidle0' });
    const boot = await page.evaluate(() => ({
      text: document.body.innerText.slice(0, 800),
      html: document.body.innerHTML.slice(0, 800),
    }));
    if (!boot.text.includes('External video') && !boot.html.includes('external-embed-player')) {
      throw new Error(`player did not render\n${pageErrors.join('\n')}\n${boot.html}`);
    }
    const structure = await page.evaluate(() => ({
      virtualArticle: !!document.querySelector('article[data-id="player-row"]'),
      itemList: !!document.querySelector('.item-list'),
      frameClass: !!document.querySelector('.external-embed-player__frame'),
      callsLayout: !/layoutExternalPlayers/.test(document.documentElement.innerHTML),
    }));
    await page.click('button.external-embed-player__launch');
    await sleep(400);
    const aligned = async (label) => page.evaluate((name) => {
      const anchor = document.querySelector('.external-embed-player__frame');
      const iframe = document.querySelector('#external-player-host iframe');
      const anchorBox = anchor.getBoundingClientRect();
      const iframeBox = iframe.getBoundingClientRect();
      return {
        label: name,
        anchorTop: anchorBox.top,
        iframeTop: iframeBox.top,
        delta: Math.abs(anchorBox.top - iframeBox.top),
        anchorHeight: anchorBox.height,
        iframeHeight: iframeBox.height,
      };
    }, label);
    const before = await aligned('before');
    await page.click('#toggle-warning');
    await sleep(200);
    const warning = await aligned('warning');
    await page.click('#toggle-body');
    await sleep(200);
    const expanded = await aligned('body');
    await page.click('#show-image');
    await page.waitForSelector('#above-image');
    await sleep(300);
    const loaded = await aligned('image');
    const sessionBeforePin = await page.evaluate(() => {
      const iframe = document.querySelector('#external-player-host iframe');
      return {
        allow: iframe.getAttribute('allow'),
        sandbox: iframe.getAttribute('sandbox'),
        referrer: iframe.getAttribute('referrerpolicy'),
        src: iframe.getAttribute('src'),
      };
    });
    await page.click('button.external-player-toolbar__button');
    await sleep(200);
    const pinned = await page.evaluate(() => {
      const slot = document.querySelector('.external-player-dock__slot');
      const iframe = document.querySelector('#external-player-host iframe');
      const slotBox = slot.getBoundingClientRect();
      const iframeBox = iframe.getBoundingClientRect();
      return {
        slotTop: slotBox.top,
        iframeTop: iframeBox.top,
        delta: Math.abs(slotBox.top - iframeBox.top),
        sameSrc: iframe.getAttribute('src'),
      };
    });
    await page.evaluate(() => {
      document.querySelector('.external-player-dock').style.bottom = '120px';
    });
    await sleep(200);
    const movedDock = await page.evaluate(() => {
      const slot = document.querySelector('.external-player-dock__slot');
      const iframe = document.querySelector('#external-player-host iframe');
      const slotBox = slot.getBoundingClientRect();
      const iframeBox = iframe.getBoundingClientRect();
      return {
        slotTop: slotBox.top,
        iframeTop: iframeBox.top,
        delta: Math.abs(slotBox.top - iframeBox.top),
      };
    });
    const returns = await page.$$('button.external-player-toolbar__button');
    await returns[0].click();
    await sleep(400);
    const returned = await aligned('returned');
    const messages = samples.filter((item) => item && item.source === 'fedibird-player-fixture');
    report.structure = structure;
    report.positions = { before, warning, expanded, loaded, pinned, movedDock, returned };
    report.permissions = sessionBeforePin;
    report.samples = messages;
    report.consoleErrors = samples.filter((item) => typeof item === 'string');
    report.entryCallsLayout = readFileSync(join(root, 'script/external_player_layout_entry.js'), 'utf8').includes('layoutExternalPlayers');
    const topsMoved = warning.anchorTop > before.anchorTop + 40 && expanded.anchorTop > warning.anchorTop + 40 && loaded.anchorTop > expanded.anchorTop + 40;
    const followed = [before, warning, expanded, loaded, returned].every((row) => row.delta < 2 && row.anchorHeight > 40);
    const dockFollowed = pinned.delta < 2 && movedDock.delta < 2 && Math.abs(movedDock.slotTop - pinned.slotTop) > 20;
    const first = messages[0];
    const last = messages[messages.length - 1];
    report.session = {
      loads: last && last.loads,
      tokenStable: !!(first && last && first.token === last.token && last.loads === 1 && last.ticks > first.ticks),
      allow: sessionBeforePin.allow,
    };
    report.pass = structure.virtualArticle && structure.itemList && report.entryCallsLayout === false && topsMoved && followed && dockFollowed && report.session.tokenStable && sessionBeforePin.allow === 'fullscreen *; encrypted-media; picture-in-picture';
    await page.screenshot({ path: '/opt/cursor/artifacts/external-player-layout.png', fullPage: true });
  } finally {
    await browser.close();
    fixture.close();
    harness.close();
  }

  writeFileSync('/opt/cursor/artifacts/external-player-layout.json', JSON.stringify(report, null, 2));
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
