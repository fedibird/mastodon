import { List as ImmutableList, Map as ImmutableMap, Set as ImmutableSet, fromJS } from 'immutable';
import { changeCompose, changeComposeLanguage, changeComposeSearchability, changeComposeVisibility } from '../../actions/compose';
import { applyComposerPostingContext, COMPOSER_DRAFT_RESTORE } from '../../actions/composer';
import { groupPostingContext } from '../../posting_context/fixtures/group_context_fixture';
import { materializeComposerText } from '../../posting_context/materialize';
import composer, { initialState } from '../../reducers/composer';
import {
  applyComposerDraft,
  composerDraftHasPersistableInput,
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
