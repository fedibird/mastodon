import { Map as ImmutableMap, List as ImmutableList, fromJS } from 'immutable';
import { applyMiddleware, createStore } from 'redux';
import thunk from 'redux-thunk';

import { COMPOSE_CHANGE, COMPOSE_POLL_ADD, COMPOSE_REPLY, COMPOSE_REPLY_CANCEL, COMPOSE_VISIBILITY_CHANGE } from '../../actions/compose';
import { submitComposer } from '../../actions/compose';
import { acceptComposerSurface, applyComposerSurface, createComposer } from '../../actions/composer';
import { COMPOSER_CONTEXT_APPLY } from '../../actions/composer';
import { USER_POSTING_STYLES_FETCH_SUCCESS, maybeAutoSelectPortablePostingStyle } from '../../actions/user_posting_styles';
import composer from '../../reducers/composer';
import composers from '../../reducers/composers';
import userPostingStyles from '../../reducers/user_posting_styles';
import { selectComposerEffectiveCreateCapability } from '../create_capability';
import { groupPostingContext } from '../fixtures/group_context_fixture';
import { mitraGroupPostingContext } from '../fixtures/mitra_group_context_fixture';
import { buildHashtagTimelinePostingContext } from '../hashtag';
import { materializeComposerText } from '../materialize';
import { selectPortablePostingStyleCandidates } from '../surface';
import { resolveUserPostingStyle } from '../user_style_resolver';
import { toggleComposerManagedHashtag } from '../../actions/composer';

jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

const groupStyle = (id, accountId, extra = {}) => fromJS({
  id,
  name: `Group ${id}`,
  revision: 1,
  target: { kind: 'group', accountId, hashtag: null, label: `group-${accountId}` },
  defaults: { visibility: 'unlisted' },
  managed: { hashtags: [] },
  ...extra,
});

const hashtagStyle = fromJS({
  id: 'hash-1',
  name: '読書メモ',
  revision: 1,
  target: { kind: 'hashtag', accountId: null, hashtag: 'Foo', label: '#Foo' },
  defaults: { visibility: 'unlisted' },
  managed: {
    hashtags: [{ name: 'Foo', normalizedName: 'foo', enforcement: 'advisory' }],
  },
});

const otherHashtagStyle = fromJS({
  id: 'hash-2',
  name: '別タグ',
  revision: 1,
  target: { kind: 'hashtag', accountId: null, hashtag: 'News', label: '#News' },
  defaults: {},
  managed: { hashtags: [] },
});

const plainStyle = fromJS({
  id: 'plain-1',
  name: '共通',
  revision: 1,
  target: { kind: 'none', accountId: null, hashtag: null, label: null },
  defaults: { visibility: 'private' },
  managed: { hashtags: [] },
});

const applyGroup = (accountId, context = groupPostingContext) => (
  applyComposerSurface(`portable:group-column:${accountId}`, { kind: 'group', key: String(accountId) }, context, String(accountId))
);

const commitStyle = (state, style, origin = 'manual') => composer(state, {
  type: 'USER_POSTING_STYLE_COMMIT',
  plan: resolveUserPostingStyle(style, state, { destinationPolicy: state.get('surface') ? 'locked' : 'change' }),
  snapshot: style,
  resetSuppressions: true,
  selectionOrigin: origin,
  evaluatedSurface: state.get('surface') ? { kind: state.getIn(['surface', 'kind']), key: state.getIn(['surface', 'key']) } : null,
});

const withStyles = (styles) => ({
  type: USER_POSTING_STYLES_FETCH_SUCCESS,
  styles,
});

const storeFor = (composerState, styles, extra = ImmutableMap()) => createStore((state, action) => {
  const current = state || extra.merge(ImmutableMap({
    compose: composer(undefined, { type: '@@INIT' }),
    composers: composers(undefined, createComposer('portable:group-column:123'))
      .setIn(['byId', 'portable:group-column:123'], composerState),
    userPostingStyles: userPostingStyles(undefined, withStyles(styles)),
    relationships: ImmutableMap(),
    posting_contexts: ImmutableMap(),
  }));

  if (!action || action.type === '@@INIT') {
    return current;
  }

  return current.set('composers', composers(current.get('composers'), action));
}, undefined, applyMiddleware(thunk));

describe('portable posting styles', () => {
  it('auto-selects the only dedicated group style on an empty composer', () => {
    const drafted = composer(undefined, applyGroup('123'));
    const store = storeFor(drafted, ImmutableList([groupStyle('1', '123'), plainStyle, groupStyle('9', '999')]));

    store.dispatch(maybeAutoSelectPortablePostingStyle('portable:group-column:123'));

    const next = store.getState().getIn(['composers', 'byId', 'portable:group-column:123']);

    expect(next.getIn(['userPostingStyle', 'selectedId'])).toEqual('1');
    expect(next.getIn(['userPostingStyle', 'selectionOrigin'])).toEqual('automatic');
    expect(next.get('privacy')).toEqual('unlisted');
    expect(next.get('posting_context_account_id')).toEqual('123');
    expect(next.getIn(['context', 'resolvedAccountId'])).toEqual('123');
  });

  it('does not auto-select when several dedicated styles match', () => {
    const drafted = composer(undefined, applyGroup('123'));
    const store = storeFor(drafted, ImmutableList([groupStyle('1', '123'), groupStyle('2', '123')]));

    store.dispatch(maybeAutoSelectPortablePostingStyle('portable:group-column:123'));

    expect(store.getState().getIn(['composers', 'byId', 'portable:group-column:123', 'userPostingStyle', 'selectedId'])).toBeNull();
  });

  it('does not auto-select from a shared style alone', () => {
    const drafted = composer(undefined, applyGroup('123'));
    const store = storeFor(drafted, ImmutableList([plainStyle]));

    store.dispatch(maybeAutoSelectPortablePostingStyle('portable:group-column:123'));

    expect(store.getState().getIn(['composers', 'byId', 'portable:group-column:123', 'userPostingStyle', 'selectedId'])).toBeNull();
  });

  it('does not auto-select again after the style is explicitly cleared', () => {
    let drafted = composer(undefined, applyGroup('123'));
    drafted = commitStyle(drafted, groupStyle('1', '123'), 'automatic');
    drafted = commitStyle(drafted, null, 'none');
    const store = storeFor(drafted, ImmutableList([groupStyle('1', '123')]));

    store.dispatch(maybeAutoSelectPortablePostingStyle('portable:group-column:123'));

    const next = store.getState().getIn(['composers', 'byId', 'portable:group-column:123']);

    expect(next.getIn(['userPostingStyle', 'selectedId'])).toBeNull();
    expect(next.getIn(['userPostingStyle', 'selectionOrigin'])).toEqual('none');
    expect(next.getIn(['context', 'key'])).toEqual(groupPostingContext.key);
    expect(next.get('posting_context_account_id')).toEqual('123');
  });

  it('hides dedicated styles for a different destination', () => {
    const surface = ImmutableMap({ kind: 'group', key: '123' });
    const styles = ImmutableList([
      groupStyle('1', '123'),
      groupStyle('9', '999'),
      otherHashtagStyle,
      plainStyle,
    ]);
    const candidates = selectPortablePostingStyleCandidates(styles, surface);

    expect(candidates.map(style => style.get('id')).toArray()).toEqual(['1', 'plain-1']);
  });

  it('keeps the group account id and audience when a style changes settings', () => {
    let drafted = composer(undefined, applyGroup('456', mitraGroupPostingContext));
    drafted = commitStyle(drafted, groupStyle('1', '999', { defaults: { visibility: 'unlisted' } }));

    expect(drafted.get('privacy')).toEqual('unlisted');
    expect(drafted.get('posting_context_account_id')).toEqual('456');
    expect(drafted.getIn(['context', 'resolvedAccountId'])).toEqual('456');
    expect(drafted.getIn(['context', 'protocol', 'activityPub', 'audience', 'accountId'])).toEqual('456');
    expect(drafted.getIn(['userPostingStyle', 'destinationStatus'])).not.toEqual('pending');
    expect(drafted.getIn(['userPostingStyle', 'destinationSource'])).toBeNull();
  });

  it('does not append a duplicate hashtag and keeps timeline suppression separate', () => {
    let drafted = composer(undefined, applyComposerSurface(
      'portable:hashtag-column:a',
      { kind: 'hashtag', key: 'foo' },
      buildHashtagTimelinePostingContext('Foo'),
      null,
    ));
    drafted = drafted.set('text', 'Hello');
    drafted = commitStyle(drafted, hashtagStyle);

    expect(materializeComposerText(drafted)).toEqual('Hello\n\n#Foo');
    expect(drafted.getIn(['context', 'managed', 'hashtags']).size).toEqual(1);

    const contextSuppressed = composer(drafted, toggleComposerManagedHashtag('portable:hashtag-column:a', 'foo'));

    expect(materializeComposerText(contextSuppressed)).toEqual('Hello\n\n#Foo');
    expect(contextSuppressed.getIn(['context', 'suppressions', 'hashtags']).includes('foo')).toBe(true);
    expect(contextSuppressed.getIn(['userPostingStyle', 'suppressions']).includes('style:foo')).toBe(false);
  });

  it('does not create a destination for a list', () => {
    const styles = ImmutableList([plainStyle, groupStyle('1', '123'), hashtagStyle]);
    const candidates = selectPortablePostingStyleCandidates(styles, { kind: 'list', key: '7' });
    let drafted = composer(undefined, applyComposerSurface('portable:list-column:a', { kind: 'list', key: '7' }));

    drafted = commitStyle(drafted, plainStyle);

    expect(candidates.map(style => style.get('id')).toArray()).toEqual(['plain-1']);
    expect(drafted.get('posting_context_account_id')).toBeNull();
    expect(drafted.getIn(['context', 'resolvedAccountId'])).toBeNull();
    expect(drafted.getIn(['context', 'protocol', 'activityPub', 'audience'])).toBeNull();
    expect(drafted.get('privacy')).toEqual('private');
  });

  it('keeps the surface context when returning to this place only', () => {
    let drafted = composer(undefined, applyGroup('123'));
    drafted = commitStyle(drafted, groupStyle('1', '123'));
    drafted = commitStyle(drafted, null, 'none');

    expect(drafted.getIn(['userPostingStyle', 'selectedId'])).toBeNull();
    expect(drafted.getIn(['userPostingStyle', 'selectionOrigin'])).toEqual('none');
    expect(drafted.getIn(['context', 'key'])).toEqual(groupPostingContext.key);
    expect(drafted.get('posting_context_account_id')).toEqual('123');
    expect(drafted.getIn(['context', 'managed', 'mentions', 0, 'acct'])).toEqual('group');
  });

  it('keeps manual settings, text, media, and the poll when a style is applied', () => {
    let drafted = composer(undefined, applyGroup('123'));
    drafted = composer(drafted, { type: COMPOSE_VISIBILITY_CHANGE, value: 'public' });
    drafted = composer(drafted, { type: COMPOSE_CHANGE, text: 'Hello' });
    drafted = composer(drafted, { type: COMPOSE_POLL_ADD });
    drafted = drafted.set('media_attachments', ImmutableList([ImmutableMap({ id: 'media-1' })]));
    drafted = commitStyle(drafted, groupStyle('1', '123'));

    expect(drafted.get('text')).toEqual('Hello');
    expect(drafted.get('media_attachments').getIn([0, 'id'])).toEqual('media-1');
    expect(drafted.get('poll')).not.toBeNull();
    expect(drafted.get('privacy')).toEqual('public');
    expect(drafted.getIn(['userPostingStyle', 'unapplied']).includes('privacy')).toBe(true);
    expect(drafted.get('posting_context_account_id')).toEqual('123');
  });

  it('does not overwrite a draft that started before styles arrived', () => {
    let drafted = composer(undefined, applyGroup('123'));
    drafted = composer(drafted, { type: COMPOSE_CHANGE, text: 'already writing' });
    const store = storeFor(drafted, ImmutableList([groupStyle('1', '123')]));

    store.dispatch(maybeAutoSelectPortablePostingStyle('portable:group-column:123'));

    const next = store.getState().getIn(['composers', 'byId', 'portable:group-column:123']);

    expect(next.get('text')).toEqual('already writing');
    expect(next.getIn(['userPostingStyle', 'selectedId'])).toBeNull();
    expect(next.getIn(['userPostingStyle', 'styleInputLock'])).toBe(true);
  });

  it('blocks sending when the group visibility rule no longer matches the draft', () => {
    const allowed = mitraGroupPostingContext;
    let drafted = composer(undefined, applyGroup('456', allowed));
    drafted = composer(drafted, { type: COMPOSE_VISIBILITY_CHANGE, value: 'unlisted' });
    const discovery = fromJS({
      status: 'resolved',
      context: allowed,
      discovery: { mechanism: 'test', adapter: 'mitra_group', authority: 'compatibility' },
      viewerEvidence: {
        permissions: { create: { status: 'allowed', source: 'fep-5219', viaRelationship: 'member', authority: 'protocol' } },
      },
      receivedAt: 1_700_000_000_000,
    });
    const openState = ImmutableMap({
      composers: ImmutableMap({ byId: ImmutableMap({ 'portable:group-column:456': drafted }) }),
      relationships: ImmutableMap(),
      posting_contexts: ImmutableMap({ 456: discovery }),
      posting_context_revalidations: ImmutableMap(),
    });

    expect(selectComposerEffectiveCreateCapability(openState, 'portable:group-column:456', 1_700_000_000_000).canAttempt).toBe(true);

    const narrowed = {
      ...allowed,
      constraints: { allowedVisibilities: ['public'] },
    };
    const blockedDraft = composer(drafted, applyGroup('456', narrowed));
    const blockedState = openState.setIn(['composers', 'byId', 'portable:group-column:456'], blockedDraft).setIn(
      ['posting_contexts', '456', 'context'],
      fromJS(narrowed),
    );
    const capability = selectComposerEffectiveCreateCapability(blockedState, 'portable:group-column:456', 1_700_000_000_000);

    expect(blockedDraft.get('privacy')).toEqual('unlisted');
    expect(capability.compliance.valid).toBe(false);
    expect(capability.canAttempt).toBe(false);
    expect(capability.reason).toEqual('compliance');
  });

  it('does not mix state between composer ids', () => {
    let registry = composers(undefined, createComposer('portable:group-column:a'));
    registry = composers(registry, createComposer('portable:group-column:b'));
    registry = composers(registry, applyComposerSurface(
      'portable:group-column:a',
      { kind: 'group', key: '123' },
      groupPostingContext,
      '123',
    ));
    registry = composers(registry, applyComposerSurface(
      'portable:group-column:b',
      { kind: 'group', key: '456' },
      mitraGroupPostingContext,
      '456',
    ));

    const left = registry.getIn(['byId', 'portable:group-column:a']);
    const styled = commitStyle(left, groupStyle('1', '123'));

    registry = registry.setIn(['byId', 'portable:group-column:a'], styled);

    expect(registry.getIn(['byId', 'portable:group-column:a', 'userPostingStyle', 'selectedId'])).toEqual('1');
    expect(registry.getIn(['byId', 'portable:group-column:a', 'posting_context_account_id'])).toEqual('123');
    expect(registry.getIn(['byId', 'portable:group-column:b', 'userPostingStyle', 'selectedId'])).toBeNull();
    expect(registry.getIn(['byId', 'portable:group-column:b', 'posting_context_account_id'])).toEqual('456');
    expect(registry.getIn(['byId', 'portable:group-column:b', 'context', 'key'])).toEqual(mitraGroupPostingContext.key);
  });

  it('does not send a draft to the previous destination when the surface changes', () => {
    let drafted = composer(undefined, applyGroup('123'));
    drafted = composer(drafted, { type: COMPOSE_CHANGE, text: 'Hello group' });
    const staleEpoch = drafted.get('surfaceEpoch');
    const moved = composer(drafted, applyGroup('456', mitraGroupPostingContext));

    expect(moved.get('surfaceMismatch')).toBe(true);
    expect(moved.getIn(['context', 'key'])).toEqual(groupPostingContext.key);
    expect(moved.get('posting_context_account_id')).toEqual('123');

    const store = storeFor(moved, ImmutableList());
    store.dispatch(submitComposer('portable:group-column:123'));

    expect(store.getState().getIn(['composers', 'byId', 'portable:group-column:123', 'is_submitting'])).not.toBe(true);

    const ignored = composer(moved, {
      type: COMPOSER_CONTEXT_APPLY,
      surface: { kind: 'group', key: '111' },
      hasPostingContext: true,
      postingContext: { ...groupPostingContext, key: 'builtin:fedibird-group:111' },
      postingContextAccountId: '111',
      surfaceEpoch: staleEpoch,
    });

    expect(ignored.get('posting_context_account_id')).toEqual('123');
    expect(ignored.getIn(['context', 'key'])).toEqual(groupPostingContext.key);

    const accepted = composer(moved, acceptComposerSurface('portable:group-column:123'));

    expect(accepted.get('surfaceMismatch')).toBe(false);
    expect(accepted.get('text')).toEqual('Hello group');
    expect(accepted.get('posting_context_account_id')).toEqual('456');
    expect(accepted.getIn(['context', 'key'])).toEqual(mitraGroupPostingContext.key);
    expect(accepted.getIn(['context', 'protocol', 'activityPub', 'audience', 'accountId'])).toEqual('456');
  });

  it('keeps the group context across reply and cancel', () => {
    let drafted = composer(undefined, applyGroup('123'));
    drafted = commitStyle(drafted, groupStyle('1', '123'), 'automatic');
    drafted = composer(drafted, {
      type: COMPOSE_REPLY,
      status: ImmutableMap({
        id: 'status-1',
        visibility: 'public',
        spoiler_text: '',
        language: 'ja',
        mentions: ImmutableList(),
      }),
      context_references: ImmutableList(),
    });

    expect(drafted.get('in_reply_to')).toEqual('status-1');
    expect(drafted.get('posting_context_account_id')).toEqual('123');

    const cancelled = composer(drafted, { type: COMPOSE_REPLY_CANCEL });

    expect(cancelled.get('in_reply_to')).toBeNull();
    expect(cancelled.get('posting_context_account_id')).toEqual('123');
    expect(cancelled.getIn(['context', 'key'])).toEqual(groupPostingContext.key);
    expect(cancelled.getIn(['userPostingStyle', 'selectedId'])).toEqual('1');
  });

  it('still lets the primary composer change its destination', () => {
    const drafted = composer(undefined, { type: '@@INIT' });
    const plan = resolveUserPostingStyle(groupStyle('1', '123'), drafted);

    expect(plan.destination).toMatchObject({ action: 'group', accountId: '123', changes: true });
    expect(plan.destination.policy).toBeUndefined();
  });
});
