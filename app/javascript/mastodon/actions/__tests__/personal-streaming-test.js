import { List as ImmutableList, Map as ImmutableMap } from 'immutable';
import { applyMiddleware, createStore } from 'redux';
import { combineReducers } from 'redux-immutable';
import thunk from 'redux-thunk';

jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
  injectIntl: Component => Component,
  FormattedMessage: () => null,
}));

jest.mock('../importer', () => ({
  importFetchedStatus: () => ({ type: 'IMPORT_STATUS' }),
  importFetchedStatuses: () => ({ type: 'IMPORT_STATUSES' }),
  importFetchedAccounts: () => ({ type: 'IMPORT_ACCOUNTS' }),
}));

jest.mock('../accounts', () => ({
  fetchRelationshipsSuccess: () => ({ type: 'REL_SUCCESS' }),
  fetchRelationshipsFromStatus: () => ({ type: 'REL_STATUS' }),
  fetchRelationshipsFromStatuses: () => ({ type: 'REL_STATUSES' }),
}));

jest.mock('../markers', () => ({
  submitMarkers: () => ({ type: 'MARKERS' }),
}));

jest.mock('mastodon/api', () => ({
  __esModule: true,
  default: jest.fn(() => ({ get: jest.fn(), put: jest.fn(() => Promise.resolve({ data: {} })) })),
  getLinks: () => ({ refs: [] }),
}));

import settings from '../../reducers/settings';
import timelines from '../../reducers/timelines';
import { TIMELINE_SPLIT_CREATE, updateTimeline } from '../timelines';

const buildStore = (present = []) => {
  const reducer = combineReducers({ timelines, settings });
  let state = reducer(undefined, { type: '@@INIT' });

  present.forEach(id => {
    state = state.setIn(['timelines', id], ImmutableMap({
      unread: 0,
      online: false,
      top: true,
      isLoading: false,
      hasMore: true,
      isPartial: false,
      pendingItems: ImmutableList(),
      items: ImmutableList(id === 'personal:media' ? ['100'] : []),
    }));
  });

  return createStore(reducer, state, applyMiddleware(thunk));
};

const collectedIds = (store, timelineId) => {
  const items = store.getState().getIn(['timelines', timelineId, 'items'], ImmutableList());
  const pending = store.getState().getIn(['timelines', timelineId, 'pendingItems'], ImmutableList());

  return items.concat(pending);
};

describe('personal streaming variants', () => {
  it('inserts a personal status with media into personal and personal:media', () => {
    const store = buildStore(['personal', 'personal:media']);

    store.dispatch(updateTimeline('home', {
      id: '200',
      visibility: 'personal',
      media_attachments: [{ id: 'm1', type: 'image' }],
    }));

    expect(collectedIds(store, 'personal').includes('200')).toBe(true);
    expect(collectedIds(store, 'personal:media').includes('200')).toBe(true);
    expect(store.getState().has('timelines') && store.getState().get('timelines').has('personal:nomedia')).toBe(false);
  });

  it('inserts a personal status without media into personal and personal:nomedia', () => {
    const store = buildStore(['personal', 'personal:nomedia']);

    store.dispatch(updateTimeline('home', {
      id: '201',
      visibility: 'personal',
      media_attachments: [],
    }));

    expect(collectedIds(store, 'personal').includes('201')).toBe(true);
    expect(collectedIds(store, 'personal:nomedia').includes('201')).toBe(true);
    expect(store.getState().get('timelines').has('personal:media')).toBe(false);
  });

  it('queues a filtered personal status into the active split pending items', () => {
    const splitTimelineId = 'personal:media:split:column-a:uuid-1';
    const store = buildStore(['personal', 'personal:media']);

    store.dispatch({
      type: TIMELINE_SPLIT_CREATE,
      sourceTimeline: 'personal:media',
      splitTimeline: splitTimelineId,
    });

    const items = store.getState().getIn(['timelines', 'personal:media', 'items']);
    const history = store.getState().getIn(['timelines', splitTimelineId, 'items']);

    store.dispatch(updateTimeline('home', {
      id: '200',
      visibility: 'personal',
      media_attachments: [{ id: 'm1', type: 'image' }],
    }));

    expect(store.getState().getIn(['timelines', 'personal:media', 'pendingItems'])).toEqual(ImmutableList(['200']));
    expect(store.getState().getIn(['timelines', 'personal:media', 'items'])).toEqual(items);
    expect(store.getState().getIn(['timelines', splitTimelineId, 'items'])).toEqual(history);
    expect(store.getState().get('timelines').has('personal:nomedia')).toBe(false);
  });
});
