import {
  SERVER_DRAFT_CONFLICT_COPY,
  canonicalJson,
  createMemorySyncLedger,
  createPostDraftSync,
  createSyncLedgerState,
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
  const bindAccount = sync.bindAccount.bind(sync);

  sync.bindAccount = (id) => {
    bindAccount(id);

    if (!options.deferResume) {
      sync.boot = sync.resume(() => Promise.resolve([]));
    }
  };

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

async function edit (sync, text, generation, uuid = UUID, accountId = '42') {
  if (sync.boot) {
    await sync.boot;
  }

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

    expect(calls.map(call => call.method)).toEqual(['post', 'patch']);
    expect(sync.snapshot().drafts[UUID].status).not.toBe('synced');
    expect(sync.snapshot().drafts[UUID].intentUnresolved).toBe(true);
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
    await fire(1000);

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

    expect(calls.map(call => call.method)).toEqual(['post']);
    expect(sync.snapshot().drafts[UUID]).toMatchObject({
      status: 'conflict',
      reason: 'conflict',
      contentHash: 'hash-local',
      serverDraftId: '15',
      serverRevision: null,
      conflictRevision: 4,
      conflict: true,
    });
    expect(SERVER_DRAFT_CONFLICT_COPY.available).toBe(false);
  });

  it('deletes a row created by a save that finishes after discard', async () => {
    let release;

    const { sync, calls, fire } = harness((spec) => {
      if (spec.method === 'post') {
        return new Promise((resolve) => {
          release = () => resolve(created(spec, 1));
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
    expect(calls[1].body).toEqual({ expected_revision: 1 });
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
    expect(await ledger.read('42', UUID)).toMatchObject({
      server_draft_id: null,
      tombstone: false,
      intent_kind: 'create',
    });
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
      delete_revision: 1,
      delete_draft_id: '9',
      delete_state: 'pending',
    });
    const { sync, calls, fire } = harness(spec => Promise.resolve(spec.method === 'delete' ? { status: 200, body: {} } : created(spec, 1)), { ledger, deferResume: true });

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

  it('does not patch over another device after a conflict, including after reload', async () => {
    const ledger = createMemorySyncLedger();
    const { sync, calls, fire } = harness((spec) => {
      if (spec.method === 'get') {
        return Promise.resolve({
          status: 200,
          body: {
            draft_id: '15',
            revision: 6,
            payload: snapshot('device-a'),
          },
        });
      }

      return Promise.resolve({
        status: 409,
        body: { draft_id: '15', revision: 6, updated_at: '2026-11-26T01:00:00Z' },
      });
    }, { ledger });

    sync.bindAccount('42');
    await edit(sync, 'mine', 1);
    await fire(2000);
    await edit(sync, 'mine-more', 2);
    await fire(2000);
    await fire(60000);

    expect(calls.map(call => call.method)).toEqual(['post']);
    expect(sync.snapshot().drafts[UUID].status).toBe('conflict');
    expect(sync.snapshot().drafts[UUID].serverRevision).toBeNull();

    const reloaded = createPostDraftSync({
      ledger,
      request: () => Promise.resolve({ status: 500, body: {} }),
      schedule: (fn) => fn(),
      cancel: () => undefined,
      online: () => true,
      subscribeOnline: () => () => undefined,
      serverDebounceMs: 0,
    });

    reloaded.bindAccount('42');
    await reloaded.resume(() => Promise.resolve([snapshot('mine-more')]));
    await reloaded.observeLocal({
      accountId: '42',
      clientUuid: UUID,
      localRevision: 3,
      contentHash: 'hash-again',
      payload: snapshot('again'),
      editGeneration: 1,
      sessionId: 'reloaded-page',
    });
    await reloaded.settle();

    expect(reloaded.snapshot().drafts[UUID].status).toBe('conflict');
    expect(reloaded.snapshot().drafts[UUID].conflictRevision).toBe(6);
  });

  it('does not treat the same text at a new revision as this client acknowledgement', async () => {
    let phase = 'create';
    const { sync, calls, fire } = harness((spec) => {
      if (phase === 'create') {
        phase = 'patch';
        return Promise.resolve(created(spec, 1));
      }

      if (spec.method === 'patch') {
        return Promise.resolve({
          status: 409,
          body: { draft_id: '15', revision: 6 },
        });
      }

      return Promise.resolve({
        status: 200,
        body: {
          draft_id: '15',
          revision: 6,
          payload: snapshot('hello'),
        },
      });
    });

    sync.bindAccount('42');
    await edit(sync, 'hello', 1);
    await fire(2000);
    await edit(sync, 'edited', 2);
    await fire(2000);
    await fire(60000);

    expect(calls.filter(call => call.method === 'patch')).toHaveLength(1);
    expect(sync.snapshot().drafts[UUID]).toMatchObject({
      status: 'conflict',
      serverRevision: 1,
      conflictRevision: 6,
    });
  });

  it('does not delete another device revision when discard meets a 409', async () => {
    let release;

    const { sync, calls, fire } = harness((spec) => {
      if (spec.method === 'post') {
        return Promise.resolve(created(spec, 1));
      }

      if (spec.method === 'patch') {
        return new Promise((resolve) => {
          release = () => resolve({
            status: 409,
            body: { draft_id: '15', revision: 6 },
          });
        });
      }

      return Promise.resolve({ status: 200, body: {} });
    });

    sync.bindAccount('42');
    await edit(sync, 'hello', 1);
    await fire(2000);
    await edit(sync, 'edited', 2);
    const pending = fire(2000);

    await waitFor(() => calls.some(call => call.method === 'patch'));
    const discarded = sync.noteDiscard({ accountId: '42', clientUuid: UUID });

    release();
    await pending;
    await discarded;
    await sync.settle();
    await fire(60000);

    expect(calls.map(call => call.method)).toEqual(['post', 'patch']);
    expect(sync.snapshot().drafts[UUID]).toMatchObject({
      status: 'conflict',
      reason: 'discard_blocked',
      conflictRevision: 6,
    });
  });

  it('looks up a create whose response was lost and deletes only the matching body', async () => {
    let release;

    const { sync, calls, fire } = harness((spec) => {
      if (spec.method === 'post') {
        return new Promise((resolve) => {
          release = () => resolve({ status: 0, timedOut: true, body: null });
        });
      }

      if (spec.method === 'get' && spec.path.indexOf('?') !== -1) {
        return Promise.resolve({
          status: 200,
          body: [{ draft_id: '15', client_uuid: UUID, revision: 1 }],
        });
      }

      if (spec.method === 'get') {
        return Promise.resolve({
          status: 200,
          body: {
            draft_id: '15',
            revision: 1,
            payload: snapshot('hello'),
          },
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

    expect(calls.some(call => call.method === 'delete')).toBe(false);
    expect(sync.snapshot().drafts[UUID].deleteState).not.toBe('deleted');
    expect(sync.snapshot().drafts[UUID].reason).toBe('delete_unknown');
  });

  it('stops when a conflict cannot be stored', async () => {
    const inner = createMemorySyncLedger();
    const ledger = {
      read: (...args) => inner.read(...args),
      list: (...args) => inner.list(...args),
      commit: (accountId, clientUuid, proposed) => {
        if (proposed && proposed.conflict === true) {
          return Promise.reject(new Error('full'));
        }

        return inner.commit(accountId, clientUuid, proposed);
      },
    };
    const { sync, calls, fire } = harness((spec) => {
      if (spec.method === 'get') {
        return Promise.resolve({
          status: 200,
          body: { draft_id: '15', revision: 4, payload: snapshot('other') },
        });
      }

      return Promise.resolve({ status: 409, body: { draft_id: '15', revision: 4 } });
    }, { ledger });

    sync.bindAccount('42');
    await edit(sync, 'hello', 1);
    await fire(2000);
    await fire(60000);

    expect(calls.filter(call => call.method === 'post')).toHaveLength(1);
    expect(sync.snapshot().drafts[UUID].status).toBe('conflict');
    expect(sync.snapshot().drafts[UUID].reason).toBe('ledger');
  });

  it('accepts a page epoch of 1 after a resumed generation', async () => {
    const ledger = createMemorySyncLedger();

    await ledger.write({
      account_id: '42',
      client_uuid: UUID,
      server_draft_id: '15',
      server_revision: 5,
      acked_hash: 'hash-hello',
      acked_generation: 8,
      sync_generation: 8,
      conflict: false,
      tombstone: false,
    });
    const { sync, calls, fire } = harness(spec => Promise.resolve({
      status: 200,
      body: {
        draft_id: '15',
        revision: 6,
        payload: spec.body.payload,
      },
    }), { ledger, serverDebounceMs: 0, deferResume: true });

    sync.bindAccount('42');
    await sync.resume(() => Promise.resolve([snapshot('hello')]));
    await sync.observeLocal({
      accountId: '42',
      clientUuid: UUID,
      localRevision: 9,
      contentHash: 'hash-next',
      payload: snapshot('next'),
      editGeneration: 1,
      sessionId: 'reloaded-page',
    });
    await fire(0);

    expect(calls).toHaveLength(1);
    expect(calls[0].method).toBe('patch');
    expect(calls[0].body.expected_revision).toBe(5);
    expect(calls[0].body.payload.content_hash).toBe('hash-next');
    expect(sync.snapshot().drafts[UUID].status).toBe('synced');
  });

  it('keeps an edit that arrives while resume is still listing', async () => {
    let release;
    const { sync, calls, fire } = harness(spec => Promise.resolve(created(spec, 1)), { serverDebounceMs: 0, deferResume: true });

    sync.bindAccount('42');
    const pending = sync.resume(() => new Promise((resolve) => {
      release = () => resolve([snapshot('old')]);
    }));

    await edit(sync, 'new', 1);
    await waitFor(() => typeof release === 'function');
    release();
    await pending;
    await fire(0);

    expect(calls).toHaveLength(1);
    expect(calls[0].body.payload.input.text).toBe('new');
  });

  it('refuses a claim that still names the acknowledgement from before another tab saved', async () => {
    const ledger = createMemorySyncLedger();

    await ledger.write({
      account_id: '42',
      client_uuid: UUID,
      server_draft_id: '15',
      server_revision: 5,
      acked_hash: 'hash-base',
      cursor_version: 1,
    });

    const seen = await ledger.read('42', UUID);
    const claimed = await ledger.commit('42', UUID, {
      transition: 'claim',
      cursor_version: seen.cursor_version,
      operation_id: 'op-b',
      operation_owner: 'tab-b',
      intent_kind: 'patch',
      intent_hash: 'hash-b',
      intent_base_revision: 5,
      intent_expected_revision: 6,
      intent_draft_id: '15',
    });
    const finished = await ledger.commit('42', UUID, {
      transition: 'finish',
      cursor_version: claimed.record.cursor_version,
      operation_id: 'op-b',
      operation_owner: 'tab-b',
      intent_kind: 'patch',
      intent_hash: 'hash-b',
      intent_base_revision: 5,
      intent_expected_revision: 6,
      intent_draft_id: '15',
      server_revision: 6,
      server_draft_id: '15',
    });
    const stale = await ledger.commit('42', UUID, {
      transition: 'claim',
      cursor_version: seen.cursor_version,
      operation_id: 'op-a',
      operation_owner: 'tab-a',
      intent_kind: 'patch',
      intent_hash: 'hash-a',
      intent_base_revision: 5,
      intent_expected_revision: 6,
      intent_draft_id: '15',
    });

    expect(finished.accepted).toBe(true);
    expect(finished.record.server_revision).toBe(6);
    expect(stale.accepted).toBe(false);
    expect(stale.record.server_revision).toBe(6);
    expect(stale.record.intent_kind).toBeNull();
  });

  it('does not patch or delete at a revision another tab acknowledged', async () => {
    const state = createSyncLedgerState();
    const ledger = createMemorySyncLedger(state);

    await ledger.write({
      account_id: '42',
      client_uuid: UUID,
      server_draft_id: '15',
      server_revision: 5,
      acked_hash: 'hash-base',
      cursor_version: 1,
    });

    const calls = [];
    const queued = [];
    const syncA = createPostDraftSync({
      ledger,
      ownerId: 'tab-a',
      serverDebounceMs: 0,
      schedule: (fn) => {
        queued.push(fn);
        return queued.length;
      },
      cancel: () => undefined,
      online: () => true,
      subscribeOnline: () => () => undefined,
      request: (spec) => {
        calls.push({ owner: 'tab-a', method: spec.method, body: spec.body });
        return Promise.resolve({ status: 200, body: {} });
      },
    });
    const syncB = createPostDraftSync({
      ledger,
      ownerId: 'tab-b',
      serverDebounceMs: 0,
      schedule: (fn) => {
        fn();
        return 1;
      },
      cancel: () => undefined,
      online: () => true,
      subscribeOnline: () => () => undefined,
      request: (spec) => {
        calls.push({ owner: 'tab-b', method: spec.method, body: spec.body });
        return Promise.resolve({
          status: 200,
          body: { draft_id: '15', revision: 6, payload: spec.body.payload },
        });
      },
    });

    syncA.bindAccount('42');
    syncB.bindAccount('42');
    const based = (text) => ({
      ...snapshot(text),
      sync_base: { recorded: true, revision: 5, draft_id: '15', hash: 'hash-base' },
    });

    await syncA.resume(() => Promise.resolve([based('from-a')]));
    await syncB.resume(() => Promise.resolve([based('from-b')]));
    await syncB.settle();
    queued.splice(0).forEach(fn => fn());
    await syncA.settle();
    await syncA.noteDiscard({ accountId: '42', clientUuid: UUID });
    await syncA.settle();

    const fromA = calls.filter(call => call.owner === 'tab-a');

    expect(calls.filter(call => call.owner === 'tab-b').map(call => call.body.expected_revision)).toEqual([5]);
    expect(fromA.every(call => !call.body || call.body.expected_revision !== 6)).toBe(true);
    expect(fromA.some(call => call.method === 'delete')).toBe(false);
    expect((await ledger.read('42', UUID)).server_revision).toBe(6);
    expect(syncA.snapshot().drafts[UUID].status).not.toBe('synced');
  });

  it('clears a definite rejection so a later edit can sync', async () => {
    let attempts = 0;
    const { sync, calls, fire } = harness((spec) => {
      attempts += 1;

      if (attempts === 1) {
        return Promise.resolve({ status: 422, body: { errors: [{ error: 'validation' }] } });
      }

      return Promise.resolve(created(spec, 1));
    });

    sync.bindAccount('42');
    await edit(sync, 'media', 1);
    await fire(2000);
    expect(sync.snapshot().drafts[UUID].status).toBe('failed');

    await edit(sync, 'ready', 2);
    await fire(2000);

    expect(calls.map(call => call.method)).toEqual(['post', 'post']);
    expect(sync.snapshot().drafts[UUID].status).toBe('synced');
  });

  it('holds a discard that starts before the cursor is loaded', async () => {
    const ledger = createMemorySyncLedger();

    await ledger.write({
      account_id: '42',
      client_uuid: UUID,
      server_draft_id: '15',
      server_revision: 4,
      acked_hash: 'hash-old',
      intent_kind: 'create',
      intent_hash: 'hash-old',
      intent_expected_revision: 1,
    });

    const { sync, calls } = harness(() => Promise.resolve({ status: 200, body: {} }), { ledger, deferResume: true });

    sync.bindAccount('42');
    const discarded = sync.noteDiscard({ accountId: '42', clientUuid: UUID });

    await discarded;
    expect(calls).toHaveLength(0);

    await sync.resume(() => Promise.resolve([]));
    await sync.settle();

    expect(calls.some(call => call.method === 'delete' || call.method === 'post')).toBe(false);

    const row = await ledger.read('42', UUID);

    expect(row.tombstone).toBe(true);
    expect(row.server_revision).toBe(4);
    expect(row.intent_kind).toBe('create');
    expect(row.delete_state).not.toBe('deleted');
    expect(sync.snapshot().drafts[UUID].status).not.toBe('deleted');
  });

  it('does not post over a tombstone or patch over a conflict learned during boot', async () => {
    const ledger = createMemorySyncLedger();

    await ledger.write({
      account_id: '42',
      client_uuid: UUID,
      server_draft_id: '15',
      server_revision: 4,
      acked_hash: 'hash-old',
      sync_generation: 4,
      conflict: true,
      conflict_revision: 6,
      tombstone: false,
    });
    await ledger.write({
      account_id: '42',
      client_uuid: '33333333-3333-4333-8333-333333333333',
      server_draft_id: '9',
      server_revision: 1,
      delete_state: 'unknown',
      tombstone: true,
      probe_hash: 'hash-gone',
    });
    let release;
    const { sync, calls } = harness(() => Promise.resolve(created({ body: { payload: snapshot('x') } }, 1)), { ledger, deferResume: true });

    sync.bindAccount('42');
    const pending = sync.resume(() => new Promise((resolve) => {
      release = () => resolve([snapshot('typed-during-boot'), snapshot('gone', '33333333-3333-4333-8333-333333333333')]);
    }));

    await edit(sync, 'typed-during-boot', 1);
    await edit(sync, 'gone', 1, '33333333-3333-4333-8333-333333333333');
    release();
    await pending;
    await sync.settle();

    expect(calls).toEqual([]);
    expect(sync.snapshot().drafts[UUID].status).toBe('conflict');
    expect(sync.snapshot().drafts[UUID].contentHash).toBe('hash-typed-during-boot');
    expect(sync.snapshot().drafts['33333333-3333-4333-8333-333333333333'].tombstone).toBe(true);
    expect(sync.snapshot().drafts['33333333-3333-4333-8333-333333333333'].deleteState).toBe('unknown');
  });

  it('stops retrying when the server stays on the acknowledged revision', async () => {
    let phase = 'create';
    const { sync, calls, fire } = harness((spec) => {
      if (phase === 'create') {
        phase = 'lost';
        return Promise.resolve(created(spec, 1));
      }

      if (spec.method === 'get') {
        return Promise.resolve({
          status: 200,
          body: { draft_id: '15', revision: 1, payload: snapshot('hello') },
        });
      }

      return Promise.resolve({ status: 0, timedOut: true, body: null });
    }, { maxAttempts: 2, retryBaseMs: 1000 });

    sync.bindAccount('42');
    await edit(sync, 'hello', 1);
    await fire(2000);
    await edit(sync, 'edited', 2);
    await fire(2000);
    await fire(1000);
    await fire(2000);
    await fire(8000);

    const patches = calls.filter(call => call.method === 'patch');

    expect(patches.length).toBeLessThanOrEqual(2);
    expect(sync.snapshot().drafts[UUID].reason).toBe('retry_exhausted');
  });

  it('does not recreate a draft when a conflict lookup returns 404', async () => {
    const { sync, calls, fire } = harness((spec) => {
      if (spec.method === 'get') {
        return Promise.resolve({ status: 404, body: {} });
      }

      return Promise.resolve({
        status: 409,
        body: { draft_id: '15', revision: 3 },
      });
    });

    sync.bindAccount('42');
    await edit(sync, 'hello', 1);
    await fire(2000);
    await fire(60000);

    expect(calls.filter(call => call.method === 'post')).toHaveLength(1);
    expect(sync.snapshot().drafts[UUID].status).toBe('conflict');
  });

  it('leaves an unknown create unknown when the list does not show it', async () => {
    let release;
    const { sync, calls, fire } = harness((spec) => {
      if (spec.method === 'post') {
        return new Promise((resolve) => {
          release = () => resolve({ status: 0, timedOut: true, body: null });
        });
      }

      return Promise.resolve({ status: 200, body: [] });
    });

    sync.bindAccount('42');
    await edit(sync, 'hello', 1);
    const pending = fire(2000);

    await waitFor(() => calls.some(call => call.method === 'post'));
    const discarded = sync.noteDiscard({ accountId: '42', clientUuid: UUID });

    release();
    await pending;
    await discarded;
    await sync.settle();
    await fire(60000);

    expect(calls.some(call => call.method === 'delete')).toBe(false);
    expect(sync.snapshot().drafts[UUID].deleteState).toBe('unknown');
    expect(sync.snapshot().drafts[UUID].status).not.toBe('deleted');
  });

  it('does not adopt an acknowledgement when the ledger rejects finish', async () => {
    const inner = createMemorySyncLedger();
    const ledger = {
      read: (...args) => inner.read(...args),
      list: (...args) => inner.list(...args),
      commit: (accountId, clientUuid, proposed) => {
        if (proposed.transition === 'finish' || proposed.transition === 'deleted') {
          return Promise.resolve({
            accepted: false,
            rejected: true,
            reason: 'stale_cursor',
            record: { tombstone: proposed.transition === 'deleted' },
          });
        }

        return inner.commit(accountId, clientUuid, proposed);
      },
    };
    const { sync, calls, fire } = harness(spec => Promise.resolve(created(spec, 1)), { ledger });

    sync.bindAccount('42');
    await edit(sync, 'hello', 1);
    await fire(2000);

    expect(calls.map(call => call.method)).toEqual(['post']);
    expect(sync.snapshot().drafts[UUID].status).not.toBe('synced');
    expect(sync.snapshot().drafts[UUID].serverRevision).toBeNull();
    expect((await inner.read('42', UUID)).intent_kind).toBe('create');
    expect((await inner.read('42', UUID)).server_revision).toBeNull();
  });

  it('keeps a held draft when the in-flight save succeeds and does not delete it', async () => {
    let release;
    const { sync, calls, fire } = harness(spec => new Promise((resolve) => {
      release = () => resolve(created(spec, 1));
    }), { serverDebounceMs: 0 });

    sync.bindAccount('42');
    await edit(sync, 'hello', 1);
    const pending = fire(0);

    await waitFor(() => calls.some(call => call.method === 'post'));
    sync.notePublish({ accountId: '42', clientUuid: UUID });
    release();
    await pending;
    await sync.settle();

    expect(calls.map(call => call.method)).toEqual(['post']);
    expect(sync.snapshot().drafts[UUID].status).toBe('held');
    expect(sync.snapshot().drafts[UUID].serverRevision).toBe(1);
  });

  it('rejects a claim that is held before it is sent', async () => {
    const inner = createMemorySyncLedger();
    let sync;
    const calls = [];
    const ledger = {
      read: (...args) => inner.read(...args),
      list: (...args) => inner.list(...args),
      commit: async (accountId, clientUuid, proposed) => {
        const result = await inner.commit(accountId, clientUuid, proposed);

        if (proposed.transition === 'claim') {
          sync.notePublish({ accountId: '42', clientUuid: UUID });
        }

        return result;
      },
    };

    sync = createPostDraftSync({
      ledger,
      ownerId: 'tab-a',
      serverDebounceMs: 0,
      schedule: (fn) => {
        fn();
        return 1;
      },
      cancel: () => undefined,
      online: () => true,
      subscribeOnline: () => () => undefined,
      request: (spec) => {
        calls.push(spec.method);
        return Promise.resolve(created(spec, 1));
      },
    });

    sync.bindAccount('42');
    await sync.resume(() => Promise.resolve([snapshot('hello')]));
    await sync.settle();

    expect(calls).toEqual([]);
    expect(sync.snapshot().drafts[UUID].status).toBe('held');
    expect((await inner.read('42', UUID)).intent_kind).toBeNull();
  });

  it('does not patch reloaded text at another tab acknowledgement', async () => {
    const ledger = createMemorySyncLedger();

    await ledger.write({
      account_id: '42',
      client_uuid: UUID,
      server_draft_id: '15',
      server_revision: 6,
      acked_hash: 'hash-server',
      cursor_version: 1,
    });

    const { sync, calls, fire } = harness(() => Promise.resolve(created({ body: { payload: snapshot('x') } }, 1)), { ledger, deferResume: true, serverDebounceMs: 0 });

    sync.bindAccount('42');
    await sync.resume(() => Promise.resolve([{
      ...snapshot('mine'),
      sync_base: { recorded: true, revision: 5, draft_id: '15', hash: 'hash-base' },
    }]));
    await fire(0);

    expect(calls).toEqual([]);
    expect(sync.snapshot().drafts[UUID].reason).toBe('unbased');
    expect(sync.snapshot().drafts[UUID].serverRevision).toBeNull();
  });

  it('continues a reloaded draft whose text already matches the acknowledgement', async () => {
    const ledger = createMemorySyncLedger();

    await ledger.write({
      account_id: '42',
      client_uuid: UUID,
      server_draft_id: '15',
      server_revision: 2,
      acked_hash: 'hash-hello',
      cursor_version: 1,
    });

    const { sync, calls } = harness(() => Promise.resolve({ status: 500, body: {} }), { ledger, deferResume: true });

    sync.bindAccount('42');
    await sync.resume(() => Promise.resolve([snapshot('hello')]));

    expect(calls).toEqual([]);
    expect(sync.snapshot().drafts[UUID].status).toBe('synced');
  });

  it('patches a boot edit from its own base instead of an older saved body', async () => {
    const ledger = createMemorySyncLedger();

    await ledger.write({
      account_id: '42',
      client_uuid: UUID,
      server_draft_id: '15',
      server_revision: 5,
      acked_hash: 'hash-old',
      cursor_version: 1,
    });

    let release;
    const { sync, calls, fire } = harness(spec => Promise.resolve({
      status: 200,
      body: { draft_id: '15', revision: 6, payload: spec.body.payload },
    }), { ledger, deferResume: true, serverDebounceMs: 0 });

    sync.bindAccount('42');
    const pending = sync.resume(() => new Promise((resolve) => {
      release = () => resolve([{
        ...snapshot('old'),
        content_hash: 'hash-old',
        sync_base: { recorded: true, revision: 5, draft_id: '15', hash: 'hash-old' },
      }]);
    }));

    await sync.observeLocal({
      accountId: '42',
      clientUuid: UUID,
      localRevision: 2,
      contentHash: 'hash-new',
      payload: {
        ...snapshot('new'),
        content_hash: 'hash-new',
        sync_base: { recorded: true, revision: 5, draft_id: '15', hash: 'hash-old' },
      },
      editGeneration: 1,
      sessionId: 'boot',
    });
    await waitFor(() => typeof release === 'function');
    release();
    await pending;
    await fire(0);

    expect(calls).toHaveLength(1);
    expect(calls[0].method).toBe('patch');
    expect(calls[0].body.expected_revision).toBe(5);
    expect(calls[0].body.payload.content_hash).toBe('hash-new');
  });

  it('does not apply a resume that is still reading after the account changes', async () => {
    const inner = createMemorySyncLedger();
    let release;
    const ledger = {
      list: (...args) => inner.list(...args),
      commit: (...args) => inner.commit(...args),
      read: (accountId, clientUuid) => new Promise((resolve) => {
        release = () => inner.read(accountId, clientUuid).then(resolve);
      }),
    };
    const { sync, calls } = harness(() => Promise.resolve(created({ body: { payload: snapshot('x') } }, 1)), { ledger, deferResume: true, serverDebounceMs: 0 });

    sync.bindAccount('42');
    const pending = sync.resume(() => Promise.resolve([snapshot('hello')]));

    await waitFor(() => typeof release === 'function');
    sync.bindAccount('7');
    release();
    await pending;

    expect(calls).toEqual([]);
    expect(sync.snapshot().accountId).toBe('7');
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
