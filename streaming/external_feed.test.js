const { describe, it } = require('node:test');
const assert = require('node:assert/strict');
const externalFeed = require('./external_feed');

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
  feeds_enabled: '--- true\n',
  feeds_testers: '--- \'17,42\'\n',
}, overrides);

const request = (overrides = {}) => Object.assign({
  userId: '17',
  accessTokenId: '4',
  accountId: '9',
  on: () => {},
}, overrides);

const ticketFor = (kind, listId = null) => ({
  active: true,
  channels: [],
  revisions: new Map(),
  kind: kind,
  listId: listId,
  listener: null,
});

describe('external feed channel names and settings', () => {
  it('compares decimal ids without rounding past 2^53', () => {
    assert.equal(externalFeed.compareDecimal('9007199254740993', '9007199254740992'), 1);
    assert.equal(externalFeed.compareDecimal('9007199254740993', '9007199254740993'), 0);
    assert.equal(externalFeed.compareDecimal('01', '1'), 0);
    assert.equal(externalFeed.compareDecimal('9', '10'), -1);
  });

  it('reads the settings scalars and does not treat one id as a substring of another', () => {
    assert.equal(externalFeed.flagEnabled('--- true\n'), true);
    assert.equal(externalFeed.flagEnabled('--- \'true\'\n'), true);
    assert.equal(externalFeed.flagEnabled('--- false\n'), false);
    assert.equal(externalFeed.flagEnabled('--- trueish\n'), false);
    assert.equal(externalFeed.testerListed('--- \'1,12\'\n', '1'), true);
    assert.equal(externalFeed.testerListed('--- \'12\'\n', '1'), false);
    assert.equal(externalFeed.testerListed('--- \'17,42\'\n', '9007199254740993'), false);
    assert.equal(externalFeed.testerListed('--- \'9007199254740993\'\n', '9007199254740993'), true);
  });

  it('builds private channels only from decimal ids', () => {
    assert.deepEqual(externalFeed.channelNames('9007199254740993', 'user', null), [
      'timeline:external:user:9007199254740993:home',
      'timeline:external:user:9007199254740993:control',
    ]);
    assert.deepEqual(externalFeed.channelNames('17', 'list', '9007199254740993'), [
      'timeline:external:user:17:list:9007199254740993',
      'timeline:external:user:17:control',
    ]);
    assert.deepEqual(externalFeed.channelNames('01', 'user', null), []);
    assert.deepEqual(externalFeed.channelNames('17', 'list', '1.2'), []);
    assert.deepEqual(externalFeed.channelNames('17', 'public', null), []);
  });
});

describe('external feed authorization and payloads', () => {
  it('accepts a functional allowlisted user and rejects the neighbouring cases', () => {
    const req = request();

    assert.equal(externalFeed.accountRowAllowed(allowedRow(), req), true);
    assert.equal(externalFeed.accountRowAllowed(allowedRow({ user_id: '42' }), req), false);
    assert.equal(externalFeed.accountRowAllowed(allowedRow({ user_account_id: '8' }), req), false);
    assert.equal(externalFeed.accountRowAllowed(allowedRow({ revoked_at: new Date() }), req), false);
    assert.equal(externalFeed.accountRowAllowed(allowedRow({
      created_at: new Date(Date.now() - 120000),
      expires_in: 60,
    }), req), false);
    assert.equal(externalFeed.accountRowAllowed(allowedRow({ confirmed_at: null }), req), false);
    assert.equal(externalFeed.accountRowAllowed(allowedRow({ approved: false }), req), false);
    assert.equal(externalFeed.accountRowAllowed(allowedRow({ disabled: true }), req), false);
    assert.equal(externalFeed.accountRowAllowed(allowedRow({ suspended_at: new Date() }), req), false);
    assert.equal(externalFeed.accountRowAllowed(allowedRow({ memorial: true }), req), false);
    assert.equal(externalFeed.accountRowAllowed(allowedRow({ moved_to_account_id: '3' }), req), false);
    assert.equal(externalFeed.accountRowAllowed(allowedRow({ feeds_enabled: '--- false\n' }), req), false);
    assert.equal(externalFeed.accountRowAllowed(allowedRow({ feeds_testers: '--- \'42\'\n' }), req), false);
  });

  it('fails closed when the database query rejects', async () => {
    const result = await externalFeed.authorizeExternalDelivery(
      () => Promise.reject(new Error('connection refused')),
      request(),
      { kind: 'user', listId: null },
    );

    assert.equal(result, false);
  });

  it('requires the list row to belong to the token account', async () => {
    const queries = [];
    const query = (sql, params) => {
      queries.push({ sql: sql, params: params });

      if (sql.includes('FROM lists')) {
        return Promise.resolve({ rows: [] });
      }

      return Promise.resolve({ rows: [allowedRow()] });
    };
    const result = await externalFeed.authorizeExternalDelivery(query, request(), { kind: 'list', listId: '55' });

    assert.equal(result, false);
    assert.equal(queries[1].params[0], '55');
    assert.equal(queries[1].params[1], '9');
    assert.equal(queries[0].sql.includes('$1'), true);
  });

  it('drops unknown control fields, non-string ids, and events for another view', () => {
    const clean = externalFeed.sanitizeControl({
      version: 1,
      reason: 'routes_updated',
      targets: [{ type: 'home' }, { type: 'list', id: '55' }],
      subscription_id: '7',
      feed_routes_revision: '3',
      content: 'secret body',
      url: 'https://secret.example/post',
      token: 'bearer-secret',
    }, 'user', null);

    assert.deepEqual(Object.keys(clean), ['version', 'reason', 'targets', 'subscription_id', 'feed_routes_revision']);
    assert.equal(JSON.stringify(clean).includes('secret'), false);
    assert.equal(externalFeed.sanitizeControl({
      version: 1,
      reason: 'routes_updated',
      targets: [{ type: 'list', id: '55' }],
      subscription_id: '7',
      feed_routes_revision: '3',
    }, 'user', null), null);
    const listRemoved = externalFeed.sanitizeControl({
      version: 1,
      reason: 'list_removed',
      targets: [{ type: 'list', id: '55' }],
      subscription_id: '7',
      feed_routes_revision: '3',
      content: 'secret body',
    }, 'user', null);

    assert.equal(listRemoved.reason, 'list_removed');
    assert.equal(JSON.stringify(listRemoved).includes('secret'), false);
    assert.equal(externalFeed.sanitizeControl({
      version: 1,
      reason: 'list_removed',
      targets: [{ type: 'list', id: '55' }],
      subscription_id: '7',
      feed_routes_revision: '3',
    }, 'list', '56'), null);
    assert.equal(externalFeed.sanitizeControl({
      version: 1,
      reason: 'list_removed',
      targets: [{ type: 'list', id: '55' }],
      subscription_id: '7',
      feed_routes_revision: '3',
    }, 'list', '55').reason, 'list_removed');
    assert.equal(externalFeed.sanitizeControl({
      version: 2,
      reason: 'routes_updated',
      targets: [{ type: 'home' }],
      subscription_id: '7',
      feed_routes_revision: '0',
    }, 'user', null), null);
    assert.equal(externalFeed.sanitizeControl({
      version: 1,
      reason: 'source_deleted',
      targets: [{ type: 'home' }],
      subscription_id: '7',
      feed_routes_revision: '0',
      status_id: 12,
    }, 'user', null), null);
  });

  it('prepares public events without logging or re-encoding a delete id', () => {
    const ticket = ticketFor('user');
    const delivery = {
      kind: 'content',
      user_id: '17',
      status_id: '9007199254740993',
      projection_id: '3',
      subscription_id: '7',
      generation: '1',
    };
    const update = externalFeed.prepareEvent(ticket, {
      event: 'update',
      payload: { id: '9007199254740993', content: 'hello', _fedibird_searchable_text: 'hidden' },
      delivery: delivery,
    });
    const removed = externalFeed.prepareEvent(ticket, {
      event: 'delete',
      payload: '9007199254740993',
      delivery: { kind: 'delete', user_id: '17', status_id: '9007199254740993' },
    });

    assert.equal(update.event, 'update');
    assert.equal(JSON.parse(update.encoded)._fedibird_searchable_text, undefined);
    assert.equal(JSON.parse(update.encoded).id, '9007199254740993');
    assert.equal(JSON.parse(update.encoded).delivery, undefined);
    assert.equal(update.encoded.includes('projection_id'), false);
    assert.equal(removed.encoded, '9007199254740993');
    assert.equal(removed.encoded.includes('kind'), false);
    assert.equal(externalFeed.prepareEvent(ticket, { event: 'delete', payload: 5 }), null);
    assert.equal(externalFeed.prepareEvent(ticket, { event: 'update', payload: { id: '5' }, delivery: delivery }), null);
    assert.equal(externalFeed.prepareEvent(ticket, { event: 'delete', payload: '9007199254740993' }), null);
    assert.equal(externalFeed.prepareEvent(ticket, { event: 'status.update', payload: '5' }), null);
  });

  it('drops an older control revision and still accepts the same revision', () => {
    const ticket = ticketFor('list', '55');
    const payload = revision => ({
      event: 'external_feed_changed',
      payload: {
        version: 1,
        reason: 'source_deleted',
        targets: [{ type: 'list', id: '55' }],
        subscription_id: '7',
        feed_routes_revision: revision,
        status_id: '9007199254740993',
        content: 'secret body',
      },
    });
    const first = externalFeed.prepareEvent(ticket, payload('4'));

    assert.equal(first.control.feed_routes_revision, '4');
    assert.equal(JSON.parse(first.encoded).content, undefined);
    assert.equal(externalFeed.claimRevision(ticket, first.control), true);
    assert.equal(externalFeed.prepareEvent(ticket, payload('3')), null);
    const repeat = externalFeed.prepareEvent(ticket, payload('4'));

    assert.equal(repeat.control.status_id, '9007199254740993');
    assert.equal(externalFeed.prepareEvent(ticketFor('user'), payload('4')), null);
  });
});

describe('external feed subscription tickets', () => {
  const row = allowedRow();

  it('does not subscribe when unsubscribe wins the authorize race', async () => {
    let release;
    const gate = new Promise(resolve => {
      release = resolve;
    });
    const subscribed = [];
    const listener = () => {};

    externalFeed.attachExternalFeed({
      listener: listener,
      req: request(),
      externalFeed: { kind: 'user' },
      query: () => gate.then(() => ({ rows: [row] })),
      redisPrefix: 'ns:',
      subscribe: channel => subscribed.push(['subscribe', channel]),
      unsubscribe: channel => subscribed.push(['unsubscribe', channel]),
      output: () => {},
    });
    externalFeed.detachExternalFeed(listener, { unsubscribe: channel => subscribed.push(['unsubscribe', channel]) });
    release({ rows: [row] });
    await gate;
    await new Promise(resolve => setImmediate(resolve));

    assert.deepEqual(subscribed, []);
  });

  it('subscribes only the replacement ticket after a resubscribe', async () => {
    let release;
    const gate = new Promise(resolve => {
      release = resolve;
    });
    const subscribed = [];
    const first = () => {};
    const second = () => {};
    const query = () => gate.then(() => ({ rows: [row] }));
    const options = listener => ({
      listener: listener,
      req: request(),
      externalFeed: { kind: 'user' },
      query: query,
      redisPrefix: 'ns:',
      subscribe: channel => subscribed.push(channel),
      unsubscribe: () => {},
      output: () => {},
    });

    externalFeed.attachExternalFeed(options(first));
    externalFeed.detachExternalFeed(first, { unsubscribe: () => {} });
    externalFeed.attachExternalFeed(options(second));
    release({ rows: [row] });
    await gate;
    await new Promise(resolve => setImmediate(resolve));

    assert.deepEqual(subscribed, [
      'ns:timeline:external:user:17:home',
      'ns:timeline:external:user:17:control',
    ]);
  });

  it('does not deliver a private payload when send-time authorization fails', async () => {
    let calls = 0;
    const output = [];
    const listener = () => {};
    let privateListener = null;
    const query = () => {
      calls += 1;

      if (calls === 1) {
        return Promise.resolve({ rows: [row] });
      }

      return Promise.resolve({ rows: [] });
    };

    externalFeed.attachExternalFeed({
      listener: listener,
      req: request(),
      externalFeed: { kind: 'user' },
      query: query,
      redisPrefix: '',
      subscribe: (_channel, callback) => {
        privateListener = callback;
      },
      unsubscribe: () => {},
      output: (event, payload) => output.push([event, payload]),
    });
    await new Promise(resolve => setImmediate(resolve));
    privateListener(JSON.stringify({
      event: 'update',
      payload: { id: '8', content: 'secret body' },
      delivery: {
        kind: 'content',
        user_id: '17',
        status_id: '8',
        projection_id: '3',
        subscription_id: '7',
        generation: '1',
      },
    }));
    await new Promise(resolve => setImmediate(resolve));

    assert.deepEqual(output, []);
  });
});

describe('external feed send order', () => {
  const flush = () => new Promise(resolve => setImmediate(resolve));
  const contentMessage = (content, generation) => JSON.stringify({
    event: 'status.update',
    payload: { id: '8', content: content },
    delivery: {
      kind: 'content',
      user_id: '17',
      status_id: '8',
      projection_id: '3',
      subscription_id: '7',
      generation: generation,
    },
  });
  const deleteMessage = () => JSON.stringify({
    event: 'delete',
    payload: '8',
    delivery: { kind: 'delete', user_id: '17', status_id: '8' },
  });
  const controlMessage = (reason, targets) => JSON.stringify({
    event: 'external_feed_changed',
    payload: {
      version: 1,
      reason: reason,
      targets: targets,
      subscription_id: '7',
      feed_routes_revision: '2',
    },
  });
  const accountBody = () => ({ rows: [allowedRow()] });
  const contentBody = (generation, routed = true) => ({
    rows: [{ content_generation: generation, routed: routed }],
  });

  const answer = (gate, body) => {
    gate.settled = true;
    gate.resolve(body);
  };

  const openFeed = async (kind, listId) => {
    const gates = [];
    const output = [];
    const socket = () => {};
    let privateListener = null;

    externalFeed.attachExternalFeed({
      listener: socket,
      req: request(),
      externalFeed: { kind: kind, listId: listId },
      query: (sql, params) => new Promise((resolve, reject) => {
        gates.push({ sql: sql, params: params, resolve: resolve, reject: reject, settled: false });
      }),
      redisPrefix: '',
      subscribe: (_channel, callback) => {
        privateListener = callback;
      },
      unsubscribe: () => {},
      output: (event, payload) => output.push([event, payload]),
    });
    await flush();
    answer(gates[0], accountBody());

    if (kind === 'list') {
      await flush();
      answer(gates[1], { rows: [{ present: 1 }] });
    }

    await flush();

    return { gates: gates, output: output, listener: privateListener, socket: socket };
  };

  const texts = output => output.map(entry => entry[1]);

  it('keeps content order when the later authorization finishes first', async () => {
    const session = await openFeed('user');

    session.listener(contentMessage('old-body', '1'));
    session.listener(contentMessage('new-body', '2'));
    await flush();
    const firstAccount = session.gates[session.gates.length - 2];
    const secondAccount = session.gates[session.gates.length - 1];

    answer(secondAccount, accountBody());
    await flush();
    answer(session.gates[session.gates.length - 1], contentBody('2'));
    await flush();
    assert.deepEqual(session.output, []);
    answer(firstAccount, accountBody());
    await flush();
    answer(session.gates[session.gates.length - 1], contentBody('1'));
    await flush();

    assert.deepEqual(session.output.map(entry => entry[0]), ['status.update', 'status.update']);
    assert.equal(texts(session.output)[0].includes('old-body'), true);
    assert.equal(texts(session.output)[1].includes('new-body'), true);
    assert.equal(texts(session.output)[0].includes('projection_id'), false);
    assert.equal(texts(session.output)[0].includes('delivery'), false);
  });

  it('drops an older generation that finishes authorizing after a newer one was received first', async () => {
    const session = await openFeed('user');

    session.listener(contentMessage('new-body', '2'));
    session.listener(contentMessage('old-body', '1'));
    await flush();
    const newerAccount = session.gates[session.gates.length - 2];
    const olderAccount = session.gates[session.gates.length - 1];

    answer(olderAccount, accountBody());
    await flush();
    answer(session.gates[session.gates.length - 1], contentBody('1'));
    await flush();
    assert.deepEqual(session.output, []);
    answer(newerAccount, accountBody());
    await flush();
    answer(session.gates[session.gates.length - 1], contentBody('2'));
    await flush();

    assert.equal(texts(session.output).some(body => body.includes('old-body')), false);
    assert.equal(texts(session.output).some(body => body.includes('new-body')), true);
    assert.deepEqual(session.output.map(entry => entry[0]), ['status.update']);
  });

  it('drops a rendered generation that no longer matches the marker', async () => {
    const session = await openFeed('user');

    session.listener(contentMessage('old-body', '1'));
    session.listener(contentMessage('new-body', '2'));
    await flush();
    const olderAccount = session.gates[session.gates.length - 2];
    const newerAccount = session.gates[session.gates.length - 1];

    answer(newerAccount, accountBody());
    await flush();
    answer(session.gates[session.gates.length - 1], contentBody('2'));
    await flush();
    answer(olderAccount, accountBody());
    await flush();
    answer(session.gates[session.gates.length - 1], contentBody('2'));
    await flush();

    assert.equal(texts(session.output).some(body => body.includes('old-body')), false);
    assert.equal(texts(session.output).some(body => body.includes('new-body')), true);
  });

  it('keeps update before delete when delete authorization finishes first', async () => {
    const session = await openFeed('user');

    session.listener(contentMessage('old-body', '1'));
    session.listener(deleteMessage());
    await flush();
    const contentAccount = session.gates[session.gates.length - 2];
    const deleteAccount = session.gates[session.gates.length - 1];

    answer(deleteAccount, accountBody());
    await flush();
    answer(session.gates[session.gates.length - 1], { rows: [{ status_present: false, marker_present: false }] });
    await flush();
    assert.deepEqual(session.output, []);
    answer(contentAccount, accountBody());
    await flush();
    answer(session.gates[session.gates.length - 1], contentBody('1'));
    await flush();

    assert.deepEqual(session.output.map(entry => entry[0]), ['status.update', 'delete']);
    assert.equal(session.output[1][1], '8');
  });

  it('does not emit content after a delete that was received first', async () => {
    const session = await openFeed('user');

    session.listener(deleteMessage());
    session.listener(contentMessage('old-body', '1'));
    await flush();
    const deleteAccount = session.gates[session.gates.length - 2];
    const contentAccount = session.gates[session.gates.length - 1];

    answer(contentAccount, accountBody());
    await flush();
    answer(session.gates[session.gates.length - 1], contentBody('1'));
    await flush();
    assert.deepEqual(session.output, []);
    answer(deleteAccount, accountBody());
    await flush();
    answer(session.gates[session.gates.length - 1], { rows: [{ status_present: false, marker_present: false }] });
    await flush();

    assert.deepEqual(session.output.map(entry => entry[0]), ['delete']);
    assert.equal(texts(session.output).some(body => body.includes('old-body')), false);
  });

  it('keeps a membership change behind the content event that arrived first', async () => {
    const session = await openFeed('user');

    session.listener(contentMessage('still-routed', '1'));
    session.listener(controlMessage('routes_updated', [{ type: 'home' }]));
    await flush();
    const contentAccount = session.gates[session.gates.length - 2];
    const controlAccount = session.gates[session.gates.length - 1];

    answer(controlAccount, accountBody());
    await flush();
    assert.deepEqual(session.output, []);
    answer(contentAccount, accountBody());
    await flush();
    answer(session.gates[session.gates.length - 1], contentBody('1', true));
    await flush();

    assert.deepEqual(session.output.map(entry => entry[0]), ['status.update', 'external_feed_changed']);
  });

  it('drops content received after the route is gone', async () => {
    const session = await openFeed('user');

    session.listener(controlMessage('source_deleted', [{ type: 'home' }]));
    session.listener(contentMessage('removed-body', '1'));
    await flush();
    const controlAccount = session.gates[session.gates.length - 2];
    const contentAccount = session.gates[session.gates.length - 1];

    answer(contentAccount, accountBody());
    await flush();
    answer(session.gates[session.gates.length - 1], contentBody('1', false));
    await flush();
    assert.deepEqual(session.output, []);
    answer(controlAccount, accountBody());
    await flush();

    assert.deepEqual(session.output.map(entry => entry[0]), ['external_feed_changed']);
    assert.equal(texts(session.output).some(body => body.includes('removed-body')), false);
  });

  it('delivers list_removed without the deleted list row and still rejects later content', async () => {
    const session = await openFeed('list', '55');
    const before = session.gates.length;

    session.listener(controlMessage('list_removed', [{ type: 'list', id: '55' }]));
    await flush();
    assert.equal(session.gates.length, before + 1);
    assert.equal(session.gates[before].sql.includes('FROM lists'), false);
    answer(session.gates[before], accountBody());
    await flush();
    assert.equal(session.output.length, 1);
    assert.equal(JSON.parse(session.output[0][1]).reason, 'list_removed');

    session.listener(contentMessage('after-delete', '1'));
    await flush();
    const contentAccount = session.gates[session.gates.length - 1];

    answer(contentAccount, accountBody());
    await flush();
    const listGate = session.gates[session.gates.length - 1];

    assert.equal(listGate.sql.includes('FROM lists'), true);
    answer(listGate, { rows: [] });
    await flush();
    assert.equal(session.output.length, 1);
  });

  it('continues the queue when one authorization fails', async () => {
    const session = await openFeed('user');

    session.listener(contentMessage('failed-body', '1'));
    session.listener(contentMessage('later-body', '2'));
    await flush();
    const failed = session.gates[session.gates.length - 2];
    const later = session.gates[session.gates.length - 1];

    failed.settled = true;
    failed.reject(new Error('db down'));
    await flush();
    answer(later, accountBody());
    await flush();
    answer(session.gates[session.gates.length - 1], contentBody('2'));
    await flush();

    assert.equal(texts(session.output).some(body => body.includes('failed-body')), false);
    assert.equal(texts(session.output).some(body => body.includes('later-body')), true);
  });

  it('does not deliver after the ticket is replaced', async () => {
    const session = await openFeed('user');

    session.listener(contentMessage('late-body', '1'));
    await flush();
    externalFeed.detachExternalFeed(session.socket, { unsubscribe: () => {} });
    const account = session.gates[session.gates.length - 1];

    answer(account, accountBody());
    await flush();
    answer(session.gates[session.gates.length - 1], contentBody('1'));
    await flush();
    assert.deepEqual(session.output, []);
  });

  it('stops accepting private events past the pending limit', async () => {
    const session = await openFeed('user');

    for (let index = 0; index < externalFeed.PRIVATE_PENDING_LIMIT + 1; index += 1) {
      const id = String(index + 1);

      session.listener(JSON.stringify({
        event: 'update',
        payload: { id: id, content: `n${index}` },
        delivery: {
          kind: 'content',
          user_id: '17',
          status_id: id,
          projection_id: '3',
          subscription_id: '7',
          generation: '1',
        },
      }));
    }

    await flush();
    assert.equal(session.gates.filter(gate => !gate.settled).length, externalFeed.PRIVATE_PENDING_LIMIT);

    let guard = 0;

    while (guard < 200) {
      const gate = session.gates.find(item => !item.settled);

      if (!gate) {
        break;
      }

      if (gate.sql.includes('oauth_access_tokens')) {
        answer(gate, accountBody());
      } else {
        answer(gate, contentBody('1'));
      }

      await flush();
      guard += 1;
    }

    assert.equal(session.output.length, externalFeed.PRIVATE_PENDING_LIMIT);
    assert.equal(texts(session.output).some(body => body.includes('n64')), false);
  });
});
