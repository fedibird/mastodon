import { List as ImmutableList, Map as ImmutableMap } from 'immutable';
import { COMPOSE_REPLY_CANCEL, COMPOSE_RESET, COMPOSE_SET_STATUS, COMPOSE_SUBMIT_FAIL, COMPOSE_SUBMIT_REQUEST, COMPOSE_SUBMIT_SUCCESS, COMPOSE_UPLOAD_SUCCESS, changeCompose, submissionSnapshot } from '../../actions/compose';
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

  it('deletes the sent draft when the composer instance changes or the composer is gone', async () => {
    const { backend, session } = harness();
    const drafted = composerWith('hello');

    session.sync({
      accountId: '42',
      action: { type: 'COMPOSE_CHANGE' },
      composers: [{ composerId: 'primary', state: drafted }],
    });
    await session.flush();
    session.sync({
      accountId: '42',
      action: { type: COMPOSE_SUBMIT_REQUEST, submitId: 'submit-1' },
      composers: [{ composerId: 'primary', state: drafted.set('is_submitting', true) }],
    });
    session.sync({
      accountId: '42',
      action: {
        type: COMPOSE_SUBMIT_SUCCESS,
        submission: submissionSnapshot(drafted, 'new', 'submit-1'),
      },
      composers: [{ composerId: 'primary', state: composerWith('', { instanceId: 'composer-2' }) }],
    });
    await session.flush();

    expect(await backend.readDraft('42', 'draft-1')).toBeNull();

    session.sync({
      accountId: '42',
      action: { type: 'COMPOSE_CHANGE' },
      composers: [{ composerId: 'primary', state: composerWith('again', { instanceId: 'composer-2' }) }],
    });
    await session.flush();
    session.sync({
      accountId: '42',
      action: { type: COMPOSE_SUBMIT_REQUEST, submitId: 'submit-2' },
      composers: [{ composerId: 'primary', state: composerWith('again', { instanceId: 'composer-2' }).set('is_submitting', true) }],
    });
    session.sync({
      accountId: '42',
      action: {
        type: COMPOSE_SUBMIT_SUCCESS,
        submission: submissionSnapshot(composerWith('again', { instanceId: 'composer-2' }), 'new', 'submit-2'),
      },
      composers: [],
    });
    await session.flush();

    expect(await backend.listDrafts('42')).toEqual([]);
  });

  it('does not let a late write put a sent draft back', async () => {
    const backend = createMemoryDraftBackend();
    let release;
    const gate = new Promise((resolve) => {
      release = resolve;
    });
    let writes = 0;
    const hostile = {
      readDraft: (...args) => backend.readDraft(...args),
      deleteDraft: (...args) => backend.deleteDraft(...args),
      listDrafts: (...args) => backend.listDrafts(...args),
      writeDraft: (record, options) => {
        writes += 1;

        if (writes === 1) {
          return backend.writeDraft(record, options);
        }

        return gate.then(() => backend.writeDraft(record, { baseRevision: options.baseRevision }));
      },
    };
    const session = createComposerDraftSession({
      backend: hostile,
      now: () => '2026-11-14T00:00:01.000Z',
      createId: () => 'draft-1',
      schedule: (fn) => fn,
      cancel: () => undefined,
    });
    const drafted = composerWith('hello');

    session.sync({
      accountId: '42',
      action: { type: 'COMPOSE_CHANGE' },
      composers: [{ composerId: 'primary', state: drafted }],
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
      action: {
        type: COMPOSE_SUBMIT_SUCCESS,
        submission: submissionSnapshot(drafted, 'new', 'submit-1'),
      },
      composers: [{ composerId: 'primary', state: composerWith('') }],
    });
    release();
    await stale;
    await session.flush();

    expect(await backend.readDraft('42', 'draft-1')).toBeNull();
    expect(await backend.listDrafts('42')).toEqual([]);
  });

  function portableSession () {
    const backend = createMemoryDraftBackend();
    const queued = [];
    const session = createComposerDraftSession({
      backend,
      now: () => '2026-11-14T00:00:04.000Z',
      createId: (() => {
        let next = 0;

        return () => {
          next += 1;
          return `draft-${next}`;
        };
      })(),
      schedule: (fn) => {
        queued.push(fn);
        return queued.length;
      },
      cancel: (id) => {
        queued[id - 1] = null;
      },
    });

    return { backend, session, queued };
  }

  async function runQueued (session, queued) {
    const pending = [];

    queued.forEach((fn, index) => {
      if (typeof fn === 'function') {
        pending.push(fn);
        queued[index] = null;
      }
    });
    pending.forEach(fn => fn());
    await session.flush();
  }

  it('saves a reopened composer when an older submit for that composer succeeds', async () => {
    const { backend, session, queued } = portableSession();
    const composerId = 'portable';
    const postA = composerWith('post A', { instanceId: 'instance-a', idempotencyKey: 'token-a' });
    const postB = composerWith('post B', { instanceId: 'instance-b', idempotencyKey: 'token-b' });

    session.sync({
      accountId: '42',
      action: { type: 'COMPOSE_CHANGE', meta: { composerId } },
      composers: [{ composerId, state: postA }],
    });
    await runQueued(session, queued);
    session.sync({
      accountId: '42',
      action: { type: COMPOSE_SUBMIT_REQUEST, submitId: 'submit-1', meta: { composerId } },
      composers: [{ composerId, state: postA.set('is_submitting', true) }],
    });
    session.sync({
      accountId: '42',
      action: { type: 'COMPOSER_DESTROY', meta: { composerId } },
      composers: [],
    });
    session.sync({
      accountId: '42',
      action: { type: 'COMPOSE_CHANGE', meta: { composerId } },
      composers: [{ composerId, state: postB }],
    });

    const pendingSave = queued.filter(fn => typeof fn === 'function');

    expect(pendingSave).toHaveLength(1);

    session.sync({
      accountId: '42',
      action: {
        type: COMPOSE_SUBMIT_SUCCESS,
        submission: submissionSnapshot(postA, 'new', 'submit-1'),
        meta: { composerId },
      },
      composers: [{ composerId, state: postB }],
    });
    expect(queued.filter(fn => typeof fn === 'function')).toHaveLength(1);
    await runQueued(session, queued);

    expect((await backend.listDrafts('42')).map(item => item.input.text)).toEqual(['post B']);
  });

  it('deletes only the submit that succeeded when two submits share a composer id', async () => {
    const { backend, session } = harness();
    const composerId = 'portable';
    const postA = composerWith('post A', { instanceId: 'instance-a', idempotencyKey: 'token-a' });
    const postB = composerWith('post B', { instanceId: 'instance-b', idempotencyKey: 'token-b' });

    session.sync({
      accountId: '42',
      action: { type: 'COMPOSE_CHANGE', meta: { composerId } },
      composers: [{ composerId, state: postA }],
    });
    await session.flush();
    session.sync({
      accountId: '42',
      action: { type: COMPOSE_SUBMIT_REQUEST, submitId: 'submit-1', meta: { composerId } },
      composers: [{ composerId, state: postA.set('is_submitting', true) }],
    });
    session.sync({
      accountId: '42',
      action: { type: 'COMPOSER_DESTROY', meta: { composerId } },
      composers: [],
    });
    session.sync({
      accountId: '42',
      action: { type: 'COMPOSE_CHANGE', meta: { composerId } },
      composers: [{ composerId, state: postB }],
    });
    await session.flush();
    session.sync({
      accountId: '42',
      action: { type: COMPOSE_SUBMIT_REQUEST, submitId: 'submit-2', meta: { composerId } },
      composers: [{ composerId, state: postB.set('is_submitting', true) }],
    });
    session.sync({
      accountId: '42',
      action: { type: COMPOSE_SUBMIT_FAIL, submitId: 'submit-1', meta: { composerId } },
      composers: [{ composerId, state: postB }],
    });
    await session.flush();

    expect((await backend.listDrafts('42')).map(item => item.input.text).sort()).toEqual(['post A', 'post B']);

    session.sync({
      accountId: '42',
      action: {
        type: COMPOSE_SUBMIT_SUCCESS,
        submission: submissionSnapshot(postA, 'new', 'submit-1'),
        meta: { composerId },
      },
      composers: [{ composerId, state: postB }],
    });
    await session.flush();

    expect((await backend.listDrafts('42')).map(item => item.input.text)).toEqual(['post B']);

    session.sync({
      accountId: '42',
      action: {
        type: COMPOSE_SUBMIT_SUCCESS,
        submission: submissionSnapshot(postB.set('is_submitting', true), 'new', 'submit-2'),
        meta: { composerId },
      },
      composers: [{ composerId, state: postB.set('text', '') }],
    });
    await session.flush();

    expect(await backend.listDrafts('42')).toEqual([]);
  });

  it('deletes each sent draft when the newer submit finishes first', async () => {
    const { backend, session } = harness();
    const composerId = 'portable';
    const postA = composerWith('post A', { instanceId: 'instance-a', idempotencyKey: 'token-a' });
    const postB = composerWith('post B', { instanceId: 'instance-b', idempotencyKey: 'token-b' });

    session.sync({
      accountId: '42',
      action: { type: 'COMPOSE_CHANGE', meta: { composerId } },
      composers: [{ composerId, state: postA }],
    });
    await session.flush();
    session.sync({
      accountId: '42',
      action: { type: COMPOSE_SUBMIT_REQUEST, submitId: 'submit-1', meta: { composerId } },
      composers: [{ composerId, state: postA.set('is_submitting', true) }],
    });
    session.sync({
      accountId: '42',
      action: { type: 'COMPOSER_DESTROY', meta: { composerId } },
      composers: [],
    });
    session.sync({
      accountId: '42',
      action: { type: 'COMPOSE_CHANGE', meta: { composerId } },
      composers: [{ composerId, state: postB }],
    });
    await session.flush();
    session.sync({
      accountId: '42',
      action: { type: COMPOSE_SUBMIT_REQUEST, submitId: 'submit-2', meta: { composerId } },
      composers: [{ composerId, state: postB.set('is_submitting', true) }],
    });
    session.sync({
      accountId: '42',
      action: {
        type: COMPOSE_SUBMIT_SUCCESS,
        submission: submissionSnapshot(postB.set('is_submitting', true), 'new', 'submit-2'),
        meta: { composerId },
      },
      composers: [{ composerId, state: postB.set('text', '') }],
    });
    await session.flush();

    expect((await backend.listDrafts('42')).map(item => item.input.text)).toEqual(['post A']);

    session.sync({
      accountId: '42',
      action: {
        type: COMPOSE_SUBMIT_SUCCESS,
        submission: submissionSnapshot(postA, 'new', 'submit-1'),
        meta: { composerId },
      },
      composers: [{ composerId, state: postB.set('text', '') }],
    });
    await session.flush();

    expect(await backend.listDrafts('42')).toEqual([]);
  });

  function restoreSentDraft (composerId, clientDraftUuid, idempotencyKey) {
    return {
      type: 'COMPOSER_DRAFT_RESTORE',
      meta: { composerId },
      snapshot: {
        schema_version: 1,
        account_id: '42',
        client_draft_uuid: clientDraftUuid,
        content_hash: 'sent',
        input: { text: 'post A' },
      },
      idempotencyKey,
      baseRevision: 1,
    };
  }

  async function closeWhileSending (session, composerId, state, submitId) {
    session.sync({
      accountId: '42',
      action: { type: 'COMPOSE_CHANGE', meta: { composerId } },
      composers: [{ composerId, state }],
    });
    await session.flush();
    session.sync({
      accountId: '42',
      action: { type: COMPOSE_SUBMIT_REQUEST, submitId, meta: { composerId } },
      composers: [{ composerId, state: state.set('is_submitting', true) }],
    });
    session.sync({
      accountId: '42',
      action: { type: 'COMPOSER_DESTROY', meta: { composerId } },
      composers: [],
    });
  }

  it('keeps an edit on another composer when it restores a draft that is still being sent', async () => {
    const { backend, session } = harness();
    const sent = composerWith('post A', { instanceId: 'instance-a', idempotencyKey: 'token-a' });
    const edited = composerWith('post B edited', { instanceId: 'instance-b', idempotencyKey: 'restore-b' });

    await closeWhileSending(session, 'portable-a', sent, 'submit-1');

    const sentDraft = (await backend.listDrafts('42'))[0];

    expect(session.claim(sentDraft.client_draft_uuid, 'portable-b')).toBe(false);
    expect((await session.refreshOffers('42')).map(item => item.client_draft_uuid)).not.toContain(sentDraft.client_draft_uuid);

    session.sync({
      accountId: '42',
      action: restoreSentDraft('portable-b', sentDraft.client_draft_uuid, 'restore-b'),
      composers: [{ composerId: 'portable-b', state: composerWith('post A', { instanceId: 'instance-b', idempotencyKey: 'restore-b' }) }],
    });
    await session.flush();
    session.sync({
      accountId: '42',
      action: { type: 'COMPOSE_CHANGE', meta: { composerId: 'portable-b' } },
      composers: [{ composerId: 'portable-b', state: edited }],
    });
    await session.flush();

    expect((await backend.listDrafts('42')).map(item => item.input.text).sort()).toEqual(['post A', 'post B edited']);
    expect((await session.refreshOffers('42')).map(item => item.client_draft_uuid)).not.toContain(sentDraft.client_draft_uuid);

    session.sync({
      accountId: '42',
      action: {
        type: COMPOSE_SUBMIT_SUCCESS,
        submission: submissionSnapshot(sent, 'new', 'submit-1'),
        meta: { composerId: 'portable-a' },
      },
      composers: [{ composerId: 'portable-b', state: edited }],
    });
    await session.flush();

    const remaining = await backend.listDrafts('42');

    expect(remaining.map(item => item.input.text)).toEqual(['post B edited']);
    expect(remaining.map(item => item.client_draft_uuid)).not.toContain(sentDraft.client_draft_uuid);
  });

  it('keeps a delayed edit on another composer when the older submit succeeds or fails', async () => {
    const { backend, session, queued } = portableSession();
    const sent = composerWith('post A', { instanceId: 'instance-a', idempotencyKey: 'token-a' });
    const restored = composerWith('post A', { instanceId: 'instance-b', idempotencyKey: 'restore-b' });
    const edited = composerWith('post B edited', { instanceId: 'instance-b', idempotencyKey: 'restore-b' });

    session.sync({
      accountId: '42',
      action: { type: 'COMPOSE_CHANGE', meta: { composerId: 'portable-a' } },
      composers: [{ composerId: 'portable-a', state: sent }],
    });
    await runQueued(session, queued);
    session.sync({
      accountId: '42',
      action: { type: COMPOSE_SUBMIT_REQUEST, submitId: 'submit-1', meta: { composerId: 'portable-a' } },
      composers: [{ composerId: 'portable-a', state: sent.set('is_submitting', true) }],
    });
    session.sync({
      accountId: '42',
      action: { type: 'COMPOSER_DESTROY', meta: { composerId: 'portable-a' } },
      composers: [],
    });

    const sentId = (await backend.listDrafts('42'))[0].client_draft_uuid;

    expect(session.claim(sentId, 'portable-b')).toBe(false);

    session.sync({
      accountId: '42',
      action: restoreSentDraft('portable-b', sentId, 'restore-b'),
      composers: [{ composerId: 'portable-b', state: restored }],
    });
    session.sync({
      accountId: '42',
      action: { type: 'COMPOSE_CHANGE', meta: { composerId: 'portable-b' } },
      composers: [{ composerId: 'portable-b', state: edited }],
    });
    expect(queued.filter(fn => typeof fn === 'function')).toHaveLength(1);

    session.sync({
      accountId: '42',
      action: { type: COMPOSE_SUBMIT_FAIL, submitId: 'submit-1', meta: { composerId: 'portable-a' } },
      composers: [{ composerId: 'portable-b', state: edited }],
    });
    expect(queued.filter(fn => typeof fn === 'function')).toHaveLength(1);
    await runQueued(session, queued);

    expect((await backend.listDrafts('42')).map(item => item.input.text).sort()).toEqual(['post A', 'post B edited']);
    expect((await session.refreshOffers('42')).map(item => item.client_draft_uuid)).toContain(sentId);

    session.sync({
      accountId: '42',
      action: { type: 'COMPOSE_CHANGE', meta: { composerId: 'portable-b' } },
      composers: [{ composerId: 'portable-b', state: edited.set('text', 'post B later') }],
    });
    session.sync({
      accountId: '42',
      action: {
        type: COMPOSE_SUBMIT_SUCCESS,
        submission: submissionSnapshot(sent, 'new', 'submit-1'),
        meta: { composerId: 'portable-a' },
      },
      composers: [{ composerId: 'portable-b', state: edited.set('text', 'post B later') }],
    });
    expect(queued.filter(fn => typeof fn === 'function')).toHaveLength(1);
    await runQueued(session, queued);

    const remaining = await backend.listDrafts('42');

    expect(remaining.map(item => item.input.text)).toEqual(['post B later']);
    expect(remaining.map(item => item.client_draft_uuid)).not.toContain(sentId);
  });

  function tabSession (backend, prefix) {
    let next = 0;

    return createComposerDraftSession({
      backend,
      now: () => '2026-11-14T00:00:08.000Z',
      createId: () => {
        next += 1;
        return `${prefix}-${next}`;
      },
      schedule: (fn) => fn,
      cancel: () => undefined,
    });
  }

  async function sharedDraftTabs () {
    const backend = createMemoryDraftBackend();
    const left = tabSession(backend, 'left');
    const right = tabSession(backend, 'right');
    const posted = composerWith('original', { instanceId: 'composer-1', idempotencyKey: 'token-a' });
    const other = composerWith('keep other', { instanceId: 'composer-2', idempotencyKey: 'token-other' });

    left.sync({
      accountId: '42',
      action: { type: 'COMPOSE_CHANGE' },
      composers: [
        { composerId: 'primary', state: posted },
        { composerId: 'portable', state: other },
      ],
    });
    await left.flush();

    const saved = await backend.readDraft('42', 'left-1');

    right.claim(saved.client_draft_uuid, 'primary');
    right.sync({
      accountId: '42',
      action: {
        type: 'COMPOSER_DRAFT_RESTORE',
        snapshot: saved,
        idempotencyKey: 'right-key',
        baseRevision: saved.revision,
      },
      composers: [{ composerId: 'primary', state: composerWith('original', { idempotencyKey: 'right-key' }) }],
    });

    return { backend, left, right, posted };
  }

  it('keeps another tab’s newer save when the sent draft is posted', async () => {
    const { backend, left, right, posted } = await sharedDraftTabs();
    const edited = composerWith('from the other tab', { idempotencyKey: 'right-key' });

    left.sync({
      accountId: '42',
      action: { type: COMPOSE_SUBMIT_REQUEST, submitId: 'submit-1' },
      composers: [
        { composerId: 'primary', state: posted.set('is_submitting', true) },
        { composerId: 'portable', state: composerWith('keep other', { instanceId: 'composer-2', idempotencyKey: 'token-other' }) },
      ],
    });
    right.sync({
      accountId: '42',
      action: { type: 'COMPOSE_CHANGE' },
      composers: [{ composerId: 'primary', state: edited }],
    });
    await right.flush();
    left.sync({
      accountId: '42',
      action: {
        type: COMPOSE_SUBMIT_SUCCESS,
        submission: submissionSnapshot(posted, 'new', 'submit-1'),
      },
      composers: [
        { composerId: 'primary', state: composerWith('', { instanceId: 'composer-1', idempotencyKey: 'token-a' }) },
        { composerId: 'portable', state: composerWith('keep other', { instanceId: 'composer-2', idempotencyKey: 'token-other' }) },
      ],
    });
    await left.flush();

    const reloaded = tabSession(backend, 'reloaded');
    const kept = await backend.readDraft('42', 'left-1');

    expect(kept.input.text).toBe('from the other tab');
    expect(kept.revision).toBe(2);
    expect((await reloaded.refreshOffers('42')).map(item => item.client_draft_uuid)).toContain('left-1');
    expect((await backend.listDrafts('42')).map(item => item.input.text).sort()).toEqual(['from the other tab', 'keep other']);
  });

  it('forks the other tab when the sent draft is deleted before that tab saves', async () => {
    const { backend, left, right, posted } = await sharedDraftTabs();

    left.sync({
      accountId: '42',
      action: { type: COMPOSE_SUBMIT_REQUEST, submitId: 'submit-1' },
      composers: [{ composerId: 'primary', state: posted.set('is_submitting', true) }],
    });
    left.sync({
      accountId: '42',
      action: {
        type: COMPOSE_SUBMIT_SUCCESS,
        submission: submissionSnapshot(posted, 'new', 'submit-1'),
      },
      composers: [{ composerId: 'primary', state: composerWith('', { instanceId: 'composer-1', idempotencyKey: 'token-a' }) }],
    });
    await left.flush();

    expect(await backend.readDraft('42', 'left-1')).toBeNull();

    right.sync({
      accountId: '42',
      action: { type: 'COMPOSE_CHANGE' },
      composers: [{ composerId: 'primary', state: composerWith('from the other tab', { idempotencyKey: 'right-key' }) }],
    });
    await right.flush();

    const remaining = await backend.listDrafts('42');

    expect(remaining.map(item => item.input.text).sort()).toEqual(['from the other tab', 'keep other']);
    expect(remaining.map(item => item.client_draft_uuid)).not.toContain('left-1');
  });

  it('deletes the sent draft when the other tab has not changed it and leaves a failed submit stored', async () => {
    const unchanged = await sharedDraftTabs();

    unchanged.left.sync({
      accountId: '42',
      action: { type: COMPOSE_SUBMIT_REQUEST, submitId: 'submit-1' },
      composers: [{ composerId: 'primary', state: unchanged.posted.set('is_submitting', true) }],
    });
    unchanged.left.sync({
      accountId: '42',
      action: {
        type: COMPOSE_SUBMIT_SUCCESS,
        submission: submissionSnapshot(unchanged.posted, 'new', 'submit-1'),
      },
      composers: [{ composerId: 'primary', state: composerWith('', { instanceId: 'composer-1', idempotencyKey: 'token-a' }) }],
    });
    await unchanged.left.flush();

    expect(await unchanged.backend.readDraft('42', 'left-1')).toBeNull();
    expect((await unchanged.backend.listDrafts('42')).map(item => item.input.text)).toEqual(['keep other']);

    const failed = await sharedDraftTabs();
    const edited = composerWith('from the other tab', { idempotencyKey: 'right-key' });

    failed.right.sync({
      accountId: '42',
      action: { type: 'COMPOSE_CHANGE' },
      composers: [{ composerId: 'primary', state: edited }],
    });
    await failed.right.flush();
    failed.left.sync({
      accountId: '42',
      action: { type: COMPOSE_SUBMIT_REQUEST, submitId: 'submit-1' },
      composers: [{ composerId: 'primary', state: failed.posted.set('is_submitting', true) }],
    });
    failed.left.sync({
      accountId: '42',
      action: { type: COMPOSE_SUBMIT_FAIL, submitId: 'submit-1' },
      composers: [{ composerId: 'primary', state: failed.posted.set('is_submitting', false) }],
    });
    await failed.left.flush();

    expect((await failed.backend.readDraft('42', 'left-1')).input.text).toBe('from the other tab');
    expect((await failed.backend.listDrafts('42')).map(item => item.input.text).sort()).toEqual(['from the other tab', 'keep other']);
  });

  it('deletes the saved draft when a newer edit is posted before its save timer', async () => {
    const { backend, session, queued } = portableSession();
    const saved = composerWith('old', { idempotencyKey: 'token-a' });
    const posted = composerWith('new', { idempotencyKey: 'token-a' });

    session.sync({
      accountId: '42',
      action: { type: 'COMPOSE_CHANGE' },
      composers: [{ composerId: 'primary', state: saved }],
    });
    await runQueued(session, queued);

    const stored = await backend.readDraft('42', 'draft-1');

    expect(stored.input.text).toBe('old');
    expect(stored.revision).toBe(1);

    session.sync({
      accountId: '42',
      action: { type: 'COMPOSE_CHANGE' },
      composers: [{ composerId: 'primary', state: posted }],
    });
    expect(queued.filter(fn => typeof fn === 'function')).toHaveLength(1);

    session.sync({
      accountId: '42',
      action: { type: COMPOSE_SUBMIT_REQUEST, submitId: 'submit-1' },
      composers: [{ composerId: 'primary', state: posted.set('is_submitting', true) }],
    });
    session.sync({
      accountId: '42',
      action: {
        type: COMPOSE_SUBMIT_SUCCESS,
        submission: submissionSnapshot(posted, 'new', 'submit-1'),
      },
      composers: [{ composerId: 'primary', state: composerWith('', { idempotencyKey: 'token-a' }) }],
    });
    await session.flush();

    expect(await backend.readDraft('42', 'draft-1')).toBeNull();
    expect(await backend.listDrafts('42')).toEqual([]);

    const reloaded = createComposerDraftSession({
      backend,
      now: () => '2026-11-14T00:00:09.000Z',
      createId: () => 'reloaded',
      schedule: (fn) => fn,
      cancel: () => undefined,
    });

    expect(await reloaded.refreshOffers('42')).toEqual([]);
  });
});
