import { applyMiddleware, createStore } from 'redux';
import thunk from 'redux-thunk';
import { combineReducers } from 'redux-immutable';
import { changeCompose, changeComposeVisibility, COMPOSE_RESET, COMPOSE_SUBMIT_REQUEST, COMPOSE_SUBMIT_SUCCESS, submissionSnapshot } from '../../actions/compose';
import { createComposer, destroyComposer, targetComposerAction } from '../../actions/composer';
import compose from '../../reducers/compose';
import composerDraftRecovery from '../../reducers/composer_draft_recovery';
import composers from '../../reducers/composers';
import { composerDraftMiddleware } from '../middleware';
import { createComposerDraftSession } from '../session';
import { createMemorySyncLedger, createPostDraftSync } from '../sync';
import { composerDraftContentHash, snapshotComposerDraft } from '../snapshot';
import { createMemoryDraftBackend } from '../storage';

function storeFor () {
  const backend = createMemoryDraftBackend();
  let clock = 0;
  const session = createComposerDraftSession({
    backend,
    now: () => {
      clock += 1;
      return `2026-11-13T00:00:0${clock}.000Z`;
    },
    createId: (() => {
      let next = 0;

      return () => {
        next += 1;
        return `draft-${next}`;
      };
    })(),
    schedule: (fn) => fn,
    cancel: () => undefined,
  });
  const store = createStore(
    combineReducers({
      compose,
      composers,
      composerDraftRecovery,
    }),
    applyMiddleware(thunk, composerDraftMiddleware({
      session,
      backend,
      accountId: '42',
      target: null,
    })),
  );

  return { store, session, backend };
}

describe('composer draft middleware', () => {
  it('saves primary and portable composers separately and restores only an empty surface', async () => {
    const { store, session, backend } = storeFor();

    store.dispatch(changeCompose('primary text'));
    store.dispatch(createComposer('portable-a'));
    store.dispatch(createComposer('portable-b'));
    store.dispatch(targetComposerAction(changeCompose('from a'), 'portable-a'));
    store.dispatch(targetComposerAction(changeCompose('from b'), 'portable-b'));
    await session.flush();
    store.dispatch(destroyComposer('portable-a'));
    await session.flush();
    await session.refreshOffers('42');

    const texts = (await backend.listDrafts('42')).map(item => item.input.text).sort();

    expect(texts).toEqual(['from a', 'from b', 'primary text']);

    store.dispatch(changeCompose('still typing'));
    const before = store.getState().getIn(['compose', 'text']);
    const offer = (await backend.listDrafts('42')).find(item => item.input.text === 'from a');

    store.dispatch(targetComposerAction({
      type: 'COMPOSER_DRAFT_RESTORE',
      snapshot: offer,
      idempotencyKey: 'should-not-apply',
      baseRevision: offer.revision,
    }, 'primary'));

    expect(store.getState().getIn(['compose', 'text'])).toBe(before);

    store.dispatch(changeCompose(''));
    store.dispatch(targetComposerAction({
      type: 'COMPOSER_DRAFT_RESTORE',
      snapshot: offer,
      idempotencyKey: 'restore-key',
      baseRevision: offer.revision,
    }, 'primary'));

    expect(store.getState().getIn(['compose', 'text'])).toBe('from a');
    expect(store.getState().getIn(['composers', 'byId', 'portable-b', 'text'])).toBe('from b');
  });

  it('removes a draft after a successful post and does not recreate it from the cleared composer', async () => {
    const { store, session, backend } = storeFor();

    store.dispatch(changeCompose('to post'));
    await session.flush();
    store.dispatch({
      type: COMPOSE_SUBMIT_SUCCESS,
      submission: null,
    });
    await session.flush();

    expect(await backend.listDrafts('42')).toEqual([]);
    expect(store.getState().getIn(['compose', 'text'])).toBe('');
  });

  async function publish (store, composerId) {
    const request = { type: COMPOSE_SUBMIT_REQUEST, submitId: 'submit-1' };

    store.dispatch(composerId === 'primary' ? request : targetComposerAction(request, composerId));

    const composer = composerId === 'primary'
      ? store.getState().get('compose')
      : store.getState().getIn(['composers', 'byId', composerId]);
    const success = {
      type: COMPOSE_SUBMIT_SUCCESS,
      status: { id: 'status-1', visibility: 'personal' },
      submission: submissionSnapshot(composer, 'new', 'submit-1'),
    };

    store.dispatch(composerId === 'primary' ? success : targetComposerAction(success, composerId));
  }

  it('deletes the sent personal draft after a real submit and keeps a different draft', async () => {
    const { store, session, backend } = storeFor();

    store.dispatch(changeComposeVisibility('personal'));
    store.dispatch(changeCompose('first post'));
    store.dispatch(createComposer('portable-a'));
    store.dispatch(targetComposerAction(changeComposeVisibility('personal'), 'portable-a'));
    store.dispatch(targetComposerAction(changeCompose('portable post'), 'portable-a'));
    await session.flush();

    const before = await backend.listDrafts('42');
    const primary = before.find(item => item.input.text === 'first post');
    const portable = before.find(item => item.input.text === 'portable post');

    expect(primary.input.privacy).toBe('personal');
    expect(portable.input.privacy).toBe('personal');

    await publish(store, 'primary');
    await session.flush();

    expect(store.getState().getIn(['compose', 'text'])).toBe('');
    expect(await backend.readDraft('42', primary.client_draft_uuid)).toBeNull();
    expect((await backend.readDraft('42', portable.client_draft_uuid)).input.text).toBe('portable post');

    const reloaded = createComposerDraftSession({
      backend,
      now: () => '2026-11-14T00:00:01.000Z',
      createId: () => 'reloaded',
      schedule: (fn) => fn,
      cancel: () => undefined,
    });

    expect((await reloaded.refreshOffers('42')).map(item => item.client_draft_uuid)).toEqual([portable.client_draft_uuid]);
  });

  it('deletes a restored personal draft on submit and keeps text typed while the request is open', async () => {
    const { store, session, backend } = storeFor();

    store.dispatch(changeCompose('restored post'));
    await session.flush();

    const saved = (await backend.listDrafts('42'))[0];

    store.dispatch({ type: COMPOSE_RESET });
    await session.flush();
    const personalInput = { ...saved.input, privacy: 'personal' };

    await backend.writeDraft({
      ...saved,
      content_hash: composerDraftContentHash(personalInput, saved.media_incomplete),
      input: personalInput,
    }, { baseRevision: 0 });
    const rewritten = await backend.readDraft('42', saved.client_draft_uuid);

    store.dispatch({
      type: 'COMPOSER_DRAFT_RESTORE',
      snapshot: rewritten,
      idempotencyKey: 'restore-key',
      restoreToken: 'restore-token',
      baseRevision: rewritten.revision,
    });

    expect(store.getState().getIn(['compose', 'text'])).toBe('restored post');
    expect(store.getState().getIn(['compose', 'privacy'])).toBe('personal');

    const aligned = snapshotComposerDraft(store.getState().get('compose'), {
      accountId: '42',
      clientDraftUuid: saved.client_draft_uuid,
      composerId: 'primary',
      savedAt: rewritten.saved_at,
    });

    await backend.writeDraft({
      ...rewritten,
      content_hash: aligned.content_hash,
      input: aligned.input,
    }, { baseRevision: rewritten.revision });

    store.dispatch({ type: COMPOSE_SUBMIT_REQUEST, submitId: 'submit-1' });

    const submitted = store.getState().get('compose');

    store.dispatch(changeCompose('typed while sending'));
    store.dispatch({
      type: COMPOSE_SUBMIT_SUCCESS,
      status: { id: 'status-1', visibility: 'personal' },
      submission: submissionSnapshot(submitted, 'new', 'submit-1'),
    });
    await session.flush();

    const remaining = await backend.listDrafts('42');

    expect(await backend.readDraft('42', saved.client_draft_uuid)).toBeNull();
    expect(remaining.map(item => item.client_draft_uuid)).not.toContain(saved.client_draft_uuid);
    expect(remaining.map(item => item.input.text)).toEqual(['typed while sending']);
    expect(store.getState().getIn(['compose', 'text'])).toBe('typed while sending');

    const reloaded = createComposerDraftSession({
      backend,
      now: () => '2026-11-14T00:00:02.000Z',
      createId: () => 'reloaded',
      schedule: (fn) => fn,
      cancel: () => undefined,
    });

    expect((await reloaded.refreshOffers('42')).map(item => item.client_draft_uuid)).toEqual(remaining.map(item => item.client_draft_uuid));
    expect((await backend.listDrafts('42')).map(item => item.input.text)).toEqual(['typed while sending']);
  });

  it('deletes a portable personal draft on submit', async () => {
    const { store, session, backend } = storeFor();

    store.dispatch(changeCompose('keep primary'));
    store.dispatch(createComposer('portable-a'));
    store.dispatch(targetComposerAction(changeComposeVisibility('personal'), 'portable-a'));
    store.dispatch(targetComposerAction(changeCompose('from portable'), 'portable-a'));
    await session.flush();

    const portable = (await backend.listDrafts('42')).find(item => item.input.text === 'from portable');

    await publish(store, 'portable-a');
    await session.flush();

    expect(await backend.readDraft('42', portable.client_draft_uuid)).toBeNull();
    expect((await backend.listDrafts('42')).map(item => item.input.text)).toEqual(['keep primary']);
    expect(store.getState().getIn(['composers', 'byId', 'portable-a', 'text'])).toBe('');
  });

  it('publishes server sync into Redux and does not treat an older acknowledgement as current', async () => {
    const calls = [];
    const waiting = [];
    const serverSync = createPostDraftSync({
      serverDebounceMs: 0,
      schedule: (fn) => {
        fn();
        return 1;
      },
      cancel: () => undefined,
      online: () => true,
      subscribeOnline: () => () => undefined,
      request: (spec) => new Promise((resolve) => {
        calls.push(spec.body && spec.body.payload && spec.body.payload.content_hash);
        waiting.push(() => resolve({
          status: calls.length === 1 ? 201 : 200,
          body: {
            draft_id: '15',
            revision: calls.length,
            payload: spec.body.payload,
          },
        }));
      }),
    });
    const backend = createMemoryDraftBackend();
    const session = createComposerDraftSession({
      backend,
      serverSync,
      now: () => '2026-11-26T00:00:00.000Z',
      createId: () => 'draft-1',
      schedule: (fn) => fn,
      cancel: () => undefined,
    });
    const store = createStore(
      combineReducers({
        compose,
        composers,
        composerDraftRecovery,
      }),
      applyMiddleware(thunk, composerDraftMiddleware({
        session,
        backend,
        accountId: '42',
        target: null,
      })),
    );

    const syncStatus = () => store.getState().getIn(['composerDraftRecovery', 'sync', 'drafts', 'draft-1', 'status']);

    store.dispatch(changeCompose('one'));
    await session.flush();
    await new Promise((resolve) => {
      setTimeout(resolve, 0);
    });
    expect(calls).toHaveLength(1);
    store.dispatch(changeCompose('two'));
    waiting[0]();
    await new Promise((resolve) => {
      setTimeout(resolve, 0);
    });

    expect(syncStatus()).not.toBe('synced');
    expect(store.getState().getIn(['composerDraftRecovery', 'sync', 'drafts', 'draft-1', 'reason'])).toBe('coalesced');
    await session.flush();
    await new Promise((resolve) => {
      setTimeout(resolve, 0);
    });
    expect(calls.length).toBeGreaterThan(1);
    waiting[1]();
    await serverSync.settle();

    expect(syncStatus()).toBe('synced');
    expect(store.getState().getIn(['composerDraftRecovery', 'sync', 'drafts', 'draft-1', 'contentHash'])).not.toBe(calls[0]);
  });

  it('publishes syncing, a publish hold, and an account change', async () => {
    let release;
    const serverSync = createPostDraftSync({
      serverDebounceMs: 0,
      schedule: (fn) => {
        fn();
        return 1;
      },
      cancel: () => undefined,
      online: () => true,
      subscribeOnline: () => () => undefined,
      request: (spec) => new Promise((resolve) => {
        release = () => resolve({
          status: 201,
          body: { draft_id: '15', revision: 1, payload: spec.body.payload },
        });
      }),
    });
    const backend = createMemoryDraftBackend();
    const session = createComposerDraftSession({
      backend,
      serverSync,
      now: () => '2026-11-26T00:00:00.000Z',
      createId: () => 'draft-1',
      schedule: (fn) => fn,
      cancel: () => undefined,
    });
    const store = createStore(
      combineReducers({
        compose,
        composers,
        composerDraftRecovery,
      }),
      applyMiddleware(thunk, composerDraftMiddleware({
        session,
        backend,
        accountId: '42',
        target: null,
      })),
    );
    const view = () => store.getState().getIn(['composerDraftRecovery', 'sync']);

    store.dispatch(changeCompose('one'));
    await session.flush();
    await new Promise((resolve) => {
      setTimeout(resolve, 0);
    });
    expect(view().getIn(['drafts', 'draft-1', 'status'])).toBe('syncing');

    release();
    await serverSync.settle();
    serverSync.notePublish({ accountId: '42', clientUuid: 'draft-1' });
    expect(view().getIn(['drafts', 'draft-1', 'status'])).toBe('held');

    session.releaseServerSync();
    expect(view().get('accountId')).toBeNull();
  });

  it('publishes a deleted draft after the delete retry succeeds', async () => {
    const timers = [];
    let now = 0;
    let deletes = 0;
    const serverSync = createPostDraftSync({
      serverDebounceMs: 0,
      schedule: (fn, ms) => {
        if (!ms) {
          fn();
          return 0;
        }

        timers.push({ at: now + ms, fn });
        return timers.length;
      },
      cancel: () => undefined,
      online: () => true,
      subscribeOnline: () => () => undefined,
      request: (spec) => {
        if (spec.method === 'delete') {
          deletes += 1;

          return Promise.resolve(deletes === 1 ? { status: 500, body: {} } : { status: 200, body: {} });
        }

        return Promise.resolve({
          status: 201,
          body: { draft_id: '15', revision: 1, payload: spec.body.payload },
        });
      },
    });
    const backend = createMemoryDraftBackend();
    const session = createComposerDraftSession({
      backend,
      serverSync,
      now: () => '2026-11-26T00:00:00.000Z',
      createId: () => 'draft-1',
      schedule: (fn) => fn,
      cancel: () => undefined,
    });
    const store = createStore(
      combineReducers({
        compose,
        composers,
        composerDraftRecovery,
      }),
      applyMiddleware(thunk, composerDraftMiddleware({
        session,
        backend,
        accountId: '42',
        target: null,
      })),
    );
    const syncStatus = () => store.getState().getIn(['composerDraftRecovery', 'sync', 'drafts', 'draft-1', 'status']);

    store.dispatch(changeCompose('one'));
    await session.flush();
    await serverSync.settle();
    await serverSync.noteDiscard({ accountId: '42', clientUuid: 'draft-1' });
    await serverSync.settle();

    expect(deletes).toBe(1);
    expect(syncStatus()).not.toBe('deleted');

    now = 1000;
    const due = timers.filter(timer => timer.at <= now);

    due.forEach(timer => timer.fn());
    await serverSync.settle();

    expect(deletes).toBe(2);
    expect(syncStatus()).toBe('deleted');
  });

  it('keeps a ledger failure stopped when the composer changes again', async () => {
    const calls = [];
    const ledger = {
      read: () => Promise.resolve(null),
      list: () => Promise.resolve([]),
      commit: () => Promise.reject(new Error('full')),
    };
    const serverSync = createPostDraftSync({
      ledger,
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
        return Promise.resolve({ status: 201, body: { draft_id: '15', revision: 1, payload: spec.body.payload } });
      },
    });
    const backend = createMemoryDraftBackend();
    const session = createComposerDraftSession({
      backend,
      serverSync,
      now: () => '2026-11-26T00:00:00.000Z',
      createId: () => 'draft-1',
      schedule: (fn) => fn,
      cancel: () => undefined,
    });
    const store = createStore(
      combineReducers({
        compose,
        composers,
        composerDraftRecovery,
      }),
      applyMiddleware(thunk, composerDraftMiddleware({
        session,
        backend,
        accountId: '42',
        target: null,
      })),
    );
    const reason = () => store.getState().getIn(['composerDraftRecovery', 'sync', 'drafts', 'draft-1', 'reason']);

    store.dispatch(changeCompose('one'));
    await session.flush();
    await serverSync.settle();
    store.dispatch(changeCompose('two'));
    await session.flush();
    await serverSync.settle();

    expect(calls).toHaveLength(0);
    expect(reason()).toBe('ledger');
  });

  it('does not show synced on reload while an unresolved intent is stored', async () => {
    const ledger = createMemorySyncLedger();
    const backend = createMemoryDraftBackend();
    const draft = {
      account_id: '42',
      client_draft_uuid: 'draft-1',
      schema_version: 1,
      revision: 2,
      content_hash: 'hash-kept',
      input: { text: 'kept' },
    };

    await backend.writeDraft(draft);
    await ledger.write({
      account_id: '42',
      client_uuid: 'draft-1',
      server_draft_id: '15',
      server_revision: 2,
      acked_hash: 'hash-kept',
      acked_generation: 2,
      intent_kind: 'patch',
      intent_hash: 'hash-kept',
      intent_base_revision: 1,
      intent_expected_revision: 2,
    });

    const calls = [];
    const serverSync = createPostDraftSync({
      ledger,
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
        return Promise.resolve({ status: 200, body: {} });
      },
    });
    const session = createComposerDraftSession({
      backend,
      serverSync,
      now: () => '2026-11-26T00:00:00.000Z',
      createId: () => 'draft-2',
      schedule: (fn) => fn,
      cancel: () => undefined,
    });
    const store = createStore(
      combineReducers({
        compose,
        composers,
        composerDraftRecovery,
      }),
      applyMiddleware(thunk, composerDraftMiddleware({
        session,
        backend,
        accountId: '42',
        target: null,
      })),
    );

    store.dispatch({ type: 'NOOP' });
    await new Promise((resolve) => {
      setTimeout(resolve, 0);
    });
    await serverSync.settle();

    expect(calls).toHaveLength(0);
    expect(store.getState().getIn(['composerDraftRecovery', 'sync', 'drafts', 'draft-1', 'status'])).not.toBe('synced');
    expect(store.getState().getIn(['composerDraftRecovery', 'sync', 'drafts', 'draft-1', 'reason'])).toBe('intent_held');
  });

  it('does not delete or replace a stored cursor when discard starts during resume', async () => {
    let releaseList;
    const inner = createMemorySyncLedger();

    await inner.write({
      account_id: '42',
      client_uuid: 'draft-1',
      server_draft_id: '15',
      server_revision: 4,
      acked_hash: 'hash-old',
      intent_kind: 'create',
      intent_hash: 'hash-old',
      intent_expected_revision: 1,
    });

    const calls = [];
    const ledger = {
      read: (...args) => inner.read(...args),
      commit: (...args) => inner.commit(...args),
      write: (record) => inner.write(record),
      list: (accountId) => new Promise((resolve) => {
        releaseList = () => inner.list(accountId).then(resolve);
      }),
    };
    const serverSync = createPostDraftSync({
      ledger,
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
        return Promise.resolve({ status: 200, body: {} });
      },
    });
    const backend = createMemoryDraftBackend();
    const session = createComposerDraftSession({
      backend,
      serverSync,
      now: () => '2026-11-26T00:00:00.000Z',
      createId: () => 'draft-1',
      schedule: (fn) => fn,
      cancel: () => undefined,
    });
    const store = createStore(
      combineReducers({
        compose,
        composers,
        composerDraftRecovery,
      }),
      applyMiddleware(thunk, composerDraftMiddleware({
        session,
        backend,
        accountId: '42',
        target: null,
      })),
    );

    store.dispatch(changeCompose('hello'));
    await session.flush();
    await new Promise((resolve) => {
      setTimeout(resolve, 0);
    });
    expect(typeof releaseList).toBe('function');

    store.dispatch({ type: COMPOSE_RESET });
    await session.flush();
    await serverSync.settle();

    expect(calls).not.toContain('delete');
    releaseList();
    await serverSync.settle();
    await new Promise((resolve) => {
      setTimeout(resolve, 0);
    });

    const row = await inner.read('42', 'draft-1');

    expect(calls).not.toContain('delete');
    expect(row.tombstone).toBe(true);
    expect(row.server_revision).toBe(4);
    expect(row.intent_kind).toBe('create');
    expect(store.getState().getIn(['composerDraftRecovery', 'sync', 'drafts', 'draft-1', 'status'])).not.toBe('deleted');
  });
});
