import { Map as ImmutableMap, List as ImmutableList, fromJS } from 'immutable';
import { applyMiddleware, createStore } from 'redux';
import thunk from 'redux-thunk';

import { COMPOSE_CHANGE, COMPOSE_POLL_ADD, COMPOSE_REPLY, COMPOSE_REPLY_CANCEL, COMPOSE_VISIBILITY_CHANGE } from '../../actions/compose';
import { submitComposer } from '../../actions/compose';
import { acceptComposerSurface, applyComposerSurface, createComposer } from '../../actions/composer';
import { COMPOSER_CONTEXT_APPLY } from '../../actions/composer';
import { USER_POSTING_CONTEXT_ASSIGNMENT_FETCH_SUCCESS } from '../../actions/user_posting_context_assignments';
import { USER_POSTING_STYLES_FETCH_SUCCESS, commitUserPostingStyle, maybeAutoSelectPortablePostingStyle } from '../../actions/user_posting_styles';
import composer from '../../reducers/composer';
import composers from '../../reducers/composers';
import userPostingContextAssignments from '../../reducers/user_posting_context_assignments';
import userPostingStyles from '../../reducers/user_posting_styles';
import { selectComposerEffectiveCreateCapability } from '../create_capability';
import { groupPostingContext } from '../fixtures/group_context_fixture';
import { mitraGroupPostingContext } from '../fixtures/mitra_group_context_fixture';
import { buildHashtagTimelinePostingContext } from '../hashtag';
import { materializeComposerText } from '../materialize';
import { selectPortablePostingStyleCandidates } from '../surface';
import { resolveUserPostingStyle } from '../user_style_resolver';
import { toggleComposerManagedHashtag } from '../../actions/composer';
import { PRIMARY_COMPOSER_ID } from '../../utils/composer';

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

const readyUnsetAssignment = (composerState) => {
  const surface = composerState && composerState.get('surface');
  const kind = surface ? surface.get('kind') : 'group';
  const key = surface ? String(surface.get('key')) : '123';

  const surfaceKey = `${kind}:${key}`;
  const requested = userPostingContextAssignments(undefined, {
    type: 'USER_POSTING_CONTEXT_ASSIGNMENT_FETCH_REQUEST',
    surfaceKey,
    surface: { kind, key },
    generation: 1,
  });

  return userPostingContextAssignments(requested, {
    type: USER_POSTING_CONTEXT_ASSIGNMENT_FETCH_SUCCESS,
    surfaceKey,
    surface: { kind, key },
    generation: 1,
    assignment: {
      surface: { kind, key },
      assignmentStatus: 'unset',
      styleId: null,
      revision: null,
    },
  });
};

const storeFor = (composerState, styles, extra = ImmutableMap(), composerId = 'portable:group-column:123', assignmentState) => createStore((state, action) => {
  const current = state || extra.merge(ImmutableMap({
    compose: composer(undefined, { type: '@@INIT' }),
    composers: composers(undefined, createComposer(composerId))
      .setIn(['byId', composerId], composerState),
    userPostingStyles: userPostingStyles(undefined, withStyles(styles)),
    userPostingContextAssignments: assignmentState || readyUnsetAssignment(composerState),
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
    drafted = commitStyle(drafted, groupStyle('1', '456', { defaults: { visibility: 'unlisted' } }));

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

  it('still lets the primary composer change its destination', async () => {
    const drafted = composer(undefined, { type: '@@INIT' });
    const plan = resolveUserPostingStyle(groupStyle('1', '123'), drafted);

    expect(plan.destination).toMatchObject({ action: 'group', accountId: '123', changes: true });
    expect(plan.destination.policy).toBeUndefined();

    const now = Date.now();
    const store = createStore((state, action) => {
      const current = state || ImmutableMap({
        compose: drafted,
        userPostingStyles: userPostingStyles(undefined, withStyles(ImmutableList([groupStyle('1', '123')]))),
        posting_contexts: ImmutableMap({
          123: fromJS({
            status: 'resolved',
            context: groupPostingContext,
            discovery: { mechanism: 'built_in', adapter: 'fedibird_group', authority: 'server' },
            receivedAt: now,
            refreshing: false,
            refreshError: null,
          }),
        }),
        relationships: ImmutableMap(),
      });

      if (!action || action.type === '@@INIT') {
        return current;
      }

      return current.set('compose', composer(current.get('compose'), action));
    }, undefined, applyMiddleware(thunk));

    await store.dispatch(commitUserPostingStyle(PRIMARY_COMPOSER_ID, '1'));

    const next = store.getState().get('compose');

    expect(next.get('surface')).toBeNull();
    expect(next.get('privacy')).toEqual('unlisted');
    expect(next.get('posting_context_account_id')).toEqual('123');
    expect(next.getIn(['context', 'resolvedAccountId'])).toEqual('123');
    expect(next.getIn(['context', 'key'])).toEqual(groupPostingContext.key);
    expect(next.getIn(['userPostingStyle', 'selectedId'])).toEqual('1');
    expect(next.getIn(['userPostingStyle', 'destinationStatus'])).toEqual('ready');
    expect(next.getIn(['userPostingStyle', 'destinationPolicy'])).not.toEqual('locked');
  });

  it('does not apply a style confirmed for group A after the composer moves to group B', async () => {
    let drafted = composer(undefined, applyGroup('123'));
    drafted = composer(drafted, { type: COMPOSE_CHANGE, text: 'Hello group' });
    const surfaceAtChoice = { kind: 'group', key: '123' };
    const moved = composer(drafted, applyGroup('456', mitraGroupPostingContext));
    const store = storeFor(moved, ImmutableList([groupStyle('1', '123'), plainStyle]));

    await store.dispatch(commitUserPostingStyle('portable:group-column:123', '1', { expectedSurface: surfaceAtChoice }));

    let next = store.getState().getIn(['composers', 'byId', 'portable:group-column:123']);

    expect(next.get('surfaceMismatch')).toBe(true);
    expect(next.get('text')).toEqual('Hello group');
    expect(next.get('privacy')).toBeNull();
    expect(next.getIn(['userPostingStyle', 'selectedId'])).toBeNull();
    expect(next.get('posting_context_account_id')).toEqual('123');
    expect(next.getIn(['context', 'key'])).toEqual(groupPostingContext.key);

    store.dispatch(acceptComposerSurface('portable:group-column:123'));
    await store.dispatch(commitUserPostingStyle('portable:group-column:123', 'plain-1', { expectedSurface: surfaceAtChoice }));

    next = store.getState().getIn(['composers', 'byId', 'portable:group-column:123']);

    expect(next.get('surfaceMismatch')).toBe(false);
    expect(next.get('text')).toEqual('Hello group');
    expect(next.get('privacy')).toBeNull();
    expect(next.getIn(['userPostingStyle', 'selectedId'])).toBeNull();
    expect(next.get('posting_context_account_id')).toEqual('456');
    expect(next.getIn(['context', 'key'])).toEqual(mitraGroupPostingContext.key);
  });

  it('does not apply a group style dispatched directly onto a list composer', async () => {
    const composerId = 'portable:list-column:a';
    let drafted = composer(undefined, applyComposerSurface(composerId, { kind: 'list', key: '7' }));
    drafted = composer(drafted, { type: COMPOSE_CHANGE, text: 'List draft' });
    const untouched = commitStyle(drafted, groupStyle('1', '123'));
    const store = storeFor(drafted, ImmutableList([groupStyle('1', '123'), plainStyle]), ImmutableMap(), composerId);

    expect(untouched).toBe(drafted);

    await store.dispatch(commitUserPostingStyle(composerId, '1'));

    const next = store.getState().getIn(['composers', 'byId', composerId]);

    expect(next.get('text')).toEqual('List draft');
    expect(next.get('privacy')).toBeNull();
    expect(next.getIn(['userPostingStyle', 'selectedId'])).toBeNull();
    expect(next.get('posting_context_account_id')).toBeNull();
    expect(next.getIn(['context', 'resolvedAccountId'])).toBeNull();
    expect(next.getIn(['context', 'key'])).toBeNull();
    expect(next.getIn(['context', 'protocol', 'activityPub', 'audience'])).toBeNull();
  });

  it('clears the group destination when an empty composer moves to a list', () => {
    let drafted = composer(undefined, applyGroup('123'));
    const staleEpoch = drafted.get('surfaceEpoch');
    const moved = composer(drafted, applyComposerSurface('portable:group-column:123', { kind: 'list', key: '7' }));

    expect(moved.get('surfaceMismatch')).toBe(false);
    expect(moved.getIn(['surface', 'kind'])).toEqual('list');
    expect(moved.getIn(['surface', 'key'])).toEqual('7');
    expect(moved.get('posting_context_account_id')).toBeNull();
    expect(moved.getIn(['context', 'resolvedAccountId'])).toBeNull();
    expect(moved.getIn(['context', 'key'])).toBeNull();
    expect(moved.getIn(['context', 'managed', 'mentions']).size).toEqual(0);
    expect(moved.getIn(['context', 'protocol', 'activityPub', 'audience'])).toBeNull();

    const ignored = composer(moved, {
      type: COMPOSER_CONTEXT_APPLY,
      surface: { kind: 'group', key: '123' },
      hasPostingContext: true,
      postingContext: groupPostingContext,
      postingContextAccountId: '123',
      surfaceEpoch: staleEpoch,
    });

    expect(ignored.getIn(['surface', 'kind'])).toEqual('list');
    expect(ignored.get('posting_context_account_id')).toBeNull();
    expect(ignored.getIn(['context', 'key'])).toBeNull();

    const renamed = composer(moved, applyComposerSurface('portable:group-column:123', { kind: 'list', key: '8' }));

    expect(renamed.get('surfaceMismatch')).toBe(false);
    expect(renamed.getIn(['surface', 'key'])).toEqual('8');
    expect(renamed.get('posting_context_account_id')).toBeNull();
    expect(renamed.getIn(['context', 'resolvedAccountId'])).toBeNull();
    expect(renamed.getIn(['context', 'protocol', 'activityPub', 'audience'])).toBeNull();
  });

  it('blocks sending when a draft moves from a group to a list', () => {
    let drafted = composer(undefined, applyGroup('123'));
    drafted = composer(drafted, { type: COMPOSE_CHANGE, text: 'Hello group' });
    drafted = composer(drafted, { type: COMPOSE_POLL_ADD });
    drafted = drafted.set('media_attachments', ImmutableList([ImmutableMap({ id: 'media-1' })]));
    const moved = composer(drafted, applyComposerSurface('portable:group-column:123', { kind: 'list', key: '7' }));

    expect(moved.get('surfaceMismatch')).toBe(true);
    expect(moved.get('text')).toEqual('Hello group');
    expect(moved.get('poll')).not.toBeNull();
    expect(moved.get('media_attachments').getIn([0, 'id'])).toEqual('media-1');
    expect(moved.get('posting_context_account_id')).toEqual('123');
    expect(moved.getIn(['context', 'key'])).toEqual(groupPostingContext.key);
    expect(moved.getIn(['context', 'resolvedAccountId'])).toEqual('123');

    const store = storeFor(moved, ImmutableList());
    store.dispatch(submitComposer('portable:group-column:123'));

    expect(store.getState().getIn(['composers', 'byId', 'portable:group-column:123', 'is_submitting'])).not.toBe(true);
    expect(store.getState().getIn(['composers', 'byId', 'portable:group-column:123', 'text'])).toEqual('Hello group');
  });

  it('keeps the draft and clears the old group destination when the list surface is accepted', () => {
    let drafted = composer(undefined, applyGroup('123'));
    drafted = commitStyle(drafted, groupStyle('1', '123'));
    drafted = composer(drafted, { type: COMPOSE_CHANGE, text: 'Hello group' });
    drafted = composer(drafted, { type: COMPOSE_POLL_ADD });
    drafted = drafted.set('media_attachments', ImmutableList([ImmutableMap({ id: 'media-1' })]));
    const moved = composer(drafted, applyComposerSurface('portable:group-column:123', { kind: 'list', key: '7' }));
    const accepted = composer(moved, acceptComposerSurface('portable:group-column:123'));

    expect(moved.get('surfaceMismatch')).toBe(true);
    expect(accepted.get('surfaceMismatch')).toBe(false);
    expect(accepted.get('text')).toEqual('Hello group');
    expect(accepted.get('poll')).not.toBeNull();
    expect(accepted.get('media_attachments').getIn([0, 'id'])).toEqual('media-1');
    expect(accepted.getIn(['surface', 'kind'])).toEqual('list');
    expect(accepted.get('posting_context_account_id')).toBeNull();
    expect(accepted.getIn(['context', 'resolvedAccountId'])).toBeNull();
    expect(accepted.getIn(['context', 'key'])).toBeNull();
    expect(accepted.getIn(['context', 'managed', 'mentions']).size).toEqual(0);
    expect(accepted.getIn(['context', 'protocol', 'activityPub', 'audience'])).toBeNull();
    expect(accepted.getIn(['userPostingStyle', 'selectedId'])).toBeNull();
  });

  it('drops the timeline hashtag when a hashtag composer moves to a list', () => {
    const hashtagSurface = applyComposerSurface(
      'portable:hashtag-column:a',
      { kind: 'hashtag', key: 'foo' },
      buildHashtagTimelinePostingContext('Foo'),
      null,
    );
    const listSurface = applyComposerSurface('portable:hashtag-column:a', { kind: 'list', key: '7' });
    const empty = composer(composer(undefined, hashtagSurface), listSurface);

    expect(empty.getIn(['context', 'managed', 'hashtags']).size).toEqual(0);
    expect(empty.getIn(['context', 'key'])).toBeNull();
    expect(empty.get('posting_context_account_id')).toBeNull();

    let drafted = composer(undefined, hashtagSurface);
    drafted = composer(drafted, { type: COMPOSE_CHANGE, text: 'reading' });
    const moved = composer(drafted, listSurface);
    const accepted = composer(moved, acceptComposerSurface('portable:hashtag-column:a'));

    expect(moved.get('surfaceMismatch')).toBe(true);
    expect(moved.getIn(['context', 'managed', 'hashtags']).size).toEqual(1);
    expect(accepted.get('text')).toEqual('reading');
    expect(accepted.get('surfaceMismatch')).toBe(false);
    expect(accepted.getIn(['context', 'managed', 'hashtags']).size).toEqual(0);
    expect(accepted.getIn(['context', 'key'])).toBeNull();
    expect(accepted.get('posting_context_account_id')).toBeNull();
    expect(accepted.getIn(['context', 'resolvedAccountId'])).toBeNull();
    expect(accepted.getIn(['context', 'protocol', 'activityPub', 'audience'])).toBeNull();
  });

  it('cannot send to a group moved from a list until that group definition arrives', () => {
    const composerId = 'portable:group-column:123';
    let drafted = composer(undefined, applyComposerSurface(composerId, { kind: 'list', key: '7' }));
    drafted = composer(drafted, applyComposerSurface(composerId, { kind: 'group', key: '456' }));
    const now = 1_700_000_000_000;
    const blockedState = ImmutableMap({
      composers: ImmutableMap({ byId: ImmutableMap({ [composerId]: drafted }) }),
      relationships: ImmutableMap(),
      posting_contexts: ImmutableMap(),
      posting_context_revalidations: ImmutableMap(),
    });
    const blocked = selectComposerEffectiveCreateCapability(blockedState, composerId, now);

    expect(drafted.get('surfaceMismatch')).toBe(false);
    expect(drafted.getIn(['surface', 'kind'])).toEqual('group');
    expect(drafted.get('posting_context_account_id')).toEqual('456');
    expect(drafted.getIn(['context', 'resolvedAccountId'])).toBeNull();
    expect(drafted.getIn(['context', 'key'])).toBeNull();
    expect(blocked.canAttempt).toBe(false);
    expect(blocked.reason).toEqual('delivery_unresolved');

    let readyDraft = composer(drafted, applyComposerSurface(composerId, { kind: 'group', key: '456' }, mitraGroupPostingContext, '456'));
    readyDraft = composer(readyDraft, { type: COMPOSE_VISIBILITY_CHANGE, value: 'public' });
    const discovery = fromJS({
      status: 'resolved',
      context: mitraGroupPostingContext,
      discovery: { mechanism: 'test', adapter: 'mitra_group', authority: 'compatibility' },
      viewerEvidence: {
        permissions: { create: { status: 'allowed', source: 'fep-5219', viaRelationship: 'member', authority: 'protocol' } },
      },
      receivedAt: now,
    });
    const readyState = blockedState
      .setIn(['composers', 'byId', composerId], readyDraft)
      .setIn(['posting_contexts', '456'], discovery);
    const ready = selectComposerEffectiveCreateCapability(readyState, composerId, now);

    expect(readyDraft.getIn(['context', 'key'])).toEqual(mitraGroupPostingContext.key);
    expect(readyDraft.getIn(['context', 'resolvedAccountId'])).toEqual('456');
    expect(ready.canAttempt).toBe(true);
  });

  const hashtagSurface = (name) => applyComposerSurface(
    'portable:hashtag-column:a',
    { kind: 'hashtag', key: name },
    buildHashtagTimelinePostingContext(name),
    null,
  );

  it('releases the pending destination when the draft returns to its original group', () => {
    let drafted = composer(undefined, applyGroup('123'));
    drafted = composer(drafted, { type: COMPOSE_CHANGE, text: 'Hello group' });
    drafted = composer(drafted, { type: COMPOSE_POLL_ADD });
    drafted = drafted.set('media_attachments', ImmutableList([ImmutableMap({ id: 'media-1' })]));
    drafted = composer(drafted, { type: COMPOSE_VISIBILITY_CHANGE, value: 'public' });
    drafted = composer(drafted, toggleComposerManagedHashtag('portable:group-column:123', 'memo'));
    const moveToB = applyGroup('456', mitraGroupPostingContext);
    const moved = composer(drafted, moveToB);
    const returned = composer(moved, applyGroup('123'));

    expect(moved.get('surfaceMismatch')).toBe(true);
    expect(moved.getIn(['pendingSurface', 'key'])).toEqual('456');
    expect(returned.get('surfaceMismatch')).toBe(false);
    expect(returned.get('pendingSurface')).toBeNull();
    expect(returned.getIn(['displayedSurface', 'key'])).toEqual('123');
    expect(returned.get('text')).toEqual('Hello group');
    expect(returned.get('poll')).not.toBeNull();
    expect(returned.get('media_attachments').getIn([0, 'id'])).toEqual('media-1');
    expect(returned.get('privacy')).toEqual('public');
    expect(returned.getIn(['userPostingStyle', 'manualFields']).includes('privacy')).toBe(true);
    expect(returned.getIn(['context', 'suppressions', 'hashtags']).includes('memo')).toBe(true);
    expect(returned.get('posting_context_account_id')).toEqual('123');
    expect(returned.getIn(['context', 'resolvedAccountId'])).toEqual('123');
    expect(returned.getIn(['context', 'key'])).toEqual(groupPostingContext.key);
    expect(returned.getIn(['context', 'managed', 'mentions', 0, 'acct'])).toEqual('group');
    expect(returned.getIn(['context', 'protocol', 'activityPub', 'audience'])).toBeNull();

    const accepted = composer(returned, acceptComposerSurface('portable:group-column:123'));
    const replayed = composer(returned, moveToB);

    expect(accepted).toBe(returned);
    expect(replayed.get('surfaceMismatch')).toBe(false);
    expect(replayed.get('pendingSurface')).toBeNull();
    expect(replayed.get('posting_context_account_id')).toEqual('123');
    expect(replayed.getIn(['context', 'key'])).toEqual(groupPostingContext.key);
    expect(replayed.get('text')).toEqual('Hello group');
  });

  it('releases the pending destination when a group draft returns from a hashtag', () => {
    let drafted = composer(undefined, applyGroup('123'));
    drafted = composer(drafted, { type: COMPOSE_CHANGE, text: 'Hello group' });
    const moved = composer(drafted, hashtagSurface('bar'));
    const returned = composer(moved, applyGroup('123'));

    expect(moved.get('surfaceMismatch')).toBe(true);
    expect(moved.getIn(['pendingSurface', 'kind'])).toEqual('hashtag');
    expect(returned.get('surfaceMismatch')).toBe(false);
    expect(returned.get('pendingSurface')).toBeNull();
    expect(returned.get('text')).toEqual('Hello group');
    expect(returned.get('posting_context_account_id')).toEqual('123');
    expect(returned.getIn(['context', 'key'])).toEqual(groupPostingContext.key);
    expect(returned.getIn(['context', 'managed', 'mentions', 0, 'acct'])).toEqual('group');
    expect(returned.getIn(['context', 'managed', 'hashtags']).size).toEqual(0);
  });

  it('restores the original hashtag when the draft returns to it', () => {
    let drafted = composer(undefined, hashtagSurface('foo'));
    drafted = composer(drafted, { type: COMPOSE_CHANGE, text: 'reading' });
    const moved = composer(drafted, hashtagSurface('bar'));
    const returned = composer(moved, hashtagSurface('foo'));

    expect(moved.getIn(['pendingSurface', 'key'])).toEqual('bar');
    expect(moved.getIn(['context', 'key'])).toEqual('builtin:hashtag:foo');
    expect(returned.get('surfaceMismatch')).toBe(false);
    expect(returned.get('pendingSurface')).toBeNull();
    expect(returned.get('text')).toEqual('reading');
    expect(returned.getIn(['surface', 'key'])).toEqual('foo');
    expect(returned.getIn(['context', 'key'])).toEqual('builtin:hashtag:foo');
    expect(returned.getIn(['context', 'managed', 'hashtags']).map(tag => tag.get('normalizedName')).toArray()).toEqual(['foo']);
  });

  it('keeps only the latest displayed group as the pending destination', () => {
    let drafted = composer(undefined, applyGroup('123'));
    drafted = composer(drafted, { type: COMPOSE_CHANGE, text: 'Hello group' });
    const third = { ...groupPostingContext, key: 'builtin:fedibird-group:789' };
    const moved = composer(drafted, applyGroup('456', mitraGroupPostingContext));
    const refreshed = composer(moved, applyGroup('456', { ...mitraGroupPostingContext, key: 'protocol:refreshed-b' }));
    const next = composer(refreshed, applyGroup('789', third));

    expect(refreshed.get('surfaceMismatch')).toBe(true);
    expect(refreshed.get('posting_context_account_id')).toEqual('123');
    expect(refreshed.getIn(['context', 'key'])).toEqual(groupPostingContext.key);
    expect(refreshed.getIn(['pendingSurface', 'key'])).toEqual('456');
    expect(next.getIn(['pendingSurface', 'key'])).toEqual('789');
    expect(next.getIn(['displayedSurface', 'key'])).toEqual('789');
    expect(next.getIn(['surface', 'key'])).toEqual('123');
    expect(next.get('posting_context_account_id')).toEqual('123');
    expect(next.getIn(['context', 'key'])).toEqual(groupPostingContext.key);
    expect(next.get('text')).toEqual('Hello group');
  });

  it('rechecks create capability for the original group after the pending destination is released', () => {
    let drafted = composer(undefined, applyGroup('456', mitraGroupPostingContext));
    drafted = composer(drafted, { type: COMPOSE_VISIBILITY_CHANGE, value: 'public' });
    drafted = composer(drafted, { type: COMPOSE_CHANGE, text: 'Hello group' });
    const moved = composer(drafted, applyGroup('123'));
    const returned = composer(moved, applyGroup('456', mitraGroupPostingContext));
    const now = 1_700_000_000_000;
    const composerId = 'portable:group-column:456';
    const base = ImmutableMap({
      composers: ImmutableMap({ byId: ImmutableMap({ [composerId]: returned }) }),
      relationships: ImmutableMap(),
      posting_context_revalidations: ImmutableMap(),
    });
    const unconfirmed = selectComposerEffectiveCreateCapability(
      base.set('posting_contexts', ImmutableMap()),
      composerId,
      now,
    );
    const discovery = fromJS({
      status: 'resolved',
      context: mitraGroupPostingContext,
      discovery: { mechanism: 'test', adapter: 'mitra_group', authority: 'compatibility' },
      viewerEvidence: {
        permissions: { create: { status: 'allowed', source: 'fep-5219', viaRelationship: 'member', authority: 'protocol' } },
      },
      receivedAt: now,
    });
    const confirmed = selectComposerEffectiveCreateCapability(
      base.set('posting_contexts', ImmutableMap({ 456: discovery })),
      composerId,
      now,
    );

    expect(returned.get('surfaceMismatch')).toBe(false);
    expect(returned.get('posting_context_account_id')).toEqual('456');
    expect(unconfirmed.canAttempt).toBe(false);
    expect(unconfirmed.reason).toEqual('delivery_unresolved');
    expect(confirmed.canAttempt).toBe(true);
  });
});
