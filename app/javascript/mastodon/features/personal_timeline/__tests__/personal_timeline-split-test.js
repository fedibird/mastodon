/* eslint-disable react/prop-types, react/jsx-no-bind */

import { act, fireEvent, render, screen } from '@testing-library/react';
import { List as ImmutableList, Map as ImmutableMap } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { applyMiddleware, createStore } from 'redux';
import { combineReducers } from 'redux-immutable';
import thunk from 'redux-thunk';

import { changeSetting } from '../../../actions/settings';
import { updateTimeline } from '../../../actions/timelines';
import settings from 'mastodon/reducers/settings';
import timelines from 'mastodon/reducers/timelines';

jest.mock('react-intl', () => {
  const React = require('react');
  const intl = { formatMessage: message => message.defaultMessage || message.id };

  return {
    defineMessages: messages => messages,
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    FormattedMessage: ({ defaultMessage }) => defaultMessage,
  };
});

const mockGet = jest.fn(() => new Promise(() => {}));

jest.mock('mastodon/api', () => ({
  __esModule: true,
  default: jest.fn(() => ({ get: mockGet, put: jest.fn(() => Promise.resolve({ data: {} })) })),
  getLinks: () => ({ refs: [] }),
}));

jest.mock('mastodon/actions/importer', () => ({
  importFetchedStatus: () => ({ type: 'IMPORT_STATUS' }),
  importFetchedStatuses: () => ({ type: 'IMPORT_STATUSES' }),
  importFetchedAccounts: () => ({ type: 'IMPORT_ACCOUNTS' }),
}));

jest.mock('mastodon/actions/accounts', () => ({
  fetchRelationshipsSuccess: () => ({ type: 'REL_SUCCESS' }),
  fetchRelationshipsFromStatus: () => ({ type: 'REL_STATUS' }),
  fetchRelationshipsFromStatuses: () => ({ type: 'REL_STATUSES' }),
}));

jest.mock('mastodon/actions/markers', () => ({
  submitMarkers: () => ({ type: 'MARKERS' }),
}));

jest.mock('../containers/column_settings_container', () => () => null);
jest.mock('../../ui/containers/status_list_container', () => require('../../ui/components/__tests__/status_list_split_mock'));

import PersonalTimeline from '../index';

const timelineState = (unread = 0) => ImmutableMap({
  unread,
  online: true,
  top: false,
  isLoading: false,
  hasMore: true,
  isPartial: false,
  pendingItems: ImmutableList(),
  items: ImmutableList(['100', '90']),
});

const buildStore = (mutate) => {
  const reducer = combineReducers({ timelines, settings });
  let state = reducer(undefined, { type: '@@INIT' });

  state = state
    .setIn(['timelines', 'personal'], timelineState(0))
    .setIn(['timelines', 'personal:media'], timelineState(3))
    .setIn(['timelines', 'personal:nomedia'], timelineState(0));

  if (mutate) {
    state = mutate(state);
  }

  return createStore(reducer, state, applyMiddleware(thunk));
};

const renderPersonal = (store, extra = {}) => render(
  <Provider store={store}>
    <PersonalTimeline columnId='col-a' multiColumn location={{ key: 'A', pathname: '/timelines/personal' }} {...extra} />
  </Provider>,
);

describe('PersonalTimeline split', () => {
  beforeEach(() => {
    mockGet.mockClear();
    const portal = document.createElement('div');
    portal.id = 'tabs-bar__portal';
    document.body.appendChild(portal);
  });

  afterEach(() => {
    document.getElementById('tabs-bar__portal')?.remove();
    document.body.classList.remove('status-timeline-split');
  });

  it('selects the canonical personal variant and writes history load-more there', () => {
    const plain = buildStore();
    const plainView = renderPersonal(plain);

    expect(plainView.container.querySelector('.scrollable').getAttribute('data-timeline')).toBe('personal');
    expect(plainView.container.querySelector('.column-header.active')).toBeNull();
    plainView.unmount();

    const mediaStore = buildStore(state => state.setIn(['settings', 'personal', 'other', 'onlyMedia'], true));
    const mediaView = renderPersonal(mediaStore);

    expect(mediaView.container.querySelector('.scrollable').getAttribute('data-timeline')).toBe('personal:media');
    expect(mediaView.container.querySelector('.column-header.active')).not.toBeNull();

    fireEvent.click(screen.getByRole('button', { name: 'Split timeline' }));
    const splitTimelineId = mediaStore.getState().getIn(['timelines', 'personal:media', 'splitTimelineId']);

    fireEvent.click(mediaView.container.querySelector('[data-testid="load-history"]'));

    expect(splitTimelineId).toEqual(expect.stringMatching(/^personal:media:split:col-a:.+/));
    expect(mediaStore.getState().getIn(['timelines', splitTimelineId, 'isLoading'])).toBe(true);
    expect(mockGet).toHaveBeenLastCalledWith('/api/v1/timelines/personal', expect.objectContaining({
      params: expect.objectContaining({ max_id: '70', only_media: true, without_media: false }),
    }));

    const items = mediaStore.getState().getIn(['timelines', 'personal:media', 'items']);
    const history = mediaStore.getState().getIn(['timelines', splitTimelineId, 'items']);

    mediaStore.dispatch(updateTimeline('home', {
      id: '200',
      visibility: 'personal',
      media_attachments: [{ id: 'm1', type: 'image' }],
    }));

    expect(mediaStore.getState().getIn(['timelines', 'personal:media', 'pendingItems'])).toEqual(ImmutableList(['200']));
    expect(mediaStore.getState().getIn(['timelines', 'personal:media', 'items'])).toEqual(items);
    expect(mediaStore.getState().getIn(['timelines', splitTimelineId, 'items'])).toEqual(history);
    mediaView.unmount();

    const textStore = buildStore(state => state.setIn(['settings', 'personal', 'other', 'withoutMedia'], true));
    const textView = renderPersonal(textStore);

    expect(textView.container.querySelector('.scrollable').getAttribute('data-timeline')).toBe('personal:nomedia');

    fireEvent.click(screen.getByRole('button', { name: 'Split timeline' }));
    textStore.dispatch(updateTimeline('home', {
      id: '201',
      visibility: 'personal',
      media_attachments: [],
    }));

    expect(textStore.getState().getIn(['timelines', 'personal:nomedia', 'pendingItems'])).toEqual(ImmutableList(['201']));
    expect(textStore.getState().getIn(['timelines', 'personal:media', 'pendingItems']).includes('201')).toBe(false);
  });

  it('clears the previous variant return anchor when the media filter changes', () => {
    const store = buildStore();
    const view = renderPersonal(store, { columnId: undefined, multiColumn: false });

    fireEvent.click(screen.getByRole('button', { name: 'Split timeline' }));
    act(() => {
      store.dispatch(changeSetting(['personal', 'other', 'onlyMedia'], true));
    });

    expect(view.container.querySelector('.scrollable').getAttribute('data-timeline')).toBe('personal:media');
    expect(store.getState().getIn(['timelines', 'personal', 'splitReturnAnchor'])).toBeUndefined();
    expect(store.getState().getIn(['timelines', 'personal', 'splitTimelineId'])).toBeUndefined();
  });
});
