import { List as ImmutableList, Map as ImmutableMap, Set as ImmutableSet, fromJS } from 'immutable';
import { applyMiddleware, createStore } from 'redux';
import thunk from 'redux-thunk';

jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

jest.mock('../../initial_state', () => ({
  ...jest.requireActual('../../initial_state'),
  isAdministrator: true,
}));

jest.mock('../../api', () => ({
  __esModule: true,
  default: jest.fn(),
}));

import api from '../../api';
import { COMPOSE_CHANGE, COMPOSE_POLL_ADD, COMPOSE_POLL_OPTION_CHANGE, COMPOSE_REPLY_CANCEL, COMPOSE_RESET, COMPOSE_SPOILER_TEXT_CHANGE, COMPOSE_SPOILERNESS_CHANGE, COMPOSE_SUBMIT_FAIL, COMPOSE_SUBMIT_REQUEST, COMPOSE_SUBMIT_SUCCESS, SCHEDULED_STATUS_SUBMIT_SUCCESS, classifySubmission } from '../compose';
import { applyComposerSurface, createComposer, destroyComposer } from '../composer';
import {
  USER_POSTING_CONTEXT_ASSIGNMENT_FETCH_FAIL,
  USER_POSTING_CONTEXT_ASSIGNMENT_FETCH_REQUEST,
  USER_POSTING_CONTEXT_ASSIGNMENT_FETCH_SUCCESS,
} from '../user_posting_context_assignments';
import {
  USER_POSTING_STYLES_FETCH_SUCCESS,
  commitUserPostingStyle,
  retryUsualResolution,
  returnToUsualSelection,
  saveCurrentStyleAsUsual,
  settleUsualSelection,
} from '../user_posting_styles';
import { decideUsualSelection } from '../../posting_context/usual_selection';
import { selectComposerEffectiveCreateCapability } from '../../posting_context/create_capability';
import { groupPostingContext } from '../../posting_context/fixtures/group_context_fixture';
import composer from '../../reducers/composer';
import composers from '../../reducers/composers';
import userPostingContextAssignments from '../../reducers/user_posting_context_assignments';
import userPostingStyles from '../../reducers/user_posting_styles';
import { PRIMARY_COMPOSER_ID } from '../../utils/composer';

const style = (id, name, defaults = {}) => fromJS({
  id,
  name,
  revision: 1,
  target: { kind: 'none', accountId: null, hashtag: null, label: null },
  defaults,
  managed: { hashtags: [{ name: 'kept', normalizedName: 'kept' }] },
});

const groupStyle = (id, accountId) => fromJS({
  id,
  name: `Group ${id}`,
  revision: 1,
  target: { kind: 'group', accountId, hashtag: null, label: `group-${accountId}` },
  defaults: { visibility: 'unlisted' },
  managed: { hashtags: [] },
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

const buildStore = (styles = ImmutableList()) => createStore(reduce, ImmutableMap({
  compose: composer(undefined, { type: '@@INIT' }).set('default_privacy', 'unlisted'),
  composers: composers(undefined, { type: '@@INIT' }),
  userPostingStyles: userPostingStyles(undefined, { type: USER_POSTING_STYLES_FETCH_SUCCESS, styles }),
  userPostingContextAssignments: userPostingContextAssignments(undefined, { type: '@@INIT' }),
  relationships: ImmutableMap(),
}), applyMiddleware(thunk));

const loadGlobal = (store, assignmentStatus, styleId = null) => {
  store.dispatch({
    type: USER_POSTING_CONTEXT_ASSIGNMENT_FETCH_SUCCESS,
    scope: 'global',
    surfaceKey: 'global:default',
    assignment: {
      surface: { kind: 'global', key: 'default' },
      assignmentStatus,
      styleId,
      revision: 1,
    },
    generation: store.getState().getIn(['userPostingContextAssignments', 'global', 'generation']) || 0,
  });
};

const loadPlace = (store, assignmentStatus, styleId = null, key = '123') => {
  const surfaceKey = `group:${key}`;

  store.dispatch({
    type: USER_POSTING_CONTEXT_ASSIGNMENT_FETCH_SUCCESS,
    surfaceKey,
    assignment: {
      surface: { kind: 'group', key },
      assignmentStatus,
      styleId,
      revision: 2,
    },
    generation: store.getState().getIn(['userPostingContextAssignments', 'bySurface', surfaceKey, 'generation']) || 0,
  });
};

const primary = store => store.getState().get('compose');

const snapshotOf = (record, extra = {}) => ({
  token: record.get('idempotencyKey'),
  instanceId: record.get('instanceId'),
  selectionGeneration: record.getIn(['userPostingStyle', 'selectionGeneration']) || 0,
  draftGeneration: record.get('draftGeneration') || 0,
  text: record.get('text') || '',
  mediaIds: '',
  surface: record.get('surface') ? { kind: record.get('surface').get('kind'), key: record.get('surface').get('key') } : null,
  senderIdentityId: record.getIn(['senderIdentity', 'id']) || null,
  kind: 'new',
  ...extra,
});

describe('usual style selection', () => {
  beforeEach(() => {
    api.mockReset();
    api.mockReturnValue({ put: jest.fn(() => Promise.resolve({ data: { surface: { kind: 'global', key: 'default' }, status: 'style', style_id: 'b', revision: 3 } })) });
  });

  it('returns a one-time style to the usual style and drops fields the usual style does not set', async () => {
    const styles = ImmutableList([
      style('a', 'Usual', { visibility: 'public' }),
      style('b', 'Once'),
    ]);
    const store = buildStore(styles);
    loadGlobal(store, 'style', 'a');
    await store.dispatch(settleUsualSelection(PRIMARY_COMPOSER_ID));

    expect(primary(store).getIn(['userPostingStyle', 'selectedId'])).toEqual('a');
    expect(primary(store).get('privacy')).toEqual('public');
    expect(primary(store).getIn(['userPostingStyle', 'usageMode'])).toEqual('usual');

    await store.dispatch(commitUserPostingStyle(PRIMARY_COMPOSER_ID, 'b'));
    expect(primary(store).get('privacy')).toEqual('unlisted');
    expect(primary(store).getIn(['userPostingStyle', 'usageMode'])).toEqual('once');
    expect(primary(store).getIn(['userPostingStyle', 'selectionKind'])).toEqual('style');

    store.dispatch({ type: COMPOSE_CHANGE, text: 'Sent' });
    store.dispatch({ type: COMPOSE_SUBMIT_SUCCESS, submission: snapshotOf(primary(store)) });
    expect(primary(store).get('text')).toEqual('');
    expect(primary(store).getIn(['userPostingStyle', 'selectedId'])).toBeNull();
    expect(primary(store).getIn(['userPostingStyle', 'usageMode'])).toEqual('usual');

    await store.dispatch(settleUsualSelection(PRIMARY_COMPOSER_ID));
    expect(primary(store).getIn(['userPostingStyle', 'selectedId'])).toEqual('a');
    expect(primary(store).get('privacy')).toEqual('public');
    expect(primary(store).getIn(['senderIdentity', 'id']) || null).toBeNull();
  });

  it('returns an explicit one-time none to the usual style and keeps none when that choice is kept', async () => {
    const styles = ImmutableList([style('a', 'Usual', { visibility: 'public' })]);
    const store = buildStore(styles);
    loadGlobal(store, 'style', 'a');
    await store.dispatch(settleUsualSelection(PRIMARY_COMPOSER_ID));
    await store.dispatch(commitUserPostingStyle(PRIMARY_COMPOSER_ID, null, { selectionKind: 'none' }));

    expect(primary(store).getIn(['userPostingStyle', 'usageMode'])).toEqual('once');
    expect(primary(store).getIn(['userPostingStyle', 'selectionKind'])).toEqual('none');
    expect(primary(store).get('privacy')).toEqual('unlisted');

    store.dispatch({ type: COMPOSE_CHANGE, text: 'Plain' });
    store.dispatch({ type: COMPOSE_SUBMIT_SUCCESS, submission: snapshotOf(primary(store)) });
    await store.dispatch(settleUsualSelection(PRIMARY_COMPOSER_ID));
    expect(primary(store).getIn(['userPostingStyle', 'selectedId'])).toEqual('a');

    await store.dispatch(commitUserPostingStyle(PRIMARY_COMPOSER_ID, null, { usageMode: 'keep', selectionKind: 'none' }));
    store.dispatch({ type: COMPOSE_CHANGE, text: 'Stay' });
    store.dispatch({ type: COMPOSE_SUBMIT_SUCCESS, submission: snapshotOf(primary(store)) });
    expect(primary(store).get('text')).toEqual('');
    expect(primary(store).getIn(['userPostingStyle', 'selectedId'])).toBeNull();
    expect(primary(store).getIn(['userPostingStyle', 'selectionKind'])).toEqual('none');
    expect(primary(store).getIn(['userPostingStyle', 'usageMode'])).toEqual('keep');
    expect(primary(store).get('privacy')).toEqual('unlisted');
  });

  it('keeps a chosen style, clears its hashtag suppression, and makes the next choice one-time', async () => {
    const styles = ImmutableList([
      style('a', 'Usual', { visibility: 'public' }),
      style('b', 'Kept', { visibility: 'private' }),
      style('c', 'Next', { visibility: 'public' }),
    ]);
    const store = buildStore(styles);
    loadGlobal(store, 'none');
    await store.dispatch(settleUsualSelection(PRIMARY_COMPOSER_ID));
    await store.dispatch(commitUserPostingStyle(PRIMARY_COMPOSER_ID, 'b', { usageMode: 'keep' }));
    store.dispatch({
      type: 'USER_POSTING_STYLE_HASHTAG_TOGGLE',
      origin: 'style',
      normalizedName: 'kept',
    });
    expect(primary(store).getIn(['userPostingStyle', 'suppressions']).includes('style:kept')).toBe(true);

    store.dispatch({ type: COMPOSE_CHANGE, text: 'Keep me' });
    store.dispatch({ type: COMPOSE_SUBMIT_SUCCESS, submission: snapshotOf(primary(store)) });
    expect(primary(store).getIn(['userPostingStyle', 'selectedId'])).toEqual('b');
    expect(primary(store).getIn(['userPostingStyle', 'usageMode'])).toEqual('keep');
    expect(primary(store).getIn(['userPostingStyle', 'suppressions'])).toEqual(ImmutableSet());
    expect(primary(store).get('privacy')).toEqual('private');

    await store.dispatch(commitUserPostingStyle(PRIMARY_COMPOSER_ID, 'c'));
    expect(primary(store).getIn(['userPostingStyle', 'usageMode'])).toEqual('once');
    expect(primary(store).getIn(['userPostingStyle', 'selectedId'])).toEqual('c');
  });

  it('keeps the draft when sending fails and restores as soon as a new schedule is accepted', async () => {
    const styles = ImmutableList([style('a', 'Usual', { visibility: 'public' }), style('b', 'Once', { visibility: 'private' })]);
    const store = buildStore(styles);
    loadGlobal(store, 'style', 'a');
    await store.dispatch(settleUsualSelection(PRIMARY_COMPOSER_ID));
    await store.dispatch(commitUserPostingStyle(PRIMARY_COMPOSER_ID, 'b'));
    store.dispatch({ type: COMPOSE_CHANGE, text: 'Still here' });
    const before = primary(store);

    store.dispatch({ type: COMPOSE_SUBMIT_FAIL });
    expect(primary(store).get('text')).toEqual('Still here');
    expect(primary(store).getIn(['userPostingStyle', 'selectedId'])).toEqual('b');
    expect(primary(store).getIn(['userPostingStyle', 'usageMode'])).toEqual('once');

    store.dispatch({ type: SCHEDULED_STATUS_SUBMIT_SUCCESS, submission: snapshotOf(before, { kind: 'schedule' }) });
    await store.dispatch(settleUsualSelection(PRIMARY_COMPOSER_ID));
    expect(primary(store).get('text')).toEqual('');
    expect(primary(store).getIn(['userPostingStyle', 'selectedId'])).toEqual('a');
  });

  it('does not restore over an edit, a changed draft, a repeated success, or a recreated composer', async () => {
    const styles = ImmutableList([style('a', 'Usual', { visibility: 'public' }), style('b', 'Once', { visibility: 'private' })]);
    const store = buildStore(styles);
    loadGlobal(store, 'style', 'a');
    await store.dispatch(settleUsualSelection(PRIMARY_COMPOSER_ID));
    await store.dispatch(commitUserPostingStyle(PRIMARY_COMPOSER_ID, 'b'));
    store.dispatch({ type: COMPOSE_CHANGE, text: 'Editing' });
    const editing = primary(store).set('id', '99');
    const edited = composer(editing, { type: COMPOSE_SUBMIT_SUCCESS, submission: snapshotOf(editing, { kind: 'edit' }) });
    expect(edited.getIn(['userPostingStyle', 'selectedId'])).toEqual('b');
    expect(edited.getIn(['userPostingStyle', 'usageMode'])).toEqual('once');

    const sent = snapshotOf(primary(store), { text: 'Editing' });
    store.dispatch({ type: COMPOSE_CHANGE, text: 'Changed while sending' });
    store.dispatch({ type: COMPOSE_SUBMIT_SUCCESS, submission: sent });
    expect(primary(store).get('text')).toEqual('Changed while sending');
    expect(primary(store).getIn(['userPostingStyle', 'selectedId'])).toEqual('b');

    const current = snapshotOf(primary(store));
    store.dispatch({ type: COMPOSE_SUBMIT_SUCCESS, submission: current });
    expect(primary(store).get('text')).toEqual('');
    store.dispatch({ type: COMPOSE_CHANGE, text: 'Next draft' });
    store.dispatch({ type: COMPOSE_SUBMIT_SUCCESS, submission: current });
    expect(primary(store).get('text')).toEqual('Next draft');

    const composerId = 'portable:group-column:123';
    store.dispatch(createComposer(composerId));
    store.dispatch(applyComposerSurface(composerId, { kind: 'group', key: '123' }, groupPostingContext, '123'));
    await store.dispatch(commitUserPostingStyle(composerId, 'b'));
    store.dispatch({ type: COMPOSE_CHANGE, text: 'Portable', meta: { composerId } });
    const portable = store.getState().getIn(['composers', 'byId', composerId]);
    const stale = snapshotOf(portable);
    store.dispatch(destroyComposer(composerId));
    store.dispatch(createComposer(composerId));
    store.dispatch(applyComposerSurface(composerId, { kind: 'group', key: '123' }, groupPostingContext, '123'));
    store.dispatch({ type: COMPOSE_CHANGE, text: 'Rebuilt', meta: { composerId } });
    store.dispatch({ type: COMPOSE_SUBMIT_SUCCESS, submission: stale, meta: { composerId } });
    expect(store.getState().getIn(['composers', 'byId', composerId, 'text'])).toEqual('Rebuilt');
    expect(store.getState().getIn(['composers', 'byId', composerId, 'instanceId'])).not.toEqual(stale.instanceId);
  });

  it('discards a temporary choice on a new draft and leaves reply cancellation alone', async () => {
    const styles = ImmutableList([style('b', 'Once', { visibility: 'private' })]);
    const store = buildStore(styles);
    loadGlobal(store, 'none');
    await store.dispatch(settleUsualSelection(PRIMARY_COMPOSER_ID));
    await store.dispatch(commitUserPostingStyle(PRIMARY_COMPOSER_ID, 'b', { usageMode: 'keep' }));
    store.dispatch({ type: COMPOSE_REPLY_CANCEL });
    expect(primary(store).getIn(['userPostingStyle', 'usageMode'])).toEqual('keep');
    expect(primary(store).getIn(['userPostingStyle', 'selectedId'])).toEqual('b');

    store.dispatch({ type: COMPOSE_RESET });
    expect(primary(store).getIn(['userPostingStyle', 'usageMode'])).toEqual('usual');
    expect(primary(store).getIn(['userPostingStyle', 'selectionKind'])).toEqual('pending');
    expect(primary(store).get('text')).toEqual('');
  });

  it('saves the usual style without changing the open draft', async () => {
    const styles = ImmutableList([style('b', 'Once', { visibility: 'private' })]);
    const store = buildStore(styles);
    loadGlobal(store, 'none');
    await store.dispatch(settleUsualSelection(PRIMARY_COMPOSER_ID));
    await store.dispatch(commitUserPostingStyle(PRIMARY_COMPOSER_ID, 'b'));
    store.dispatch({ type: COMPOSE_CHANGE, text: 'Leave this' });
    const before = primary(store);

    await store.dispatch(saveCurrentStyleAsUsual(PRIMARY_COMPOSER_ID));
    expect(primary(store)).toBe(before);
    expect(api().put).toHaveBeenCalledWith('/api/v1/fedibird/user_posting_context_assignments', {
      surface_kind: 'global',
      surface_key: 'default',
      style_id: 'b',
    });
  });

  it('holds a new post until the usual choice is resolved or explicitly chosen', async () => {
    const store = buildStore(ImmutableList());
    store.dispatch({ type: 'USER_POSTING_STYLE_RESOLUTION', resolutionRequired: true, selectionKind: 'pending' });
    expect(selectComposerEffectiveCreateCapability(store.getState(), PRIMARY_COMPOSER_ID).canAttempt).toBe(false);
    expect(selectComposerEffectiveCreateCapability(store.getState(), PRIMARY_COMPOSER_ID).reason).toEqual('style_unresolved');

    await store.dispatch(commitUserPostingStyle(PRIMARY_COMPOSER_ID, null, { selectionKind: 'none' }));
    expect(selectComposerEffectiveCreateCapability(store.getState(), PRIMARY_COMPOSER_ID).reason).not.toEqual('style_unresolved');
  });

  it('prefers a place default over a dedicated style and an unfit usual style', () => {
    const composerId = 'portable:group-column:123';
    const store = buildStore(ImmutableList([
      groupStyle('dedicated', '123'),
      groupStyle('other', '999'),
      style('global-fit', 'Fits'),
      style('place', 'Place', { visibility: 'public' }),
    ]));
    store.dispatch(createComposer(composerId));
    store.dispatch(applyComposerSurface(composerId, { kind: 'group', key: '123' }, groupPostingContext, '123'));
    const drafted = store.getState().getIn(['composers', 'byId', composerId]);
    const styles = store.getState().getIn(['userPostingStyles', 'styles']);
    const globalFit = {
      get: key => ({ status: 'ready', assignmentStatus: 'style', styleId: 'global-fit', generation: 1 }[key]),
    };
    const place = status => ({
      get: key => ({ status: 'ready', assignmentStatus: status, styleId: status === 'style' ? 'place' : 'missing', generation: 1, writePending: false }[key]),
    });

    expect(decideUsualSelection({
      portable: true,
      composer: drafted,
      styles,
      placeAssignment: place('style'),
      globalAssignment: globalFit,
      catalogStatus: 'ready',
    }).style.get('id')).toEqual('place');

    expect(decideUsualSelection({
      portable: true,
      composer: drafted,
      styles,
      placeAssignment: place('none'),
      globalAssignment: globalFit,
      catalogStatus: 'ready',
    }).phase).toEqual('none');

    expect(decideUsualSelection({
      portable: true,
      composer: drafted,
      styles,
      placeAssignment: place('unavailable'),
      globalAssignment: globalFit,
      catalogStatus: 'ready',
    }).phase).toEqual('unavailable');

    const unset = place('unset');
    expect(decideUsualSelection({
      portable: true,
      composer: drafted,
      styles,
      placeAssignment: unset,
      globalAssignment: globalFit,
      catalogStatus: 'ready',
    }).style.get('id')).toEqual('dedicated');

    const many = store.getState().getIn(['userPostingStyles', 'styles']).push(groupStyle('second', '123'));
    expect(decideUsualSelection({
      portable: true,
      composer: drafted,
      styles: many,
      placeAssignment: unset,
      globalAssignment: globalFit,
      catalogStatus: 'ready',
    }).style.get('id')).toEqual('global-fit');

    const unfit = {
      get: key => ({ status: 'ready', assignmentStatus: 'style', styleId: 'other', generation: 1 }[key]),
    };
    expect(decideUsualSelection({
      portable: true,
      composer: drafted,
      styles: many,
      placeAssignment: unset,
      globalAssignment: unfit,
      catalogStatus: 'ready',
    })).toMatchObject({ phase: 'none', scope: 'global_unfit' });

    expect(decideUsualSelection({
      portable: true,
      composer: drafted,
      styles,
      placeAssignment: { get: key => ({ status: 'failed' }[key]) },
      globalAssignment: globalFit,
      catalogStatus: 'ready',
    }).phase).toEqual('failed');

    expect(decideUsualSelection({
      portable: true,
      composer: drafted,
      styles,
      placeAssignment: place('style'),
      globalAssignment: null,
      catalogStatus: 'loading',
    }).phase).toEqual('pending');
  });

  it('does not let a failed usual-style read replace a saved place style', async () => {
    const composerId = 'portable:group-column:123';
    const store = buildStore(ImmutableList([style('place', 'Place', { visibility: 'public' }), groupStyle('dedicated', '123')]));
    store.dispatch(createComposer(composerId));
    store.dispatch(applyComposerSurface(composerId, { kind: 'group', key: '123' }, groupPostingContext, '123'));
    loadPlace(store, 'style', 'place');
    store.dispatch({
      type: USER_POSTING_CONTEXT_ASSIGNMENT_FETCH_REQUEST,
      scope: 'global',
      surfaceKey: 'global:default',
      surface: { kind: 'global', key: 'default' },
      generation: 1,
    });
    store.dispatch({
      type: USER_POSTING_CONTEXT_ASSIGNMENT_FETCH_FAIL,
      scope: 'global',
      surfaceKey: 'global:default',
      generation: 1,
    });

    await store.dispatch(settleUsualSelection(composerId));
    expect(store.getState().getIn(['composers', 'byId', composerId, 'userPostingStyle', 'selectedId'])).toEqual('place');
    expect(store.getState().getIn(['composers', 'byId', composerId, 'privacy'])).toEqual('public');
  });

  it('clears the applied style when a post succeeds and the usual choice is now none', async () => {
    const styles = ImmutableList([style('a', 'Usual', { visibility: 'public' })]);
    const store = buildStore(styles);
    loadGlobal(store, 'style', 'a');
    await store.dispatch(settleUsualSelection(PRIMARY_COMPOSER_ID));
    expect(primary(store).get('privacy')).toEqual('public');

    loadGlobal(store, 'none');
    await store.dispatch(settleUsualSelection(PRIMARY_COMPOSER_ID));
    expect(primary(store).getIn(['userPostingStyle', 'selectedId'])).toEqual('a');
    expect(primary(store).get('privacy')).toEqual('public');

    store.dispatch({ type: COMPOSE_CHANGE, text: 'Send A' });
    store.dispatch({ type: COMPOSE_SUBMIT_SUCCESS, submission: snapshotOf(primary(store)) });
    await store.dispatch(settleUsualSelection(PRIMARY_COMPOSER_ID));

    expect(primary(store).getIn(['userPostingStyle', 'selectionKind'])).toEqual('none');
    expect(primary(store).getIn(['userPostingStyle', 'selectedId'])).toBeNull();
    expect(primary(store).getIn(['userPostingStyle', 'snapshot'])).toBeNull();
    expect(primary(store).get('privacy')).toEqual('unlisted');
    expect(primary(store).getIn(['userPostingStyle', 'suppressions'])).toEqual(ImmutableSet());
  });

  it('confirms usual none after text typed before the first read, without clearing that text', async () => {
    const store = buildStore(ImmutableList());
    store.dispatch({ type: 'USER_POSTING_STYLE_RESOLUTION', resolutionRequired: true, selectionKind: 'pending' });
    store.dispatch({ type: COMPOSE_CHANGE, text: 'Early' });
    await store.dispatch(settleUsualSelection(PRIMARY_COMPOSER_ID));
    expect(primary(store).getIn(['userPostingStyle', 'selectionKind'])).toEqual('pending');
    expect(primary(store).getIn(['userPostingStyle', 'defaultsSettledSurface'])).toBeNull();
    expect(selectComposerEffectiveCreateCapability(store.getState(), PRIMARY_COMPOSER_ID).canAttempt).toBe(false);

    loadGlobal(store, 'none');
    await store.dispatch(settleUsualSelection(PRIMARY_COMPOSER_ID));

    expect(primary(store).get('text')).toEqual('Early');
    expect(primary(store).getIn(['userPostingStyle', 'selectionKind'])).toEqual('none');
    expect(primary(store).getIn(['userPostingStyle', 'selectedId'])).toBeNull();
    expect(primary(store).getIn(['userPostingStyle', 'defaultsSettledSurface'])).toEqual('primary');
    expect(selectComposerEffectiveCreateCapability(store.getState(), PRIMARY_COMPOSER_ID).reason).not.toEqual('style_unresolved');
  });

  it('asks before returning to a fitting place style that would change visibility', async () => {
    const composerId = 'portable:group-column:123';
    const styles = ImmutableList([
      style('a', 'Public place', { visibility: 'public' }),
      style('b', 'Quiet', { visibility: 'unlisted' }),
    ]);
    const store = buildStore(styles);
    store.dispatch(createComposer(composerId));
    store.dispatch(applyComposerSurface(composerId, { kind: 'group', key: '123' }, groupPostingContext, '123'));
    loadPlace(store, 'style', 'a');
    await store.dispatch(settleUsualSelection(composerId));
    await store.dispatch(commitUserPostingStyle(composerId, 'b'));
    store.dispatch({ type: COMPOSE_CHANGE, text: 'Draft', meta: { composerId } });

    const portable = () => store.getState().getIn(['composers', 'byId', composerId]);
    const preview = store.dispatch(returnToUsualSelection(composerId));

    expect(preview.status).toEqual('confirm');
    expect(portable().getIn(['userPostingStyle', 'selectedId'])).toEqual('b');
    expect(portable().getIn(['userPostingStyle', 'usageMode'])).toEqual('once');
    expect(portable().get('text')).toEqual('Draft');

    const applied = store.dispatch(returnToUsualSelection(composerId, { confirmed: true }));
    expect(applied.status).toEqual('applied');
    expect(portable().getIn(['userPostingStyle', 'selectedId'])).toEqual('a');
    expect(portable().getIn(['userPostingStyle', 'usageMode'])).toEqual('usual');
    expect(portable().get('privacy')).toEqual('public');
    expect(portable().get('text')).toEqual('Draft');
  });

  it('reloads the usual style during a one-time choice without changing that choice', async () => {
    const styles = ImmutableList([style('b', 'Once', { visibility: 'private' })]);
    const store = buildStore(styles);
    store.dispatch({
      type: USER_POSTING_CONTEXT_ASSIGNMENT_FETCH_FAIL,
      scope: 'global',
      surfaceKey: 'global:default',
      generation: store.getState().getIn(['userPostingContextAssignments', 'global', 'generation']) || 0,
    });
    await store.dispatch(commitUserPostingStyle(PRIMARY_COMPOSER_ID, 'b'));
    store.dispatch({ type: COMPOSE_CHANGE, text: 'Keep' });
    api.mockReturnValue({
      get: jest.fn(() => Promise.resolve({ data: [] })),
    });

    await store.dispatch(retryUsualResolution(PRIMARY_COMPOSER_ID));

    expect(api().get).toHaveBeenCalled();
    expect(primary(store).get('text')).toEqual('Keep');
    expect(primary(store).getIn(['userPostingStyle', 'selectedId'])).toEqual('b');
    expect(primary(store).getIn(['userPostingStyle', 'usageMode'])).toEqual('once');
    expect(primary(store).getIn(['userPostingStyle', 'selectionKind'])).toEqual('style');
  });

  it('does not let a content warning or poll edited while sending be cleared by the old success', () => {
    const styles = ImmutableList([style('a', 'Usual', { visibility: 'public' })]);
    const store = buildStore(styles);
    store.dispatch({ type: COMPOSE_CHANGE, text: 'Hello' });
    store.dispatch({ type: COMPOSE_SPOILERNESS_CHANGE });
    store.dispatch({ type: COMPOSE_SPOILER_TEXT_CHANGE, text: 'before' });
    store.dispatch({ type: COMPOSE_POLL_ADD });
    const sent = snapshotOf(primary(store));
    store.dispatch({ type: COMPOSE_SUBMIT_REQUEST, submitId: 'submit-1' });
    store.dispatch({ type: COMPOSE_SPOILER_TEXT_CHANGE, text: 'after' });
    store.dispatch({ type: COMPOSE_POLL_OPTION_CHANGE, index: 0, title: 'Later' });
    store.dispatch({ type: COMPOSE_SUBMIT_REQUEST, submitId: 'submit-2' });

    store.dispatch({ type: COMPOSE_SUBMIT_SUCCESS, submitId: 'submit-1', submission: { ...sent, submitId: 'submit-1' } });
    expect(primary(store).get('is_submitting')).toBe(true);
    expect(primary(store).get('spoiler_text')).toEqual('after');
    expect(primary(store).getIn(['poll', 'options', 0])).toEqual('Later');

    store.dispatch({ type: COMPOSE_SUBMIT_FAIL, submitId: 'submit-1' });
    expect(primary(store).get('is_submitting')).toBe(true);
    expect(primary(store).get('text')).toEqual('Hello');

    const restored = snapshotOf(primary(store).set('text', 'Hello').set('spoiler_text', 'before'));
    store.dispatch({ type: COMPOSE_CHANGE, text: 'Hello again' });
    store.dispatch({ type: COMPOSE_CHANGE, text: 'Hello' });
    store.dispatch({ type: COMPOSE_SUBMIT_SUCCESS, submitId: 'submit-2', submission: { ...restored, submitId: 'submit-2', text: 'Hello' } });
    expect(primary(store).get('text')).toEqual('Hello');
    expect(primary(store).get('spoiler_text')).toEqual('after');
    expect(primary(store).get('is_submitting')).toBe(false);
  });

  it('keeps a one-time choice when an existing scheduled post is saved', () => {
    const scheduled = primary(buildStore(ImmutableList([style('b', 'Once', { visibility: 'private' })])));
    const drafted = scheduled.set('scheduled_status_id', 'sched-1').set('id', null);
    expect(classifySubmission(drafted, true)).toEqual('edit');
    expect(classifySubmission(drafted.set('scheduled', null), false)).toEqual('edit');
    expect(classifySubmission(drafted.set('scheduled_status_id', null), true)).toEqual('schedule');

    const withChoice = drafted.setIn(['userPostingStyle', 'selectedId'], 'b')
      .setIn(['userPostingStyle', 'usageMode'], 'once')
      .setIn(['userPostingStyle', 'selectionKind'], 'style')
      .set('text', 'Later');
    const saved = composer(withChoice, {
      type: COMPOSE_SUBMIT_SUCCESS,
      submission: snapshotOf(withChoice, { kind: 'edit' }),
    });

    expect(saved.get('text')).toEqual('');
    expect(saved.getIn(['userPostingStyle', 'selectedId'])).toEqual('b');
    expect(saved.getIn(['userPostingStyle', 'usageMode'])).toEqual('once');
  });

  it('clears a place style when that place settles back to none', async () => {
    const composerId = 'portable:group-column:123';
    const store = buildStore(ImmutableList([style('a', 'Place', { visibility: 'public' })]));
    store.dispatch(createComposer(composerId));
    store.dispatch(applyComposerSurface(composerId, { kind: 'group', key: '123' }, groupPostingContext, '123'));
    loadPlace(store, 'style', 'a');
    await store.dispatch(settleUsualSelection(composerId));
    const portable = () => store.getState().getIn(['composers', 'byId', composerId]);
    expect(portable().getIn(['userPostingStyle', 'selectedId'])).toEqual('a');

    loadPlace(store, 'none');
    store.dispatch({
      type: 'USER_POSTING_STYLE_RESOLUTION',
      clearSettled: true,
      meta: { composerId },
    });
    await store.dispatch(settleUsualSelection(composerId));

    expect(portable().getIn(['userPostingStyle', 'selectionKind'])).toEqual('none');
    expect(portable().getIn(['userPostingStyle', 'selectedId'])).toBeNull();
    expect(portable().getIn(['userPostingStyle', 'snapshot'])).toBeNull();
    expect(portable().getIn(['userPostingStyle', 'suppressions'])).toEqual(ImmutableSet());
  });
});
