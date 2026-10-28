// Visual and hit-test check for compact external-player controls.
// The feed is fictional. It does not load a publisher page.

import { execFileSync, spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
const require = createRequire(import.meta.url);

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const artifacts = '/opt/cursor/artifacts';

const pixelAt = (file, x, y) => execFileSync('convert', [
  file,
  '-format',
  `%[fx:int(255*p{${x},${y}}.r)],%[fx:int(255*p{${x},${y}}.g)],%[fx:int(255*p{${x},${y}}.b)]`,
  'info:',
], { encoding: 'utf8' }).trim().split(',').map(Number);

const runCommand = (command, args) => new Promise((resolve, reject) => {
  const child = spawn(command, args, { cwd: root, stdio: 'inherit' });
  child.on('exit', (code) => (code === 0 ? resolve() : reject(new Error(`${command} exited ${code}`))));
});

const listen = (handler) => new Promise((resolve) => {
  const server = createServer(handler);
  server.listen(0, '127.0.0.1', () => resolve(server));
});

const wav = () => {
  const samples = 8000;
  const data = Buffer.alloc(44 + samples * 2);
  data.write('RIFF', 0);
  data.writeUInt32LE(36 + samples * 2, 4);
  data.write('WAVE', 8);
  data.write('fmt ', 12);
  data.writeUInt32LE(16, 16);
  data.writeUInt16LE(1, 20);
  data.writeUInt16LE(1, 22);
  data.writeUInt32LE(8000, 24);
  data.writeUInt32LE(16000, 28);
  data.writeUInt16LE(2, 32);
  data.writeUInt16LE(16, 34);
  data.write('data', 36);
  data.writeUInt32LE(samples * 2, 40);
  return data;
};

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const pageHtml = ({ audioUrl, videoUrl, frameUrl }) => `<!DOCTYPE html>
<html lang="ja">
<head>
  <meta charset="utf-8">
  <title>External player controls</title>
  <link rel="stylesheet" href="/font-awesome/css/font-awesome.css">
  <link rel="stylesheet" href="/app.css">
  <style>
    html, body { margin: 0; }
    body { background: #d9e1e8; }
    .fixture { display: flex; flex-direction: column; gap: 16px; padding: 16px; }
    .demo-card, .column { width: 480px; max-width: calc(100vw - 32px); }
    .demo-card { padding: 12px; border-radius: 8px; }
    .demo-card--light { background: #ffffff; color: #1a1a1a; }
    .demo-card--dark { background: #282c37; color: #ffffff; }
    .demo-card h1, .status h2 { margin: 0 0 8px; font: 600 16px/1.3 sans-serif; }
    .demo-label, .status p { margin: 8px 0; font: 14px/1.4 sans-serif; }
    .demo-audio { display: block; width: 100%; height: 72px; }
    .demo-audio--old { background: #000; }
    .column.narrow { width: 300px; }
    .status { padding: 12px; border-radius: 8px; background: #ffffff; color: #1a1a1a; }
    body.theme-dark { background: #191b22; }
    body.theme-dark .status { background: #282c37; color: #ffffff; }
    #video-swatch { position: absolute; width: 8px; height: 8px; opacity: 0; pointer-events: none; }
  </style>
</head>
<body class="theme-light">
  <div id="app"></div>
  <script>window.__PLAYER_AUDIO__=${JSON.stringify(audioUrl)};window.__PLAYER_VIDEO__=${JSON.stringify(videoUrl)};window.__PLAYER_FRAME__=${JSON.stringify(frameUrl)};</script>
  <script src="/bundle.js"></script>
</body>
</html>`;

const boxes = (page, scope) => page.evaluate((rootSelector) => {
  const rect = (node) => {
    if (!node) return null;
    const box = node.getBoundingClientRect();
    return { top: box.top, left: box.left, right: box.right, bottom: box.bottom, width: box.width, height: box.height };
  };
  const hit = (node) => {
    if (!node) return null;
    const box = node.getBoundingClientRect();
    const target = document.elementFromPoint(box.left + box.width / 2, box.top + box.height / 2);
    const action = target && target.closest('[data-external-player-action]');
    return {
      tag: target && target.tagName,
      action: action && action.getAttribute('data-external-player-action'),
      label: action && action.getAttribute('aria-label'),
    };
  };
  const root = document.querySelector(rootSelector);
  const audio = document.querySelector('#external-player-host audio');
  const frame = document.querySelector('#external-player-host iframe');
  const media = rootSelector.includes('audio') ? audio : frame;
  const button = root && root.querySelector('[data-external-player-action="pin"], [data-external-player-action="return"]');
  const styleOf = (node) => (node ? getComputedStyle(node).backgroundColor : null);
  return {
    audio: rect(audio),
    frame: rect(frame),
    button: rect(button),
    buttonHit: hit(button),
    mediaHit: media ? hit(media) : null,
    audioBackground: styleOf(audio),
    swatch: styleOf(document.querySelector('#video-swatch')),
    audioClass: audio && audio.className,
    src: media && media.getAttribute('src'),
    toolbar: !!document.querySelector('.external-player-toolbar'),
  };
}, scope);

const overlaps = (a, b) => {
  if (!a || !b) return false;
  const width = Math.min(a.right, b.right) - Math.max(a.left, b.left);
  const height = Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top);
  return width > 1 && height > 1;
};

const run = async () => {
  const dir = mkdtempSync(join(tmpdir(), 'external-player-controls-'));
  const scssPath = join(dir, 'app.scss');
  const cssPath = join(dir, 'app.css');
  writeFileSync(scssPath, `@import 'mastodon-light/variables';\n@import 'mastodon/mixins';\n@import 'mastodon/variables';\n@import 'mastodon/statuses';\n@import 'mastodon/components';\n`);
  await runCommand(join(root, 'node_modules/.bin/sass'), ['--quiet', '--load-path=app/javascript/styles', scssPath, cssPath]);
  const bundlePath = join(dir, 'bundle.js');
  await runCommand('npx', [
    '--yes', 'esbuild', 'script/external_player_controls_entry.js',
    '--bundle', `--outfile=${bundlePath}`, '--format=iife', '--loader:.js=jsx',
    `--alias:mastodon=${join(root, 'app/javascript/mastodon')}`,
    '--define:process.env.NODE_ENV="development"',
  ]);
  const css = readFileSync(cssPath);
  const bundle = readFileSync(bundlePath);
  const fixtureHtml = readFileSync(join(root, 'spec/fixtures/external_bridge/player_session.html'));
  const faRoot = join(root, 'node_modules/font-awesome');
  const silent = wav();
  const server = await listen((req, res) => {
    const url = req.url.split('?')[0];
    if (url === '/app.css') {
      res.writeHead(200, { 'content-type': 'text/css; charset=utf-8' });
      res.end(css);
      return;
    }
    if (url === '/bundle.js') {
      res.writeHead(200, { 'content-type': 'text/javascript; charset=utf-8' });
      res.end(bundle);
      return;
    }
    if (url.startsWith('/font-awesome/')) {
      const file = join(faRoot, url.slice('/font-awesome/'.length));
      try {
        const body = readFileSync(file);
        const type = file.endsWith('.css') ? 'text/css' : 'font/woff';
        res.writeHead(200, { 'content-type': type });
        res.end(body);
      } catch (_error) {
        res.writeHead(404);
        res.end();
      }
      return;
    }
    if (url === '/talk.wav') {
      res.writeHead(200, { 'content-type': 'audio/wav' });
      res.end(silent);
      return;
    }
    if (url === '/clip.mp4') {
      res.writeHead(200, { 'content-type': 'video/mp4' });
      res.end(Buffer.alloc(0));
      return;
    }
    if (url === '/frame.html') {
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
      res.end(fixtureHtml);
      return;
    }
    const port = server.address().port;
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
    res.end(pageHtml({
      audioUrl: `http://127.0.0.1:${port}/talk.wav`,
      videoUrl: `http://127.0.0.1:${port}/clip.mp4`,
      frameUrl: `http://127.0.0.1:${port}/frame.html`,
    }));
  });

  const puppeteer = require('puppeteer-core');
  const browser = await puppeteer.launch({
    executablePath: '/usr/bin/google-chrome',
    headless: 'new',
    args: ['--no-sandbox', '--disable-dev-shm-usage', '--autoplay-policy=no-user-gesture-required'],
  });
  const report = { browser: await browser.version() };
  try {
    const page = await browser.newPage();
    const errors = [];
    page.on('pageerror', (error) => errors.push(String(error)));
    await page.setViewport({ width: 900, height: 1400, deviceScaleFactor: 1 });
    await page.goto(`http://127.0.0.1:${server.address().port}/`, { waitUntil: 'networkidle0' });
    await page.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: 'light' }]);
    await sleep(300);
    await page.$eval('#compare-light', (node) => node.scrollIntoView({ block: 'start' }));
    await sleep(100);
    const lightCard = await (await page.$('#compare-light')).boundingBox();
    await page.screenshot({ path: join(artifacts, 'external-player-audio-background-light.png'), clip: { x: 0, y: Math.max(0, lightCard.y), width: 540, height: Math.min(lightCard.height + 8, 500) } });

    await page.evaluate(() => { document.body.className = 'theme-dark'; });
    await page.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: 'dark' }]);
    await page.$eval('#compare-dark', (node) => node.scrollIntoView({ block: 'start' }));
    await sleep(200);
    const darkCard = await page.$('#compare-dark');
    const darkBox = await darkCard.boundingBox();
    await page.screenshot({
      path: join(artifacts, 'external-player-audio-background-dark.png'),
      clip: { x: Math.max(0, darkBox.x - 8), y: Math.max(0, darkBox.y - 8), width: darkBox.width + 16, height: darkBox.height + 16 },
    });

    const cornerOf = async (selector) => {
      await page.$eval(selector, (node) => node.scrollIntoView({ block: 'center' }));
      await sleep(50);
      const box = await page.$eval(selector, (node) => {
        const rect = node.getBoundingClientRect();
        return { x: rect.x, y: rect.y, width: rect.width, height: rect.height };
      });
      const topFile = join(artifacts, 'corner-top.png');
      const bottomFile = join(artifacts, 'corner-bottom.png');
      await page.screenshot({
        path: topFile,
        clip: { x: Math.round(box.x), y: Math.round(box.y), width: 12, height: 12 },
      });
      await page.screenshot({
        path: bottomFile,
        clip: {
          x: Math.round(box.x),
          y: Math.max(0, Math.round(box.y + box.height - 12)),
          width: 12,
          height: 12,
        },
      });
      return {
        box,
        top: pixelAt(topFile, 1, 1),
        bottom: pixelAt(bottomFile, 1, 10),
      };
    };
    await page.evaluate(() => { document.body.className = 'theme-light'; });
    await page.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: 'light' }]);
    await sleep(100);
    const lightOld = await cornerOf('#compare-light .demo-audio--old');
    const lightNew = await cornerOf('#compare-light .demo-audio--new');
    await page.evaluate(() => { document.body.className = 'theme-dark'; });
    await page.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: 'dark' }]);
    await sleep(100);
    const darkOld = await cornerOf('#compare-dark .demo-audio--old');
    const darkNew = await cornerOf('#compare-dark .demo-audio--new');

    await page.$eval('#audio-post', (node) => node.scrollIntoView({ block: 'center' }));
    await page.click('#audio-post .external-remote-media__launch');
    await sleep(400);
    const wideAudio = await boxes(page, '#audio-post');
    await (await page.$('#audio-post')).screenshot({ path: join(artifacts, 'external-player-audio-wide.png') });
    await page.$eval('#frame-post', (node) => node.scrollIntoView({ block: 'center' }));
    await page.click('#frame-post .external-embed-player__launch');
    await sleep(400);
    const wideFrame = await boxes(page, '#frame-post');
    await (await page.$('#frame-post')).screenshot({ path: join(artifacts, 'external-player-iframe-controls.png') });

    await page.evaluate(() => document.querySelector('#column').classList.add('narrow'));
    await page.setViewport({ width: 360, height: 900, deviceScaleFactor: 1 });
    await page.$eval('#audio-post', (node) => node.scrollIntoView({ block: 'center' }));
    await sleep(400);
    const narrowAudio = await boxes(page, '#audio-post');
    await (await page.$('#audio-post')).screenshot({ path: join(artifacts, 'external-player-audio-narrow.png') });

    await page.setViewport({ width: 900, height: 1400, deviceScaleFactor: 1 });
    await page.evaluate(() => document.querySelector('#column').classList.remove('narrow'));
    await sleep(200);
    await page.$eval('#external-player-host iframe', (node) => node.setAttribute('data-same-node', 'kept'));
    const beforePin = await page.$eval('#external-player-host iframe', (node) => node.getAttribute('src'));
    await page.$eval('#frame-post', (node) => node.scrollIntoView({ block: 'center' }));
    await page.click('#frame-post [data-external-player-action="pin"]');
    await sleep(400);
    const pinned = await page.evaluate(() => {
      const iframe = document.querySelector('#external-player-host iframe');
      const slot = document.querySelector('.external-player-dock__slot');
      const button = document.querySelector('.external-player-dock [data-external-player-action="return"]');
      const close = document.querySelector('.external-player-dock [data-external-player-action="close"]');
      const box = (node) => node && node.getBoundingClientRect();
      const at = (node) => {
        const rect = box(node);
        if (!rect) return { hit: null };
        const x = Math.min(window.innerWidth - 2, Math.max(1, rect.left + rect.width / 2));
        const y = Math.min(window.innerHeight - 2, Math.max(1, rect.top + rect.height / 2));
        const stack = document.elementsFromPoint(x, y).slice(0, 6).map((target) => {
          const action = target.closest && target.closest('[data-external-player-action]');
          return action ? action.getAttribute('data-external-player-action') : target.tagName;
        });
        return {
          hit: stack[0] || null,
          stack,
          rect: { top: rect.top, left: rect.left, width: rect.width, height: rect.height },
          viewport: { width: window.innerWidth, height: window.innerHeight },
        };
      };
      return {
        src: iframe && iframe.getAttribute('src'),
        sameNode: iframe && iframe.getAttribute('data-same-node'),
        parent: iframe && iframe.parentElement && iframe.parentElement.id,
        returnHit: at(button).hit,
        closeHit: at(close).hit,
        returnProbe: at(button),
        closeProbe: at(close),
        frameHit: at(iframe).hit,
        returnLabel: button && button.getAttribute('aria-label'),
        closeLabel: close && close.getAttribute('aria-label'),
        title: document.querySelector('.external-player-dock__title') && document.querySelector('.external-player-dock__title').textContent,
        note: document.querySelector('.external-player-dock__note') && document.querySelector('.external-player-dock__note').textContent,
      };
    });
    await (await page.$('.external-player-dock')).screenshot({ path: join(artifacts, 'external-player-dock.png') });

    const sameNode = beforePin && pinned.src === beforePin && pinned.parent === 'external-player-host';
    const isBlack = (pixel) => pixel && pixel[0] < 30 && pixel[1] < 30 && pixel[2] < 30;
    const isLight = (pixel) => pixel && pixel[0] > 180 && pixel[1] > 180 && pixel[2] > 180;
    const isDark = (pixel) => pixel && pixel[0] < 90 && pixel[1] < 100 && pixel[2] < 120 && !isLight(pixel);
    const lightCornerDark = ['top', 'bottom'].some((edge) => isBlack(lightOld[edge]));
    const lightFixed = ['top', 'bottom'].some((edge) => isBlack(lightOld[edge]) && isLight(lightNew[edge]));
    const darkFixed = ['top', 'bottom'].some((edge) => isBlack(darkOld[edge]) && isDark(darkNew[edge]));
    report.corners = { lightOld, lightNew, darkOld, darkNew };
    report.wideAudio = wideAudio;
    report.wideFrame = wideFrame;
    report.narrowAudio = narrowAudio;
    report.pinned = pinned;
    report.errors = errors;
    report.pass = {
      lightOldWasBlack: lightCornerDark,
      lightNewIsNotBlack: lightFixed,
      darkNewIsNotLightPatch: darkFixed,
      noToolbar: wideAudio.toolbar === false,
      audioControlsOutside: wideAudio.button && wideAudio.audio && !overlaps(wideAudio.button, wideAudio.audio) && wideAudio.buttonHit.action === 'pin',
      audioBesideOnWide: wideAudio.button && wideAudio.audio && wideAudio.button.left >= wideAudio.audio.right - 2,
      audioBelowOnNarrow: narrowAudio.button && narrowAudio.audio && narrowAudio.button.top >= narrowAudio.audio.bottom - 2,
      frameControlsOutside: wideFrame.button && wideFrame.frame && !overlaps(wideFrame.button, wideFrame.frame) && wideFrame.buttonHit.action === 'pin',
      frameReceivesHits: wideFrame.mediaHit && wideFrame.mediaHit.tag === 'IFRAME',
      audioBackgroundTransparent: wideAudio.audioBackground === 'rgba(0, 0, 0, 0)',
      videoBackgroundBlack: wideFrame.swatch === 'rgb(0, 0, 0)',
      sameNode: sameNode && pinned.sameNode === 'kept',
      dockHits: pinned.returnHit === 'return' && pinned.closeHit === 'close' && pinned.frameHit === 'IFRAME',
      japaneseLabels: pinned.returnLabel === '投稿内へ戻す' && pinned.closeLabel === 'プレイヤーを閉じる' && pinned.title === '固定プレイヤー',
    };
    report.ok = Object.values(report.pass).every(Boolean);
  } finally {
    await browser.close();
    server.close();
  }

  writeFileSync(join(artifacts, 'external-player-controls.json'), JSON.stringify(report, null, 2));
  console.log(JSON.stringify({ ok: report.ok, pass: report.pass, errors: report.errors, pinned: report.pinned, corners: report.corners }, null, 2));
  if (!report.ok) process.exit(1);
};

run().catch((error) => {
  console.error(error);
  process.exit(1);
});
