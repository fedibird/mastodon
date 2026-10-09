import { Map as ImmutableMap, List as ImmutableList, Set as ImmutableSet, fromJS } from 'immutable';
import { applyMiddleware, createStore } from 'redux';
import thunk from 'redux-thunk';

jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

jest.mock('../../api', () => ({
  __esModule: true,
  default: jest.fn(),
}));

import api from '../../api';
import { COMPOSE_CHANGE, COMPOSE_POLL_ADD, COMPOSE_REPLY, COMPOSE_SUBMIT_SUCCESS, COMPOSE_VISIBILITY_CHANGE } from '../compose';
import { acceptComposerSurface, applyComposerSurface, createComposer, targetComposerAction } from '../composer';
import {
  fetchUserPostingContextAssignment,
  resetGuardedPlaceDefault,
  resetUserPostingContextAssignment,
  saveGuardedPlaceDefault,
  saveUserPostingContextAssignment,
} from '../user_posting_context_assignments';
import { USER_POSTING_STYLES_FETCH_SUCCESS, maybeAutoSelectPortablePostingStyle } from '../user_posting_styles';
import { selectComposerEffectiveCreateCapability } from '../../posting_context/create_capability';
import { groupPostingContext } from '../../posting_context/fixtures/group_context_fixture';
import composer from '../../reducers/composer';
import composers from '../../reducers/composers';
import userPostingContextAssignments from '../../reducers/user_posting_context_assignments';
import userPostingStyles from '../../reducers/user_posting_styles';
import { PRIMARY_COMPOSER_ID } from '../../utils/composer';

const groupStyle = (id, accountId, extra = {}) => fromJS({
  id,
  name: `Group ${id}`,
  revision: 1,
  target: { kind: 'group', accountId, hashtag: null, label: `group-${accountId}` },
  defaults: { visibility: 'unlisted' },
  managed: { hashtags: [] },
  ...extra,
});

const plainStyle = fromJS({
  id: 'plain-1',
  name: '共通',
  revision: 1,
  target: { kind: 'none', accountId: null, hashtag: null, label: null },
  defaults: { visibility: 'public' },
  managed: { hashtags: [] },
});

const payload = (status, styleId, revision, surface = { kind: 'group', key: '123' }) => ({
  surface,
  status,
  style_id: styleId,
  revision,
});

const applyGroup = (composerId, accountId) => (
  composer(undefined, applyComposerSurface(composerId, { kind: 'group', key: String(accountId) }, groupPostingContext, String(accountId)))
);

const withStyles = styles => ({
  type: USER_POSTING_STYLES_FETCH_SUCCESS,
  styles,
});

const reduce = (state, action) => {
  if (!state || !action || action.type === '@@INIT') {
    return state;
  }

  return state
    .set('composers', composers(state.get('composers'), action))
    .set('compose', composer(state.get('compose'), action))
    .set('userPostingStyles', userPostingStyles(state.get('userPostingStyles'), action))
    .set('userPostingContextAssignments', userPostingContextAssignments(state.get('userPostingContextAssignments'), action));
};

const buildStore = ({ composerId = 'portable:group-column:123', drafted, styles = ImmutableList(), extra = ImmutableMap() } = {}) => {
  let registry = composers(undefined, createComposer(composerId));

  if (drafted) {
    registry = registry.setIn(['byId', composerId], drafted);
  }

  return createStore(reduce, ImmutableMap({
    compose: composer(undefined, { type: '@@INIT' }),
    composers: registry,
    userPostingStyles: userPostingStyles(undefined, withStyles(styles)),
    userPostingContextAssignments: userPostingContextAssignments(undefined, { type: '@@INIT' }),
    relationships: ImmutableMap(),
    posting_contexts: ImmutableMap(),
  }).merge(extra), applyMiddleware(thunk));
};

const assignmentOf = (store, kind, key) => (
  store.getState().getIn(['userPostingContextAssignments', 'bySurface', `${kind}:${key}`])
);

describe('place posting-style defaults', () => {
  beforeEach(() => {
    api.mockReset();
  });

  it('prefers a saved style over the single dedicated guess', async () => {
    const composerId = 'portable:group-column:123';
    const store = buildStore({
      composerId,
      drafted: applyGroup(composerId, '123'),
      styles: ImmutableList([groupStyle('1', '123'), plainStyle]),
    });
    api.mockReturnValue({
      get: jest.fn(() => Promise.resolve({ data: payload('style', 'plain-1', 4) })),
    });

    await store.dispatch(fetchUserPostingContextAssignment({ kind: 'group', key: '123' }));
    await store.dispatch(maybeAutoSelectPortablePostingStyle(composerId));

    const next = store.getState().getIn(['composers', 'byId', composerId]);

    expect(next.getIn(['userPostingStyle', 'selectedId'])).toEqual('plain-1');
    expect(next.getIn(['userPostingStyle', 'selectionOrigin'])).toEqual('saved_default');
    expect(next.get('privacy')).toEqual('public');
    expect(next.get('posting_context_account_id')).toEqual('123');
    expect(next.getIn(['context', 'managed', 'mentions', 0, 'acct'])).toEqual('group');
    expect(next.getIn(['context', 'protocol', 'activityPub', 'audience'])).toBeNull();
  });

  it('does not guess when the saved choice is none or unavailable', async () => {
    const composerId = 'portable:group-column:123';
    const drafted = applyGroup(composerId, '123');

    for (const status of ['none', 'unavailable']) {
      const store = buildStore({
        composerId,
        drafted,
        styles: ImmutableList([groupStyle('1', '123')]),
      });
      api.mockReturnValue({
        get: jest.fn(() => Promise.resolve({ data: payload(status, status === 'unavailable' ? '1' : null, 2) })),
      });

      await store.dispatch(fetchUserPostingContextAssignment({ kind: 'group', key: '123' }));
      await store.dispatch(maybeAutoSelectPortablePostingStyle(composerId));

      expect(store.getState().getIn(['composers', 'byId', composerId, 'userPostingStyle', 'selectedId'])).toBeNull();
    }
  });

  it('keeps the one-dedicated-style guess when the place is unset', async () => {
    const composerId = 'portable:group-column:123';
    const store = buildStore({
      composerId,
      drafted: applyGroup(composerId, '123'),
      styles: ImmutableList([groupStyle('1', '123'), plainStyle, groupStyle('9', '999')]),
    });
    api.mockReturnValue({
      get: jest.fn(() => Promise.resolve({ data: payload('unset', null, null) })),
    });

    await store.dispatch(fetchUserPostingContextAssignment({ kind: 'group', key: '123' }));
    await store.dispatch(maybeAutoSelectPortablePostingStyle(composerId));

    const next = store.getState().getIn(['composers', 'byId', composerId]);

    expect(next.getIn(['userPostingStyle', 'selectedId'])).toEqual('1');
    expect(next.getIn(['userPostingStyle', 'selectionOrigin'])).toEqual('automatic');
  });

  it('waits for both the catalog and the place, in either order, before choosing', async () => {
    const composerId = 'portable:group-column:123';
    const styles = ImmutableList([groupStyle('1', '123'), plainStyle]);
    const store = buildStore({
      composerId,
      drafted: applyGroup(composerId, '123'),
      styles: ImmutableList(),
    });
    api.mockReturnValue({
      get: jest.fn(() => Promise.resolve({ data: payload('style', 'plain-1', 1) })),
    });

    await store.dispatch(maybeAutoSelectPortablePostingStyle(composerId));
    expect(store.getState().getIn(['composers', 'byId', composerId, 'userPostingStyle', 'selectedId'])).toBeNull();

    await store.dispatch(fetchUserPostingContextAssignment({ kind: 'group', key: '123' }));
    await store.dispatch(maybeAutoSelectPortablePostingStyle(composerId));
    expect(store.getState().getIn(['composers', 'byId', composerId, 'userPostingStyle', 'selectedId'])).toBeNull();

    store.dispatch(withStyles(styles));
    await store.dispatch(maybeAutoSelectPortablePostingStyle(composerId));

    expect(store.getState().getIn(['composers', 'byId', composerId, 'userPostingStyle', 'selectedId'])).toEqual('plain-1');
    expect(store.getState().getIn(['composers', 'byId', composerId, 'privacy'])).toEqual('public');
  });

  it('does not guess a dedicated style when the place could not be loaded', async () => {
    const composerId = 'portable:group-column:123';
    const store = buildStore({
      composerId,
      drafted: applyGroup(composerId, '123'),
      styles: ImmutableList([groupStyle('1', '123')]),
    });
    api.mockReturnValue({
      get: jest.fn(() => Promise.reject(new Error('offline'))),
    });

    await store.dispatch(fetchUserPostingContextAssignment({ kind: 'group', key: '123' }));
    await store.dispatch(maybeAutoSelectPortablePostingStyle(composerId));

    expect(assignmentOf(store, 'group', '123').get('status')).toEqual('failed');
    expect(assignmentOf(store, 'group', '123').get('failure')).toEqual('fetch');
    expect(assignmentOf(store, 'group', '123').get('assignmentStatus')).toBeNull();
    expect(store.getState().getIn(['composers', 'byId', composerId, 'userPostingStyle', 'selectedId'])).toBeNull();
  });

  it('does not overwrite a draft, a manual choice, or another composer', async () => {
    const leftId = 'portable:group-column:a';
    const rightId = 'portable:group-column:b';
    let left = applyGroup(leftId, '123');
    left = composer(left, { type: COMPOSE_CHANGE, text: 'already writing' });
    let right = applyGroup(rightId, '123');
    right = composer(right, { type: COMPOSE_VISIBILITY_CHANGE, value: 'public' });
    let registry = composers(undefined, createComposer(leftId));
    registry = composers(registry, createComposer(rightId));
    registry = registry.setIn(['byId', leftId], left).setIn(['byId', rightId], right);
    const store = createStore(reduce, ImmutableMap({
      compose: composer(undefined, { type: '@@INIT' }),
      composers: registry,
      userPostingStyles: userPostingStyles(undefined, withStyles(ImmutableList([groupStyle('1', '123'), plainStyle]))),
      userPostingContextAssignments: userPostingContextAssignments(undefined, { type: '@@INIT' }),
      relationships: ImmutableMap(),
      posting_contexts: ImmutableMap(),
    }), applyMiddleware(thunk));
    api.mockReturnValue({
      get: jest.fn(() => Promise.resolve({ data: payload('style', 'plain-1', 3) })),
    });

    await store.dispatch(fetchUserPostingContextAssignment({ kind: 'group', key: '123' }));
    await store.dispatch(maybeAutoSelectPortablePostingStyle(leftId));
    await store.dispatch(maybeAutoSelectPortablePostingStyle(rightId));

    expect(store.getState().getIn(['userPostingContextAssignments', 'bySurface']).size).toEqual(1);
    expect(store.getState().getIn(['composers', 'byId', leftId, 'text'])).toEqual('already writing');
    expect(store.getState().getIn(['composers', 'byId', leftId, 'userPostingStyle', 'selectedId'])).toBeNull();
    expect(store.getState().getIn(['composers', 'byId', rightId, 'privacy'])).toEqual('public');
    expect(store.getState().getIn(['composers', 'byId', rightId, 'userPostingStyle', 'selectedId'])).toBeNull();

    const freshId = 'portable:group-column:c';
    store.dispatch(createComposer(freshId));
    store.dispatch(applyComposerSurface(freshId, { kind: 'group', key: '123' }, groupPostingContext, '123'));
    await store.dispatch(maybeAutoSelectPortablePostingStyle(freshId));

    expect(store.getState().getIn(['composers', 'byId', freshId, 'userPostingStyle', 'selectedId'])).toEqual('plain-1');
    expect(store.getState().getIn(['composers', 'byId', leftId, 'text'])).toEqual('already writing');
  });

  it('leaves a manual selection on one composer alone', async () => {
    const manualId = 'portable:group-column:manual';
    const otherId = 'portable:group-column:other';
    let manual = applyGroup(manualId, '123');
    manual = composer(manual, {
      type: 'USER_POSTING_STYLE_COMMIT',
      plan: {
        blocked: false,
        selectedId: '1',
        revision: 1,
        fields: { privacy: 'public' },
        ownedFields: ['privacy'],
        unapplied: [],
        destination: { action: 'keep', accountId: null, hashtag: null, changes: false, policy: 'locked' },
      },
      snapshot: groupStyle('1', '123'),
      resetSuppressions: true,
      selectionOrigin: 'manual',
    });
    let registry = composers(undefined, createComposer(manualId));
    registry = composers(registry, createComposer(otherId));
    registry = registry.setIn(['byId', manualId], manual);
    registry = registry.setIn(['byId', otherId], applyGroup(otherId, '123'));
    const store = createStore(reduce, ImmutableMap({
      compose: composer(undefined, { type: '@@INIT' }),
      composers: registry,
      userPostingStyles: userPostingStyles(undefined, withStyles(ImmutableList([groupStyle('1', '123'), plainStyle]))),
      userPostingContextAssignments: userPostingContextAssignments(undefined, { type: '@@INIT' }),
    }), applyMiddleware(thunk));
    api.mockReturnValue({
      get: jest.fn(() => Promise.resolve({ data: payload('style', 'plain-1', 1) })),
    });

    await store.dispatch(fetchUserPostingContextAssignment({ kind: 'group', key: '123' }));
    await store.dispatch(maybeAutoSelectPortablePostingStyle(manualId));
    await store.dispatch(maybeAutoSelectPortablePostingStyle(otherId));

    expect(store.getState().getIn(['composers', 'byId', manualId, 'userPostingStyle', 'selectedId'])).toEqual('1');
    expect(store.getState().getIn(['composers', 'byId', manualId, 'userPostingStyle', 'selectionOrigin'])).toEqual('manual');
    expect(store.getState().getIn(['composers', 'byId', otherId, 'userPostingStyle', 'selectedId'])).toEqual('plain-1');
    expect(store.getState().getIn(['composers', 'byId', otherId, 'userPostingStyle', 'selectionOrigin'])).toEqual('saved_default');
  });

  it('does not apply a saved style that disagrees with the surface or the create rules', async () => {
    const composerId = 'portable:group-column:123';
    const violating = groupStyle('1', '123', { defaults: { visibility: 'private' } });
    const foreign = groupStyle('9', '999', { defaults: { visibility: 'unlisted' } });
    const now = 1_700_000_000_000;
    const store = buildStore({
      composerId,
      drafted: applyGroup(composerId, '123'),
      styles: ImmutableList([violating, foreign]),
      extra: ImmutableMap({
        posting_contexts: ImmutableMap({
          123: fromJS({
            status: 'resolved',
            context: groupPostingContext,
            discovery: { mechanism: 'built_in', adapter: 'fedibird_group', authority: 'server' },
            receivedAt: now,
          }),
        }),
      }),
    });
    api.mockReturnValue({
      get: jest.fn(() => Promise.resolve({ data: payload('style', '9', 1) })),
    });

    await store.dispatch(fetchUserPostingContextAssignment({ kind: 'group', key: '123' }));
    await store.dispatch(maybeAutoSelectPortablePostingStyle(composerId));

    let next = store.getState().getIn(['composers', 'byId', composerId]);

    expect(next.getIn(['userPostingStyle', 'selectedId'])).toBeNull();
    expect(next.get('posting_context_account_id')).toEqual('123');
    expect(next.getIn(['context', 'managed', 'mentions', 0, 'acct'])).toEqual('group');

    api.mockReturnValue({
      get: jest.fn(() => Promise.resolve({ data: payload('style', '1', 2) })),
    });
    await store.dispatch(fetchUserPostingContextAssignment({ kind: 'group', key: '123' }, { force: true }));
    await store.dispatch(maybeAutoSelectPortablePostingStyle(composerId));
    next = store.getState().getIn(['composers', 'byId', composerId]);
    const capability = selectComposerEffectiveCreateCapability(store.getState(), composerId, now);

    expect(next.getIn(['userPostingStyle', 'selectedId'])).toBeNull();
    expect(next.get('privacy')).not.toEqual('private');
    expect(next.get('posting_context_account_id')).toEqual('123');
    expect(capability.canAttempt).toBe(false);
    expect(next.getIn(['context', 'protocol', 'activityPub', 'audience'])).toBeNull();
  });

  it('does not let a stale read replace a newer save, or a save land on another place', async () => {
    const store = buildStore();
    let resolveGet;
    const puts = [];
    const get = jest.fn(() => new Promise(resolve => {
      resolveGet = resolve;
    }));
    const put = jest.fn(() => new Promise(resolve => {
      puts.push(resolve);
    }));
    api.mockReturnValue({ get, put });

    const pendingGet = store.dispatch(fetchUserPostingContextAssignment({ kind: 'group', key: '123' }));
    await Promise.resolve();
    const pendingPut = store.dispatch(saveUserPostingContextAssignment({ kind: 'group', key: '123' }, '9'));
    const pendingOther = store.dispatch(saveUserPostingContextAssignment({ kind: 'hashtag', key: 'foo' }, '9'));
    expect(get).toHaveBeenCalledTimes(1);
    expect(put).toHaveBeenCalledTimes(2);

    store.dispatch(fetchUserPostingContextAssignment({ kind: 'group', key: '123' }));
    expect(get).toHaveBeenCalledTimes(1);

    puts[0]({ data: payload('style', '9', 5) });
    await pendingPut;
    resolveGet({ data: payload('unset', null, null) });
    await pendingGet;

    expect(assignmentOf(store, 'group', '123').get('status')).toEqual('ready');
    expect(assignmentOf(store, 'group', '123').get('assignmentStatus')).toEqual('style');
    expect(assignmentOf(store, 'group', '123').get('styleId')).toEqual('9');
    expect(assignmentOf(store, 'hashtag', 'foo').get('status')).toEqual('saving');

    puts[1]({ data: payload('style', '9', 1, { kind: 'hashtag', key: 'foo' }) });
    await pendingOther;

    expect(assignmentOf(store, 'hashtag', 'foo').get('assignmentStatus')).toEqual('style');
    expect(assignmentOf(store, 'group', '123').get('styleId')).toEqual('9');
  });

  it('keeps a failed save from looking saved and leaves the composer untouched', async () => {
    const composerId = 'portable:group-column:123';
    const store = buildStore({
      composerId,
      drafted: composer(applyGroup(composerId, '123'), { type: COMPOSE_CHANGE, text: 'Hello' }),
    });
    api.mockReturnValue({
      get: jest.fn(() => Promise.resolve({ data: payload('unset', null, null) })),
      put: jest.fn(() => Promise.reject(new Error('nope'))),
    });

    await store.dispatch(fetchUserPostingContextAssignment({ kind: 'group', key: '123' }));
    await store.dispatch(saveUserPostingContextAssignment({ kind: 'group', key: '123' }, '9'));

    const entry = assignmentOf(store, 'group', '123');
    const next = store.getState().getIn(['composers', 'byId', composerId]);

    expect(entry.get('failure')).toEqual('save');
    expect(entry.get('assignmentStatus')).toEqual('unset');
    expect(entry.get('styleId')).toBeNull();
    expect(entry.get('status')).toEqual('ready');
    expect(next.get('text')).toEqual('Hello');
    expect(next.get('privacy')).toBeNull();
    expect(next.getIn(['userPostingStyle', 'selectedId'])).toBeNull();
  });

  it('reapplies the selected style after a successful post and does not start another guess', async () => {
    const composerId = 'portable:group-column:123';
    let drafted = applyGroup(composerId, '123');
    drafted = composer(drafted, {
      type: 'USER_POSTING_STYLE_COMMIT',
      plan: {
        blocked: false,
        selectedId: 'plain-1',
        revision: 1,
        fields: { privacy: 'public' },
        ownedFields: ['privacy'],
        unapplied: [],
        destination: { action: 'keep', accountId: null, hashtag: null, changes: false, policy: 'locked' },
      },
      snapshot: plainStyle,
      resetSuppressions: true,
      selectionOrigin: 'saved_default',
    });
    drafted = composer(drafted, { type: COMPOSE_CHANGE, text: 'Sent' });
    const store = buildStore({
      composerId,
      drafted,
      styles: ImmutableList([groupStyle('1', '123'), plainStyle]),
    });
    api.mockReturnValue({
      get: jest.fn(() => Promise.resolve({ data: payload('style', 'plain-1', 1) })),
    });

    await store.dispatch(fetchUserPostingContextAssignment({ kind: 'group', key: '123' }));
    const posted = composer(store.getState().getIn(['composers', 'byId', composerId]), { type: COMPOSE_SUBMIT_SUCCESS });

    expect(posted.get('text')).toEqual('');
    expect(posted.get('privacy')).toEqual('public');
    expect(posted.getIn(['userPostingStyle', 'selectedId'])).toEqual('plain-1');
    expect(posted.getIn(['userPostingStyle', 'selectionOrigin'])).toEqual('saved_default');
    expect(posted.get('posting_context_account_id')).toEqual('123');
  });

  it('does not change the primary composer from a place default', async () => {
    const store = buildStore({
      styles: ImmutableList([groupStyle('1', '123')]),
    });
    api.mockReturnValue({
      get: jest.fn(() => Promise.resolve({ data: payload('style', '1', 1) })),
    });

    await store.dispatch(fetchUserPostingContextAssignment({ kind: 'group', key: '123' }));
    await store.dispatch(maybeAutoSelectPortablePostingStyle(PRIMARY_COMPOSER_ID));

    expect(store.getState().getIn(['compose', 'userPostingStyle', 'selectedId'])).toBeNull();
    expect(store.getState().get('compose').get('surface')).toBeNull();
    expect(store.getState().getIn(['compose', 'posting_context_account_id'])).toBeNull();
  });

  it('clears a place back to unset without writing that result onto a draft', async () => {
    const composerId = 'portable:group-column:123';
    const store = buildStore({
      composerId,
      drafted: composer(applyGroup(composerId, '123'), { type: COMPOSE_POLL_ADD }),
      styles: ImmutableList([groupStyle('1', '123')]),
    });
    api.mockReturnValue({
      get: jest.fn(() => Promise.resolve({ data: payload('none', null, 2) })),
      delete: jest.fn(() => Promise.resolve({ data: payload('unset', null, null) })),
    });

    await store.dispatch(fetchUserPostingContextAssignment({ kind: 'group', key: '123' }));
    await store.dispatch(maybeAutoSelectPortablePostingStyle(composerId));
    expect(store.getState().getIn(['composers', 'byId', composerId, 'userPostingStyle', 'selectedId'])).toBeNull();

    await store.dispatch(resetUserPostingContextAssignment({ kind: 'group', key: '123' }));

    expect(assignmentOf(store, 'group', '123').get('assignmentStatus')).toEqual('unset');
    expect(store.getState().getIn(['composers', 'byId', composerId, 'poll'])).not.toBeNull();
    expect(store.getState().getIn(['composers', 'byId', composerId, 'userPostingStyle', 'selectedId'])).toBeNull();
  });

  it('skips replies when applying a saved default', async () => {
    const composerId = 'portable:group-column:123';
    let drafted = applyGroup(composerId, '123');
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
    const store = buildStore({
      composerId,
      drafted,
      styles: ImmutableList([plainStyle]),
    });
    api.mockReturnValue({
      get: jest.fn(() => Promise.resolve({ data: payload('style', 'plain-1', 1) })),
    });

    await store.dispatch(fetchUserPostingContextAssignment({ kind: 'group', key: '123' }));
    await store.dispatch(maybeAutoSelectPortablePostingStyle(composerId));

    const next = store.getState().getIn(['composers', 'byId', composerId]);

    expect(next.get('in_reply_to')).toEqual('status-1');
    expect(next.getIn(['userPostingStyle', 'selectedId'])).toBeNull();
    expect(next.get('privacy')).not.toEqual('private');
  });

  it('does not repeat a failed place read until an explicit retry or another place', async () => {
    const store = buildStore();
    const get = jest.fn()
      .mockRejectedValueOnce(new Error('down'))
      .mockRejectedValueOnce(new Error('down'))
      .mockResolvedValueOnce({ data: payload('unset', null, null, { kind: 'hashtag', key: 'books' }) });

    api.mockReturnValue({ get });

    await store.dispatch(fetchUserPostingContextAssignment({ kind: 'group', key: '123' }));
    await store.dispatch(fetchUserPostingContextAssignment({ kind: 'group', key: '123' }));
    await store.dispatch(fetchUserPostingContextAssignment({ kind: 'group', key: '123' }));

    expect(get).toHaveBeenCalledTimes(1);
    expect(assignmentOf(store, 'group', '123').get('status')).toEqual('failed');
    expect(assignmentOf(store, 'group', '123').get('failure')).toEqual('fetch');

    await store.dispatch(fetchUserPostingContextAssignment({ kind: 'group', key: '123' }, { force: true }));

    expect(get).toHaveBeenCalledTimes(2);
    expect(assignmentOf(store, 'group', '123').get('status')).toEqual('failed');

    await store.dispatch(fetchUserPostingContextAssignment({ kind: 'hashtag', key: 'books' }));

    expect(get).toHaveBeenCalledTimes(3);
    expect(assignmentOf(store, 'hashtag', 'books').get('status')).toEqual('ready');
    expect(assignmentOf(store, 'hashtag', 'books').get('assignmentStatus')).toEqual('unset');
  });

  it('does not reapply a changed place default onto composers that already considered that place', async () => {
    const openId = 'portable:group-column:open';
    const siblingId = 'portable:group-column:sibling';
    const freshId = 'portable:group-column:fresh';
    let drafted = applyGroup(openId, '123');

    drafted = composer(drafted, { type: COMPOSE_CHANGE, text: 'keep me' });
    drafted = composer(drafted, { type: COMPOSE_VISIBILITY_CHANGE, value: 'private' });
    drafted = drafted.setIn(['context', 'suppressions', 'hashtags'], ImmutableSet(['kept']));

    const store = buildStore({
      composerId: openId,
      drafted,
      styles: ImmutableList([groupStyle('1', '123')]),
    });

    store.dispatch(createComposer(siblingId));
    store.dispatch(applyComposerSurface(siblingId, { kind: 'group', key: '123' }, groupPostingContext, '123'));
    store.dispatch(targetComposerAction({ type: COMPOSE_CHANGE, text: 'sibling draft' }, siblingId));

    api.mockReturnValue({
      get: jest.fn(() => Promise.resolve({ data: payload('none', null, 2) })),
      delete: jest.fn(() => Promise.resolve({ data: payload('unset', null, null) })),
    });

    await store.dispatch(fetchUserPostingContextAssignment({ kind: 'group', key: '123' }));
    await store.dispatch(maybeAutoSelectPortablePostingStyle(openId));
    await store.dispatch(maybeAutoSelectPortablePostingStyle(siblingId));
    await store.dispatch(resetUserPostingContextAssignment({ kind: 'group', key: '123' }));
    await store.dispatch(maybeAutoSelectPortablePostingStyle(openId));
    await store.dispatch(maybeAutoSelectPortablePostingStyle(siblingId));

    const open = store.getState().getIn(['composers', 'byId', openId]);
    const sibling = store.getState().getIn(['composers', 'byId', siblingId]);

    expect(assignmentOf(store, 'group', '123').get('assignmentStatus')).toEqual('unset');
    expect(open.get('text')).toEqual('keep me');
    expect(open.get('privacy')).toEqual('private');
    expect(open.getIn(['context', 'suppressions', 'hashtags']).includes('kept')).toBe(true);
    expect(open.get('posting_context_account_id')).toEqual('123');
    expect(open.getIn(['userPostingStyle', 'selectedId'])).toBeNull();
    expect(sibling.get('text')).toEqual('sibling draft');
    expect(sibling.getIn(['userPostingStyle', 'selectedId'])).toBeNull();

    store.dispatch(createComposer(freshId));
    store.dispatch(applyComposerSurface(freshId, { kind: 'group', key: '123' }, groupPostingContext, '123'));
    await store.dispatch(maybeAutoSelectPortablePostingStyle(freshId));

    const fresh = store.getState().getIn(['composers', 'byId', freshId]);

    expect(fresh.getIn(['userPostingStyle', 'selectedId'])).toEqual('1');
    expect(fresh.getIn(['userPostingStyle', 'selectionOrigin'])).toEqual('automatic');
    expect(store.getState().getIn(['composers', 'byId', openId, 'userPostingStyle', 'selectedId'])).toBeNull();
    expect(store.getState().getIn(['composers', 'byId', openId, 'text'])).toEqual('keep me');
  });

  it('refuses place-default writes until the displayed destination is the draft destination', async () => {
    const composerId = 'portable:group-column:draft';
    let drafted = applyGroup(composerId, '111');

    drafted = composer(drafted, { type: COMPOSE_CHANGE, text: 'moving' });

    const store = buildStore({
      composerId,
      drafted,
      styles: ImmutableList([groupStyle('1', '111'), groupStyle('2', '222')]),
    });
    const put = jest.fn(() => Promise.resolve({ data: payload('none', null, 3, { kind: 'group', key: '222' }) }));
    const remove = jest.fn(() => Promise.resolve({ data: payload('unset', null, null, { kind: 'group', key: '222' }) }));

    api.mockReturnValue({ put, delete: remove });

    store.dispatch(applyComposerSurface(composerId, { kind: 'group', key: '222' }, groupPostingContext, '222'));

    const moved = store.getState().getIn(['composers', 'byId', composerId]);

    expect(moved.get('surfaceMismatch')).toBe(true);
    expect(moved.getIn(['surface', 'key'])).toEqual('111');
    expect(moved.getIn(['displayedSurface', 'key'])).toEqual('222');

    await store.dispatch(saveGuardedPlaceDefault(composerId, '2'));
    await store.dispatch(saveGuardedPlaceDefault(composerId, null));
    await store.dispatch(resetGuardedPlaceDefault(composerId));

    expect(put).not.toHaveBeenCalled();
    expect(remove).not.toHaveBeenCalled();
    expect(assignmentOf(store, 'group', '111')).toBeUndefined();
    expect(assignmentOf(store, 'group', '222')).toBeUndefined();
    expect(moved.get('text')).toEqual('moving');

    store.dispatch(acceptComposerSurface(composerId));

    const accepted = store.getState().getIn(['composers', 'byId', composerId]);

    expect(accepted.get('surfaceMismatch')).toBe(false);
    expect(accepted.getIn(['surface', 'key'])).toEqual('222');
    expect(accepted.getIn(['displayedSurface', 'key'])).toEqual('222');

    await store.dispatch(saveGuardedPlaceDefault(composerId, null));

    expect(put).toHaveBeenCalledTimes(1);
    expect(put.mock.calls[0][1]).toEqual({
      surface_kind: 'group',
      surface_key: '222',
      style_id: null,
    });
    expect(remove).not.toHaveBeenCalled();
    expect(assignmentOf(store, 'group', '111')).toBeUndefined();
    expect(store.getState().getIn(['composers', 'byId', composerId, 'text'])).toEqual('moving');

    store.dispatch(applyComposerSurface(composerId, { kind: 'group', key: '111' }, groupPostingContext, '111'));
    await store.dispatch(saveGuardedPlaceDefault(composerId, '1'));
    await store.dispatch(resetGuardedPlaceDefault(composerId));

    expect(put).toHaveBeenCalledTimes(1);
    expect(remove).not.toHaveBeenCalled();
  });
});
