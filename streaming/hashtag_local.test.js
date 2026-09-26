const { describe, it, before, after } = require('node:test');
const assert = require('node:assert/strict');
const http = require('http');
const { spawn } = require('child_process');
const redis = require('redis');
const WebSocket = require('ws');

const PORT = 4017;
const BASE = `http://127.0.0.1:${PORT}`;

let serverProcess;
let serverLog = '';
let publisher;

const waitFor = (predicate, timeoutMs, label) => new Promise((resolve, reject) => {
  const started = Date.now();
  let pending = false;

  const timer = setInterval(() => {
    if (pending) {
      return;
    }

    pending = true;
    Promise.resolve()
      .then(predicate)
      .then(ok => {
        pending = false;

        if (ok) {
          clearInterval(timer);
          resolve();
        } else if (Date.now() - started > timeoutMs) {
          clearInterval(timer);
          reject(new Error(`${label} timed out\n${serverLog}`));
        }
      })
      .catch(error => {
        pending = false;

        if (Date.now() - started > timeoutMs) {
          clearInterval(timer);
          reject(new Error(`${label} timed out: ${error}\n${serverLog}`));
        }
      });
  }, 50);
});

const openSse = (path) => new Promise((resolve, reject) => {
  const req = http.get(`${BASE}${path}`, res => {
    const chunks = [];
    res.on('data', chunk => chunks.push(chunk));
    resolve({
      status: res.statusCode,
      headers: res.headers,
      text: () => Buffer.concat(chunks).toString('utf8'),
      close: () => {
        req.destroy();
        res.destroy();
      },
    });
  });

  req.on('error', reject);
});

const readHttp = (path) => new Promise((resolve, reject) => {
  http.get(`${BASE}${path}`, res => {
    const chunks = [];
    res.on('data', chunk => chunks.push(chunk));
    res.on('end', () => {
      resolve({
        status: res.statusCode,
        body: Buffer.concat(chunks).toString('utf8'),
      });
    });
  }).on('error', reject);
});

const connectSocket = () => new Promise((resolve, reject) => {
  const ws = new WebSocket(`ws://127.0.0.1:${PORT}/api/v1/streaming`);
  const messages = [];

  ws.on('message', data => messages.push(data.toString()));
  ws.once('open', () => resolve({
    ws,
    messages,
    send: payload => ws.send(JSON.stringify(payload)),
  }));
  ws.once('error', reject);
});

const publish = (channel, message) => new Promise((resolve, reject) => {
  publisher.publish(channel, message, err => {
    if (err) {
      reject(err);
    } else {
      resolve();
    }
  });
});

describe('hashtag:local streaming compatibility', () => {
  before(async () => {
    serverProcess = spawn(process.execPath, ['./streaming/index.js'], {
      env: {
        ...process.env,
        NODE_ENV: 'development',
        PORT: String(PORT),
        BIND: '127.0.0.1',
        STREAMING_CLUSTER_NUM: '1',
        LOG_LEVEL: 'error',
      },
      stdio: ['ignore', 'pipe', 'pipe'],
    });

    serverProcess.stdout.on('data', chunk => {
      serverLog += chunk.toString();
    });
    serverProcess.stderr.on('data', chunk => {
      serverLog += chunk.toString();
    });

    await waitFor(async () => {
      try {
        const health = await readHttp('/api/v1/streaming/health');
        return health.status === 200;
      } catch (error) {
        serverLog += `${error}\n`;
        return false;
      }
    }, 15000, 'streaming server startup');

    publisher = redis.createClient({ host: '127.0.0.1', port: 6379 });
    await waitFor(() => publisher.connected, 5000, 'redis publisher');
  });

  after(async () => {
    if (publisher) {
      publisher.quit();
    }

    if (serverProcess && serverProcess.exitCode === null) {
      serverProcess.kill('SIGTERM');
      await waitFor(() => serverProcess.exitCode !== null, 5000, 'streaming server shutdown').catch(() => {
        serverProcess.kill('SIGKILL');
      });
    }
  });

  it('resolves the SSE path and keeps an empty subscription open', async () => {
    const local = await openSse('/api/v1/streaming/hashtag/local?tag=test');
    const shared = await openSse('/api/v1/streaming/hashtag?tag=test');

    try {
      assert.equal(local.status, 200);
      assert.match(local.headers['content-type'], /text\/event-stream/);
      await waitFor(() => local.text().includes(':)'), 3000, 'local SSE hello');
      await waitFor(() => shared.text().includes(':)'), 3000, 'shared SSE hello');

      await publish('timeline:hashtag:test', JSON.stringify({ event: 'delete', payload: 'shared-marker' }));
      await publish('timeline:hashtag:test:local', JSON.stringify({ event: 'delete', payload: 'local-marker' }));

      await waitFor(() => shared.text().includes('shared-marker'), 3000, 'shared channel delivery');
      await new Promise(resolve => setTimeout(resolve, 400));

      assert.equal(local.text().includes('shared-marker'), false);
      assert.equal(local.text().includes('local-marker'), false);
      assert.equal(shared.text().includes('local-marker'), false);
    } finally {
      local.close();
      shared.close();
    }
  });

  it('rejects a missing tag the same way as the shared hashtag stream', async () => {
    const local = await readHttp('/api/v1/streaming/hashtag/local');
    const shared = await readHttp('/api/v1/streaming/hashtag');

    assert.equal(local.status, 404);
    assert.equal(shared.status, 404);
    assert.equal(local.body, shared.body);
  });

  it('accepts a WebSocket subscription and names the stream ["hashtag:local", tag]', async () => {
    const socket = await connectSocket();

    try {
      socket.send({ type: 'subscribe', stream: 'hashtag:local', tag: 'Test' });
      await new Promise(resolve => setTimeout(resolve, 300));
      assert.equal(socket.messages.some(message => message.includes('error')), false);

      await publish('timeline:hashtag:test', JSON.stringify({ event: 'delete', payload: 'shared-marker' }));
      await publish('timeline:hashtag:test:local', JSON.stringify({ event: 'delete', payload: 'canonical-local-marker' }));
      await new Promise(resolve => setTimeout(resolve, 400));
      assert.equal(socket.messages.some(message => message.includes('shared-marker')), false);
      assert.equal(socket.messages.some(message => message.includes('canonical-local-marker')), false);

      await publish('timeline:fedibird:empty:hashtag:local:test', JSON.stringify({ event: 'delete', payload: 'named-marker' }));
      await waitFor(() => socket.messages.some(message => message.includes('named-marker')), 3000, 'websocket event');

      const event = JSON.parse(socket.messages.find(message => message.includes('named-marker')));
      assert.deepEqual(event.stream, ['hashtag:local', 'Test']);

      socket.send({ type: 'unsubscribe', stream: 'hashtag:local', tag: 'Test' });
      await new Promise(resolve => setTimeout(resolve, 300));
      assert.equal(socket.messages.some(message => message.includes('error')), false);

      const before = socket.messages.length;
      await publish('timeline:fedibird:empty:hashtag:local:test', JSON.stringify({ event: 'delete', payload: 'after-unsubscribe' }));
      await new Promise(resolve => setTimeout(resolve, 400));
      assert.equal(socket.messages.slice(before).some(message => message.includes('after-unsubscribe')), false);
    } finally {
      socket.ws.close();
    }
  });

  it('returns the shared missing-tag error on WebSocket subscribe', async () => {
    const socket = await connectSocket();

    try {
      socket.send({ type: 'subscribe', stream: 'hashtag:local' });
      await waitFor(() => socket.messages.some(message => message.includes('No tag for stream provided')), 3000, 'missing tag error');

      const error = JSON.parse(socket.messages.find(message => message.includes('No tag for stream provided')));
      assert.match(error.error, /No tag for stream provided/);
    } finally {
      socket.ws.close();
    }
  });

  it('does not deliver local or remote hashtag posts', { timeout: 120000 }, async () => {
    const local = await openSse('/api/v1/streaming/hashtag/local?tag=policytest');
    const shared = await openSse('/api/v1/streaming/hashtag?tag=policytest');

    try {
      await waitFor(() => local.text().includes(':)'), 3000, 'policy SSE hello');

      const script = [
        'ActiveRecord::Base.logger = Logger.new(nil)',
        'Rails.logger.level = Logger::ERROR',
        'suffix = SecureRandom.hex(4)',
        'local_account = Account.create!(username: "hl#{suffix}")',
        'remote_account = Account.create!(username: "hr#{suffix}", domain: "remote.example")',
        'local_status = Status.create!(account: local_account, text: "local #{suffix} #policytest", visibility: :public)',
        'remote_status = Status.create!(account: remote_account, text: "remote #{suffix} #policytest", visibility: :public, uri: "https://remote.example/users/hr#{suffix}/statuses/1")',
        'begin',
        '  ProcessHashtagsService.new.call(local_status)',
        '  ProcessHashtagsService.new.call(remote_status, ["policytest"])',
        '  FanOutOnWriteService.new.call(local_status)',
        '  FanOutOnWriteService.new.call(remote_status)',
        '  puts "FANOUT_OK"',
        'ensure',
        '  [local_status, remote_status, local_account, remote_account].compact.each do |record|',
        '    begin',
        '      record.destroy',
        '    rescue StandardError',
        '      nil',
        '    end',
        '  end',
        'end',
      ].join('; ');

      const result = await new Promise((resolve, reject) => {
        const child = spawn('bundle', ['exec', 'rails', 'runner', script], {
          env: { ...process.env, RAILS_ENV: 'development' },
          stdio: ['ignore', 'pipe', 'pipe'],
        });
        let output = '';
        child.stdout.on('data', chunk => {
          output += chunk.toString();
        });
        child.stderr.on('data', chunk => {
          output += chunk.toString();
        });
        child.on('error', reject);
        child.on('close', code => resolve({ code, output }));
      });

      assert.match(result.output, /FANOUT_OK/, result.output.slice(-1500));
      assert.equal(result.code, 0, result.output.slice(-1500));
      await new Promise(resolve => setTimeout(resolve, 500));

      assert.equal(local.text().includes('policytest'), false);
      assert.equal(local.text().includes('event: update'), false);
      assert.match(shared.text(), /event: update/);
      assert.match(shared.text(), /policytest/);
    } finally {
      local.close();
      shared.close();
    }
  });

  it('keeps the SSE connection alive through a heartbeat', { timeout: 20000 }, async () => {
    const local = await openSse('/api/v1/streaming/hashtag/local?tag=heartbeat');

    try {
      await waitFor(() => local.text().includes(':thump'), 17000, 'SSE heartbeat');
    } finally {
      local.close();
    }
  });
});
