const { describe, it, before, after } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('crypto');
const http = require('http');
const { spawn } = require('child_process');
const redis = require('redis');
const { Client } = require('pg');
const WebSocket = require('ws');

// Dedicated database and port, so this file can run next to
// external_feed_stream.test.js without sharing its table locks.
const PORT = 4023;
const BASE = `http://127.0.0.1:${PORT}`;
const NAMESPACE = 'extboostc';
const PREFIX = `${NAMESPACE}:`;
const HUGE_USER_ID = '9007199254740993';
const HUGE_STATUS_ID = '9007199254740995';
const HUGE_REVISION = '9007199254740997';
const SECRET = `SECRET_BODY_c_${crypto.randomBytes(4).toString('hex')}`;
const TEST_DB_KEYS = [
  'EXTERNAL_BOOST_STREAM_TEST_DB_NAME',
  'EXTERNAL_BOOST_STREAM_TEST_DB_USER',
  'EXTERNAL_BOOST_STREAM_TEST_DB_PASSWORD',
  'EXTERNAL_BOOST_STREAM_TEST_DB_HOST',
  'EXTERNAL_BOOST_STREAM_TEST_DB_PORT',
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
  listIds: [],
  statusIds: [],
  sourceIds: [],
  resourceIds: [],
  subscriptionIds: [],
};
const seeded = new Map();

const testDatabaseConfig = (env) => {
  const missing = TEST_DB_KEYS.filter(key => {
    if (!Object.prototype.hasOwnProperty.call(env, key) || env[key] === undefined) {
      return true;
    }

    return key !== 'EXTERNAL_BOOST_STREAM_TEST_DB_PASSWORD' && env[key] === '';
  });

  if (missing.length > 0) {
    throw new Error(`Refusing to start without ${missing.join(', ')}`);
  }

  const database = env.EXTERNAL_BOOST_STREAM_TEST_DB_NAME;

  if (!/^[A-Za-z0-9_]+$/.test(database) || !/test/i.test(database) || /development|production/i.test(database)) {
    throw new Error(`Refusing database "${database}"`);
  }

  const port = Number(env.EXTERNAL_BOOST_STREAM_TEST_DB_PORT);

  if (!Number.isInteger(port) || port <= 0) {
    throw new Error('EXTERNAL_BOOST_STREAM_TEST_DB_PORT must be a positive integer');
  }

  return {
    database: database,
    user: env.EXTERNAL_BOOST_STREAM_TEST_DB_USER,
    password: env.EXTERNAL_BOOST_STREAM_TEST_DB_PASSWORD,
    host: env.EXTERNAL_BOOST_STREAM_TEST_DB_HOST,
    port: port,
  };
};

const boostChannel = userId => `${PREFIX}timeline:external:user:${userId}:boost`;
const homeChannel = userId => `${PREFIX}timeline:external:user:${userId}:home`;
const controlChannel = userId => `${PREFIX}timeline:external:user:${userId}:control`;
const accountChannel = accountId => `${PREFIX}timeline:${accountId}`;

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

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

const publish = (channel, message) => new Promise((resolve, reject) => {
  publisher.publish(channel, JSON.stringify(Object.assign({ queued_at: Date.now() }, message)), error => {
    if (error) {
      reject(error);
      return;
    }

    resolve();
  });
});

const publishBoost = (userId, statusId, revision, reblogged, extra = {}) => publish(boostChannel(userId), Object.assign({
  event: 'external_link_boost_changed',
  payload: { version: 1, status_id: String(statusId), reblogged: reblogged, revision: String(revision) },
  delivery: { kind: 'boost', user_id: String(userId), status_id: String(statusId), revision: String(revision) },
}, extra));

const openSse = (path, token) => new Promise((resolve, reject) => {
  const headers = {};

  if (token) {
    headers.Authorization = `Bearer ${token}`;
  }

  const req = http.get(`${BASE}${path}`, { headers: headers }, res => {
    req.setTimeout(0);
    const chunks = [];

    res.on('data', chunk => chunks.push(chunk));
    resolve({
      status: res.statusCode,
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

const readHttp = path => new Promise((resolve, reject) => {
  const req = http.get(`${BASE}${path}`, res => {
    const chunks = [];

    res.on('data', chunk => chunks.push(chunk));
    res.on('end', () => resolve({ status: res.statusCode, body: Buffer.concat(chunks).toString('utf8') }));
  });

  req.setTimeout(4000, () => {
    req.destroy(new Error('request timeout'));
  });
  req.on('error', reject);
});

const connectSocket = token => new Promise((resolve, reject) => {
  const ws = new WebSocket(`ws://127.0.0.1:${PORT}/api/v1/streaming`, { headers: { Authorization: `Bearer ${token}` } });
  const messages = [];
  let settled = false;

  ws.on('message', data => messages.push(data.toString()));
  ws.once('open', () => {
    settled = true;
    resolve({ ws: ws, messages: messages, send: payload => ws.send(JSON.stringify(payload)) });
  });
  ws.on('error', () => {});
  setTimeout(() => {
    if (!settled) {
      reject(new Error(`websocket open timed out\n${serverLog}`));
    }
  }, 8000);
});

const frames = socket => socket.messages.flatMap(message => {
  try {
    return [JSON.parse(message)];
  } catch (parseError) {
    return parseError ? [] : [];
  }
});

const boostFrames = socket => frames(socket).filter(frame => frame.event === 'external_link_boost_changed');

const closeSocket = socket => {
  if (socket && socket.ws && socket.ws.readyState === WebSocket.OPEN) {
    socket.ws.close();
  }
};

const insertAccount = async (username, fields) => {
  const result = await db.query(
    'INSERT INTO accounts (username, memorial, suspended_at, moved_to_account_id, created_at, updated_at) VALUES ($1, $2, $3, $4, NOW(), NOW()) RETURNING id::text',
    [username, fields.memorial === true, fields.suspendedAt || null, fields.movedTo || null],
  );

  created.accountIds.push(result.rows[0].id);

  return result.rows[0].id;
};

const insertUser = async (accountId, email, fields, explicitId) => {
  const result = await db.query(
    'INSERT INTO users (id, email, account_id, confirmed_at, approved, disabled, created_at, updated_at) VALUES (COALESCE($1::bigint, nextval(\'users_id_seq\')), $2, $3, $4, $5, $6, NOW(), NOW()) RETURNING id::text',
    [explicitId || null, email, accountId, fields.confirmed === false ? null : new Date(), fields.approved !== false, fields.disabled === true],
  );

  created.userIds.push(result.rows[0].id);

  return result.rows[0].id;
};

const insertToken = async (userId, scopes, fields) => {
  const token = `ebc_${crypto.randomBytes(18).toString('hex')}`;
  const result = await db.query(
    'INSERT INTO oauth_access_tokens (token, scopes, resource_owner_id, created_at, expires_in, revoked_at) VALUES ($1, $2, $3, $4, $5, $6) RETURNING id::text',
    [
      token,
      scopes,
      userId,
      fields.createdAt || new Date(),
      Object.prototype.hasOwnProperty.call(fields, 'expiresIn') ? fields.expiresIn : null,
      fields.revoked === true ? new Date() : null,
    ],
  );

  created.tokenIds.push(result.rows[0].id);

  return { token: token, id: result.rows[0].id };
};

const insertList = async (accountId, title) => {
  const result = await db.query(
    'INSERT INTO lists (account_id, title, created_at, updated_at) VALUES ($1, $2, NOW(), NOW()) RETURNING id::text',
    [accountId, title],
  );

  created.listIds.push(result.rows[0].id);

  return result.rows[0].id;
};

const createPersonOn = async (accountId, name, scopes, userFields, tokenFields, explicitUserId) => {
  const username = `b${runId}${name}`.slice(0, 30);
  const userId = await insertUser(accountId, `${username}@external.test`, userFields || {}, explicitUserId);
  const token = await insertToken(userId, scopes, tokenFields || {});

  return { username: username, accountId: accountId, userId: userId, token: token.token, tokenId: token.id };
};

const createPerson = async (name, scopes, accountFields, userFields, tokenFields, explicitUserId) => {
  const accountId = await insertAccount(`b${runId}${name}`.slice(0, 30), accountFields || {});

  return createPersonOn(accountId, name, scopes, userFields, tokenFields, explicitUserId);
};

// One projection (visibility 201 status plus marker) owned by `person`, and
// its (revision, reblogged) row. No feed route is created: this channel must
// not depend on one.
const seedProjection = async (person, statusId, revision, reblogged) => {
  let entry = seeded.get(`${person.userId}:${statusId}`);

  if (!entry) {
    const source = await db.query(
      'INSERT INTO external_sources (protocol, canonical_key, created_at, updated_at) VALUES (\'rss\', $1, NOW(), NOW()) RETURNING id::text',
      [`https://feeds.example/${runId}/${person.userId}/${statusId}.xml`],
    );
    const subscription = await db.query(
      'INSERT INTO external_subscriptions (user_id, external_source_id, state, created_at, updated_at) VALUES ($1, $2, \'active\', NOW(), NOW()) RETURNING id::text',
      [person.userId, source.rows[0].id],
    );
    const resource = await db.query(
      'INSERT INTO external_resources (external_source_id, protocol, canonical_key, created_at, updated_at) VALUES ($1, \'rss\', $2, NOW(), NOW()) RETURNING id::text',
      [source.rows[0].id, `feed:${source.rows[0].id}\nitem:${statusId}`],
    );

    await db.query(
      'INSERT INTO statuses (id, text, created_at, updated_at, sensitive, visibility, spoiler_text, reply, local, account_id, searchability, external_projection) VALUES ($1, $2, NOW(), NOW(), FALSE, 201, \'\', FALSE, TRUE, $3, 200, TRUE)',
      [statusId, SECRET, person.accountId],
    );
    await db.query(
      'INSERT INTO external_status_projections (user_id, account_id, external_source_id, external_subscription_id, external_resource_id, status_id, source_deleted, content_generation, created_at, updated_at) VALUES ($1, $2, $3, $4, $5, $6, FALSE, 1, NOW(), NOW())',
      [person.userId, person.accountId, source.rows[0].id, subscription.rows[0].id, resource.rows[0].id, statusId],
    );
    created.sourceIds.push(source.rows[0].id);
    created.subscriptionIds.push(subscription.rows[0].id);
    created.resourceIds.push(resource.rows[0].id);
    created.statusIds.push(String(statusId));
    entry = true;
    seeded.set(`${person.userId}:${statusId}`, entry);
  }

  await setState(person, statusId, revision, reblogged);
};

const setState = async (person, statusId, revision, reblogged) => {
  await db.query(
    'INSERT INTO external_projection_link_boost_states (user_id, projection_status_id, revision, reblogged, created_at, updated_at) VALUES ($1, $2, $3, $4, NOW(), NOW()) ON CONFLICT (user_id, projection_status_id) DO UPDATE SET revision = EXCLUDED.revision, reblogged = EXCLUDED.reblogged',
    [person.userId, statusId, revision, reblogged],
  );
};

const deleteCreated = async () => {
  await db.query('BEGIN');

  try {
    await db.query('SELECT set_config(\'fedibird.projection_status_delete\', \'on\', true)');

    if (created.userIds.length > 0) {
      await db.query('DELETE FROM external_projection_link_boost_states WHERE user_id = ANY($1::bigint[])', [created.userIds]);
    }

    if (created.statusIds.length > 0) {
      await db.query('DELETE FROM statuses WHERE id = ANY($1::bigint[])', [created.statusIds]);
    }

    if (created.subscriptionIds.length > 0) {
      await db.query('DELETE FROM external_subscriptions WHERE id = ANY($1::bigint[])', [created.subscriptionIds]);
    }

    if (created.resourceIds.length > 0) {
      await db.query('DELETE FROM external_resources WHERE id = ANY($1::bigint[])', [created.resourceIds]);
    }

    if (created.sourceIds.length > 0) {
      await db.query('DELETE FROM external_sources WHERE id = ANY($1::bigint[])', [created.sourceIds]);
    }

    await db.query('COMMIT');
  } catch (error) {
    await db.query('ROLLBACK');
    throw error;
  }

  if (created.tokenIds.length > 0) {
    await db.query('DELETE FROM oauth_access_tokens WHERE id = ANY($1::bigint[])', [created.tokenIds]);
  }

  if (created.listIds.length > 0) {
    await db.query('DELETE FROM lists WHERE id = ANY($1::bigint[])', [created.listIds]);
  }

  if (created.userIds.length > 0) {
    await db.query('DELETE FROM users WHERE id = ANY($1::bigint[])', [created.userIds]);
  }

  if (created.accountIds.length > 0) {
    await db.query('DELETE FROM accounts WHERE id = ANY($1::bigint[])', [created.accountIds]);
  }
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

const payloadOf = frame => JSON.parse(frame.payload);

describe('external boost stream database guard', () => {
  const present = {
    EXTERNAL_BOOST_STREAM_TEST_DB_NAME: 'external_boost_stream_test',
    EXTERNAL_BOOST_STREAM_TEST_DB_USER: 'mastodon',
    EXTERNAL_BOOST_STREAM_TEST_DB_PASSWORD: 'mastodon',
    EXTERNAL_BOOST_STREAM_TEST_DB_HOST: 'localhost',
    EXTERNAL_BOOST_STREAM_TEST_DB_PORT: '5432',
  };

  it('rejects a missing test database before changing data', () => {
    assert.throws(() => testDatabaseConfig({}), /Refusing to start without/);
  });

  it('rejects a database name that is not a dedicated test database', () => {
    ['mastodon_development', 'mastodon_production', 'postgres', 'production_test'].forEach(name => {
      assert.throws(() => testDatabaseConfig(Object.assign({}, present, { EXTERNAL_BOOST_STREAM_TEST_DB_NAME: name })), /Refusing database/);
    });
    assert.equal(testDatabaseConfig(present).database, 'external_boost_stream_test');
  });
});

describe('owner boost state streaming', { concurrency: 1, timeout: 180000 }, () => {
  before(async () => {
    const dbConfig = testDatabaseConfig(process.env);
    const client = new Client(dbConfig);

    await client.connect();
    db = client;
    const current = await db.query('SELECT current_database() AS name');

    if (current.rows[0].name !== dbConfig.database) {
      throw new Error(`Connected to ${current.rows[0].name} instead of ${dbConfig.database}`);
    }

    // The feature flags are deliberately absent: the E3 feed flag is off and
    // no tester is listed, and this channel must still work.
    world.owner = await createPerson('owner', 'read:statuses');
    world.roommate = await createPersonOn(world.owner.accountId, 'room', 'read:statuses');
    world.lists = await createPerson('lists', 'read:lists');
    world.notes = await createPerson('notes', 'read:notifications');
    world.stranger = await createPerson('stranger', 'read:statuses');
    world.expired = await createPerson('expired', 'read:statuses', {}, {}, { createdAt: new Date(Date.now() - (60 * 60 * 1000)), expiresIn: 60 });
    world.revoked = await createPerson('revoked', 'read:statuses', {}, {}, { revoked: true });
    world.suspended = await createPerson('suspended', 'read:statuses', { suspendedAt: new Date() });
    world.unconfirmed = await createPerson('unconfirmed', 'read:statuses', {}, { confirmed: false });
    world.huge = await createPerson('huge', 'read:statuses', {}, {}, {}, HUGE_USER_ID);
    world.listA = await insertList(world.owner.accountId, `A ${runId}`);

    const held = new Client(dbConfig);

    await held.connect();
    lockClient = held;
    const childEnv = Object.assign({}, process.env, {
      NODE_ENV: 'test',
      PORT: String(PORT),
      BIND: '127.0.0.1',
      STREAMING_CLUSTER_NUM: '1',
      LOG_LEVEL: 'silly',
      REDIS_NAMESPACE: NAMESPACE,
      DB_HOST: dbConfig.host,
      DB_PORT: String(dbConfig.port),
      DB_USER: dbConfig.user,
      DB_PASS: dbConfig.password,
      DB_NAME: dbConfig.database,
    });

    delete childEnv.DATABASE_URL;
    delete childEnv.LIMITED_FEDERATION_MODE;
    delete childEnv.WHITELIST_MODE;
    delete childEnv.AUTHORIZED_FETCH;
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
      await db.end();
    }
  });

  it('delivers the database pair over WebSocket and SSE with no feed route, flag, or tester', async () => {
    await seedProjection(world.owner, '41', '1', true);
    const socket = await connectSocket(world.owner.token);
    const sse = await openSse('/api/v1/streaming/user', world.owner.token);

    try {
      socket.send({ type: 'subscribe', stream: 'user' });
      await waitNumsub(boostChannel(world.owner.userId), 1);
      await sleep(300);
      assert.equal(await numsub(homeChannel(world.owner.userId)), 0);
      assert.equal(await numsub(controlChannel(world.owner.userId)), 0);

      await publishBoost(world.owner.userId, '41', '1', true, { payload_extra: SECRET });
      await waitFor(() => boostFrames(socket).length === 1, 8000, 'websocket boost frame');
      await waitFor(() => sse.text().includes('event: external_link_boost_changed'), 8000, 'sse boost frame');

      const frame = boostFrames(socket)[0];

      assert.deepEqual(frame.stream, ['user']);
      assert.deepEqual(payloadOf(frame), { version: 1, status_id: '41', reblogged: true, revision: '1' });
      const block = sse.text().split('\n\n').find(item => item.includes('external_link_boost_changed'));

      assert.equal(block.includes('data: {"version":1,"status_id":"41","reblogged":true,"revision":"1"}'), true);
      assert.equal(JSON.stringify(frames(socket)).includes(SECRET), false);
      assert.equal(sse.text().includes(SECRET), false);
      assert.equal(sse.text().includes('delivery'), false);
    } finally {
      sse.close();
      closeSocket(socket);
      await waitNumsub(boostChannel(world.owner.userId), 0);
    }
  });

  it('writes the current row, never a stale frame, and drops older and repeated revisions', async () => {
    await seedProjection(world.owner, '42', '3', true);
    const socket = await connectSocket(world.owner.token);

    try {
      socket.send({ type: 'subscribe', stream: 'user' });
      await waitNumsub(boostChannel(world.owner.userId), 1);
      await publishBoost(world.owner.userId, '42', '2', false);
      await publishBoost(world.owner.userId, '42', '3', true);
      await waitFor(() => boostFrames(socket).length >= 1, 8000, 'first frame');
      await sleep(300);
      assert.deepEqual(boostFrames(socket).map(payloadOf), [{ version: 1, status_id: '42', reblogged: true, revision: '3' }]);

      await setState(world.owner, '42', '4', false);
      await publishBoost(world.owner.userId, '42', '4', false);
      await waitFor(() => boostFrames(socket).length === 2, 8000, 'second frame');
      await publishBoost(world.owner.userId, '42', '3', true);
      await publishBoost(world.owner.userId, '42', '4', false);
      await sleep(400);
      assert.deepEqual(boostFrames(socket).map(item => payloadOf(item).revision), ['3', '4']);
      assert.equal(payloadOf(boostFrames(socket)[1]).reblogged, false);
    } finally {
      closeSocket(socket);
      await waitNumsub(boostChannel(world.owner.userId), 0);
    }
  });

  it('keeps ids and revisions at or above 2^53 as strings', async () => {
    await seedProjection(world.huge, HUGE_STATUS_ID, HUGE_REVISION, true);
    const sse = await openSse('/api/v1/streaming/user', world.huge.token);

    try {
      await waitNumsub(boostChannel(HUGE_USER_ID), 1);
      await publishBoost(HUGE_USER_ID, HUGE_STATUS_ID, '9007199254740993', false);
      await waitFor(() => sse.text().includes('external_link_boost_changed'), 8000, 'huge frame');
      const block = sse.text().split('\n\n').find(item => item.includes('external_link_boost_changed'));

      assert.equal(block.includes(`data: {"version":1,"status_id":"${HUGE_STATUS_ID}","reblogged":true,"revision":"${HUGE_REVISION}"}`), true);
    } finally {
      sse.close();
      await waitNumsub(boostChannel(HUGE_USER_ID), 0);
    }
  });

  it('separates two users of one account and another account', async () => {
    await seedProjection(world.owner, '43', '1', true);
    const owner = await connectSocket(world.owner.token);
    const roommate = await connectSocket(world.roommate.token);
    const stranger = await connectSocket(world.stranger.token);

    try {
      owner.send({ type: 'subscribe', stream: 'user', user_id: world.roommate.userId });
      roommate.send({ type: 'subscribe', stream: 'user' });
      stranger.send({ type: 'subscribe', stream: 'user' });
      await waitNumsub(boostChannel(world.owner.userId), 1);
      await waitNumsub(boostChannel(world.roommate.userId), 1);
      await waitNumsub(boostChannel(world.stranger.userId), 1);

      await publishBoost(world.owner.userId, '43', '1', true);
      await waitFor(() => boostFrames(owner).length === 1, 8000, 'owner frame');
      await sleep(300);
      assert.equal(boostFrames(roommate).length, 0);
      assert.equal(boostFrames(stranger).length, 0);

      // A frame on another user's own channel that names the owner's
      // projection finds no marker for that user, so nothing is written.
      await publishBoost(world.roommate.userId, '43', '1', true);
      await publishBoost(world.stranger.userId, '43', '1', true);
      await sleep(400);
      assert.equal(boostFrames(roommate).length, 0);
      assert.equal(boostFrames(stranger).length, 0);

      // A frame addressed to the owner but published on the roommate's
      // channel is dropped by the delivery check.
      await publish(boostChannel(world.roommate.userId), {
        event: 'external_link_boost_changed',
        payload: { version: 1, status_id: '43', reblogged: true, revision: '1' },
        delivery: { kind: 'boost', user_id: world.owner.userId, status_id: '43', revision: '1' },
      });
      await sleep(300);
      assert.equal(boostFrames(roommate).length, 0);

      // Ordinary account-channel traffic is unchanged.
      await publish(accountChannel(world.owner.accountId), { event: 'update', payload: { id: '11', content: `ordinary-${runId}` } });
      await waitFor(() => frames(owner).some(item => JSON.stringify(item).includes(`ordinary-${runId}`)), 8000, 'owner ordinary');
      await waitFor(() => frames(roommate).some(item => JSON.stringify(item).includes(`ordinary-${runId}`)), 8000, 'roommate ordinary');
    } finally {
      closeSocket(owner);
      closeSocket(roommate);
      closeSocket(stranger);
      await waitNumsub(boostChannel(world.owner.userId), 0);
      await waitNumsub(boostChannel(world.roommate.userId), 0);
      await waitNumsub(boostChannel(world.stranger.userId), 0);
    }
  });

  it('attaches only to user and list streams, never to notification, public, or direct', async () => {
    const notes = await openSse('/api/v1/streaming/user/notification', world.notes.token);
    const direct = await openSse('/api/v1/streaming/direct', world.owner.token);
    const publicStream = await openSse('/api/v1/streaming/public', world.owner.token);
    const prefs = await openSse('/api/v1/streaming/user:preferences', world.owner.token);

    try {
      await waitNumsub(accountChannel(world.notes.accountId), 1);
      await sleep(400);
      assert.equal(await numsub(boostChannel(world.owner.userId)), 0);
      assert.equal(await numsub(boostChannel(world.notes.userId)), 0);
    } finally {
      notes.close();
      direct.close();
      publicStream.close();
      prefs.close();
    }

    const list = await openSse(`/api/v1/streaming/list?list=${world.listA}`, world.owner.token);

    try {
      await waitNumsub(boostChannel(world.owner.userId), 1);
    } finally {
      list.close();
      await waitNumsub(boostChannel(world.owner.userId), 0);
    }
  });

  it('does not subscribe a token that is expired, revoked, or whose user is not functional', async () => {
    for (const person of [world.expired, world.revoked, world.suspended, world.unconfirmed]) {
      // eslint-disable-next-line no-await-in-loop
      const sse = await openSse('/api/v1/streaming/user', person.token);

      try {
        // eslint-disable-next-line no-await-in-loop
        await sleep(400);
        // eslint-disable-next-line no-await-in-loop
        assert.equal(await numsub(boostChannel(person.userId)), 0, person.username);
      } finally {
        sse.close();
      }
    }
  });

  it('stops writing when the token is revoked, without a reconnect', async () => {
    await seedProjection(world.owner, '44', '1', true);
    const socket = await connectSocket(world.owner.token);

    try {
      socket.send({ type: 'subscribe', stream: 'user' });
      await waitNumsub(boostChannel(world.owner.userId), 1);
      await publishBoost(world.owner.userId, '44', '1', true);
      await waitFor(() => boostFrames(socket).length === 1, 8000, 'before revoke');
      await db.query('UPDATE oauth_access_tokens SET revoked_at = NOW() WHERE id = $1', [world.owner.tokenId]);
      await setState(world.owner, '44', '2', false);
      await publishBoost(world.owner.userId, '44', '2', false);
      await sleep(500);
      assert.equal(boostFrames(socket).length, 1);
    } finally {
      await db.query('UPDATE oauth_access_tokens SET revoked_at = NULL WHERE id = $1', [world.owner.tokenId]);
      closeSocket(socket);
      await waitNumsub(boostChannel(world.owner.userId), 0);
    }
  });

  it('drops a late authorize result after unsubscribe and removes the listener on unsubscribe and close', async () => {
    await seedProjection(world.owner, '45', '1', true);
    const socket = await connectSocket(world.owner.token);

    try {
      await withHeldAuthorization(async release => {
        socket.send({ type: 'subscribe', stream: 'user' });
        await waitNumsub(accountChannel(world.owner.accountId), 1);
        assert.equal(await numsub(boostChannel(world.owner.userId)), 0);
        socket.send({ type: 'unsubscribe', stream: 'user' });
        await waitNumsub(accountChannel(world.owner.accountId), 0);
        await release();
      });
      await sleep(300);
      assert.equal(await numsub(boostChannel(world.owner.userId)), 0);

      socket.send({ type: 'subscribe', stream: 'user' });
      await waitNumsub(boostChannel(world.owner.userId), 1);
      await publishBoost(world.owner.userId, '45', '1', true);
      await waitFor(() => boostFrames(socket).length === 1, 8000, 'after resubscribe');
      socket.send({ type: 'unsubscribe', stream: 'user' });
      await waitNumsub(boostChannel(world.owner.userId), 0);
      await publishBoost(world.owner.userId, '45', '1', true);
      await sleep(300);
      assert.equal(boostFrames(socket).length, 1);
    } finally {
      closeSocket(socket);
    }

    const sse = await openSse('/api/v1/streaming/user', world.owner.token);

    await waitNumsub(boostChannel(world.owner.userId), 1);
    sse.close();
    await waitNumsub(boostChannel(world.owner.userId), 0);
  });

  it('survives a flooded channel: bounded queue, one write per status, ordinary traffic intact', async () => {
    await seedProjection(world.owner, '46', '1', true);
    const socket = await connectSocket(world.owner.token);

    try {
      socket.send({ type: 'subscribe', stream: 'user' });
      await waitNumsub(boostChannel(world.owner.userId), 1);

      for (let index = 0; index < 150; index += 1) {
        // eslint-disable-next-line no-await-in-loop
        await publishBoost(world.owner.userId, '46', '1', true);
      }

      await waitFor(() => boostFrames(socket).length >= 1, 8000, 'flood frame');
      await sleep(600);
      assert.equal(boostFrames(socket).length, 1);
      await publish(accountChannel(world.owner.accountId), { event: 'update', payload: { id: '12', content: `after-flood-${runId}` } });
      await waitFor(() => frames(socket).some(item => JSON.stringify(item).includes(`after-flood-${runId}`)), 8000, 'ordinary after flood');
    } finally {
      closeSocket(socket);
      await waitNumsub(boostChannel(world.owner.userId), 0);
    }
  });
});
