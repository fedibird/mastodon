const { describe, it, before, after } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('crypto');
const http = require('http');
const { spawn } = require('child_process');
const redis = require('redis');
const { Client } = require('pg');
const WebSocket = require('ws');

const PORT = 4022;
const BASE = `http://127.0.0.1:${PORT}`;
const NAMESPACE = 'extfeedb1';
const PREFIX = `${NAMESPACE}:`;
const HUGE_USER_ID = '9007199254740993';
const HUGE_LIST_ID = '9007199254740994';
const HUGE_STATUS_ID = '9007199254740995';
const SECRET = `SECRET_BODY_b1_${crypto.randomBytes(4).toString('hex')}`;
const TEST_DB_KEYS = [
  'EXTERNAL_FEED_STREAM_TEST_DB_NAME',
  'EXTERNAL_FEED_STREAM_TEST_DB_USER',
  'EXTERNAL_FEED_STREAM_TEST_DB_PASSWORD',
  'EXTERNAL_FEED_STREAM_TEST_DB_HOST',
  'EXTERNAL_FEED_STREAM_TEST_DB_PORT',
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
  settingIds: [],
  statusIds: [],
  sourceIds: [],
  resourceIds: [],
  subscriptionIds: [],
  bookmarkIds: [],
};
const feeds = new Map();

const testDatabaseConfig = (env) => {
  const missing = TEST_DB_KEYS.filter(key => {
    if (!Object.prototype.hasOwnProperty.call(env, key) || env[key] === undefined) {
      return true;
    }

    return key !== 'EXTERNAL_FEED_STREAM_TEST_DB_PASSWORD' && env[key] === '';
  });

  if (missing.length > 0) {
    throw new Error(`Refusing to start without ${missing.join(', ')}`);
  }

  const database = env.EXTERNAL_FEED_STREAM_TEST_DB_NAME;

  if (!/^[A-Za-z0-9_]+$/.test(database) || !/test/i.test(database) || /development|production/i.test(database)) {
    throw new Error(`Refusing database "${database}"`);
  }

  const port = Number(env.EXTERNAL_FEED_STREAM_TEST_DB_PORT);

  if (!Number.isInteger(port) || port <= 0) {
    throw new Error('EXTERNAL_FEED_STREAM_TEST_DB_PORT must be a positive integer');
  }

  return {
    database: database,
    user: env.EXTERNAL_FEED_STREAM_TEST_DB_USER,
    password: env.EXTERNAL_FEED_STREAM_TEST_DB_PASSWORD,
    host: env.EXTERNAL_FEED_STREAM_TEST_DB_HOST,
    port: port,
  };
};

const homeChannel = userId => `${PREFIX}timeline:external:user:${userId}:home`;
const listChannel = (userId, listId) => `${PREFIX}timeline:external:user:${userId}:list:${listId}`;
const controlChannel = userId => `${PREFIX}timeline:external:user:${userId}:control`;
const accountChannel = accountId => `${PREFIX}timeline:${accountId}`;

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

const publish = (channel, event, payload, delivery) => new Promise((resolve, reject) => {
  const message = {
    event: event,
    payload: payload,
    queued_at: Date.now(),
  };

  if (delivery) {
    message.delivery = delivery;
  }

  publisher.publish(channel, JSON.stringify(message), error => {
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

const frames = socket => socket.messages.flatMap(message => {
  try {
    return [JSON.parse(message)];
  } catch (parseError) {
    return parseError ? [] : [];
  }
});

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
  const id = result.rows[0].id;

  created.accountIds.push(id);

  return id;
};

const insertUser = async (accountId, email, fields, explicitId) => {
  const result = await db.query(
    'INSERT INTO users (id, email, account_id, confirmed_at, approved, disabled, created_at, updated_at) VALUES (COALESCE($1::bigint, nextval(\'users_id_seq\')), $2, $3, $4, $5, $6, NOW(), NOW()) RETURNING id::text',
    [
      explicitId || null,
      email,
      accountId,
      fields.confirmed === false ? null : new Date(),
      fields.approved !== false,
      fields.disabled === true,
    ],
  );
  const id = result.rows[0].id;

  created.userIds.push(id);

  return id;
};

const insertToken = async (userId, scopes, fields) => {
  const token = `efb1_${crypto.randomBytes(18).toString('hex')}`;
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
  const id = result.rows[0].id;

  created.tokenIds.push(id);

  return { token: token, id: id, userId: userId };
};

const insertList = async (accountId, title, explicitId) => {
  const result = await db.query(
    'INSERT INTO lists (id, account_id, title, created_at, updated_at) VALUES (COALESCE($1::bigint, nextval(\'lists_id_seq\')), $2, $3, NOW(), NOW()) RETURNING id::text',
    [explicitId || null, accountId, title],
  );
  const id = result.rows[0].id;

  created.listIds.push(id);

  return id;
};

const writeSetting = async (name, value) => {
  const existing = await db.query(
    'SELECT id::text FROM settings WHERE var = $1 AND thing_type IS NULL AND thing_id IS NULL ORDER BY id DESC LIMIT 1',
    [name],
  );

  if (existing.rows.length === 1) {
    await db.query('UPDATE settings SET value = $2, updated_at = NOW() WHERE id = $1', [existing.rows[0].id, value]);

    return;
  }

  const inserted = await db.query(
    'INSERT INTO settings (var, value, created_at, updated_at) VALUES ($1, $2, NOW(), NOW()) RETURNING id::text',
    [name, value],
  );

  created.settingIds.push(inserted.rows[0].id);
};

const setFeeds = async (enabled, testerIds) => {
  await writeSetting('external_bridge_feeds', enabled ? '--- true\n' : '--- false\n');
  await writeSetting('external_bridge_feeds_testers', `--- ${JSON.stringify(testerIds.join(','))}\n`);
};

const createPersonOn = async (accountId, name, scopes, userFields, tokenFields, explicitUserId) => {
  const username = `e${runId}${name}`.slice(0, 30);
  const userId = await insertUser(accountId, `${username}@external.test`, userFields || {}, explicitUserId);
  const token = await insertToken(userId, scopes, tokenFields || {});

  return {
    username: username,
    accountId: accountId,
    userId: userId,
    token: token.token,
    tokenId: token.id,
  };
};

const createPerson = async (name, scopes, accountFields, userFields, tokenFields, explicitUserId) => {
  const username = `e${runId}${name}`.slice(0, 30);
  const accountId = await insertAccount(username, accountFields || {});

  return createPersonOn(accountId, name, scopes, userFields, tokenFields, explicitUserId);
};

const ensureSubscription = async person => {
  const existing = feeds.get(person.userId);

  if (existing) {
    return existing;
  }

  const source = await db.query(
    'INSERT INTO external_sources (protocol, canonical_key, created_at, updated_at) VALUES (\'rss\', $1, NOW(), NOW()) RETURNING id::text',
    [`https://feeds.example/${runId}/${person.userId}.xml`],
  );
  const subscription = await db.query(
    'INSERT INTO external_subscriptions (user_id, external_source_id, state, created_at, updated_at) VALUES ($1, $2, \'active\', NOW(), NOW()) RETURNING id::text',
    [person.userId, source.rows[0].id],
  );
  const feed = { sourceId: source.rows[0].id, subscriptionId: subscription.rows[0].id };

  feeds.set(person.userId, feed);
  created.sourceIds.push(feed.sourceId);
  created.subscriptionIds.push(feed.subscriptionId);

  return feed;
};

const ensureRoute = async (person, home, listId) => {
  const feed = await ensureSubscription(person);
  const present = async (destination, routeListId) => {
    const found = await db.query(
      'SELECT 1 FROM external_feed_routes WHERE user_id = $1 AND external_subscription_id = $2 AND destination = $3 AND list_id IS NOT DISTINCT FROM $4::bigint',
      [person.userId, feed.subscriptionId, destination, routeListId],
    );

    return found.rows.length === 1;
  };

  if (home && !await present('home', null)) {
    await db.query(
      'INSERT INTO external_feed_routes (user_id, external_subscription_id, destination, list_id, created_at, updated_at) VALUES ($1, $2, \'home\', NULL, NOW(), NOW())',
      [person.userId, feed.subscriptionId],
    );
  }

  if (listId && !await present('list', listId)) {
    await db.query(
      'INSERT INTO external_feed_routes (user_id, external_subscription_id, destination, list_id, created_at, updated_at) VALUES ($1, $2, \'list\', $3, NOW(), NOW())',
      [person.userId, feed.subscriptionId, listId],
    );
  }

  return feed;
};

const seedContent = async (person, options) => {
  const feed = await ensureRoute(person, options.home === true, options.listId || null);
  const generation = options.generation || '1';
  const existing = await db.query(
    'SELECT id::text FROM external_status_projections WHERE status_id = $1::bigint',
    [options.statusId],
  );

  if (existing.rows.length === 1) {
    await db.query(
      'UPDATE external_status_projections SET content_generation = $2, source_deleted = FALSE WHERE status_id = $1::bigint',
      [options.statusId, generation],
    );

    return { projectionId: existing.rows[0].id, subscriptionId: feed.subscriptionId };
  }

  const resource = await db.query(
    'INSERT INTO external_resources (external_source_id, protocol, canonical_key, created_at, updated_at) VALUES ($1, \'rss\', $2, NOW(), NOW()) RETURNING id::text',
    [feed.sourceId, `feed:${feed.sourceId}\nitem:${options.statusId}`],
  );

  created.resourceIds.push(resource.rows[0].id);
  await db.query(
    'INSERT INTO statuses (id, text, created_at, updated_at, sensitive, visibility, spoiler_text, reply, local, account_id, searchability, external_projection) VALUES ($1, $2, NOW(), NOW(), FALSE, 201, \'\', FALSE, TRUE, $3, 200, TRUE)',
    [options.statusId, options.text, person.accountId],
  );
  created.statusIds.push(String(options.statusId));
  const projection = await db.query(
    'INSERT INTO external_status_projections (user_id, account_id, external_source_id, external_subscription_id, external_resource_id, status_id, source_deleted, content_generation, created_at, updated_at) VALUES ($1, $2, $3, $4, $5, $6, FALSE, $7, NOW(), NOW()) RETURNING id::text',
    [person.userId, person.accountId, feed.sourceId, feed.subscriptionId, resource.rows[0].id, options.statusId, generation],
  );

  return { projectionId: projection.rows[0].id, subscriptionId: feed.subscriptionId };
};

const publishContent = async (channel, person, statusId, content, options = {}) => {
  const seeded = await seedContent(person, {
    statusId: statusId,
    text: content,
    generation: options.generation || '1',
    home: options.home === true,
    listId: options.listId || null,
  });

  await publish(channel, options.event || 'update', Object.assign({
    id: String(statusId),
    content: content,
  }, options.extra || {}), {
    kind: 'content',
    user_id: person.userId,
    status_id: String(statusId),
    projection_id: seeded.projectionId,
    subscription_id: seeded.subscriptionId,
    generation: String(options.envelopeGeneration || options.generation || '1'),
  });

  return seeded;
};

const publishDelete = (channel, userId, statusId) => publish(channel, 'delete', String(statusId), {
  kind: 'delete',
  user_id: String(userId),
  status_id: String(statusId),
});

const deleteCreated = async () => {
  await db.query('BEGIN');

  try {
    await db.query('SELECT set_config(\'fedibird.projection_status_delete\', \'on\', true)');

    if (created.bookmarkIds.length > 0) {
      await db.query('DELETE FROM bookmarks WHERE id = ANY($1::bigint[])', [created.bookmarkIds]);
    }

    if (created.userIds.length > 0) {
      await db.query('DELETE FROM external_feed_routes WHERE user_id = ANY($1::bigint[])', [created.userIds]);
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

  if (created.settingIds.length > 0) {
    await db.query('DELETE FROM settings WHERE id = ANY($1::bigint[])', [created.settingIds]);
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

const controlPayload = (revision, targets, extra) => Object.assign({
  version: 1,
  reason: 'routes_updated',
  targets: targets,
  subscription_id: '7',
  feed_routes_revision: revision,
}, extra || {});

describe('external feed stream database guard', () => {
  const present = {
    EXTERNAL_FEED_STREAM_TEST_DB_NAME: 'external_feed_stream_test',
    EXTERNAL_FEED_STREAM_TEST_DB_USER: 'mastodon',
    EXTERNAL_FEED_STREAM_TEST_DB_PASSWORD: 'mastodon',
    EXTERNAL_FEED_STREAM_TEST_DB_HOST: 'localhost',
    EXTERNAL_FEED_STREAM_TEST_DB_PORT: '5432',
  };

  it('rejects a missing test database before changing data', () => {
    assert.throws(() => testDatabaseConfig({}), /Refusing to start without/);
  });

  it('rejects a database name that is not a dedicated test database', () => {
    ['mastodon_development', 'mastodon_production', 'postgres', 'production_test'].forEach(name => {
      assert.throws(() => testDatabaseConfig(Object.assign({}, present, {
        EXTERNAL_FEED_STREAM_TEST_DB_NAME: name,
      })), /Refusing database/);
    });
    assert.equal(testDatabaseConfig(present).database, 'external_feed_stream_test');
  });
});

describe('user and list external feed streaming', { concurrency: 1, timeout: 180000 }, () => {
  before(async () => {
    const dbConfig = testDatabaseConfig(process.env);
    const client = new Client(dbConfig);

    await client.connect();
    db = client;
    const current = await db.query('SELECT current_database() AS name');

    if (current.rows[0].name !== dbConfig.database) {
      throw new Error(`Connected to ${current.rows[0].name} instead of ${dbConfig.database}`);
    }

    world.owner = await createPerson('owner', 'read:statuses');
    world.roommate = await createPersonOn(world.owner.accountId, 'room', 'read:statuses');
    world.lists = await createPerson('lists', 'read:lists');
    world.notes = await createPerson('notes', 'read:notifications');
    world.expired = await createPerson('expired', 'read:statuses', {}, {}, {
      createdAt: new Date(Date.now() - (60 * 60 * 1000)),
      expiresIn: 60,
    });
    world.revoked = await createPerson('revoked', 'read:statuses', {}, {}, { revoked: true });
    world.suspended = await createPerson('suspended', 'read:statuses', { suspendedAt: new Date() });
    world.unconfirmed = await createPerson('unconfirmed', 'read:statuses', {}, { confirmed: false });
    world.outsider = await createPerson('outsider', 'read:statuses');
    world.huge = await createPerson('huge', 'read:statuses', {}, {}, {}, HUGE_USER_ID);
    world.listA = await insertList(world.owner.accountId, `A ${runId}`);
    world.listB = await insertList(world.owner.accountId, `B ${runId}`);
    world.hugeList = await insertList(world.owner.accountId, `H ${runId}`, HUGE_LIST_ID);
    world.testers = [
      world.owner.userId,
      world.roommate.userId,
      world.lists.userId,
      world.notes.userId,
      world.expired.userId,
      world.suspended.userId,
      world.unconfirmed.userId,
      world.huge.userId,
    ];
    await setFeeds(true, world.testers);

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

  it('merges a private update into the authenticated user SSE stream', async () => {
    const sse = await openSse('/api/v1/streaming/user', world.owner.token);

    try {
      await waitNumsub(homeChannel(world.owner.userId), 1);
      await waitNumsub(controlChannel(world.owner.userId), 1);
      await publishContent(homeChannel(world.owner.userId), world.owner, HUGE_STATUS_ID, `private-${runId}`, {
        home: true,
        extra: { _fedibird_searchable_text: `hidden-${runId}` },
      });
      await waitFor(() => sse.text().includes(`private-${runId}`), 8000, 'private sse update');
      const privateBlock = sse.text().split('\n\n').find(block => block.includes(`private-${runId}`));

      assert.equal(privateBlock.includes('event: update'), true);
      assert.equal(privateBlock.includes(`data: {"id":"${HUGE_STATUS_ID}"`), true);
      assert.equal(privateBlock.includes('_fedibird_searchable_text'), false);
      assert.equal(privateBlock.includes('projection_id'), false);
      assert.equal(privateBlock.includes('timeline:external'), false);
      await publish(accountChannel(world.owner.accountId), 'update', { id: '11', content: `ordinary-${runId}` });
      await waitFor(() => sse.text().includes(`ordinary-${runId}`), 8000, 'ordinary sse update');
    } finally {
      sse.close();
      await waitNumsub(homeChannel(world.owner.userId), 0);
    }
  });

  it('keeps the public websocket label and separates two users of one account', async () => {
    const owner = await connectSocket(world.owner.token);
    const roommate = await connectSocket(world.roommate.token);

    try {
      owner.send({ type: 'subscribe', stream: 'user', user_id: world.roommate.userId });
      roommate.send({ type: 'subscribe', stream: 'user' });
      await waitNumsub(homeChannel(world.owner.userId), 1);
      await waitNumsub(homeChannel(world.roommate.userId), 1);
      assert.equal(await numsub(homeChannel(world.huge.userId)), 0);
      await publishContent(homeChannel(world.owner.userId), world.owner, '21', `only-owner-${runId}`, { home: true });
      await waitFor(() => frames(owner).some(frame => JSON.stringify(frame).includes(`only-owner-${runId}`)), 8000, 'owner private frame');
      await new Promise(resolve => setTimeout(resolve, 250));
      const ownerFrame = frames(owner).find(frame => JSON.stringify(frame).includes(`only-owner-${runId}`));

      assert.deepEqual(ownerFrame.stream, ['user']);
      assert.equal(ownerFrame.event, 'update');
      assert.equal(JSON.parse(ownerFrame.payload).id, '21');
      assert.equal(JSON.stringify(ownerFrame).includes('projection_id'), false);
      assert.equal(frames(roommate).some(frame => JSON.stringify(frame).includes(`only-owner-${runId}`)), false);
      await publish(accountChannel(world.owner.accountId), 'update', { id: '22', content: `both-${runId}` });
      await waitFor(() => frames(owner).some(frame => JSON.stringify(frame).includes(`both-${runId}`)), 8000, 'owner ordinary');
      await waitFor(() => frames(roommate).some(frame => JSON.stringify(frame).includes(`both-${runId}`)), 8000, 'roommate ordinary');
    } finally {
      closeSocket(owner);
      closeSocket(roommate);
      await waitNumsub(homeChannel(world.owner.userId), 0);
      await waitNumsub(homeChannel(world.roommate.userId), 0);
    }
  });

  it('keeps a user id above 2^53 in the private channel name', async () => {
    const sse = await openSse('/api/v1/streaming/user', world.huge.token);

    try {
      await waitNumsub(homeChannel(HUGE_USER_ID), 1);
      assert.equal(await numsub(`${PREFIX}timeline:external:user:9007199254740992:home`), 0);
      await publishDelete(homeChannel(HUGE_USER_ID), HUGE_USER_ID, HUGE_USER_ID);
      await waitFor(() => sse.text().includes(`data: ${HUGE_USER_ID}`), 8000, 'huge delete');
      assert.equal(sse.text().includes(`data: "${HUGE_USER_ID}"`), false);
    } finally {
      sse.close();
      await waitNumsub(homeChannel(HUGE_USER_ID), 0);
    }
  });

  it('does not attach private channels to notification, direct, public, or read:lists', async () => {
    const notes = await openSse('/api/v1/streaming/user/notification', world.notes.token);
    const direct = await openSse('/api/v1/streaming/direct', world.owner.token);
    const pub = await openSse('/api/v1/streaming/public', world.owner.token);
    const denied = await readHttp(`/api/v1/streaming/list?list=${world.listA}`, world.lists.token);

    try {
      await waitNumsub(accountChannel(world.notes.accountId), 1);
      await new Promise(resolve => setTimeout(resolve, 400));
      assert.equal(await numsub(homeChannel(world.notes.userId)), 0);
      assert.equal(await numsub(homeChannel(world.owner.userId)), 0);
      assert.equal(await numsub(controlChannel(world.owner.userId)), 0);
      assert.equal(denied.status, 401);
      assert.equal(JSON.parse(denied.body).error, 'Error: Access token does not cover required scopes');
    } finally {
      notes.close();
      direct.close();
      pub.close();
    }
  });

  it('attaches a read:statuses list subscription and ignores a forged user id', async () => {
    const socket = await connectSocket(world.owner.token);

    try {
      socket.send({ type: 'subscribe', stream: 'list', list: world.listA, user_id: world.roommate.userId });
      await waitNumsub(listChannel(world.owner.userId, world.listA), 1);
      assert.equal(await numsub(listChannel(world.roommate.userId, world.listA)), 0);
      await publishContent(listChannel(world.owner.userId, world.listA), world.owner, '31', `list-a-${runId}`, { listId: world.listA });
      await waitFor(() => frames(socket).some(frame => JSON.stringify(frame).includes(`list-a-${runId}`)), 8000, 'list update');
      const frame = frames(socket).find(item => JSON.stringify(item).includes(`list-a-${runId}`));

      assert.deepEqual(frame.stream, ['list', world.listA]);
    } finally {
      closeSocket(socket);
      await waitNumsub(listChannel(world.owner.userId, world.listA), 0);
    }
  });

  it('refuses revoked tokens and does not attach private channels for expired, suspended, or unconfirmed users', async () => {
    const revoked = await readHttp('/api/v1/streaming/user', world.revoked.token);
    const expired = await openSse('/api/v1/streaming/user', world.expired.token);
    const suspended = await openSse('/api/v1/streaming/user', world.suspended.token);
    const unconfirmed = await openSse('/api/v1/streaming/user', world.unconfirmed.token);
    const outsider = await openSse('/api/v1/streaming/user', world.outsider.token);

    try {
      assert.equal(revoked.status, 401);
      await waitNumsub(accountChannel(world.expired.accountId), 1);
      await waitNumsub(accountChannel(world.suspended.accountId), 1);
      await waitNumsub(accountChannel(world.unconfirmed.accountId), 1);
      await waitNumsub(accountChannel(world.outsider.accountId), 1);
      await new Promise(resolve => setTimeout(resolve, 400));
      assert.equal(await numsub(homeChannel(world.expired.userId)), 0);
      assert.equal(await numsub(homeChannel(world.suspended.userId)), 0);
      assert.equal(await numsub(homeChannel(world.unconfirmed.userId)), 0);
      assert.equal(await numsub(homeChannel(world.outsider.userId)), 0);
    } finally {
      expired.close();
      suspended.close();
      unconfirmed.close();
      outsider.close();
    }
  });

  it('stops private events after the flag or allowlist changes and still delivers ordinary events', async () => {
    const socket = await connectSocket(world.owner.token);

    try {
      socket.send({ type: 'subscribe', stream: 'user' });
      await waitNumsub(homeChannel(world.owner.userId), 1);
      await setFeeds(false, world.testers);
      await publishContent(homeChannel(world.owner.userId), world.owner, '41', `flag-off-${runId}`, { home: true });
      await publish(accountChannel(world.owner.accountId), 'update', { id: '42', content: `flag-ordinary-${runId}` });
      await waitFor(() => frames(socket).some(frame => JSON.stringify(frame).includes(`flag-ordinary-${runId}`)), 8000, 'ordinary while flag off');
      await new Promise(resolve => setTimeout(resolve, 250));
      assert.equal(frames(socket).some(frame => JSON.stringify(frame).includes(`flag-off-${runId}`)), false);
      await setFeeds(true, [world.roommate.userId]);
      await publishContent(homeChannel(world.owner.userId), world.owner, '43', `allow-off-${runId}`, { home: true });
      await new Promise(resolve => setTimeout(resolve, 250));
      assert.equal(frames(socket).some(frame => JSON.stringify(frame).includes(`allow-off-${runId}`)), false);
    } finally {
      await setFeeds(true, world.testers);
      closeSocket(socket);
      await waitNumsub(homeChannel(world.owner.userId), 0);
    }
  });

  it('drops an authorize result that loses to unsubscribe, then accepts one replacement', async () => {
    const socket = await connectSocket(world.owner.token);

    try {
      await withHeldAuthorization(async release => {
        socket.send({ type: 'subscribe', stream: 'user' });
        await waitNumsub(accountChannel(world.owner.accountId), 1);
        assert.equal(await numsub(homeChannel(world.owner.userId)), 0);
        socket.send({ type: 'unsubscribe', stream: 'user' });
        await waitNumsub(accountChannel(world.owner.accountId), 0);
        await release();
      });
      await new Promise(resolve => setTimeout(resolve, 300));
      assert.equal(await numsub(homeChannel(world.owner.userId)), 0);

      await withHeldAuthorization(async release => {
        socket.send({ type: 'subscribe', stream: 'user' });
        await waitNumsub(accountChannel(world.owner.accountId), 1);
        socket.send({ type: 'unsubscribe', stream: 'user' });
        await waitNumsub(accountChannel(world.owner.accountId), 0);
        socket.send({ type: 'subscribe', stream: 'user' });
        await waitNumsub(accountChannel(world.owner.accountId), 1);
        await release();
      });
      await waitNumsub(homeChannel(world.owner.userId), 1);
      await publishContent(homeChannel(world.owner.userId), world.owner, '51', `once-${runId}`, { home: true });
      await waitFor(() => frames(socket).filter(frame => JSON.stringify(frame).includes(`once-${runId}`)).length === 1, 8000, 'one replacement event');
      await new Promise(resolve => setTimeout(resolve, 200));
      assert.equal(frames(socket).filter(frame => JSON.stringify(frame).includes(`once-${runId}`)).length, 1);
    } finally {
      closeSocket(socket);
      await waitNumsub(homeChannel(world.owner.userId), 0);
    }
  });

  it('removes private listeners when the websocket unsubscribes or the SSE request closes', async () => {
    const socket = await connectSocket(world.owner.token);

    socket.send({ type: 'subscribe', stream: 'list', list: world.listA });
    socket.send({ type: 'subscribe', stream: 'list', list: world.listB });
    await waitNumsub(listChannel(world.owner.userId, world.listA), 1);
    await waitNumsub(listChannel(world.owner.userId, world.listB), 1);
    socket.send({ type: 'subscribe', stream: 'list', list: world.listA });
    await publishContent(listChannel(world.owner.userId, world.listA), world.owner, '61', `dup-${runId}`, { listId: world.listA });
    await waitFor(() => frames(socket).filter(frame => JSON.stringify(frame).includes(`dup-${runId}`)).length === 1, 8000, 'duplicate subscribe');
    socket.send({ type: 'unsubscribe', stream: 'list', list: world.listA });
    await waitNumsub(listChannel(world.owner.userId, world.listA), 0);
    assert.equal(await numsub(listChannel(world.owner.userId, world.listB)), 1);
    closeSocket(socket);
    await waitNumsub(listChannel(world.owner.userId, world.listB), 0);
    await waitNumsub(controlChannel(world.owner.userId), 0);

    const sse = await openSse(`/api/v1/streaming/list?list=${HUGE_LIST_ID}`, world.owner.token);

    await waitNumsub(listChannel(world.owner.userId, HUGE_LIST_ID), 1);
    sse.close();
    await waitNumsub(listChannel(world.owner.userId, HUGE_LIST_ID), 0);
  });

  it('forwards external_feed_changed only to the matching view and strips the body', async () => {
    const userSocket = await connectSocket(world.owner.token);
    const listSocket = await connectSocket(world.owner.token);

    try {
      userSocket.send({ type: 'subscribe', stream: 'user' });
      listSocket.send({ type: 'subscribe', stream: 'list', list: world.listA });
      await waitNumsub(controlChannel(world.owner.userId), 1);
      await publish(controlChannel(world.owner.userId), 'external_feed_changed', controlPayload('2', [
        { type: 'home' },
        { type: 'list', id: world.listA },
      ], { content: SECRET, url: 'https://secret.example/post' }));
      await waitFor(() => frames(userSocket).some(frame => frame.event === 'external_feed_changed'), 8000, 'user control');
      await waitFor(() => frames(listSocket).some(frame => frame.event === 'external_feed_changed'), 8000, 'list control');
      const userPayload = JSON.parse(frames(userSocket).find(frame => frame.event === 'external_feed_changed').payload);
      const listPayload = JSON.parse(frames(listSocket).find(frame => frame.event === 'external_feed_changed').payload);

      assert.equal(userPayload.content, undefined);
      assert.equal(userPayload.url, undefined);
      assert.equal(userPayload.reason, 'routes_updated');
      assert.equal(listPayload.subscription_id, '7');
      assert.equal(serverLog.includes(SECRET), false);
      assert.equal(serverLog.includes(world.owner.token), false);
      await publish(controlChannel(world.owner.userId), 'external_feed_changed', controlPayload('1', [{ type: 'home' }]));
      await new Promise(resolve => setTimeout(resolve, 250));
      assert.equal(frames(userSocket).filter(frame => frame.event === 'external_feed_changed').length, 1);
      await publish(controlChannel(world.owner.userId), 'external_feed_changed', controlPayload('2', [{ type: 'list', id: world.listB }]));
      await new Promise(resolve => setTimeout(resolve, 250));
      assert.equal(frames(listSocket).filter(frame => frame.event === 'external_feed_changed').length, 1);
    } finally {
      closeSocket(userSocket);
      closeSocket(listSocket);
      await waitNumsub(controlChannel(world.owner.userId), 0);
    }
  });

  it('drops a numeric delete and stops forwarding after the list row is gone', async () => {
    const socket = await connectSocket(world.owner.token);

    try {
      socket.send({ type: 'subscribe', stream: 'list', list: world.listB });
      await waitNumsub(listChannel(world.owner.userId, world.listB), 1);
      await publish(listChannel(world.owner.userId, world.listB), 'delete', 5);
      await publishDelete(listChannel(world.owner.userId, world.listB), world.owner.userId, HUGE_LIST_ID);
      await waitFor(() => frames(socket).some(frame => frame.event === 'delete' && frame.payload === HUGE_LIST_ID), 8000, 'string delete');
      assert.equal(frames(socket).some(frame => frame.payload === 5 || frame.payload === '5'), false);
      await db.query('DELETE FROM lists WHERE id = $1', [world.listB]);
      created.listIds = created.listIds.filter(id => id !== world.listB);
      await publish(listChannel(world.owner.userId, world.listB), 'update', { id: '71', content: `gone-list-${runId}` }, {
        kind: 'content',
        user_id: world.owner.userId,
        status_id: '71',
        projection_id: '71',
        subscription_id: '71',
        generation: '1',
      });
      await new Promise(resolve => setTimeout(resolve, 300));
      assert.equal(frames(socket).some(frame => JSON.stringify(frame).includes(`gone-list-${runId}`)), false);
    } finally {
      closeSocket(socket);
      await waitNumsub(listChannel(world.owner.userId, world.listB), 0);
    }
  });

  it('drops a stale generation and does not restore a status after delete', async () => {
    const statusId = '81';
    const seeded = await seedContent(world.owner, {
      statusId: statusId,
      text: `current-${runId}`,
      generation: '2',
      home: true,
    });
    const channel = homeChannel(world.owner.userId);
    const delivery = generation => ({
      kind: 'content',
      user_id: world.owner.userId,
      status_id: statusId,
      projection_id: seeded.projectionId,
      subscription_id: seeded.subscriptionId,
      generation: generation,
    });
    const publishPair = async label => {
      await publish(channel, 'status.update', { id: statusId, content: `stale-${runId}` }, delivery('1'));
      await publish(channel, 'status.update', { id: statusId, content: `current-${runId}-${label}` }, delivery('2'));
    };

    const ws = await connectSocket(world.owner.token);

    try {
      ws.send({ type: 'subscribe', stream: 'user' });
      await waitNumsub(channel, 1);
      await publishPair('ws');
      await waitFor(() => frames(ws).some(frame => JSON.stringify(frame).includes(`current-${runId}-ws`)), 8000, 'current websocket body');
      await new Promise(resolve => setTimeout(resolve, 300));
      assert.equal(frames(ws).some(frame => JSON.stringify(frame).includes(`stale-${runId}`)), false);
      assert.equal(JSON.stringify(frames(ws)).includes('projection_id'), false);
    } finally {
      closeSocket(ws);
      await waitNumsub(channel, 0);
    }

    const sse = await openSse('/api/v1/streaming/user', world.owner.token);

    try {
      await waitNumsub(channel, 1);
      await publishPair('sse');
      await waitFor(() => sse.text().includes(`current-${runId}-sse`), 8000, 'current sse body');
      await new Promise(resolve => setTimeout(resolve, 300));
      assert.equal(sse.text().includes(`stale-${runId}`), false);
      assert.equal(sse.text().includes('projection_id'), false);
    } finally {
      sse.close();
      await waitNumsub(channel, 0);
    }

    await db.query('BEGIN');
    await db.query('SELECT set_config(\'fedibird.projection_status_delete\', \'on\', true)');
    await db.query('DELETE FROM statuses WHERE id = $1::bigint', [statusId]);
    await db.query('COMMIT');
    created.statusIds = created.statusIds.filter(id => id !== statusId);

    const deleted = await connectSocket(world.owner.token);

    try {
      deleted.send({ type: 'subscribe', stream: 'user' });
      await waitNumsub(channel, 1);
      await publishDelete(channel, world.owner.userId, statusId);
      await publish(channel, 'update', { id: statusId, content: `resurrect-${runId}` }, delivery('2'));
      await waitFor(() => frames(deleted).some(frame => frame.event === 'delete' && frame.payload === statusId), 8000, 'websocket delete');
      await new Promise(resolve => setTimeout(resolve, 300));
      assert.equal(frames(deleted).some(frame => JSON.stringify(frame).includes(`resurrect-${runId}`)), false);
    } finally {
      closeSocket(deleted);
      await waitNumsub(channel, 0);
    }

    const deletedSse = await openSse('/api/v1/streaming/user', world.owner.token);

    try {
      await waitNumsub(channel, 1);
      await publishDelete(channel, world.owner.userId, statusId);
      await publish(channel, 'update', { id: statusId, content: `resurrect-${runId}` }, delivery('2'));
      await waitFor(() => deletedSse.text().includes(`data: ${statusId}`), 8000, 'sse delete');
      await new Promise(resolve => setTimeout(resolve, 300));
      assert.equal(deletedSse.text().includes(`resurrect-${runId}`), false);
    } finally {
      deletedSse.close();
      await waitNumsub(channel, 0);
    }
  });

  it('delivers list_removed to the owner user and list sockets only', async () => {
    const listId = await insertList(world.owner.accountId, `C ${runId}`);
    const statusId = '91';
    const seeded = await seedContent(world.owner, {
      statusId: statusId,
      text: `kept-${runId}`,
      generation: '1',
      home: true,
      listId: listId,
    });
    const bookmark = await db.query(
      'INSERT INTO bookmarks (account_id, status_id, created_at, updated_at) VALUES ($1, $2, NOW(), NOW()) RETURNING id::text',
      [world.owner.accountId, statusId],
    );

    created.bookmarkIds.push(bookmark.rows[0].id);
    const userSocket = await connectSocket(world.owner.token);
    const listSocket = await connectSocket(world.owner.token);
    const otherList = await connectSocket(world.owner.token);
    const roommate = await connectSocket(world.roommate.token);
    const listSse = await openSse(`/api/v1/streaming/list?list=${listId}`, world.owner.token);
    const control = controlChannel(world.owner.userId);

    try {
      listSocket.send({ type: 'subscribe', stream: 'list', list: listId });
      await waitNumsub(listChannel(world.owner.userId, listId), 1);
      otherList.send({ type: 'subscribe', stream: 'list', list: world.listA });
      await waitNumsub(listChannel(world.owner.userId, world.listA), 1);
      userSocket.send({ type: 'subscribe', stream: 'user' });
      await waitNumsub(homeChannel(world.owner.userId), 1);
      roommate.send({ type: 'subscribe', stream: 'user' });
      await waitNumsub(homeChannel(world.roommate.userId), 1);
      await publish(control, 'external_feed_changed', controlPayload('1', [{ type: 'list', id: listId }], { subscription_id: seeded.subscriptionId }));
      await waitFor(() => frames(listSocket).some(frame => frame.event === 'external_feed_changed'), 8000, 'list socket attached');
      await waitFor(() => listSse.text().includes('routes_updated'), 8000, 'list sse attached');
      await publish(control, 'external_feed_changed', controlPayload('2', [{ type: 'home' }, { type: 'list', id: world.listA }], { subscription_id: seeded.subscriptionId }));
      await waitFor(() => frames(userSocket).some(frame => frame.event === 'external_feed_changed'), 8000, 'user socket attached');
      await waitFor(() => frames(otherList).some(frame => frame.event === 'external_feed_changed'), 8000, 'other list attached');
      await db.query('DELETE FROM lists WHERE id = $1::bigint', [listId]);
      created.listIds = created.listIds.filter(id => id !== listId);
      await publish(control, 'external_feed_changed', {
        version: 1,
        reason: 'list_removed',
        targets: [{ type: 'list', id: listId }],
        subscription_id: seeded.subscriptionId,
        feed_routes_revision: '3',
      });
      await waitFor(() => frames(userSocket).some(frame => JSON.stringify(frame).includes('list_removed')), 8000, 'user list_removed');
      await waitFor(() => frames(listSocket).some(frame => JSON.stringify(frame).includes('list_removed')), 8000, 'list list_removed');
      await waitFor(() => listSse.text().includes('list_removed'), 8000, 'sse list_removed');
      await new Promise(resolve => setTimeout(resolve, 300));
      const userPayload = JSON.parse(frames(userSocket).find(frame => JSON.stringify(frame).includes('list_removed')).payload);
      const listPayload = JSON.parse(frames(listSocket).find(frame => JSON.stringify(frame).includes('list_removed')).payload);

      assert.equal(userPayload.reason, 'list_removed');
      assert.equal(listPayload.reason, 'list_removed');
      assert.equal(JSON.stringify(userPayload).includes('kept-'), false);
      assert.equal(frames(otherList).some(frame => JSON.stringify(frame).includes('list_removed')), false);
      assert.equal(frames(roommate).some(frame => frame.event === 'external_feed_changed'), false);
      await publish(listChannel(world.owner.userId, listId), 'update', { id: statusId, content: `after-list-${runId}` }, {
        kind: 'content',
        user_id: world.owner.userId,
        status_id: statusId,
        projection_id: seeded.projectionId,
        subscription_id: seeded.subscriptionId,
        generation: '1',
      });
      await new Promise(resolve => setTimeout(resolve, 300));
      assert.equal(frames(listSocket).some(frame => JSON.stringify(frame).includes(`after-list-${runId}`)), false);
      assert.equal(listSse.text().includes(`after-list-${runId}`), false);
      const status = await db.query('SELECT id::text FROM statuses WHERE id = $1::bigint', [statusId]);
      const kept = await db.query('SELECT id::text FROM bookmarks WHERE id = $1::bigint', [bookmark.rows[0].id]);

      assert.equal(status.rows.length, 1);
      assert.equal(kept.rows.length, 1);
    } finally {
      closeSocket(userSocket);
      closeSocket(listSocket);
      closeSocket(otherList);
      closeSocket(roommate);
      listSse.close();
      await waitNumsub(controlChannel(world.owner.userId), 0);
      await waitNumsub(controlChannel(world.roommate.userId), 0);
    }
  });
});
