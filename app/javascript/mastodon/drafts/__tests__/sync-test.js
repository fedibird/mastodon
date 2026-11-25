import {
  SERVER_DRAFT_CONFLICT_COPY,
  canonicalJson,
  createMemorySyncLedger,
  createPostDraftSync,
  serverDraftPayload,
  storedPayloadBytes,
} from '../sync';

const UUID = '11111111-1111-4111-8111-111111111111';

function snapshot (text, uuid = UUID, accountId = '42') {
  return {
    schema_version: 1,
    account_id: accountId,
    client_draft_uuid: uuid,
    composer_id: 'primary',
    saved_at: '2026-11-26T00:00:00.000Z',
    media_incomplete: false,
    content_hash: `hash-${text}`,
    input: { text, privacy: 'personal', media: [] },
    revision: 1,
  };
}

function created (spec, revision = 1) {
  const payload = spec.body.payload || spec.body;

  return {
    status: spec.method === 'post' ? 201 : 200,
    body: {
      draft_id: '15',
      revision,
      payload,
    },
  };
}

function harness (handler, options = {}) {
  const calls = [];
  let online = true;
  const listeners = [];
  let now = 0;
  let nextId = 1;
  const timers = [];
  const sync = createPostDraftSync({
    ledger: options.ledger,
    maxAttempts: options.maxAttempts,
    maxInFlight: options.maxInFlight,
    serverDebounceMs: options.serverDebounceMs === undefined ? 2000 : options.serverDebounceMs,
    schedule: (fn, ms) => {
      const id = nextId;

      nextId += 1;
      timers.push({ id, fn, at: now + ms, fired: false });

      return id;
    },
    cancel: (id) => {
      const timer = timers.find(item => item.id === id);

      if (timer) {
        timer.fired = true;
      }
    },
    online: () => online,
    subscribeOnline: (listener) => {
      listeners.push(listener);

      return () => undefined;
    },
    request: async (spec) => {
      calls.push({
        accountId: spec.accountId,
        method: spec.method,
        path: spec.path,
        body: spec.body,
      });

      return handler(spec, calls.length);
    },
  });

  const fire = async (ms) => {
    now += ms;
    const due = timers.filter(item => !item.fired && item.at <= now);

    due.forEach((item) => {
      item.fired = true;
    });
    due.forEach(item => item.fn());
    await sync.settle();
  };

  return {
    sync,
    calls,
    fire,
    setOnline (value) {
      online = value;
    },
    goOnline () {
      online = true;
      listeners.forEach(listener => listener());
    },
  };
}

function edit (sync, text, generation, uuid = UUID, accountId = '42') {
  const body = snapshot(text, uuid, accountId);

  return sync.observeLocal({
    accountId,
    clientUuid: uuid,
    localRevision: generation,
    contentHash: body.content_hash,
    payload: body,
    editGeneration: generation,
  });
}

describe('post draft server sync', () => {
  it('keeps the conflict copy unavailable and estimates payload size without sending tokens', () => {
    expect(SERVER_DRAFT_CONFLICT_COPY).toMatchObject({
      available: false,
      sharesMediaIds: false,
      unlinksMedia: false,
      keepsLocalText: true,
    });
    const body = snapshot('hello');

    expect(serverDraftPayload(body).revision).toBeUndefined();
    expect(storedPayloadBytes(body)).toBeGreaterThan(canonicalJson(body).length);
    expect(storedPayloadBytes({ text: 'abc' })).toBeLessThan(262144);
  });

  it('marks synced only when the acknowledgement matches the current edit', async () => {
    let release;
    const gate = new Promise((resolve) => {
      release = resolve;
    });
    const { sync, calls, fire } = harness((spec, count) => {
      if (count === 1) {
        return gate.then(() => created(spec, 1));
      }

      return Promise.resolve(created(spec, 2));
    });

    sync.bindAccount('42');
    await edit(sync, 'one', 1);
    const started = fire(2000);

    await waitFor(() => calls.length === 1);
    await edit(sync, 'two', 2);
    release();
    await started;

    expect(calls[0].body.payload.content_hash).toBe('hash-one');
    expect(sync.snapshot().drafts[UUID].status).not.toBe('synced');
    expect(sync.snapshot().drafts[UUID].contentHash).toBe('hash-two');
    await fire(0);

    expect(calls[calls.length - 1].method).toBe('patch');
    expect(calls[calls.length - 1].body.payload.content_hash).toBe('hash-two');
    expect(calls[calls.length - 1].body.expected_revision).toBe(1);
    expect(sync.snapshot().drafts[UUID].status).toBe('synced');
    expect(sync.snapshot().drafts[UUID].ackedGeneration).toBe(2);
  });

  it('sends a timed-out create again and accepts the existing row', async () => {
    let posts = 0;
    const { sync, calls, fire } = harness((spec) => {
      posts += 1;

      if (posts === 1) {
        return Promise.resolve({ status: 0, timedOut: true, body: null });
      }

      return Promise.resolve({
        status: 200,
        body: {
          draft_id: '15',
          revision: 1,
          payload: spec.body.payload,
        },
      });
    }, { maxAttempts: 3, retryBaseMs: 1000 });

    sync.bindAccount('42');
    await edit(sync, 'hello', 1);
    await fire(2000);
    expect(sync.snapshot().drafts[UUID].status).not.toBe('synced');
    await fire(1000);

    expect(calls.filter(call => call.method === 'post')).toHaveLength(2);
    expect(calls[1].body.client_uuid).toBe(UUID);
    expect(sync.snapshot().drafts[UUID].status).toBe('synced');
    expect(sync.snapshot().drafts[UUID].serverRevision).toBe(1);
  });

  it('recovers a lost patch from the stored server hash', async () => {
    let phase = 'create';
    const { sync, calls, fire } = harness((spec) => {
      if (phase === 'create') {
        phase = 'patch';
        return Promise.resolve(created(spec, 1));
      }

      if (spec.method === 'patch') {
        phase = 'get';
        return Promise.resolve({ status: 0, timedOut: true, body: null });
      }

      return Promise.resolve({
        status: 200,
        body: {
          draft_id: '15',
          revision: 2,
          payload: snapshot('edited'),
        },
      });
    });

    sync.bindAccount('42');
    await edit(sync, 'hello', 1);
    await fire(2000);
    await edit(sync, 'edited', 2);
    await fire(2000);

    expect(calls.map(call => call.method)).toEqual(['post', 'patch', 'get']);
    expect(sync.snapshot().drafts[UUID].status).toBe('synced');
    expect(sync.snapshot().drafts[UUID].serverRevision).toBe(2);
    expect(sync.snapshot().drafts[UUID].ackedHash).toBe('hash-edited');
  });

  it('patches again when a lost patch did not change the server', async () => {
    let phase = 'create';
    const { sync, calls, fire } = harness((spec) => {
      if (phase === 'create') {
        phase = 'lost';
        return Promise.resolve(created(spec, 1));
      }

      if (phase === 'lost' && spec.method === 'patch') {
        phase = 'get';
        return Promise.resolve({ status: 0, timedOut: true, body: null });
      }

      if (spec.method === 'get') {
        phase = 'retry';
        return Promise.resolve({
          status: 200,
          body: {
            draft_id: '15',
            revision: 1,
            payload: snapshot('hello'),
          },
        });
      }

      return Promise.resolve(created(spec, 2));
    });

    sync.bindAccount('42');
    await edit(sync, 'hello', 1);
    await fire(2000);
    await edit(sync, 'edited', 2);
    await fire(2000);
    await fire(0);

    const patches = calls.filter(call => call.method === 'patch');

    expect(patches).toHaveLength(2);
    expect(patches[1].body.expected_revision).toBe(1);
    expect(patches[1].body.payload.content_hash).toBe('hash-edited');
    expect(sync.snapshot().drafts[UUID].status).toBe('synced');
  });

  it('keeps the local draft on 409 and does not fork or delete it', async () => {
    const { sync, calls, fire } = harness((spec) => {
      if (spec.method === 'get') {
        return Promise.resolve({
          status: 200,
          body: {
            draft_id: '15',
            revision: 4,
            updated_at: '2026-11-26T01:00:00Z',
            payload: snapshot('other-device'),
          },
        });
      }

      return Promise.resolve({
        status: 409,
        body: { draft_id: '15', revision: 4, updated_at: '2026-11-26T01:00:00Z' },
      });
    });

    sync.bindAccount('42');
    await edit(sync, 'local', 1);
    await fire(2000);
    await fire(60000);

    expect(calls.map(call => call.method)).toEqual(['post', 'get']);
    expect(sync.snapshot().drafts[UUID]).toMatchObject({
      status: 'conflict',
      reason: 'conflict',
      contentHash: 'hash-local',
      serverDraftId: '15',
      serverRevision: 4,
    });
    expect(SERVER_DRAFT_CONFLICT_COPY.available).toBe(false);
  });

  it('deletes a row created by a save that finishes after discard', async () => {
    let release;

    const { sync, calls, fire } = harness((spec) => {
      if (spec.method === 'post') {
        return new Promise((resolve) => {
          release = () => resolve(created(spec, 3));
        });
      }

      return Promise.resolve({ status: 200, body: {} });
    });

    sync.bindAccount('42');
    await edit(sync, 'hello', 1);
    const pending = fire(2000);

    await waitFor(() => calls.length === 1);
    const discarded = sync.noteDiscard({ accountId: '42', clientUuid: UUID });

    release();
    await pending;
    await discarded;
    await sync.settle();

    expect(calls.map(call => call.method)).toEqual(['post', 'delete']);
    expect(calls[1].body).toEqual({ expected_revision: 3 });
    expect(sync.snapshot().drafts[UUID].status).toBe('deleted');
    await edit(sync, 'hello', 2);
    await fire(2000);
    expect(calls.filter(call => call.method === 'post')).toHaveLength(1);
  });

  it('does not delete the server draft when the post is published', async () => {
    let release;

    const { sync, calls, fire } = harness((spec) => new Promise((resolve) => {
      release = () => resolve(created(spec, 1));
    }));

    sync.bindAccount('42');
    await edit(sync, 'hello', 1);
    const pending = fire(2000);

    await waitFor(() => calls.length === 1);
    sync.notePublish({ accountId: '42', clientUuid: UUID });
    release();
    await pending;

    expect(calls.map(call => call.method)).toEqual(['post']);
    expect(sync.snapshot().drafts[UUID]).toMatchObject({ status: 'held', reason: 'publish' });
  });

  it('cancels a create that has not started when the post is published', async () => {
    const { sync, calls, fire } = harness(() => Promise.resolve(created({ body: { payload: snapshot('hello') } }, 1)));

    sync.bindAccount('42');
    await edit(sync, 'hello', 1);
    sync.notePublish({ accountId: '42', clientUuid: UUID });
    await fire(2000);

    expect(calls).toEqual([]);
    expect(sync.snapshot().drafts[UUID].status).toBe('held');
  });

  it('does not apply one account response to the next account', async () => {
    let release;
    const ledger = createMemorySyncLedger();
    const { sync, calls, fire } = harness((spec) => {
      if (spec.accountId === '7') {
        return Promise.resolve(created(spec, 1));
      }

      return new Promise((resolve) => {
        release = () => resolve(created(spec, 1));
      });
    }, { ledger });

    sync.bindAccount('42');
    await edit(sync, 'secret', 1);
    const pending = fire(2000);

    await waitFor(() => calls.length === 1);
    sync.bindAccount('7');
    await edit(sync, 'other', 1, '22222222-2222-4222-8222-222222222222', '7');
    release();
    await pending;
    await sync.settle();

    expect(calls).toHaveLength(1);
    expect(calls[0].accountId).toBe('42');
    expect(sync.snapshot().accountId).toBe('7');
    expect(sync.snapshot().drafts[UUID]).toBeUndefined();
    expect((await ledger.read('7', UUID))).toBeNull();
    expect((await ledger.read('42', UUID)).server_draft_id).toBe('15');
    await fire(2000);
    expect(calls[1].accountId).toBe('7');
    expect(calls[1].body.payload.input.text).toBe('other');
  });

  it('stops on the draft limit, an oversized payload, and a missing scope', async () => {
    const limited = harness(() => Promise.resolve({ status: 422, body: { code: 'limit_reached', limit: 100 } }));

    limited.sync.bindAccount('42');
    await edit(limited.sync, 'hello', 1);
    await limited.fire(2000);
    await limited.fire(60000);
    expect(limited.calls).toHaveLength(1);
    expect(limited.sync.snapshot().drafts[UUID]).toMatchObject({ status: 'failed', reason: 'limit' });

    const forbidden = harness(() => Promise.resolve({ status: 403, body: {} }));

    forbidden.sync.bindAccount('42');
    await edit(forbidden.sync, 'hello', 1);
    await forbidden.fire(2000);
    await forbidden.fire(60000);
    expect(forbidden.calls).toHaveLength(1);
    expect(forbidden.sync.snapshot().drafts[UUID].reason).toBe('scope');

    const huge = harness(() => Promise.resolve(created({ body: {} }, 1)));
    const text = 'x'.repeat(300000);

    huge.sync.bindAccount('42');
    await edit(huge.sync, text, 1);
    await huge.fire(2000);
    expect(huge.calls).toEqual([]);
    expect(huge.sync.snapshot().drafts[UUID].reason).toBe('too_large');
  });

  it('waits while offline and sends after the browser is online', async () => {
    const { sync, calls, fire, setOnline, goOnline } = harness(spec => Promise.resolve(created(spec, 1)));

    setOnline(false);
    sync.bindAccount('42');
    await edit(sync, 'hello', 1);
    await fire(2000);
    expect(calls).toEqual([]);
    expect(sync.snapshot().drafts[UUID]).toMatchObject({ status: 'local', reason: 'offline' });
    goOnline();
    await sync.settle();
    await fire(0);
    expect(calls).toHaveLength(1);
    expect(sync.snapshot().drafts[UUID].status).toBe('synced');
  });

  it('resumes one account without uploading another account or a tombstone', async () => {
    const ledger = createMemorySyncLedger();

    await ledger.write({
      account_id: '7',
      client_uuid: UUID,
      server_draft_id: '8',
      server_revision: 2,
      acked_hash: 'hash-other',
      acked_generation: 2,
      tombstone: false,
    });
    await ledger.write({
      account_id: '42',
      client_uuid: '33333333-3333-4333-8333-333333333333',
      server_draft_id: '9',
      server_revision: 1,
      acked_hash: 'hash-gone',
      acked_generation: 1,
      tombstone: true,
    });
    const { sync, calls, fire } = harness(spec => Promise.resolve(spec.method === 'delete' ? { status: 200, body: {} } : created(spec, 1)), { ledger });

    sync.bindAccount('42');
    await sync.resume(() => Promise.resolve([
      snapshot('keep', UUID, '42'),
      snapshot('nope', UUID, '7'),
      snapshot('gone', '33333333-3333-4333-8333-333333333333', '42'),
    ]));
    await fire(0);
    await sync.settle();

    expect(calls.map(call => call.method).sort()).toEqual(['delete', 'post']);
    expect(calls.find(call => call.method === 'post').body.payload.input.text).toBe('keep');
    expect(calls.find(call => call.method === 'post').accountId).toBe('42');
    expect(calls.find(call => call.method === 'delete').body).toEqual({ expected_revision: 1 });
  });

  it('sends at most the configured number of drafts at once', async () => {
    const waiting = [];
    const { sync, calls, fire } = harness(() => new Promise((resolve) => {
      waiting.push(resolve);
    }), { maxInFlight: 1, serverDebounceMs: 0 });
    const second = '22222222-2222-4222-8222-222222222222';

    sync.bindAccount('42');
    await edit(sync, 'one', 1);
    await edit(sync, 'two', 1, second);
    const pending = fire(0);

    await waitFor(() => calls.length === 1);
    expect(calls).toHaveLength(1);
    waiting[0](created(calls[0], 1));
    await waitFor(() => calls.length === 2);
    waiting[1](created(calls[1], 1));
    await pending;

    expect(calls).toHaveLength(2);
    expect(calls[0].body.client_uuid).not.toBe(calls[1].body.client_uuid);
  });
});

function waitFor (predicate) {
  return new Promise((resolve, reject) => {
    const started = Date.now();
    const check = () => {
      if (predicate()) {
        resolve();
        return;
      }

      if (Date.now() - started > 1000) {
        reject(new Error('timed out waiting'));
        return;
      }

      setTimeout(check, 5);
    };

    check();
  });
}
