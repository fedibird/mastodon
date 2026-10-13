const { describe, it, before, after } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('crypto');
const fs = require('fs');
const http = require('http');
const { spawn } = require('child_process');
const redis = require('redis');
const { Client } = require('pg');
const WebSocket = require('ws');

const PORT = 4018;
const BASE = `http://127.0.0.1:${PORT}`;
const NAMESPACE = 'prefstream52';
const PREFIX = `${NAMESPACE}:`;
const PREFS_PATH = '/api/v1/streaming/user/preferences';
const USER_PATH = '/api/v1/streaming/user';
const NOTIFICATION_PATH = '/api/v1/streaming/user/notification';
const SCOPE_ERROR = 'Error: Access token does not cover required scopes';
const INVALID_TOKEN = 'Error: Invalid access token';
const MISSING_TOKEN = 'Error: Missing access token';
const TEST_DB_KEYS = [
  'PREFERENCES_STREAM_TEST_DB_NAME',
  'PREFERENCES_STREAM_TEST_DB_USER',
  'PREFERENCES_STREAM_TEST_DB_PASSWORD',
  'PREFERENCES_STREAM_TEST_DB_HOST',
  'PREFERENCES_STREAM_TEST_DB_PORT',
];

let serverProcess;
let serverLog = '';
let publisher;
let db;
let lockClient;
const world = {};
const runId = crypto.randomBytes(3).toString('hex');
const created = {
  accountIds: [],
  userIds: [],
  tokenIds: [],
};

const testDatabaseConfig = (env) => {
  const missing = TEST_DB_KEYS.filter(key => {
    if (!Object.prototype.hasOwnProperty.call(env, key) || env[key] === undefined) {
      return true;
    }

    return key !== 'PREFERENCES_STREAM_TEST_DB_PASSWORD' && env[key] === '';
  });

  if (missing.length > 0) {
    throw new Error(`Refusing to start without ${missing.join(', ')}`);
  }

  const database = env.PREFERENCES_STREAM_TEST_DB_NAME;

  if (!/^[A-Za-z0-9_]+$/.test(database) || !/test/i.test(database) || /development|production/i.test(database)) {
    throw new Error(`Refusing database "${database}"`);
  }

  const port = Number(env.PREFERENCES_STREAM_TEST_DB_PORT);

  if (!Number.isInteger(port) || port <= 0) {
    throw new Error('PREFERENCES_STREAM_TEST_DB_PORT must be a positive integer');
  }

  return {
    database: database,
    user: env.PREFERENCES_STREAM_TEST_DB_USER,
    password: env.PREFERENCES_STREAM_TEST_DB_PASSWORD,
    host: env.PREFERENCES_STREAM_TEST_DB_HOST,
    port: port,
  };
};

const writeArtifact = (name, contents) => {
  const dir = process.env.PREFERENCES_STREAM_TEST_ARTIFACT_DIR;

  if (!dir) {
    return;
  }

  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(`${dir}/${name}`, contents);
};

const deleteCreated = async () => {
  if (created.tokenIds.length > 0) {
    await db.query('DELETE FROM oauth_access_tokens WHERE id = ANY($1::bigint[])', [created.tokenIds]);
    created.tokenIds = [];
  }

  if (created.userIds.length > 0) {
    await db.query('DELETE FROM users WHERE id = ANY($1::bigint[])', [created.userIds]);
    created.userIds = [];
  }

  if (created.accountIds.length > 0) {
    await db.query('DELETE FROM accounts WHERE id = ANY($1::bigint[])', [created.accountIds]);
    created.accountIds = [];
  }
};

const waitFor = (predicate, timeoutMs, label) => new Promise((resolve, reject) => {
  const started = Date.now();
  let pending = false;
  let settled = false;

  const finish = (error) => {
    if (settled) {
      return;
    }

    settled = true;
    clearInterval(timer);

    if (error) {
      reject(error);
    } else {
      resolve();
    }
  };

  const timer = setInterval(() => {
    if (Date.now() - started > timeoutMs) {
      finish(new Error(`${label} timed out\n${serverLog}`));
      return;
    }

    if (pending) {
      return;
    }

    pending = true;
    Promise.resolve()
      .then(predicate)
      .then(ok => {
        pending = false;

        if (ok) {
          finish();
        }
      })
      .catch(error => {
        pending = false;
        serverLog += `${error}\n`;
      });
  }, 50);
});

const prefsChannel = accountId => `${PREFIX}timeline:preferences:${accountId}`;
const userChannel = accountId => `${PREFIX}timeline:${accountId}`;
const tokenChannel = tokenId => `${PREFIX}timeline:access_token:${tokenId}`;

const numsub = channel => new Promise((resolve, reject) => {
  publisher.pubsub('NUMSUB', channel, (error, result) => {
    if (error) {
      reject(error);
      return;
    }

    resolve(Number(result[1]));
  });
});

const waitNumsub = (channel, expected) => waitFor(async () => {
  const count = await numsub(channel);

  return count === expected;
}, 8000, `NUMSUB ${channel} === ${expected}`);

const publish = (channel, event, payload) => new Promise((resolve, reject) => {
  publisher.publish(channel, JSON.stringify({
    event: event,
    payload: payload,
    queued_at: Date.now(),
  }), error => {
    if (error) {
      reject(error);
      return;
    }

    resolve();
  });
});

const openSse = (path, token) => new Promise((resolve, reject) => {
  const headers = {};

  if (token) {
    headers.Authorization = `Bearer ${token}`;
  }

  const req = http.get(`${BASE}${path}`, { headers: headers }, res => {
    req.setTimeout(0);

    const chunks = [];
    let ended = false;

    res.on('data', chunk => chunks.push(chunk));
    res.on('end', () => {
      ended = true;
    });

    resolve({
      status: res.statusCode,
      headers: res.headers,
      ended: () => ended,
      text: () => Buffer.concat(chunks).toString('utf8'),
      close: () => {
        req.destroy();
      },
    });
  });

  req.setTimeout(8000, () => {
    req.destroy(new Error('sse timeout'));
  });
  req.on('error', error => {
    if (error.code !== 'ECONNRESET') {
      reject(error);
    }
  });
});

const readHttp = (path, token) => new Promise((resolve, reject) => {
  const headers = {};

  if (token) {
    headers.Authorization = `Bearer ${token}`;
  }

  const req = http.get(`${BASE}${path}`, { headers: headers }, res => {
    const chunks = [];

    res.on('data', chunk => chunks.push(chunk));
    res.on('end', () => {
      resolve({
        status: res.statusCode,
        body: Buffer.concat(chunks).toString('utf8'),
      });
    });
  });

  req.setTimeout(4000, () => {
    req.destroy(new Error('request timeout'));
  });
  req.on('error', reject);
});

const connectSocket = token => new Promise((resolve, reject) => {
  const options = {};

  if (token) {
    options.headers = { Authorization: `Bearer ${token}` };
  }

  const ws = new WebSocket(`ws://127.0.0.1:${PORT}/api/v1/streaming`, options);
  const messages = [];
  let settled = false;
  let closed = false;

  const finish = value => {
    if (settled) {
      return;
    }

    settled = true;
    resolve(value);
  };

  ws.on('message', data => messages.push(data.toString()));
  ws.on('close', () => {
    closed = true;
  });
  ws.on('unexpected-response', (request, res) => {
    const chunks = [];

    res.on('data', chunk => chunks.push(chunk));
    res.on('end', () => {
      finish({
        ws: ws,
        messages: messages,
        opened: false,
        status: res.statusCode,
        body: Buffer.concat(chunks).toString('utf8'),
        closed: () => true,
        send: () => {},
      });
    });

    return request.statusCode;
  });
  ws.once('open', () => {
    finish({
      ws: ws,
      messages: messages,
      opened: true,
      status: 101,
      body: '',
      closed: () => closed,
      send: payload => ws.send(JSON.stringify(payload)),
    });
  });
  ws.on('error', () => {});

  setTimeout(() => {
    if (!settled) {
      reject(new Error(`websocket open timed out\n${serverLog}`));
    }
  }, 8000);
});

const preferencePayload = (revision, changedKeys) => ({
  version: 1,
  revision: revision,
  changed_keys: changedKeys,
});

const preferenceMessages = socket => socket.messages.flatMap(message => {
  try {
    const parsed = JSON.parse(message);

    if (parsed.event !== 'preferences_changed' || typeof parsed.payload !== 'string') {
      return [];
    }

    return [{ raw: message, parsed: parsed, payload: JSON.parse(parsed.payload) }];
  } catch (parseError) {
    return parseError ? [] : [];
  }
});

const assertSseDenied = async (token, message) => {
  const response = await readHttp(PREFS_PATH, token);

  assert.equal(response.status, 401);
  assert.deepEqual(JSON.parse(response.body), { error: message });
};

const assertSocketDenied = async (token, message) => {
  const socket = await connectSocket(token);

  try {
    assert.equal(socket.opened, true);
    socket.send({ type: 'subscribe', stream: 'user:preferences' });
    await waitFor(() => socket.messages.some(messageText => messageText.includes(message)), 8000, message);
    const parsed = JSON.parse(socket.messages.find(messageText => messageText.includes(message)));

    assert.deepEqual(parsed, { error: message });
    assert.equal(socket.messages.some(messageText => messageText.includes('preferences_changed')), false);
  } finally {
    socket.ws.close();
  }
};

const insertAccount = async (username, fields, track) => {
  const result = await db.query(
    'INSERT INTO accounts (username, memorial, suspended_at, moved_to_account_id, created_at, updated_at) VALUES ($1, $2, $3, $4, NOW(), NOW()) RETURNING id',
    [username, fields.memorial === true, fields.suspendedAt || null, fields.movedTo || null],
  );
  const id = String(result.rows[0].id);

  if (track !== false) {
    created.accountIds.push(id);
  }

  return id;
};

const insertUser = async (accountId, email, fields) => {
  const result = await db.query(
    'INSERT INTO users (email, account_id, confirmed_at, approved, disabled, created_at, updated_at) VALUES ($1, $2, $3, $4, $5, NOW(), NOW()) RETURNING id',
    [
      email,
      accountId,
      fields.confirmed === false ? null : new Date(),
      fields.approved !== false,
      fields.disabled === true,
    ],
  );

  const id = String(result.rows[0].id);

  created.userIds.push(id);

  return id;
};

const insertToken = async (userId, scopes, fields) => {
  const token = `p52_${crypto.randomBytes(18).toString('hex')}`;
  const result = await db.query(
    'INSERT INTO oauth_access_tokens (token, scopes, resource_owner_id, created_at, expires_in, revoked_at) VALUES ($1, $2, $3, $4, $5, $6) RETURNING id',
    [
      token,
      scopes,
      userId,
      fields.createdAt || new Date(),
      Object.prototype.hasOwnProperty.call(fields, 'expiresIn') ? fields.expiresIn : null,
      fields.revoked === true ? new Date() : null,
    ],
  );

  const id = String(result.rows[0].id);

  created.tokenIds.push(id);

  return {
    token: token,
    id: id,
    userId: userId,
  };
};

const createPerson = async (name, scopes, accountFields, userFields, tokenFields) => {
  const username = `t${runId}${name}`.slice(0, 30);
  const accountId = await insertAccount(username, accountFields || {});
  const userId = await insertUser(accountId, `${username}@preferences.test`, userFields || {});
  const token = await insertToken(userId, scopes, tokenFields || {});

  return {
    username: username,
    accountId: accountId,
    userId: userId,
    token: token.token,
    tokenId: token.id,
  };
};

const countBlockedAuthQueries = async () => {
  const result = await db.query('SELECT COUNT(*)::int AS blocked FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid() AND wait_event_type = \'Lock\' AND query LIKE \'%AS user_account_id%\'');

  return Number(result.rows[0].blocked);
};

const withHeldAuthorization = async (fn) => {
  await lockClient.query('BEGIN');
  await lockClient.query('LOCK TABLE oauth_access_tokens IN ACCESS EXCLUSIVE MODE');
  let released = false;

  try {
    await fn(async () => {
      await lockClient.query('COMMIT');
      released = true;
    });
  } finally {
    if (!released) {
      await lockClient.query('ROLLBACK');
    }
  }
};

describe('preferences stream test database guard', () => {
  const present = {
    PREFERENCES_STREAM_TEST_DB_NAME: 'preferences_stream_test',
    PREFERENCES_STREAM_TEST_DB_USER: 'mastodon',
    PREFERENCES_STREAM_TEST_DB_PASSWORD: 'mastodon',
    PREFERENCES_STREAM_TEST_DB_HOST: 'localhost',
    PREFERENCES_STREAM_TEST_DB_PORT: '5432',
  };

  it('rejects a missing test database before changing data', () => {
    assert.throws(() => testDatabaseConfig({}), /Refusing to start without/);
    assert.throws(() => testDatabaseConfig(Object.assign({}, present, {
      PREFERENCES_STREAM_TEST_DB_NAME: undefined,
    })), /PREFERENCES_STREAM_TEST_DB_NAME/);
  });

  it('rejects a database name that is not a dedicated test database', () => {
    ['mastodon_development', 'mastodon_production', 'postgres', 'production_test'].forEach(name => {
      assert.throws(() => testDatabaseConfig(Object.assign({}, present, {
        PREFERENCES_STREAM_TEST_DB_NAME: name,
      })), /Refusing database/);
    });

    const accepted = testDatabaseConfig(present);

    assert.equal(accepted.database, 'preferences_stream_test');
  });
});

describe('user:preferences streaming', { concurrency: 1, timeout: 180000 }, () => {
  before(async () => {
    const dbConfig = testDatabaseConfig(process.env);

    const client = new Client(dbConfig);

    await client.connect();
    db = client;

    const current = await db.query('SELECT current_database() AS name');

    if (current.rows[0].name !== dbConfig.database) {
      throw new Error(`Connected to ${current.rows[0].name} instead of ${dbConfig.database}`);
    }

    world.preexistingAccountId = await insertAccount(`p52bkept${runId}`, {}, false);

    const destination = await insertAccount(`tdest${runId}`, {});

    world.readPreferences = await createPerson('readprefs', 'read:preferences');
    world.read = await createPerson('readall', 'read');
    world.statuses = await createPerson('statuses', 'read:statuses');
    world.notifications = await createPerson('notes', 'read:notifications');
    world.writePreferences = await createPerson('writeprefs', 'write:preferences');
    world.write = await createPerson('write', 'write');
    world.writeAccounts = await createPerson('writeacc', 'write:accounts');
    world.profile = await createPerson('profile', 'profile');
    world.readAccounts = await createPerson('readacc', 'read:accounts');
    world.expired = await createPerson('expired', 'read', {}, {}, {
      createdAt: new Date(Date.now() - (60 * 60 * 1000)),
      expiresIn: 60,
    });
    world.revoked = await createPerson('revoked', 'read', {}, {}, { revoked: true });
    world.disabled = await createPerson('disabled', 'read', {}, { disabled: true });
    world.suspended = await createPerson('suspended', 'read:preferences', { suspendedAt: new Date() });
    world.unconfirmed = await createPerson('unconfirmed', 'read', {}, { confirmed: false });
    world.unapproved = await createPerson('unapproved', 'read:preferences', {}, { approved: false });
    world.memorial = await createPerson('memorial', 'read', { memorial: true });
    world.moved = await createPerson('moved', 'read:preferences', { movedTo: destination });
    world.live = await createPerson('live', 'read:preferences');
    world.cutoffRevoke = await createPerson('cutrevoke', 'read');
    world.cutoffSuspend = await createPerson('cutsuspend', 'read:preferences');
    world.cutoffExpire = await createPerson('cutexpire', 'read', {}, {}, { expiresIn: 3600 });
    world.cutoffDisable = await createPerson('cutdisable', 'read:preferences');
    world.leak = await createPerson('leak', 'read:preferences');
    world.raceQuiet = await createPerson('racequiet', 'read');
    world.raceFail = await createPerson('racefail', 'read');
    world.raceRenew = await createPerson('racerenew', 'read');
    world.raceDrop = await createPerson('racedrop', 'read:preferences');
    world.raceLive = await createPerson('racelive', 'read');

    const held = new Client(dbConfig);

    await held.connect();
    lockClient = held;

    const childEnv = Object.assign({}, process.env, {
      NODE_ENV: 'test',
      PORT: String(PORT),
      BIND: '127.0.0.1',
      STREAMING_CLUSTER_NUM: '1',
      LOG_LEVEL: 'error',
      REDIS_NAMESPACE: NAMESPACE,
      DB_HOST: dbConfig.host,
      DB_PORT: String(dbConfig.port),
      DB_USER: dbConfig.user,
      DB_PASS: dbConfig.password,
      DB_NAME: dbConfig.database,
    });

    delete childEnv.DATABASE_URL;

    serverProcess = spawn(process.execPath, ['./streaming/index.js'], {
      env: childEnv,
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

    if (lockClient) {
      await lockClient.query('ROLLBACK').catch(() => {});
      await lockClient.end();
    }

    if (db) {
      await deleteCreated();

      if (world.preexistingAccountId) {
        const kept = await db.query('SELECT id FROM accounts WHERE id = $1', [world.preexistingAccountId]);

        if (kept.rows.length !== 1) {
          throw new Error('cleanup removed an account this run did not create');
        }

        await db.query('DELETE FROM accounts WHERE id = $1', [world.preexistingAccountId]);
      }

      await db.end();
    }
  });

  it('delivers preferences_changed to an SSE client with read:preferences', async () => {
    const person = world.readPreferences;
    const channel = prefsChannel(person.accountId);
    const stream = await openSse(PREFS_PATH, person.token);

    try {
      assert.equal(stream.status, 200);
      assert.match(stream.headers['content-type'], /text\/event-stream/);
      await waitFor(() => stream.text().includes(':)'), 8000, 'sse hello');
      await waitNumsub(channel, 1);

      await publish(`timeline:preferences:${person.accountId}`, 'preferences_changed', preferencePayload('11', ['user.default_language']));
      await publish(channel, 'preferences_changed', preferencePayload('12', ['user.default_language']));
      await waitFor(() => stream.text().includes('"revision":"12"'), 8000, 'sse revision 12');

      const sample = stream.text().split('\n').filter(line => line.startsWith('event:') || line.startsWith('data:')).join('\n');

      assert.equal(sample, 'event: preferences_changed\ndata: {"version":1,"revision":"12","changed_keys":["user.default_language"]}');
      assert.equal(stream.text().includes('"revision":"11"'), false);
      writeArtifact('preferences-sse-event.txt', `${sample}\n`);

      await publish(channel, 'preferences_changed', preferencePayload('9223372036854775807', ['user.default_language']));
      await waitFor(() => stream.text().includes('"revision":"9223372036854775807"'), 8000, 'sse big revision');
      assert.equal(stream.text().includes('9223372036854776000'), false);
    } finally {
      stream.close();
      await waitNumsub(channel, 0);
    }
  });

  it('delivers preferences_changed to an SSE client with read', async () => {
    const person = world.read;
    const channel = prefsChannel(person.accountId);
    const stream = await openSse(PREFS_PATH, person.token);

    try {
      assert.equal(stream.status, 200);
      await waitFor(() => stream.text().includes(':)'), 8000, 'read sse hello');
      await publish(channel, 'preferences_changed', preferencePayload('13', ['marker-read-sse']));
      await waitFor(() => stream.text().includes('marker-read-sse'), 8000, 'read sse event');
      assert.match(stream.text(), /event: preferences_changed\ndata: \{"version":1,"revision":"13","changed_keys":\["marker-read-sse"\]\}/);
    } finally {
      stream.close();
      await waitNumsub(channel, 0);
    }
  });

  it('delivers preferences_changed to a WebSocket client with read:preferences', async () => {
    const person = world.readPreferences;
    const channel = prefsChannel(person.accountId);
    const socket = await connectSocket(person.token);

    try {
      assert.equal(socket.opened, true);
      socket.send({ type: 'subscribe', stream: 'user:preferences', account_id: world.read.accountId });
      await waitNumsub(channel, 1);
      await publish(channel, 'preferences_changed', preferencePayload('12', ['user.default_language']));
      await waitFor(() => preferenceMessages(socket).some(message => message.payload.revision === '12'), 8000, 'ws revision 12');

      const message = preferenceMessages(socket).find(item => item.payload.revision === '12');

      assert.deepEqual(message.parsed.stream, ['user:preferences']);
      assert.equal(message.parsed.event, 'preferences_changed');
      assert.equal(typeof message.parsed.payload, 'string');
      assert.deepEqual(message.payload, preferencePayload('12', ['user.default_language']));
      assert.equal(message.raw.includes(world.read.accountId), false);
      writeArtifact('preferences-ws-event.json', `${message.raw}\n`);

      await publish(channel, 'preferences_changed', preferencePayload('9223372036854775807', ['user.default_language']));
      await waitFor(() => preferenceMessages(socket).some(item => item.payload.revision === '9223372036854775807'), 8000, 'ws big revision');
      const big = preferenceMessages(socket).find(item => item.payload.revision === '9223372036854775807');

      assert.equal(big.payload.revision, '9223372036854775807');
      assert.equal(big.raw.includes('9223372036854776000'), false);
    } finally {
      socket.ws.close();
      await waitNumsub(channel, 0);
    }
  });

  it('delivers preferences_changed to a WebSocket client with read', async () => {
    const person = world.read;
    const channel = prefsChannel(person.accountId);
    const socket = await connectSocket(person.token);

    try {
      socket.send({ type: 'subscribe', stream: 'user:preferences' });
      await waitNumsub(channel, 1);
      await publish(channel, 'preferences_changed', preferencePayload('14', ['marker-read-ws']));
      await waitFor(() => socket.messages.some(message => message.includes('marker-read-ws')), 8000, 'read ws event');
      const parsed = JSON.parse(socket.messages.find(message => message.includes('marker-read-ws')));

      assert.deepEqual(parsed.stream, ['user:preferences']);
      assert.equal(parsed.event, 'preferences_changed');
      assert.equal(JSON.parse(parsed.payload).revision, '14');
    } finally {
      socket.ws.close();
      await waitNumsub(channel, 0);
    }
  });

  it('rejects tokens that cannot read preferences on SSE and WebSocket', async () => {
    const denied = [
      world.statuses,
      world.notifications,
      world.writePreferences,
      world.write,
      world.writeAccounts,
      world.profile,
      world.readAccounts,
    ];

    for (const person of denied) {
      await assertSseDenied(person.token, SCOPE_ERROR);
      await assertSocketDenied(person.token, SCOPE_ERROR);
      assert.equal(await numsub(prefsChannel(person.accountId)), 0);
    }
  });

  it('rejects a missing access token', async () => {
    const response = await readHttp(PREFS_PATH);

    assert.equal(response.status, 401);
    assert.deepEqual(JSON.parse(response.body), { error: MISSING_TOKEN });

    const socket = await connectSocket();

    try {
      assert.equal(socket.opened, true);
      socket.send({ type: 'subscribe', stream: 'user:preferences' });
      await waitFor(() => socket.messages.some(message => message.includes(MISSING_TOKEN)), 8000, 'missing token');
      assert.deepEqual(JSON.parse(socket.messages.find(message => message.includes(MISSING_TOKEN))), { error: MISSING_TOKEN });
    } finally {
      socket.ws.close();
    }
  });

  it('rejects an expired token for preferences without closing the normal user stream', async () => {
    await assertSseDenied(world.expired.token, INVALID_TOKEN);
    await assertSocketDenied(world.expired.token, INVALID_TOKEN);

    const stream = await openSse(USER_PATH, world.expired.token);

    try {
      assert.equal(stream.status, 200);
      await waitFor(() => stream.text().includes(':)'), 8000, 'expired user hello');
      await publish(userChannel(world.expired.accountId), 'update', 'expired-user-still-open');
      await waitFor(() => stream.text().includes('expired-user-still-open'), 8000, 'expired user event');
    } finally {
      stream.close();
      await waitNumsub(userChannel(world.expired.accountId), 0);
    }
  });

  it('rejects a revoked token before either stream is established', async () => {
    const response = await readHttp(PREFS_PATH, world.revoked.token);

    assert.equal(response.status, 401);
    assert.deepEqual(JSON.parse(response.body), { error: INVALID_TOKEN });

    const userResponse = await readHttp(USER_PATH, world.revoked.token);

    assert.equal(userResponse.status, 401);

    const socket = await connectSocket(world.revoked.token);

    assert.equal(socket.opened, false);
    assert.equal(socket.status, 401);
    assert.equal(await numsub(prefsChannel(world.revoked.accountId)), 0);
  });

  it('rejects users and accounts that are not functional', async () => {
    const rejected = [
      world.disabled,
      world.suspended,
      world.unconfirmed,
      world.unapproved,
      world.memorial,
      world.moved,
    ];

    for (const person of rejected) {
      await assertSseDenied(person.token, INVALID_TOKEN);
      await assertSocketDenied(person.token, INVALID_TOKEN);
      assert.equal(await numsub(prefsChannel(person.accountId)), 0);
    }

    const stream = await openSse(USER_PATH, world.unconfirmed.token);

    try {
      assert.equal(stream.status, 200);
      await waitFor(() => stream.text().includes(':)'), 8000, 'unconfirmed user hello');
      await publish(userChannel(world.unconfirmed.accountId), 'update', 'unconfirmed-user-still-open');
      await waitFor(() => stream.text().includes('unconfirmed-user-still-open'), 8000, 'unconfirmed user event');
    } finally {
      stream.close();
      await waitNumsub(userChannel(world.unconfirmed.accountId), 0);
    }
  });

  it('delivers an account event only to that account', async () => {
    const left = world.readPreferences;
    const right = world.read;
    const leftStream = await openSse(`${PREFS_PATH}?account_id=${right.accountId}&user_id=${right.userId}`, left.token);
    const rightSocket = await connectSocket(right.token);

    try {
      assert.equal(leftStream.status, 200);
      rightSocket.send({
        type: 'subscribe',
        stream: 'user:preferences',
        account_id: left.accountId,
        user_id: left.userId,
      });
      await waitFor(() => leftStream.text().includes(':)'), 8000, 'isolation hello');
      await waitNumsub(prefsChannel(left.accountId), 1);
      await waitNumsub(prefsChannel(right.accountId), 1);

      await publish(prefsChannel(left.accountId), 'preferences_changed', preferencePayload('21', ['marker-account-a']));
      await publish(prefsChannel(right.accountId), 'preferences_changed', preferencePayload('22', ['marker-account-b']));
      await waitFor(() => leftStream.text().includes('marker-account-a'), 8000, 'account a event');
      await waitFor(() => rightSocket.messages.some(message => message.includes('marker-account-b')), 8000, 'account b event');

      assert.equal(leftStream.text().includes('marker-account-b'), false);
      assert.equal(rightSocket.messages.some(message => message.includes('marker-account-a')), false);
    } finally {
      leftStream.close();
      rightSocket.ws.close();
      await waitNumsub(prefsChannel(left.accountId), 0);
      await waitNumsub(prefsChannel(right.accountId), 0);
    }
  });

  it('does not mix preference events with user, notification, or status events', async () => {
    const prefs = await openSse(PREFS_PATH, world.live.token);
    const user = await openSse(USER_PATH, world.read.token);
    const notification = await openSse(NOTIFICATION_PATH, world.notifications.token);

    try {
      assert.equal(prefs.status, 200);
      assert.equal(user.status, 200);
      assert.equal(notification.status, 200);
      await waitFor(() => prefs.text().includes(':)') && user.text().includes(':)') && notification.text().includes(':)'), 8000, 'mix hello');

      await publish(userChannel(world.live.accountId), 'update', 'status-on-user-channel');
      await publish(userChannel(world.live.accountId), 'status.update', 'status-update-on-user-channel');
      await publish(userChannel(world.live.accountId), 'notification', 'notification-on-user-channel');
      await publish(userChannel(world.live.accountId), 'conversation', 'conversation-on-user-channel');
      await publish(prefsChannel(world.live.accountId), 'update', 'status-on-prefs-channel');
      await publish(prefsChannel(world.live.accountId), 'status.update', 'status-update-on-prefs-channel');
      await publish(prefsChannel(world.live.accountId), 'notification', 'notification-on-prefs-channel');
      await publish(prefsChannel(world.live.accountId), 'conversation', 'conversation-on-prefs-channel');
      await publish(prefsChannel(world.live.accountId), 'preferences_changed', preferencePayload('31', ['marker-prefs-only']));
      await publish(userChannel(world.read.accountId), 'update', 'marker-user-only');
      await publish(userChannel(world.notifications.accountId), 'notification', 'marker-notification-only');
      await publish(prefsChannel(world.notifications.accountId), 'preferences_changed', preferencePayload('33', ['prefs-for-notification-account']));

      await waitFor(() => prefs.text().includes('marker-prefs-only'), 8000, 'prefs marker');
      await waitFor(() => user.text().includes('marker-user-only'), 8000, 'user marker');
      await waitFor(() => notification.text().includes('marker-notification-only'), 8000, 'notification marker');

      assert.equal(prefs.text().includes('status-on-user-channel'), false);
      assert.equal(prefs.text().includes('status-update-on-user-channel'), false);
      assert.equal(prefs.text().includes('notification-on-user-channel'), false);
      assert.equal(prefs.text().includes('conversation-on-user-channel'), false);
      assert.equal(prefs.text().includes('status-on-prefs-channel'), false);
      assert.equal(prefs.text().includes('status-update-on-prefs-channel'), false);
      assert.equal(prefs.text().includes('notification-on-prefs-channel'), false);
      assert.equal(prefs.text().includes('conversation-on-prefs-channel'), false);
      assert.equal(user.text().includes('marker-prefs-only'), false);
      assert.equal(user.text().includes('preferences_changed'), false);
      assert.equal(user.text().includes('prefs-for-notification-account'), false);
      assert.equal(notification.text().includes('marker-prefs-only'), false);
      assert.equal(notification.text().includes('prefs-for-notification-account'), false);
      assert.equal(notification.text().includes('preferences_changed'), false);
      assert.equal(notification.text().includes('marker-user-only'), false);
    } finally {
      prefs.close();
      user.close();
      notification.close();
      await waitNumsub(prefsChannel(world.live.accountId), 0);
      await waitNumsub(userChannel(world.read.accountId), 0);
      await waitNumsub(userChannel(world.notifications.accountId), 0);
    }
  });

  it('unsubscribes preferences without dropping another stream on the same socket', async () => {
    const person = world.read;
    const prefs = prefsChannel(person.accountId);
    const user = userChannel(person.accountId);
    const socket = await connectSocket(person.token);

    try {
      socket.send({ type: 'subscribe', stream: 'user:preferences' });
      socket.send({ type: 'subscribe', stream: 'user' });
      await waitNumsub(prefs, 1);
      await waitNumsub(user, 1);

      await publish(prefs, 'preferences_changed', preferencePayload('41', ['marker-both-prefs']));
      await publish(user, 'update', 'marker-both-user');
      await waitFor(() => socket.messages.some(message => message.includes('marker-both-prefs')), 8000, 'both prefs');
      await waitFor(() => socket.messages.some(message => message.includes('marker-both-user')), 8000, 'both user');

      socket.send({ type: 'unsubscribe', stream: 'user:preferences' });
      await waitNumsub(prefs, 0);
      assert.equal(await numsub(user), 1);

      await publish(prefs, 'preferences_changed', preferencePayload('42', ['marker-after-unsub-prefs']));
      await publish(user, 'update', 'marker-after-unsub-user');
      await waitFor(() => socket.messages.some(message => message.includes('marker-after-unsub-user')), 8000, 'user remains');
      assert.equal(socket.messages.some(message => message.includes('marker-after-unsub-prefs')), false);
      assert.equal(socket.closed(), false);

      socket.send({ type: 'unsubscribe', stream: 'user' });
      await waitNumsub(user, 0);
      await publish(user, 'update', 'marker-user-gone');
      await publish(prefs, 'preferences_changed', preferencePayload('43', ['marker-prefs-still-gone']));
      await new Promise(resolve => {
        setTimeout(resolve, 400);
      });
      assert.equal(socket.messages.some(message => message.includes('marker-user-gone')), false);
      assert.equal(socket.messages.some(message => message.includes('marker-prefs-still-gone')), false);

      socket.send({ type: 'subscribe', stream: 'user:preferences' });
      socket.send({ type: 'subscribe', stream: 'user' });
      await waitNumsub(prefs, 1);
      await waitNumsub(user, 1);
      socket.send({ type: 'unsubscribe', stream: 'user' });
      await waitNumsub(user, 0);
      assert.equal(await numsub(prefs), 1);

      await publish(prefs, 'preferences_changed', preferencePayload('44', ['marker-prefs-after-user-unsub']));
      await publish(user, 'update', 'marker-user-after-user-unsub');
      await waitFor(() => socket.messages.some(message => message.includes('marker-prefs-after-user-unsub')), 8000, 'prefs remains');
      assert.equal(socket.messages.some(message => message.includes('marker-user-after-user-unsub')), false);
    } finally {
      socket.ws.close();
      await waitNumsub(prefs, 0);
      await waitNumsub(user, 0);
    }
  });

  it('removes the Redis listener after the SSE and WebSocket disconnect', async () => {
    const person = world.leak;
    const channel = prefsChannel(person.accountId);
    const stream = await openSse(PREFS_PATH, person.token);
    const socket = await connectSocket(person.token);

    try {
      assert.equal(stream.status, 200);
      socket.send({ type: 'subscribe', stream: 'user:preferences' });
      await waitFor(() => stream.text().includes(':)'), 8000, 'leak hello');
      await waitNumsub(channel, 1);
      await waitNumsub(tokenChannel(person.tokenId), 1);
    } finally {
      stream.close();
      socket.ws.close();
    }

    await waitNumsub(channel, 0);
    await waitNumsub(tokenChannel(person.tokenId), 0);
    await waitNumsub(`${PREFIX}timeline:system:${person.accountId}`, 0);
    await publish(channel, 'preferences_changed', preferencePayload('51', ['marker-after-disconnect']));
    await new Promise(resolve => {
      setTimeout(resolve, 400);
    });
    assert.equal(await numsub(channel), 0);
  });

  it('closes an open preferences stream when the token or account stops being usable', async () => {
    const cases = [
      {
        person: world.live,
        mutate: async () => {
          await publish(tokenChannel(world.live.tokenId), 'kill', {});
        },
      },
      {
        person: world.cutoffRevoke,
        mutate: async () => {
          await db.query('UPDATE oauth_access_tokens SET revoked_at = NOW() WHERE id = $1', [world.cutoffRevoke.tokenId]);
        },
      },
      {
        person: world.cutoffSuspend,
        mutate: async () => {
          await db.query('UPDATE accounts SET suspended_at = NOW() WHERE id = $1', [world.cutoffSuspend.accountId]);
        },
      },
      {
        person: world.cutoffExpire,
        mutate: async () => {
          await db.query('UPDATE oauth_access_tokens SET expires_in = 1, created_at = NOW() - INTERVAL \'1 hour\' WHERE id = $1', [world.cutoffExpire.tokenId]);
        },
      },
      {
        person: world.cutoffDisable,
        mutate: async () => {
          await db.query('UPDATE users SET disabled = TRUE WHERE id = $1', [world.cutoffDisable.userId]);
        },
      },
    ];

    for (const entry of cases) {
      const channel = prefsChannel(entry.person.accountId);
      const beforeKey = `before-${entry.person.username}`;
      const afterKey = `after-${entry.person.username}`;
      const stream = await openSse(PREFS_PATH, entry.person.token);
      const socket = await connectSocket(entry.person.token);

      try {
        assert.equal(stream.status, 200);
        socket.send({ type: 'subscribe', stream: 'user:preferences' });
        await waitFor(() => stream.text().includes(':)'), 8000, `${entry.person.username} hello`);
        await waitNumsub(channel, 1);
        await publish(channel, 'preferences_changed', preferencePayload('61', [beforeKey]));
        await waitFor(() => stream.text().includes(beforeKey), 8000, `${entry.person.username} sse before`);
        await waitFor(() => socket.messages.some(message => message.includes(beforeKey)), 8000, `${entry.person.username} ws before`);

        await entry.mutate();
        if (entry.person !== world.live) {
          await publish(channel, 'preferences_changed', preferencePayload('62', [afterKey]));
        }

        await waitFor(() => stream.ended() && socket.closed(), 8000, `${entry.person.username} closed`);
        assert.equal(stream.text().includes(afterKey), false);
        assert.equal(socket.messages.some(message => message.includes(afterKey)), false);
      } finally {
        stream.close();
        if (socket.opened) {
          socket.ws.close();
        }
        await waitNumsub(channel, 0);
      }
    }
  });

  it('keeps hashtag streams and the read:statuses user stream on the namespaced server', async () => {
    const local = await openSse('/api/v1/streaming/hashtag/local?tag=PrefTest');
    const shared = await openSse('/api/v1/streaming/hashtag?tag=PrefTest');
    const user = await openSse(USER_PATH, world.statuses.token);
    const preferencesDenied = await readHttp(USER_PATH, world.readPreferences.token);

    try {
      assert.equal(local.status, 200);
      assert.equal(shared.status, 200);
      assert.equal(user.status, 200);
      assert.equal(preferencesDenied.status, 401);
      assert.deepEqual(JSON.parse(preferencesDenied.body), { error: SCOPE_ERROR });
      await waitFor(() => local.text().includes(':)') && shared.text().includes(':)') && user.text().includes(':)'), 8000, 'regression hello');

      await publish('timeline:hashtag:preftest', 'delete', 'bare-hashtag');
      await publish(`${PREFIX}timeline:hashtag:preftest`, 'delete', 'namespaced-hashtag');
      await publish(`${PREFIX}timeline:hashtag:preftest:local`, 'delete', 'upstream-local-hashtag');
      await publish(`${PREFIX}timeline:fedibird:empty:hashtag:local:preftest`, 'delete', 'empty-local-hashtag');
      await publish(userChannel(world.statuses.accountId), 'update', 'statuses-user-marker');
      await publish(prefsChannel(world.statuses.accountId), 'preferences_changed', preferencePayload('71', ['statuses-prefs-marker']));

      await waitFor(() => shared.text().includes('namespaced-hashtag'), 8000, 'namespaced hashtag');
      await waitFor(() => local.text().includes('empty-local-hashtag'), 8000, 'empty local hashtag');
      await waitFor(() => user.text().includes('statuses-user-marker'), 8000, 'statuses user marker');

      assert.equal(shared.text().includes('bare-hashtag'), false);
      assert.equal(local.text().includes('upstream-local-hashtag'), false);
      assert.equal(local.text().includes('namespaced-hashtag'), false);
      assert.equal(user.text().includes('statuses-prefs-marker'), false);
      assert.equal(user.text().includes('empty-local-hashtag'), false);
    } finally {
      local.close();
      shared.close();
      user.close();
      await waitNumsub(userChannel(world.statuses.accountId), 0);
    }
  });

  it('does not deliver a preference event whose authorization finishes after unsubscribe', async () => {
    const person = world.raceQuiet;
    const prefs = prefsChannel(person.accountId);
    const user = userChannel(person.accountId);
    const socket = await connectSocket(person.token);

    try {
      socket.send({ type: 'subscribe', stream: 'user:preferences' });
      socket.send({ type: 'subscribe', stream: 'user' });
      await waitNumsub(prefs, 1);
      await waitNumsub(user, 1);

      await withHeldAuthorization(async release => {
        await publish(prefs, 'preferences_changed', preferencePayload('81', ['marker-unsub-late']));
        await waitFor(async () => (await countBlockedAuthQueries()) >= 1, 8000, 'quiet auth blocked');
        socket.send({ type: 'unsubscribe', stream: 'user:preferences' });
        await waitNumsub(prefs, 0);
        assert.equal(await numsub(user), 1);
        await release();
        await waitFor(async () => (await countBlockedAuthQueries()) === 0, 8000, 'quiet auth finished');
      });

      await publish(user, 'update', 'marker-user-after-late-auth');
      await waitFor(() => socket.messages.some(message => message.includes('marker-user-after-late-auth')), 8000, 'user after late auth');
      assert.equal(socket.messages.some(message => message.includes('marker-unsub-late')), false);
      assert.equal(socket.closed(), false);
    } finally {
      socket.ws.close();
      await waitNumsub(prefs, 0);
      await waitNumsub(user, 0);
    }
  });

  it('keeps the user stream when a removed preferences subscription fails authorization', async () => {
    const person = world.raceFail;
    const prefs = prefsChannel(person.accountId);
    const user = userChannel(person.accountId);
    const socket = await connectSocket(person.token);

    try {
      socket.send({ type: 'subscribe', stream: 'user:preferences' });
      socket.send({ type: 'subscribe', stream: 'user' });
      await waitNumsub(prefs, 1);
      await waitNumsub(user, 1);

      await withHeldAuthorization(async release => {
        await publish(prefs, 'preferences_changed', preferencePayload('82', ['marker-unsub-revoke']));
        await waitFor(async () => (await countBlockedAuthQueries()) >= 1, 8000, 'revoke auth blocked');
        socket.send({ type: 'unsubscribe', stream: 'user:preferences' });
        await waitNumsub(prefs, 0);
        await lockClient.query('UPDATE oauth_access_tokens SET revoked_at = NOW() WHERE id = $1', [person.tokenId]);
        await release();
        await waitFor(async () => (await countBlockedAuthQueries()) === 0, 8000, 'revoke auth finished');
      });

      await publish(user, 'update', 'marker-user-after-revoked-unsub');
      await waitFor(() => socket.messages.some(message => message.includes('marker-user-after-revoked-unsub')), 8000, 'user after revoked unsub');
      assert.equal(socket.messages.some(message => message.includes('marker-unsub-revoke')), false);
      assert.equal(socket.closed(), false);
    } finally {
      socket.ws.close();
      await waitNumsub(prefs, 0);
      await waitNumsub(user, 0);
    }
  });

  it('does not apply an in-flight authorization to a preferences subscription created later', async () => {
    const person = world.raceRenew;
    const prefs = prefsChannel(person.accountId);
    const socket = await connectSocket(person.token);

    try {
      socket.send({ type: 'subscribe', stream: 'user:preferences' });
      await waitNumsub(prefs, 1);

      await withHeldAuthorization(async release => {
        await publish(prefs, 'preferences_changed', preferencePayload('83', ['marker-old-subscription']));
        await waitFor(async () => (await countBlockedAuthQueries()) >= 1, 8000, 'old auth blocked');
        socket.send({ type: 'unsubscribe', stream: 'user:preferences' });
        await waitNumsub(prefs, 0);
        socket.send({ type: 'subscribe', stream: 'user:preferences' });
        await waitFor(async () => (await countBlockedAuthQueries()) >= 2, 8000, 'new auth blocked');
        await release();
        await waitFor(async () => (await countBlockedAuthQueries()) === 0, 8000, 'renew auth finished');
        await waitNumsub(prefs, 1);
      });

      assert.equal(socket.messages.some(message => message.includes('marker-old-subscription')), false);
      assert.equal(socket.closed(), false);
      await publish(prefs, 'preferences_changed', preferencePayload('84', ['marker-new-subscription']));
      await waitFor(() => socket.messages.some(message => message.includes('marker-new-subscription')), 8000, 'new subscription event');
      assert.equal(socket.messages.some(message => message.includes('marker-old-subscription')), false);
    } finally {
      socket.ws.close();
      await waitNumsub(prefs, 0);
    }
  });

  it('does not send a preference event whose authorization finishes after disconnect', async () => {
    const person = world.raceDrop;
    const prefs = prefsChannel(person.accountId);
    const socket = await connectSocket(person.token);
    const logAt = serverLog.length;

    try {
      socket.send({ type: 'subscribe', stream: 'user:preferences' });
      await waitNumsub(prefs, 1);

      await withHeldAuthorization(async release => {
        await publish(prefs, 'preferences_changed', preferencePayload('85', ['marker-after-disconnect']));
        await waitFor(async () => (await countBlockedAuthQueries()) >= 1, 8000, 'disconnect auth blocked');
        socket.ws.close();
        await waitNumsub(prefs, 0);
        await release();
        await waitFor(async () => (await countBlockedAuthQueries()) === 0, 8000, 'disconnect auth finished');
      });

      assert.equal(socket.messages.some(message => message.includes('marker-after-disconnect')), false);
      assert.equal(serverLog.slice(logAt).includes('Tried writing to closed socket'), false);
      assert.equal(await numsub(prefs), 0);
    } finally {
      if (socket.opened && !socket.closed()) {
        socket.ws.close();
      }
      await waitNumsub(prefs, 0);
    }
  });

  it('closes an active preferences subscription when authorization fails', async () => {
    const person = world.raceLive;
    const prefs = prefsChannel(person.accountId);
    const socket = await connectSocket(person.token);

    try {
      socket.send({ type: 'subscribe', stream: 'user:preferences' });
      socket.send({ type: 'subscribe', stream: 'user' });
      await waitNumsub(prefs, 1);

      await withHeldAuthorization(async release => {
        await publish(prefs, 'preferences_changed', preferencePayload('86', ['marker-active-revoke']));
        await waitFor(async () => (await countBlockedAuthQueries()) >= 1, 8000, 'active revoke blocked');
        await lockClient.query('UPDATE oauth_access_tokens SET revoked_at = NOW() WHERE id = $1', [person.tokenId]);
        await release();
        await waitFor(() => socket.closed(), 8000, 'active revoke closed');
      });

      assert.equal(socket.messages.some(message => message.includes('marker-active-revoke')), false);
    } finally {
      if (socket.opened && !socket.closed()) {
        socket.ws.close();
      }
      await waitNumsub(prefs, 0);
      await waitNumsub(userChannel(person.accountId), 0);
    }
  });

  it('deletes only the accounts, users, and tokens created by this run', async () => {
    const preexisting = world.preexistingAccountId;
    const accountIds = created.accountIds.slice();
    const userIds = created.userIds.slice();
    const tokenIds = created.tokenIds.slice();
    const keptBefore = await db.query('SELECT id FROM accounts WHERE id = $1', [preexisting]);

    assert.equal(keptBefore.rows.length, 1);
    assert.equal(accountIds.includes(preexisting), false);

    await deleteCreated();

    const keptAfter = await db.query('SELECT id FROM accounts WHERE id = $1', [preexisting]);
    const accountsLeft = await db.query('SELECT COUNT(*)::int AS n FROM accounts WHERE id = ANY($1::bigint[])', [accountIds]);
    const usersLeft = await db.query('SELECT COUNT(*)::int AS n FROM users WHERE id = ANY($1::bigint[])', [userIds]);
    const tokensLeft = await db.query('SELECT COUNT(*)::int AS n FROM oauth_access_tokens WHERE id = ANY($1::bigint[])', [tokenIds]);

    assert.equal(keptAfter.rows.length, 1);
    assert.equal(Number(accountsLeft.rows[0].n), 0);
    assert.equal(Number(usersLeft.rows[0].n), 0);
    assert.equal(Number(tokensLeft.rows[0].n), 0);
  });
});
