import { List as ImmutableList, Map as ImmutableMap } from 'immutable';
import { COMPOSE_REPLY_CANCEL, COMPOSE_RESET, COMPOSE_SET_STATUS, COMPOSE_SUBMIT_SUCCESS, COMPOSE_UPLOAD_SUCCESS, changeCompose } from '../../actions/compose';
import { REDRAFT } from '../../actions/statuses';
import composer, { initialState } from '../../reducers/composer';
import { createComposerDraftSession } from '../session';
import { createMemoryDraftBackend } from '../storage';

function harness () {
  const backend = createMemoryDraftBackend();
  let clock = 0;
  const session = createComposerDraftSession({
    backend,
    debounceMs: 300,
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

  return { backend, session };
}

function composerWith (text, extra) {
  return initialState.merge({ text, instanceId: 'composer-1', ...(extra || {}) });
}

describe('composer draft session', () => {
  it('does not store an empty composer', async () => {
    const { backend, session } = harness();

    session.sync({
      accountId: '42',
      action: { type: 'COMPOSE_MOUNT' },
      composers: [{ composerId: 'primary', state: initialState }],
    });
    await session.flush();

    expect(await backend.listDrafts('42')).toEqual([]);
  });

  it('keeps primary and portable drafts independent across close and reload', async () => {
    const { backend, session } = harness();
    const primary = composerWith('primary text', { instanceId: 'composer-1' });
    const portableA = composerWith('portable a', { instanceId: 'composer-a' });
    const portableB = composerWith('portable b', { instanceId: 'composer-b' });

    session.sync({
      accountId: '42',
      action: { type: 'COMPOSE_CHANGE' },
      composers: [
        { composerId: 'primary', state: primary },
        { composerId: 'portable-a', state: portableA },
        { composerId: 'portable-b', state: portableB },
      ],
    });
    await session.flush();
    session.sync({
      accountId: '42',
      action: { type: 'COMPOSER_DESTROY', meta: { composerId: 'portable-a' } },
      composers: [
        { composerId: 'primary', state: primary },
        { composerId: 'portable-b', state: portableB },
      ],
    });
    await session.flush();

    const reloaded = createComposerDraftSession({
      backend,
      debounceMs: 300,
      now: () => '2026-11-13T00:00:09.000Z',
      createId: () => 'draft-new',
      schedule: (fn) => fn,
      cancel: () => undefined,
    });

    await reloaded.refreshOffers('42');
    const offers = reloaded.snapshot().offers.map(item => item.client_draft_uuid);

    expect((await backend.listDrafts('42')).map(item => item.input.text).sort()).toEqual(['portable a', 'portable b', 'primary text']);
    expect(offers).toHaveLength(3);
    expect(await backend.listDrafts('7')).toEqual([]);
  });

  it('does not let a stale write replace newer text, a destroyed surface, a successful post, or a finished upload', async () => {
    const backend = createMemoryDraftBackend();
    let release;
    const gate = new Promise((resolve) => {
      release = resolve;
    });
    const gated = {
      readDraft: (...args) => backend.readDraft(...args),
      deleteDraft: (...args) => backend.deleteDraft(...args),
      listDrafts: (...args) => backend.listDrafts(...args),
      writeDraft: (record, options) => backend.writeDraft(record, { ...options, beforeCommit: () => gate }),
    };
    const session = createComposerDraftSession({
      backend: gated,
      debounceMs: 1,
      now: () => '2026-11-13T00:00:01.000Z',
      createId: () => 'draft-1',
      schedule: (fn) => fn,
      cancel: () => undefined,
    });
    session.sync({
      accountId: '42',
      action: { type: 'COMPOSE_CHANGE' },
      composers: [{ composerId: 'primary', state: composerWith('a') }],
    });
    const stale = session.flush();

    session.sync({
      accountId: '42',
      action: { type: 'COMPOSE_CHANGE' },
      composers: [{
        composerId: 'primary',
        state: composerWith('ab', {
          media_attachments: ImmutableList([
            ImmutableMap({ id: 'media-1', description: 'done', order: 0 }),
          ]),
        }),
      }],
    });
    release();
    await stale;
    await session.flush();

    const saved = await backend.readDraft('42', 'draft-1');

    expect(saved.input.text).toBe('ab');
    expect(saved.input.media.map(item => item.id)).toEqual(['media-1']);
    expect(saved.media_incomplete).toBe(false);
  });

  it('keeps a saved draft when the text is cleared and does not overwrite it', async () => {
    const { backend, session } = harness();

    session.sync({
      accountId: '42',
      action: { type: 'COMPOSE_CHANGE' },
      composers: [{ composerId: 'primary', state: composerWith('keep me') }],
    });
    await session.flush();
    session.sync({
      accountId: '42',
      action: { type: 'COMPOSE_CHANGE' },
      composers: [{ composerId: 'primary', state: composerWith('') }],
    });
    await session.flush();

    expect((await backend.readDraft('42', 'draft-1')).input.text).toBe('keep me');

    session.sync({
      accountId: '42',
      action: { type: 'COMPOSE_CHANGE' },
      composers: [{ composerId: 'primary', state: composerWith('keep me') }],
    });
    await session.flush();
    session.sync({
      accountId: '42',
      action: { type: 'COMPOSE_CHANGE' },
      composers: [{ composerId: 'primary', state: composerWith('fresh') }],
    });
    await session.flush();

    const texts = (await backend.listDrafts('42')).map(item => item.input.text).sort();

    expect(texts).toEqual(['fresh', 'keep me']);

    session.sync({
      accountId: '42',
      action: { type: 'COMPOSE_RESET' },
      composers: [{ composerId: 'primary', state: composerWith('') }],
    });
    await session.flush();

    expect((await backend.listDrafts('42')).map(item => item.input.text).sort()).toEqual(['keep me']);
  });

  it('deletes the discarded restored draft and keeps a different saved draft', async () => {
    const { backend, session } = harness();
    const typing = initialState.set('text', 'Hello group');
    const other = initialState.set('text', 'keep other').set('instanceId', 'portable-1');

    session.sync({
      accountId: '42',
      action: { type: 'COMPOSE_CHANGE' },
      composers: [
        { composerId: 'primary', state: typing },
        { composerId: 'portable', state: other },
      ],
    });
    await session.flush();

    const restored = composer(initialState, {
      type: 'COMPOSER_DRAFT_RESTORE',
      snapshot: {
        schema_version: 1,
        account_id: '42',
        client_draft_uuid: 'draft-1',
        input: {
          text: 'Hello group',
          in_reply_to_id: 'reply-1',
          surface: { kind: 'group', key: '123' },
          media: [{ id: 'media-1', order: 0, description: 'alt', focus: { x: 0, y: 0 } }],
        },
      },
      idempotencyKey: 'post-1',
      restoreToken: 'restore-1',
    });
    const reset = composer(restored, { type: COMPOSE_RESET });

    session.sync({
      accountId: '42',
      action: { type: COMPOSE_RESET },
      composers: [
        { composerId: 'primary', state: reset },
        { composerId: 'portable', state: other },
      ],
    });
    await session.flush();

    expect(await backend.readDraft('42', 'draft-1')).toBeNull();
    expect((await backend.readDraft('42', 'draft-2')).input.text).toBe('keep other');
  });

  it('deletes the old draft when a clear leaves an uploaded attachment', async () => {
    const { backend, session } = harness();
    const typing = initialState.set('text', 'Hello');
    const other = initialState.set('text', 'keep other').set('instanceId', 'portable-1');

    session.sync({
      accountId: '42',
      action: { type: 'COMPOSE_CHANGE' },
      composers: [
        { composerId: 'primary', state: typing },
        { composerId: 'portable', state: other },
      ],
    });
    await session.flush();

    const withMedia = composer(typing, {
      type: COMPOSE_UPLOAD_SUCCESS,
      media: { id: 'real-1', type: 'image' },
    });

    session.sync({
      accountId: '42',
      action: { type: COMPOSE_UPLOAD_SUCCESS },
      composers: [
        { composerId: 'primary', state: withMedia },
        { composerId: 'portable', state: other },
      ],
    });
    await session.flush();

    const reset = composer(withMedia, { type: COMPOSE_RESET });

    session.sync({
      accountId: '42',
      action: { type: COMPOSE_RESET },
      composers: [
        { composerId: 'primary', state: reset },
        { composerId: 'portable', state: other },
      ],
    });
    await session.flush();

    const afterReset = await backend.listDrafts('42');
    const kept = afterReset.find(item => item.input.text === 'keep other');
    const continued = afterReset.find(item => item.client_draft_uuid !== kept.client_draft_uuid);

    expect(await backend.readDraft('42', 'draft-1')).toBeNull();
    expect(kept.client_draft_uuid).toBe('draft-2');
    expect(continued.client_draft_uuid).not.toBe('draft-1');
    expect(continued.input.text).toBe('');
    expect(continued.input.media.map(item => item.id)).toEqual(['real-1']);
    expect(reset.get('media_attachments').map(item => item.get('id')).toArray()).toEqual(['real-1']);

    const typed = composer(reset, changeCompose('Next'));

    session.sync({
      accountId: '42',
      action: { type: 'COMPOSE_CHANGE' },
      composers: [
        { composerId: 'primary', state: typed },
        { composerId: 'portable', state: other },
      ],
    });
    await session.flush();

    expect(await backend.readDraft('42', 'draft-1')).toBeNull();
    expect((await backend.readDraft('42', 'draft-2')).input.text).toBe('keep other');
    expect((await backend.readDraft('42', continued.client_draft_uuid)).input.text).toBe('Next');
  });

  it('deletes the reply draft when the reply is canceled', async () => {
    const { backend, session } = harness();
    const reply = initialState.set('text', 'Hello').set('in_reply_to', 'reply-1');
    const other = initialState.set('text', 'keep other').set('instanceId', 'portable-1');

    session.sync({
      accountId: '42',
      action: { type: 'COMPOSE_CHANGE' },
      composers: [
        { composerId: 'primary', state: reply },
        { composerId: 'portable', state: other },
      ],
    });
    await session.flush();

    const canceled = composer(reply, { type: COMPOSE_REPLY_CANCEL });

    session.sync({
      accountId: '42',
      action: { type: COMPOSE_REPLY_CANCEL },
      composers: [
        { composerId: 'primary', state: canceled },
        { composerId: 'portable', state: other },
      ],
    });
    await session.flush();

    expect(canceled.get('text')).toBe('');
    expect(canceled.get('in_reply_to')).toBeNull();
    expect(await backend.readDraft('42', 'draft-1')).toBeNull();
    expect((await backend.readDraft('42', 'draft-2')).input.text).toBe('keep other');
    expect((await backend.listDrafts('42')).map(item => item.client_draft_uuid)).toEqual(['draft-2']);
  });

  it('drops an in-flight snapshot when the post succeeds or the surface is cleared', async () => {
    const backend = createMemoryDraftBackend();
    let release;
    const gate = new Promise((resolve) => {
      release = resolve;
    });
    let writes = 0;
    const gated = {
      readDraft: (...args) => backend.readDraft(...args),
      deleteDraft: (...args) => backend.deleteDraft(...args),
      listDrafts: (...args) => backend.listDrafts(...args),
      writeDraft: (record, options) => {
        writes += 1;
        const beforeCommit = writes === 1 ? undefined : () => gate;

        return backend.writeDraft(record, { ...options, beforeCommit });
      },
    };
    const session = createComposerDraftSession({
      backend: gated,
      now: () => '2026-11-13T00:00:01.000Z',
      createId: () => 'draft-1',
      schedule: (fn) => fn,
      cancel: () => undefined,
    });

    session.sync({
      accountId: '42',
      action: { type: 'COMPOSE_CHANGE' },
      composers: [{ composerId: 'primary', state: composerWith('hello') }],
    });
    await session.flush();
    session.sync({
      accountId: '42',
      action: { type: 'COMPOSE_CHANGE' },
      composers: [{ composerId: 'primary', state: composerWith('hello!') }],
    });
    const stale = session.flush();

    session.sync({
      accountId: '42',
      action: { type: COMPOSE_SUBMIT_SUCCESS },
      composers: [{ composerId: 'primary', state: composerWith('') }],
    });
    release();
    await stale;

    expect(await backend.readDraft('42', 'draft-1')).toBeNull();
  });

  it('forks instead of overwriting another tab', async () => {
    const backend = createMemoryDraftBackend();
    const left = createComposerDraftSession({
      backend,
      now: () => '2026-11-13T00:00:01.000Z',
      createId: (() => {
        let next = 0;
        return () => `left-${++next}`;
      })(),
      schedule: (fn) => fn,
      cancel: () => undefined,
    });
    const right = createComposerDraftSession({
      backend,
      now: () => '2026-11-13T00:00:02.000Z',
      createId: (() => {
        let next = 0;
        return () => `right-${++next}`;
      })(),
      schedule: (fn) => fn,
      cancel: () => undefined,
    });
    const record = {
      schema_version: 1,
      account_id: '42',
      client_draft_uuid: 'shared',
      composer_id: 'primary',
      saved_at: '2026-11-13T00:00:00.000Z',
      media_incomplete: false,
      revision: 1,
      content_hash: 'seed',
      input: { text: 'seed' },
    };

    await backend.writeDraft(record, { baseRevision: 0 });
    left.claim('shared', 'primary');
    right.claim('shared', 'primary');
    left.sync({
      accountId: '42',
      action: { type: 'COMPOSER_DRAFT_RESTORE', snapshot: record, idempotencyKey: 'adopt-left', baseRevision: 1 },
      composers: [{ composerId: 'primary', state: composerWith('seed').set('idempotencyKey', 'adopt-left') }],
    });
    right.sync({
      accountId: '42',
      action: { type: 'COMPOSER_DRAFT_RESTORE', snapshot: record, idempotencyKey: 'adopt-right', baseRevision: 1 },
      composers: [{ composerId: 'primary', state: composerWith('seed').set('idempotencyKey', 'adopt-right') }],
    });
    left.sync({
      accountId: '42',
      action: { type: 'COMPOSE_CHANGE' },
      composers: [{ composerId: 'primary', state: composerWith('left edit').set('idempotencyKey', 'adopt-left') }],
    });
    await left.flush();
    right.sync({
      accountId: '42',
      action: { type: 'COMPOSE_CHANGE' },
      composers: [{ composerId: 'primary', state: composerWith('right edit').set('idempotencyKey', 'adopt-right') }],
    });
    await right.flush();

    const shared = await backend.readDraft('42', 'shared');
    const all = await backend.listDrafts('42');

    expect(shared.input.text).toBe('left edit');
    expect(all.map(item => item.input.text).sort()).toEqual(['left edit', 'right edit']);
  });

  it('does not save a redraft or an existing-post edit', async () => {
    const { backend, session } = harness();

    session.sync({
      accountId: '42',
      action: { type: 'COMPOSE_CHANGE' },
      composers: [{ composerId: 'primary', state: composerWith('new post') }],
    });
    await session.flush();
    session.sync({
      accountId: '42',
      action: { type: REDRAFT },
      composers: [{ composerId: 'primary', state: composerWith('redrafted status') }],
    });
    await session.flush();
    session.sync({
      accountId: '42',
      action: { type: 'COMPOSE_CHANGE' },
      composers: [{ composerId: 'primary', state: composerWith('redrafted status edited') }],
    });
    await session.flush();

    expect((await backend.listDrafts('42')).map(item => item.input.text)).toEqual(['new post']);

    session.sync({
      accountId: '42',
      action: { type: COMPOSE_SET_STATUS },
      composers: [{ composerId: 'portable-a', state: composerWith('editing', { id: 'status-1', instanceId: 'composer-a' }) }],
    });
    await session.flush();

    expect((await backend.listDrafts('42')).map(item => item.input.text)).toEqual(['new post']);
  });

  it('reports quota failure without claiming the draft was saved', async () => {
    const backend = createMemoryDraftBackend();
    const quota = Object.assign(new Error('quota'), { name: 'QuotaExceededError' });
    const failing = {
      readDraft: (...args) => backend.readDraft(...args),
      deleteDraft: (...args) => backend.deleteDraft(...args),
      listDrafts: (...args) => backend.listDrafts(...args),
      writeDraft: (record, options) => backend.writeDraft(record, { ...options, failWith: quota }),
    };
    const session = createComposerDraftSession({
      backend: failing,
      now: () => '2026-11-13T00:00:01.000Z',
      createId: () => 'draft-1',
      schedule: (fn) => fn,
      cancel: () => undefined,
    });

    session.sync({
      accountId: '42',
      action: { type: 'COMPOSE_CHANGE' },
      composers: [{ composerId: 'primary', state: composerWith('hello') }],
    });
    await session.flush();

    expect(session.snapshot().persistence.primary).toEqual({
      status: 'failed',
      reason: 'quota',
      mediaIncomplete: false,
    });
    expect(await backend.readDraft('42', 'draft-1')).toBeNull();
  });

  it('flushes on pagehide', async () => {
    const backend = createMemoryDraftBackend();
    const queued = [];
    const session = createComposerDraftSession({
      backend,
      debounceMs: 300,
      now: () => '2026-11-13T00:00:01.000Z',
      createId: () => 'draft-1',
      schedule: (fn) => {
        queued.push(fn);
        return queued.length;
      },
      cancel: () => undefined,
    });
    const target = document.createElement('div');

    target.visibilityState = 'visible';
    session.bindLifecycle(target);
    session.sync({
      accountId: '42',
      action: { type: 'COMPOSE_CHANGE' },
      composers: [{ composerId: 'primary', state: composerWith('hidden') }],
    });
    expect(await backend.readDraft('42', 'draft-1')).toBeNull();
    const flushed = new Promise((resolve) => {
      const original = session.flush.bind(session);

      session.flush = () => {
        const result = original();

        resolve(result);

        return result;
      };
    });

    target.dispatchEvent(new Event('pagehide'));
    await flushed;

    expect((await backend.readDraft('42', 'draft-1')).input.text).toBe('hidden');
  });

  it('applies a delayed acknowledgement only to its own edit', async () => {
    const backend = createMemoryDraftBackend();
    let release;
    const gate = new Promise((resolve) => {
      release = resolve;
    });
    let writes = 0;
    let entered;
    const enteredGate = new Promise((resolve) => {
      entered = resolve;
    });
    const gated = {
      readDraft: (...args) => backend.readDraft(...args),
      deleteDraft: (...args) => backend.deleteDraft(...args),
      listDrafts: (...args) => backend.listDrafts(...args),
      writeDraft: (record, options) => {
        writes += 1;
        const afterCommit = writes === 1 ? async () => {
          entered();
          await gate;
        } : undefined;

        return backend.writeDraft(record, { ...options, afterCommit });
      },
    };
    let nextId = 0;
    const session = createComposerDraftSession({
      backend: gated,
      now: () => '2026-11-13T00:00:01.000Z',
      createId: () => {
        nextId += 1;
        return `draft-${nextId}`;
      },
      schedule: (fn) => fn,
      cancel: () => undefined,
    });

    session.sync({
      accountId: '42',
      action: { type: 'COMPOSE_CHANGE' },
      composers: [{ composerId: 'primary', state: composerWith('a') }],
    });
    expect(session.snapshot().persistence.primary.status).toBe('saving');
    const first = session.flush();

    await enteredGate;
    session.sync({
      accountId: '42',
      action: { type: 'COMPOSE_CHANGE' },
      composers: [{ composerId: 'primary', state: composerWith('b') }],
    });
    expect(session.snapshot().persistence.primary.status).toBe('saving');
    const second = session.flush();

    release();
    await first;
    await second;

    const saved = await backend.readDraft('42', 'draft-1');

    expect(saved.input.text).toBe('b');
    expect(saved.revision).toBe(2);
    expect(session.snapshot().persistence.primary.status).toBe('saved');

    session.sync({
      accountId: '42',
      action: { type: 'COMPOSE_CHANGE' },
      composers: [{ composerId: 'primary', state: composerWith('c') }],
    });
    await session.flush();

    const next = await backend.readDraft('42', 'draft-1');

    expect(next.input.text).toBe('c');
    expect(next.revision).toBe(3);
    expect(await backend.listDrafts('42')).toHaveLength(1);
  });

  it('does not serialize an unchanged composer for an unrelated action', () => {
    const { session } = harness();
    const state = composerWith('hello');
    let reads = 0;
    const counting = {
      get (key) {
        reads += 1;
        return state.get(key);
      },
      getIn (path) {
        reads += 1;
        return state.getIn(path);
      },
    };

    session.sync({
      accountId: '42',
      action: { type: 'COMPOSE_CHANGE' },
      composers: [{ composerId: 'primary', state: counting }],
    });
    expect(reads).toBeGreaterThan(0);
    reads = 0;
    session.sync({
      accountId: '42',
      action: { type: 'TIMELINE_UPDATE' },
      composers: [{ composerId: 'primary', state: counting }],
    });
    expect(reads).toBe(0);
    session.sync({
      accountId: '42',
      action: { type: 'COMPOSE_SUBMIT_SUCCESS' },
      composers: [{ composerId: 'primary', state: counting }],
    });
    expect(reads).toBeGreaterThan(0);
  });

  it('skips an unsupported record instead of throwing', async () => {
    const backend = createMemoryDraftBackend();

    await backend.writeDraft({
      schema_version: 99,
      account_id: '42',
      client_draft_uuid: 'old',
      revision: 1,
      content_hash: 'old',
      input: { text: 'old' },
    }, { baseRevision: 0 });
    await backend.writeDraft({
      schema_version: 1,
      account_id: '7',
      client_draft_uuid: 'other',
      revision: 1,
      content_hash: 'other',
      input: { text: 'other account' },
    }, { baseRevision: 0 });

    const session = createComposerDraftSession({
      backend,
      schedule: (fn) => fn,
      cancel: () => undefined,
    });

    await session.refreshOffers('42');

    expect(session.snapshot().offers).toEqual([]);
  });
});
