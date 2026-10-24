const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const boost = require('./external_boost');

const HUGE_USER = '9007199254740993';
const HUGE_STATUS = '9007199254740995';
const HUGE_REVISION = '9007199254740997';

const allowedRow = (overrides = {}) => Object.assign({
  user_id: '17',
  user_account_id: '9',
  revoked_at: null,
  expires_in: null,
  created_at: new Date(),
  confirmed_at: new Date(),
  approved: true,
  disabled: false,
  suspended_at: null,
  memorial: false,
  moved_to_account_id: null,
}, overrides);

const request = (overrides = {}) => {
  const handlers = {};

  return Object.assign({
    userId: '17',
    accessTokenId: '4',
    accountId: '9',
    on: (name, handler) => {
      handlers[name] = handler;
    },
    emit: name => handlers[name] && handlers[name](),
  }, overrides);
};

const frame = (statusId, revision, reblogged, userId = '17', extra = {}) => JSON.stringify(Object.assign({
  event: 'external_link_boost_changed',
  payload: { version: 1, status_id: statusId, reblogged: reblogged, revision: revision },
  queued_at: Date.now(),
  delivery: { kind: 'boost', user_id: userId, status_id: statusId, revision: revision },
}, extra));

const tick = () => new Promise(resolve => setImmediate(resolve));
const settle = async () => {
  for (let index = 0; index < 20; index += 1) {
    // eslint-disable-next-line no-await-in-loop
    await tick();
  }
};

/**
 * A fake world: `state` maps status id to { revision, reblogged }, `account`
 * is the row ACCOUNT_SQL returns. Every query is recorded.
 */
const harness = (options = {}) => {
  const world = {
    account: Object.prototype.hasOwnProperty.call(options, 'account') ? options.account : allowedRow(),
    state: options.state || new Map(),
    queries: [],
    gate: null,
    written: [],
    subscribed: [],
    unsubscribed: [],
    listeners: new Map(),
  };
  const query = (sql, params, queryOptions) => {
    world.queries.push({ sql: sql, params: params, options: queryOptions });
    const run = () => {
      if (sql.includes('FROM oauth_access_tokens')) {
        return { rows: world.account ? [world.account] : [] };
      }

      const row = world.state.get(params[1]);

      return { rows: row ? [row] : [] };
    };

    if (world.gate && !sql.includes('FROM oauth_access_tokens')) {
      return world.gate.then(run);
    }

    return Promise.resolve(run());
  };
  const subscribe = (channel, listener) => {
    world.subscribed.push(channel);
    world.listeners.set(channel, listener);
  };
  const unsubscribe = (channel, listener) => {
    world.unsubscribed.push(channel);

    if (world.listeners.get(channel) === listener) {
      world.listeners.delete(channel);
    }
  };
  const output = (event, payload) => {
    world.written.push({ event: event, payload: JSON.parse(payload), raw: payload });
  };

  world.attach = (req, externalFeed = { kind: 'user' }, listener = () => {}) => {
    boost.attachExternalBoost({
      listener: listener,
      req: req,
      externalFeed: externalFeed,
      query: query,
      redisPrefix: 'ns:',
      subscribe: subscribe,
      unsubscribe: unsubscribe,
      output: output,
    });

    return listener;
  };
  world.detach = listener => boost.detachExternalBoost(listener, { unsubscribe: unsubscribe });
  world.send = (message, userId = '17') => {
    const channel = `ns:${boost.boostChannelName(userId)}`;
    const listener = world.listeners.get(channel);

    assert.ok(listener, `no listener on ${channel}`);
    listener(message);
  };

  return world;
};

describe('external boost channel and frames', () => {
  it('builds the owner channel only from a decimal id', () => {
    assert.equal(boost.boostChannelName('17'), 'timeline:external:user:17:boost');
    assert.equal(boost.boostChannelName(HUGE_USER), `timeline:external:user:${HUGE_USER}:boost`);
    assert.equal(boost.boostChannelName('01'), null);
    assert.equal(boost.boostChannelName('1.5'), null);
    assert.equal(boost.boostChannelName(''), null);
  });

  it('accepts a minimal frame whose payload and delivery agree', () => {
    const json = JSON.parse(frame(HUGE_STATUS, HUGE_REVISION, true, HUGE_USER));

    assert.deepEqual(boost.prepareBoostEvent(json, HUGE_USER), { statusId: HUGE_STATUS, revision: HUGE_REVISION });
  });

  it('rejects a frame for another user, a wrong event, or a disagreeing envelope', () => {
    const good = JSON.parse(frame('5', '2', true));

    assert.ok(boost.prepareBoostEvent(good, '17'));
    assert.equal(boost.prepareBoostEvent(good, '18'), null);
    assert.equal(boost.prepareBoostEvent(Object.assign({}, good, { event: 'update' }), '17'), null);
    assert.equal(boost.prepareBoostEvent(Object.assign({}, good, { delivery: undefined }), '17'), null);
    assert.equal(boost.prepareBoostEvent(Object.assign({}, good, { delivery: Object.assign({}, good.delivery, { status_id: '6' }) }), '17'), null);
    assert.equal(boost.prepareBoostEvent(Object.assign({}, good, { delivery: Object.assign({}, good.delivery, { revision: '3' }) }), '17'), null);
    assert.equal(boost.prepareBoostEvent(Object.assign({}, good, { delivery: Object.assign({}, good.delivery, { kind: 'content' }) }), '17'), null);
    assert.equal(boost.prepareBoostEvent(Object.assign({}, good, { payload: Object.assign({}, good.payload, { status_id: 5 }) }), '17'), null);
    assert.equal(boost.prepareBoostEvent(Object.assign({}, good, { payload: Object.assign({}, good.payload, { revision: 2 }) }), '17'), null);
    assert.equal(boost.prepareBoostEvent(Object.assign({}, good, { payload: Object.assign({}, good.payload, { reblogged: 'true' }) }), '17'), null);
    assert.equal(boost.prepareBoostEvent(Object.assign({}, good, { payload: Object.assign({}, good.payload, { version: 2 }) }), '17'), null);
    assert.equal(boost.prepareBoostEvent(Object.assign({}, good, { payload: Object.assign({}, good.payload, { status_id: '05' }) }), '17'), null);
  });

  it('does not read the E3 or E4 flags and accepts a functional user only', () => {
    const req = request();

    assert.equal(boost.accountRowAllowed(allowedRow(), req), true);
    assert.equal(boost.accountRowAllowed(allowedRow({ user_id: '42' }), req), false);
    assert.equal(boost.accountRowAllowed(allowedRow({ user_account_id: '8' }), req), false);
    assert.equal(boost.accountRowAllowed(allowedRow({ revoked_at: new Date() }), req), false);
    assert.equal(boost.accountRowAllowed(allowedRow({ created_at: new Date(Date.now() - 120000), expires_in: 60 }), req), false);
    assert.equal(boost.accountRowAllowed(allowedRow({ confirmed_at: null }), req), false);
    assert.equal(boost.accountRowAllowed(allowedRow({ approved: false }), req), false);
    assert.equal(boost.accountRowAllowed(allowedRow({ disabled: true }), req), false);
    assert.equal(boost.accountRowAllowed(allowedRow({ suspended_at: new Date() }), req), false);
    assert.equal(boost.accountRowAllowed(allowedRow({ memorial: true }), req), false);
    assert.equal(boost.accountRowAllowed(allowedRow({ moved_to_account_id: '3' }), req), false);
    // feeds_enabled and feeds_testers absent: this channel does not look at them.
    assert.equal(Object.prototype.hasOwnProperty.call(allowedRow(), 'feeds_enabled'), false);
  });

  it('fails closed when the database rejects', async () => {
    const allowed = await boost.authorizeBoostDelivery(() => Promise.reject(new Error('down')), request());

    assert.equal(allowed, false);
  });
});

describe('external boost ticket', () => {
  it('subscribes the owner channel only for user and list connections, and only after authorization', async () => {
    const world = harness();

    world.attach(request(), { kind: 'user' });
    assert.deepEqual(world.subscribed, []);
    await settle();
    assert.deepEqual(world.subscribed, ['ns:timeline:external:user:17:boost']);

    const listWorld = harness();

    listWorld.attach(request(), { kind: 'list', listId: '5' });
    await settle();
    assert.deepEqual(listWorld.subscribed, ['ns:timeline:external:user:17:boost']);

    const other = harness();

    other.attach(request(), { kind: 'public' });
    other.attach(request(), null);
    await settle();
    assert.deepEqual(other.subscribed, []);
    assert.equal(other.queries.length, 0);
  });

  it('does not subscribe a user who is not allowed, and does not need a feed route or a flag', async () => {
    for (const account of [null, allowedRow({ revoked_at: new Date() }), allowedRow({ disabled: true }), allowedRow({ user_id: '99' })]) {
      const world = harness({ account: account });

      world.attach(request());
      // eslint-disable-next-line no-await-in-loop
      await settle();
      assert.deepEqual(world.subscribed, [], JSON.stringify(account));
    }

    const world = harness();

    world.attach(request());
    await settle();
    assert.equal(world.subscribed.length, 1);
    assert.equal(world.queries.some(item => /external_feed_routes|settings/.test(item.sql)), false);
  });

  it('writes the database pair, not the frame, and strips everything else', async () => {
    const world = harness({ account: allowedRow({ user_id: HUGE_USER }), state: new Map([[HUGE_STATUS, { revision: HUGE_REVISION, reblogged: true }]]) });

    world.attach(request({ userId: HUGE_USER }));
    await settle();
    world.send(frame(HUGE_STATUS, '3', false, HUGE_USER, { secret: 'SECRET_BODY', payload_extra: 1 }), HUGE_USER);
    await settle();

    assert.deepEqual(world.written, [{
      event: 'external_link_boost_changed',
      payload: { version: 1, status_id: HUGE_STATUS, reblogged: true, revision: HUGE_REVISION },
      raw: JSON.stringify({ version: 1, status_id: HUGE_STATUS, reblogged: true, revision: HUGE_REVISION }),
    }]);
    assert.equal(world.written[0].raw.includes('SECRET_BODY'), false);
  });

  it('writes nothing for a projection the user has no marker or state row for', async () => {
    const world = harness();

    world.attach(request());
    await settle();
    world.send(frame('5', '1', true));
    await settle();

    assert.deepEqual(world.written, []);
    assert.ok(world.queries.some(item => /external_status_projections/.test(item.sql) && item.params[0] === '17'));
  });

  it('never writes an older revision after a newer one and drops a repeated one', async () => {
    const world = harness({ state: new Map([['5', { revision: '3', reblogged: true }]]) });

    world.attach(request());
    await settle();
    world.send(frame('5', '3', true));
    await settle();
    world.state.set('5', { revision: '2', reblogged: false });
    world.send(frame('5', '2', false));
    await settle();
    world.send(frame('5', '3', true));
    await settle();
    world.state.set('5', { revision: '4', reblogged: false });
    world.send(frame('5', '4', false));
    await settle();

    assert.deepEqual(world.written.map(item => [item.payload.revision, item.payload.reblogged]), [['3', true], ['4', false]]);
  });

  it('compares revisions as decimal strings past 2^53', async () => {
    const world = harness({ state: new Map([['5', { revision: '9007199254740993', reblogged: true }]]) });

    world.attach(request());
    await settle();
    world.send(frame('5', '9007199254740993', true));
    await settle();
    world.state.set('5', { revision: '9007199254740992', reblogged: false });
    world.send(frame('5', '9007199254740992', false));
    await settle();
    world.state.set('5', { revision: '9007199254740994', reblogged: false });
    world.send(frame('5', '9007199254740994', false));
    await settle();

    assert.deepEqual(world.written.map(item => item.payload.revision), ['9007199254740993', '9007199254740994']);
  });

  it('reads again for a frame that arrives while an earlier one is being read', async () => {
    const world = harness({ state: new Map([['5', { revision: '1', reblogged: true }]]) });
    let release;

    world.attach(request());
    await settle();
    world.gate = new Promise(resolve => {
      release = resolve;
    });
    world.send(frame('5', '1', true));
    await settle();
    world.state.set('5', { revision: '2', reblogged: false });
    world.send(frame('5', '2', false));
    world.send(frame('5', '2', false));
    release();
    world.gate = null;
    await settle();

    assert.deepEqual(world.written.map(item => [item.payload.revision, item.payload.reblogged]), [['2', false]]);
  });

  it('coalesces waiting frames for one status and bounds the queue', async () => {
    const state = new Map();

    for (let index = 1; index <= 200; index += 1) {
      state.set(String(index), { revision: '1', reblogged: true });
    }

    const world = harness({ state: state });
    let release;

    world.attach(request());
    await settle();
    world.gate = new Promise(resolve => {
      release = resolve;
    });

    for (let index = 1; index <= 200; index += 1) {
      world.send(frame(String(index), '1', true));
      world.send(frame(String(index), '1', true));
    }

    release();
    world.gate = null;
    await settle();
    await settle();

    // The frame being read is not coalesced, so its repeat is read once more
    // and dropped by the watermark. The queue never exceeds the limit.
    assert.ok(world.written.length <= boost.BOOST_PENDING_LIMIT);
    assert.ok(world.written.length >= boost.BOOST_PENDING_LIMIT - 1);
    assert.equal(new Set(world.written.map(item => item.payload.status_id)).size, world.written.length);
  });

  it('ignores frames for another user, malformed JSON, and other events', async () => {
    const world = harness({ state: new Map([['5', { revision: '1', reblogged: true }]]) });

    world.attach(request());
    await settle();
    world.send(frame('5', '1', true, '18'));
    world.send('not json');
    world.send(JSON.stringify({ event: 'update', payload: { id: '5' } }));
    world.send(JSON.stringify({ event: 'external_feed_changed', payload: {} }));
    await settle();

    assert.deepEqual(world.written, []);
  });

  it('stops on close: no write after, unsubscribed once, and a late read is dropped', async () => {
    const world = harness({ state: new Map([['5', { revision: '1', reblogged: true }]]) });
    const req = request();
    let release;

    world.attach(req);
    await settle();
    world.gate = new Promise(resolve => {
      release = resolve;
    });
    world.send(frame('5', '1', true));
    await settle();
    req.emit('close');
    release();
    world.gate = null;
    await settle();

    assert.deepEqual(world.written, []);
    assert.deepEqual(world.unsubscribed, ['ns:timeline:external:user:17:boost']);
    assert.equal(world.listeners.size, 0);
  });

  it('stops on unsubscribe of the connection listener, and a replaced ticket does not double subscribe', async () => {
    const world = harness({ state: new Map([['5', { revision: '1', reblogged: true }]]) });
    const listener = world.attach(request());

    await settle();
    world.attach(request(), { kind: 'user' }, listener);
    await settle();
    assert.equal(world.listeners.size, 1);
    world.detach(listener);
    world.detach(listener);

    assert.equal(world.listeners.size, 0);
    assert.equal(world.unsubscribed.length, 2);
  });

  it('drops a late authorize result after the connection closed', async () => {
    let release;
    const gate = new Promise(resolve => {
      release = resolve;
    });
    const subscribed = [];
    const req = request();

    boost.attachExternalBoost({
      listener: () => {},
      req: req,
      externalFeed: { kind: 'user' },
      query: () => gate.then(() => ({ rows: [allowedRow()] })),
      redisPrefix: '',
      subscribe: channel => subscribed.push(channel),
      unsubscribe: () => {},
      output: () => {},
    });
    req.emit('close');
    release();
    await settle();

    assert.deepEqual(subscribed, []);
  });

  it('re-checks the account for every frame, so a revoked token stops delivery without a reconnect', async () => {
    const world = harness({ state: new Map([['5', { revision: '1', reblogged: true }]]) });

    world.attach(request());
    await settle();
    world.send(frame('5', '1', true));
    await settle();
    world.account = allowedRow({ revoked_at: new Date() });
    world.state.set('5', { revision: '2', reblogged: false });
    world.send(frame('5', '2', false));
    await settle();
    world.account = allowedRow({ disabled: true });
    world.send(frame('5', '2', false));
    await settle();

    assert.deepEqual(world.written.map(item => item.payload.revision), ['1']);
  });

  it('gives each query the ticket signal and a read timeout', async () => {
    const world = harness({ state: new Map([['5', { revision: '1', reblogged: true }]]) });

    world.attach(request());
    await settle();
    world.send(frame('5', '1', true));
    await settle();

    assert.ok(world.queries.length >= 3);
    world.queries.forEach(item => {
      assert.equal(item.options.timeoutMs, boost.BOOST_CONFIRM_MS);
      assert.ok(item.options.signal);
    });
  });

  it('keeps the state query owner-scoped by user id and marker', () => {
    const world = harness();

    world.attach(request());

    return settle().then(() => {
      world.send(frame('5', '1', true));

      return settle();
    }).then(() => {
      const stateQuery = world.queries.find(item => /external_projection_link_boost_states/.test(item.sql));

      assert.ok(stateQuery);
      assert.match(stateQuery.sql, /states\.user_id = \$1::bigint/);
      assert.match(stateQuery.sql, /markers\.user_id = states\.user_id/);
      assert.deepEqual(stateQuery.params, ['17', '5']);
    });
  });
});
