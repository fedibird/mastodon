import { List as ImmutableList, Map as ImmutableMap, Set as ImmutableSet, fromJS } from 'immutable';
import { COMPOSE_RESET, COMPOSE_UPLOAD_SUCCESS, changeCompose, changeComposeLanguage, changeComposeSearchability, changeComposeVisibility } from '../../actions/compose';
import { applyComposerPostingContext, COMPOSER_DRAFT_RESTORE } from '../../actions/composer';
import { fileDropBlockFromComposer } from '../../features/compose/composer_drop';
import { groupPostingContext } from '../../posting_context/fixtures/group_context_fixture';
import { materializeComposerText } from '../../posting_context/materialize';
import composer, { initialState } from '../../reducers/composer';
import {
  applyComposerDraft,
  composerDraftHasPersistableInput,
  composerDraftRestoreBlocksSubmit,
  copyComposerDraftSnapshot,
  restoreComposerDraft,
  snapshotComposerDraft,
} from '../snapshot';

const style = fromJS({
  id: 'style-1',
  name: 'サークル告知',
  revision: 4,
  target: { kind: 'group', accountId: '123', hashtag: null, label: 'localsquad' },
  defaults: { visibility: 'private', sensitive: true },
  managed: {
    hashtags: [{ name: 'fedibird', normalizedName: 'fedibird', enforcement: 'advisory' }],
  },
});

function drafted () {
  let state = composer(initialState, changeCompose('Hello'));

  state = composer(state, changeComposeVisibility('unlisted'));
  state = composer(state, changeComposeSearchability('private'));
  state = composer(state, changeComposeLanguage('ja'));
  state = composer(state, applyComposerPostingContext('primary', groupPostingContext, '123'));
  state = state.withMutations((map) => {
    map.set('spoiler', true);
    map.set('spoiler_text', 'note');
    map.set('sensitive', true);
    map.set('circle_id', 'circle-7');
    map.set('in_reply_to', 'reply-1');
    map.set('quote_from', 'quote-1');
    map.set('quote_from_url', 'https://example.test/quote');
    map.set('references', ImmutableSet(['ref-b', 'ref-a']));
    map.set('context_references', ImmutableSet(['ctx-1']));
    map.set('ignore_reference_check', true);
    map.set('poll', ImmutableMap({
      options: ImmutableList(['red', 'blue']),
      expires_in: 3600,
      multiple: true,
    }));
    map.set('scheduled', '2026-12-01 09:00');
    map.set('expires', '2026-12-02 09:00');
    map.set('expires_action', 'delete');
    map.set('media_attachments', ImmutableList([
      ImmutableMap({
        id: 'media-2',
        description: 'second',
        order: 1,
        meta: ImmutableMap({ focus: ImmutableMap({ x: 0.2, y: -0.4 }) }),
      }),
      ImmutableMap({
        id: 'media-1',
        description: 'first',
        order: 0,
        meta: ImmutableMap({ focus: ImmutableMap({ x: 0, y: 1 }) }),
      }),
    ]));
    map.setIn(['context', 'suppressions', 'hashtags'], ImmutableSet(['fedibird']));
    map.set('surface', ImmutableMap({ kind: 'group', key: '123' }));
    map.setIn(['userPostingStyle', 'selectedId'], 'style-1');
    map.setIn(['userPostingStyle', 'appliedRevision'], 4);
    map.setIn(['userPostingStyle', 'usageMode'], 'keep');
    map.setIn(['userPostingStyle', 'selectionKind'], 'style');
    map.setIn(['userPostingStyle', 'selectionOrigin'], 'manual');
    map.setIn(['userPostingStyle', 'manualFields'], ImmutableSet(['privacy', 'language']));
    map.setIn(['userPostingStyle', 'manualValues'], ImmutableMap({ privacy: 'unlisted', language: 'ja' }));
    map.setIn(['userPostingStyle', 'suppressions'], ImmutableSet(['style:fedibird']));
    map.setIn(['userPostingStyle', 'snapshot'], style);
    map.setIn(['userPostingStyle', 'destinationSource'], 'style');
    map.setIn(['userPostingStyle', 'destinationPolicy'], 'locked');
    map.setIn(['userPostingStyle', 'destinationAccountId'], '123');
    map.setIn(['userPostingStyle', 'destinationStatus'], 'ready');
    map.setIn(['senderIdentity', 'id'], 'delegated:9');
    map.setIn(['senderIdentity', 'selectionOrigin'], 'explicit');
    map.set('suggestions', ImmutableList(['nope']));
    map.set('is_submitting', true);
    map.set('idempotencyKey', 'sent-key');
    map.set('instanceId', 'composer-9');
    map.set('draftGeneration', 4);
  });

  return state;
}

describe('composer draft snapshot', () => {
  it('round-trips raw input without saving transient composer state', () => {
    const state = drafted();
    const snapshot = snapshotComposerDraft(state, {
      accountId: '42',
      clientDraftUuid: 'draft-1',
      composerId: 'primary',
      savedAt: '2026-11-13T00:00:00.000Z',
    });
    const restored = restoreComposerDraft(JSON.stringify(snapshot));
    const fresh = composer(undefined, { type: '@@INIT' });
    const applied = composer(fresh, {
      type: COMPOSER_DRAFT_RESTORE,
      snapshot: restored.snapshot,
      idempotencyKey: 'next-key',
    });

    expect(restored.ok).toBe(true);
    expect(snapshot.schema_version).toBe(1);
    expect(JSON.stringify(snapshot)).not.toContain('sent-key');
    expect(JSON.stringify(snapshot)).not.toContain('composer-9');
    expect(JSON.stringify(snapshot)).not.toContain('suggestions');
    expect(applied.get('text')).toBe('Hello');
    expect(applied.get('spoiler_text')).toBe('note');
    expect(applied.get('privacy')).toBe('unlisted');
    expect(applied.get('searchability')).toBe('private');
    expect(applied.get('circle_id')).toBe('circle-7');
    expect(applied.get('language')).toBe('ja');
    expect(applied.get('sensitive')).toBe(true);
    expect(applied.get('in_reply_to')).toBe('reply-1');
    expect(applied.get('quote_from')).toBe('quote-1');
    expect(applied.get('quote_from_url')).toBe('https://example.test/quote');
    expect(applied.get('references').toArray().sort()).toEqual(['ref-a', 'ref-b']);
    expect(applied.getIn(['poll', 'options']).toArray()).toEqual(['red', 'blue']);
    expect(applied.getIn(['poll', 'multiple'])).toBe(true);
    expect(applied.getIn(['poll', 'expires_in'])).toBe(3600);
    expect(applied.get('scheduled')).toBe('2026-12-01 09:00');
    expect(applied.get('expires')).toBe('2026-12-02 09:00');
    expect(applied.get('expires_action')).toBe('delete');
    expect(applied.get('media_attachments').map(item => item.get('id')).toArray()).toEqual(['media-1', 'media-2']);
    expect(applied.getIn(['media_attachments', 0, 'unresolved'])).toBe(true);
    expect(applied.getIn(['media_attachments', 0, 'type'])).toBeUndefined();
    expect(applied.get('draftReplyHold')).toBe('pending');
    expect(applied.get('draftQuoteHold')).toBe('pending');
    expect(applied.get('surfaceMismatch')).toBe(true);
    expect(applied.get('draftSurfaceUnconfirmed')).toBe(true);
    expect(applied.getIn(['media_attachments', 0, 'description'])).toBe('first');
    expect(applied.getIn(['media_attachments', 1, 'meta', 'focus', 'y'])).toBe(-0.4);
    expect(applied.getIn(['context', 'source', 'revision'])).toBe(1);
    expect(applied.getIn(['context', 'managed', 'mentions', 0, 'acct'])).toBe('group');
    expect(applied.getIn(['context', 'suppressions', 'hashtags']).includes('fedibird')).toBe(true);
    expect(applied.getIn(['userPostingStyle', 'selectedId'])).toBe('style-1');
    expect(applied.getIn(['userPostingStyle', 'appliedRevision'])).toBe(4);
    expect(applied.getIn(['userPostingStyle', 'usageMode'])).toBe('keep');
    expect(applied.getIn(['userPostingStyle', 'manualFields']).includes('privacy')).toBe(true);
    expect(applied.getIn(['userPostingStyle', 'snapshot', 'name'])).toBe('サークル告知');
    expect(applied.getIn(['senderIdentity', 'id'])).toBe('delegated:9');
    expect(applied.getIn(['senderIdentity', 'selectionOrigin'])).toBe('explicit');
    expect(applied.get('posting_context_account_id')).toBe('123');
    expect(applied.getIn(['surface', 'kind'])).toBe('group');
    expect(applied.get('suggestions').size).toBe(0);
    expect(applied.get('is_submitting')).toBe(false);
    expect(applied.get('idempotencyKey')).toBe('next-key');
    expect(applied.get('instanceId')).toBe(fresh.get('instanceId'));
    expect(applied.get('draftGeneration')).toBe((fresh.get('draftGeneration') || 0) + 1);
    expect(applied.get('redraftEpoch')).toBe((fresh.get('redraftEpoch') || 0) + 1);
    expect(applied.getIn(['senderIdentity', 'changeEpoch'])).toBe((fresh.getIn(['senderIdentity', 'changeEpoch']) || 0) + 1);
  });

  it('holds a restored draft when the open surface has a different destination', () => {
    const snapshot = snapshotComposerDraft(drafted(), { accountId: '42', clientDraftUuid: 'draft-1' });
    const screen = initialState.merge({
      surface: ImmutableMap({ kind: 'group', key: '456' }),
      displayedSurface: ImmutableMap({ kind: 'group', key: '456' }),
      posting_context_account_id: '456',
      context: initialState.get('context').set('key', 'builtin:fedibird-group:456'),
    });
    const applied = applyComposerDraft(screen, snapshot, { idempotencyKey: 'next-key' });

    expect(applied.get('text')).toBe('Hello');
    expect(applied.getIn(['surface', 'key'])).toBe('123');
    expect(applied.get('surfaceMismatch')).toBe(true);
    expect(applied.getIn(['displayedSurface', 'key'])).toBe('456');
    expect(applied.getIn(['pendingSurface', 'key'])).toBe('456');
    expect(applied.getIn(['pendingSurface', 'postingContext']).key).toBe('builtin:fedibird-group:456');

    const sameScreen = initialState.merge({
      surface: ImmutableMap({ kind: 'group', key: '123' }),
      displayedSurface: ImmutableMap({ kind: 'group', key: '123' }),
    });
    const matching = applyComposerDraft(sameScreen, snapshot, { idempotencyKey: 'next-key' });

    expect(matching.get('surfaceMismatch')).toBe(false);
    expect(matching.get('pendingSurface')).toBeNull();
    expect(matching.get('draftSurfaceUnconfirmed')).toBe(false);

    const hashtag = {
      ...snapshot,
      input: {
        ...snapshot.input,
        surface: { kind: 'hashtag', key: 'fedibird' },
      },
    };
    const onPrimary = applyComposerDraft(initialState, snapshot, { idempotencyKey: 'next-key', restoreToken: 'restore-1' });
    const hashtagOnPrimary = applyComposerDraft(initialState, hashtag, { idempotencyKey: 'next-key', restoreToken: 'restore-2' });
    const confirmed = composer(onPrimary, { type: 'COMPOSER_DRAFT_SURFACE_CONFIRM', kind: 'group', key: '123' });
    const moved = composer(onPrimary, {
      type: 'COMPOSER_CONTEXT_APPLY',
      surface: { kind: 'group', key: '456' },
      surfaceEpoch: (onPrimary.get('surfaceEpoch') || 0) + 1,
      postingContext: { key: 'builtin:fedibird-group:456' },
      hasPostingContext: true,
    });
    const staleConfirm = composer(moved, { type: 'COMPOSER_DRAFT_SURFACE_CONFIRM', kind: 'group', key: '123' });

    expect(onPrimary.get('surfaceMismatch')).toBe(true);
    expect(onPrimary.get('draftSurfaceUnconfirmed')).toBe(true);
    expect(onPrimary.getIn(['draftSurfaceConfirm', 'key'])).toBe('123');
    expect(onPrimary.getIn(['surface', 'kind'])).toBe('group');
    expect(onPrimary.get('pendingSurface')).toBeNull();
    expect(hashtagOnPrimary.get('draftSurfaceUnconfirmed')).toBe(true);
    expect(hashtagOnPrimary.getIn(['surface', 'kind'])).toBe('hashtag');
    expect(confirmed.get('surfaceMismatch')).toBe(false);
    expect(confirmed.get('draftSurfaceUnconfirmed')).toBe(false);
    expect(confirmed.getIn(['surface', 'key'])).toBe('123');
    expect(moved.get('surfaceMismatch')).toBe(true);
    expect(moved.getIn(['pendingSurface', 'key'])).toBe('456');
    expect(moved.getIn(['displayedSurface', 'key'])).toBe('456');
    expect(moved.getIn(['surface', 'key'])).toBe('123');
    expect(staleConfirm.get('surfaceMismatch')).toBe(true);
    expect(staleConfirm.get('draftSurfaceUnconfirmed')).toBe(true);
    expect(staleConfirm.getIn(['surface', 'key'])).toBe('123');
    expect(staleConfirm.getIn(['pendingSurface', 'key'])).toBe('456');
  });

  it('keeps a loaded reply target and ignores a target for a different restore', () => {
    const snapshot = snapshotComposerDraft(drafted(), { accountId: '42', clientDraftUuid: 'draft-1' });
    const restored = composer(initialState, {
      type: COMPOSER_DRAFT_RESTORE,
      snapshot,
      idempotencyKey: 'next-key',
      restoreToken: 'restore-1',
    });
    const typed = composer(restored, changeCompose('Hello!'));
    const ready = composer(typed, {
      type: 'COMPOSER_DRAFT_TARGET',
      role: 'reply',
      hold: null,
      targetId: 'reply-1',
      replyStatus: { id: 'reply-1', visibility: 'public' },
      restoreToken: 'restore-1',
    });
    const ignored = composer(ready, {
      type: 'COMPOSER_DRAFT_TARGET',
      role: 'reply',
      hold: 'failed',
      targetId: 'reply-1',
      restoreToken: 'restore-2',
    });
    const moved = ready.set('in_reply_to', 'other').set('draftReplyHold', 'pending');
    const staleTarget = composer(moved, {
      type: 'COMPOSER_DRAFT_TARGET',
      role: 'reply',
      hold: null,
      targetId: 'reply-1',
      restoreToken: 'restore-1',
    });

    expect(typed.get('idempotencyKey')).not.toBe('next-key');
    expect(typed.get('draftRestoreToken')).toBe('restore-1');
    expect(ready.get('draftReplyHold')).toBeNull();
    expect(ready.getIn(['reply_status', 'id'])).toBe('reply-1');
    expect(ready.get('draftQuoteHold')).toBe('pending');
    expect(ignored.get('draftReplyHold')).toBeNull();
    expect(staleTarget.get('draftReplyHold')).toBe('pending');
    expect(staleTarget.get('in_reply_to')).toBe('other');
    expect(composerDraftRestoreBlocksSubmit(ready)).toBe(true);
    expect(composerDraftRestoreBlocksSubmit(ready.set('draftQuoteHold', null).set('media_attachments', ImmutableList()))).toBe(false);
  });

  it('keeps managed mentions out of the raw text', () => {
    const state = drafted();
    const snapshot = snapshotComposerDraft(state, { accountId: '42', clientDraftUuid: 'draft-1' });
    const applied = applyComposerDraft(initialState, snapshot, { idempotencyKey: 'next-key' });

    expect(applied.get('text')).toBe('Hello');
    expect(applied.get('text')).not.toContain('@group');
    expect(materializeComposerText(applied)).toBe(materializeComposerText(state));
    expect((applied.get('text').match(/@group/g) || [])).toHaveLength(0);
    expect((materializeComposerText(applied).match(/@group/g) || []).length).toBe((materializeComposerText(state).match(/@group/g) || []).length);
  });

  it('does not snapshot an empty composer, an edit, a scheduled edit, or a redraft', () => {
    expect(composerDraftHasPersistableInput(initialState)).toBe(false);
    expect(snapshotComposerDraft(initialState, { accountId: '42', clientDraftUuid: 'draft-1' })).toBeNull();
    expect(snapshotComposerDraft(initialState.set('text', 'Hello').set('id', 'status-1'), { accountId: '42', clientDraftUuid: 'draft-1' })).toBeNull();
    expect(snapshotComposerDraft(initialState.set('text', 'Hello').set('scheduled_status_id', 'sched-1'), { accountId: '42', clientDraftUuid: 'draft-1' })).toBeNull();
    expect(snapshotComposerDraft(initialState.set('text', 'Hello').set('redraftMediaUnconfirmed', true), { accountId: '42', clientDraftUuid: 'draft-1' })).toBeNull();
  });

  it('clears a restored reply, destination, and unresolved media on discard', () => {
    const snapshot = {
      schema_version: 1,
      account_id: '42',
      client_draft_uuid: 'draft-9',
      input: {
        text: 'Hello',
        in_reply_to_id: 'reply-1',
        surface: { kind: 'group', key: '123' },
        media: [{ id: 'media-1', order: 0, description: 'alt', focus: { x: 0, y: 0 } }],
      },
    };
    const restored = composer(initialState, {
      type: COMPOSER_DRAFT_RESTORE,
      snapshot,
      idempotencyKey: 'post-1',
      restoreToken: 'restore-1',
    });
    const withUpload = restored.update('media_attachments', list => list.push(ImmutableMap({
      id: 'real-1',
      type: 'image',
      unresolved: false,
    })));
    const reset = composer(withUpload, { type: COMPOSE_RESET });
    const typed = composer(reset, changeCompose('Next'));
    const uploaded = composer(reset, {
      type: COMPOSE_UPLOAD_SUCCESS,
      media: { id: 'new-1', type: 'image' },
    });

    expect(restored.get('draftReplyHold')).toBe('pending');
    expect(restored.get('draftSurfaceUnconfirmed')).toBe(true);
    expect(restored.getIn(['media_attachments', 0, 'unresolved'])).toBe(true);
    expect(reset.get('text')).toBe('');
    expect(reset.get('in_reply_to')).toBeNull();
    expect(reset.get('draftReplyHold')).toBeNull();
    expect(reset.get('draftQuoteHold')).toBeNull();
    expect(reset.get('draftRestoreToken')).toBeNull();
    expect(reset.get('draftSurfaceUnconfirmed')).toBe(false);
    expect(reset.get('draftSurfaceConfirm')).toBeNull();
    expect(reset.get('surfaceMismatch')).toBe(false);
    expect(reset.get('surface')).toBeNull();
    expect(reset.get('media_attachments').map(item => item.get('id')).toArray()).toEqual(['real-1']);
    expect(composerDraftRestoreBlocksSubmit(reset)).toBe(false);
    expect(fileDropBlockFromComposer(reset)).not.toBe('draft_media');
    expect(composerDraftHasPersistableInput(composer(restored, { type: COMPOSE_RESET }))).toBe(false);
    expect(typed.get('text')).toBe('Next');
    expect(composerDraftRestoreBlocksSubmit(typed)).toBe(false);
    expect(uploaded.get('media_attachments').map(item => item.get('id')).toArray()).toEqual(['real-1', 'new-1']);
    expect(uploaded.get('media_attachments').some(item => item.get('unresolved') === true)).toBe(false);

    const moved = composer(restored, {
      type: 'COMPOSER_CONTEXT_APPLY',
      surface: { kind: 'group', key: '456' },
      surfaceEpoch: (restored.get('surfaceEpoch') || 0) + 1,
      postingContext: { key: 'builtin:fedibird-group:456' },
      hasPostingContext: true,
    });
    const resetMoved = composer(moved, { type: COMPOSE_RESET });

    expect(resetMoved.get('draftReplyHold')).toBeNull();
    expect(resetMoved.get('media_attachments').size).toBe(0);
    expect(resetMoved.get('surfaceMismatch')).toBe(true);
    expect(resetMoved.getIn(['surface', 'key'])).toBe('123');
    expect(resetMoved.getIn(['pendingSurface', 'key'])).toBe('456');
    expect(composerDraftRestoreBlocksSubmit(resetMoved)).toBe(false);
    expect(composerDraftHasPersistableInput(resetMoved)).toBe(false);
  });

  it('restores a snapshot whose nested fields have the wrong shape', () => {
    const broken = {
      schema_version: 1,
      account_id: '42',
      client_draft_uuid: 'draft-1',
      input: {
        text: 'Hello',
        context: {
          managed: { hashtags: { oops: true }, mentions: { acct: 'group' } },
          suppressions: { hashtags: { fedibird: true } },
        },
        user_posting_style: {
          selected_id: 'style-1',
          manual_fields: { privacy: true },
          unapplied: { a: 1 },
          snapshot: 'nope',
        },
        media: { id: 'media-1' },
        poll: { options: { red: true } },
        references: { a: 'ref-a' },
        surface: 'group',
      },
    };
    const restored = restoreComposerDraft(broken);

    expect(restored.ok).toBe(true);
    expect(restored.snapshot.input.context.managed.hashtags).toEqual([]);
    expect(restored.snapshot.input.user_posting_style.manual_fields).toEqual([]);
    expect(restored.snapshot.input.media).toEqual([]);
    expect(restored.snapshot.input.surface).toBeNull();

    let applied;
    expect(() => {
      applied = applyComposerDraft(initialState, broken, { idempotencyKey: 'next-key' });
    }).not.toThrow();
    expect(applied.get('text')).toBe('Hello');
    expect(applied.getIn(['context', 'managed', 'hashtags']).size).toBe(0);
    expect(applied.getIn(['userPostingStyle', 'manualFields']).size).toBe(0);
    expect(applied.get('media_attachments').size).toBe(0);
    expect(applied.get('surface')).toBeNull();
  });

  it('refuses an old schema, invalid JSON, and a surface that already has text', () => {
    expect(restoreComposerDraft('{').reason).toBe('invalid_json');
    expect(restoreComposerDraft({ schema_version: 0, account_id: '42', client_draft_uuid: 'draft-1', input: { text: 'Hello' } }).reason).toBe('unsupported_schema');
    expect(restoreComposerDraft({ schema_version: 1, input: { text: 'Hello' } }).reason).toBe('invalid_snapshot');

    const snapshot = snapshotComposerDraft(initialState.set('text', 'Hello'), { accountId: '42', clientDraftUuid: 'draft-1' });
    const busy = applyComposerDraft(initialState.set('text', 'Already'), snapshot, { idempotencyKey: 'next-key' });

    expect(busy.get('text')).toBe('Already');
  });

  it('returns a frozen read-only copy and leaves the source mutable', () => {
    const snapshot = snapshotComposerDraft(initialState.set('text', 'Hello'), { accountId: '42', clientDraftUuid: 'draft-1' });
    const copy = copyComposerDraftSnapshot(snapshot);

    expect(Object.isFrozen(copy)).toBe(true);
    expect(Object.isFrozen(copy.input)).toBe(true);
    expect(() => {
      copy.input.text = 'changed';
    }).toThrow();
    snapshot.input.text = 'typed';
    expect(snapshot.input.text).toBe('typed');
    expect(copy.input.text).toBe('Hello');
  });

  it('marks an in-progress upload incomplete and keeps only completed media ids', () => {
    const state = initialState.merge({
      text: 'Hello',
      is_uploading: true,
      pending_media_attachments: 1,
      media_attachments: ImmutableList([
        ImmutableMap({ id: 'media-1', description: 'done', order: 0 }),
        ImmutableMap({ description: 'not uploaded yet' }),
      ]),
    });
    const snapshot = snapshotComposerDraft(state, { accountId: '42', clientDraftUuid: 'draft-1' });

    expect(snapshot.media_incomplete).toBe(true);
    expect(snapshot.input.media.map(item => item.id)).toEqual(['media-1']);
  });
});
