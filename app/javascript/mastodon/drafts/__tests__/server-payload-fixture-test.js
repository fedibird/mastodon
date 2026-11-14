import fs from 'fs';
import path from 'path';

import { Map as ImmutableMap, List as ImmutableList, Set as ImmutableSet } from 'immutable';

import { changeCompose } from '../../actions/compose';
import { applyComposerPostingContext } from '../../actions/composer';
import { buildHashtagTimelinePostingContext } from '../../posting_context/hashtag';
import { groupPostingContext } from '../../posting_context/fixtures/group_context_fixture';
import { mitraGroupPostingContext } from '../../posting_context/fixtures/mitra_group_context_fixture';
import composer, { initialState } from '../../reducers/composer';
import { snapshotComposerDraft } from '../snapshot';

const FIXTURE_DIR = path.resolve(__dirname, '../../../../../spec/fixtures/post_drafts');

function typed (text) {
  return composer(initialState, changeCompose(text));
}

function withSender (state, id, origin) {
  return state.setIn(['senderIdentity', 'id'], id).setIn(['senderIdentity', 'selectionOrigin'], origin);
}

function withStyle (state) {
  return state.withMutations(map => {
    map.setIn(['userPostingStyle', 'selectedId'], '4');
    map.setIn(['userPostingStyle', 'appliedRevision'], 3);
    map.setIn(['userPostingStyle', 'usageMode'], 'keep');
    map.setIn(['userPostingStyle', 'selectionKind'], 'style');
    map.setIn(['userPostingStyle', 'selectionOrigin'], 'manual');
    map.setIn(['userPostingStyle', 'manualFields'], ImmutableSet(['privacy', 'spoiler']));
    map.setIn(['userPostingStyle', 'manualValues'], ImmutableMap({ privacy: 'unlisted', spoilerText: '注意' }));
    map.setIn(['userPostingStyle', 'destinationSource'], 'style');
    map.setIn(['userPostingStyle', 'destinationPolicy'], 'locked');
    map.setIn(['userPostingStyle', 'destinationAccountId'], '123');
    map.setIn(['userPostingStyle', 'destinationStatus'], 'ready');
    map.setIn(['userPostingStyle', 'snapshot'], ImmutableMap({
      id: '4',
      name: 'サークル告知',
      revision: 3,
      target: ImmutableMap({ kind: 'group', accountId: '123', hashtag: null, label: 'localsquad' }),
      defaults: ImmutableMap({ visibility: 'private', sensitive: true }),
      managed: ImmutableMap({
        hashtags: ImmutableList([ImmutableMap({
          name: 'fedibird',
          normalizedName: 'fedibird',
          enforcement: 'advisory',
          ruleId: 'user-posting-context',
        })]),
        mentions: ImmutableList(),
      }),
    }));
  });
}

function capture (state, clientDraftUuid, composerId = 'primary') {
  const snapshot = snapshotComposerDraft(state, {
    accountId: '42',
    clientDraftUuid,
    composerId,
    savedAt: '2026-11-14T00:00:00.000Z',
  });

  expect(snapshot).not.toBeNull();
  expect(snapshot.input.media).toEqual([]);

  return snapshot;
}

function expectFixture (name, snapshot) {
  const file = path.join(FIXTURE_DIR, `${name}.json`);

  if (process.env.WRITE_POST_DRAFT_FIXTURES === '1') {
    fs.mkdirSync(FIXTURE_DIR, { recursive: true });
    fs.writeFileSync(file, `${JSON.stringify(snapshot)}\n`);
  }

  expect(JSON.parse(fs.readFileSync(file, 'utf8'))).toEqual(snapshot);
}

describe('post draft server fixtures', () => {
  it('records the snapshots snapshotComposerDraft actually writes', () => {
    const primary = withSender(typed('こんにちは'), 'local:42', 'default');
    const hashtag = withSender(
      composer(typed('タグ'), applyComposerPostingContext('primary', buildHashtagTimelinePostingContext('日本語'), null))
        .set('surface', ImmutableMap({ kind: 'hashtag', key: '日本語' })),
      'local:42',
      'default',
    );
    const audience = withStyle(withSender(
      composer(typed('グループ'), applyComposerPostingContext('primary', mitraGroupPostingContext, '456')),
      'delegated:9',
      'explicit',
    ));
    const styledHashtag = withStyle(withSender(
      composer(typed('あ'.repeat(10000)), applyComposerPostingContext('primary', buildHashtagTimelinePostingContext('日本語'), null))
        .set('surface', ImmutableMap({ kind: 'hashtag', key: '日本語' })),
      'local:42',
      'default',
    ));
    const styledGroup = withStyle(withSender(
      composer(typed('a'.repeat(10000)), applyComposerPostingContext('primary', groupPostingContext, '123')),
      'delegated:9',
      'explicit',
    ));

    expect(primary.getIn(['context', 'protocol', 'activityPub', 'audience'])).toBeNull();
    expect(audience.getIn(['context', 'protocol', 'activityPub', 'audience', 'accountId'])).toBe('456');

    expectFixture('primary', capture(primary, '11111111-1111-4111-8111-111111111111'));
    expectFixture('hashtag', capture(hashtag, '22222222-2222-4222-8222-222222222222', 'portable:hashtag-column:日本語'));
    expectFixture('audience', capture(audience, '33333333-3333-4333-8333-333333333333'));
    expectFixture('long-ja', capture(styledHashtag, '44444444-4444-4444-8444-444444444444', 'portable:hashtag-column:日本語'));
    expectFixture('long-en', capture(styledGroup, '55555555-5555-4555-8555-555555555555'));
  });
});
