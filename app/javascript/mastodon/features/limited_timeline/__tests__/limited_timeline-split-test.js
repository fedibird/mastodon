/* eslint-disable react/prop-types, react/jsx-no-bind */

import { fireEvent, render, screen } from '@testing-library/react';
import { List as ImmutableList, Map as ImmutableMap, fromJS } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { applyMiddleware, createStore } from 'redux';
import { combineReducers } from 'redux-immutable';
import thunk from 'redux-thunk';

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

jest.mock('mastodon/initial_state', () => ({
  ...jest.requireActual('mastodon/initial_state'),
  enableLimitedTimeline: true,
}));

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
  ACCOUNT_UNFOLLOW_SUCCESS: 'ACCOUNT_UNFOLLOW_SUCCESS',
  ACCOUNT_UNSUBSCRIBE_SUCCESS: 'ACCOUNT_UNSUBSCRIBE_SUCCESS',
  ACCOUNT_BLOCK_SUCCESS: 'ACCOUNT_BLOCK_SUCCESS',
  ACCOUNT_MUTE_SUCCESS: 'ACCOUNT_MUTE_SUCCESS',
  fetchRelationshipsSuccess: () => ({ type: 'REL_SUCCESS' }),
  fetchRelationshipsFromStatus: () => ({ type: 'REL_STATUS' }),
  fetchRelationshipsFromStatuses: () => ({ type: 'REL_STATUSES' }),
}));

jest.mock('mastodon/actions/markers', () => ({
  submitMarkers: () => ({ type: 'MARKERS' }),
}));

jest.mock('../containers/column_settings_container', () => () => null);
jest.mock('../../ui/containers/status_list_container', () => require('../../ui/components/__tests__/status_list_split_mock'));

import { updateTimeline } from '../../../actions/timelines';
import LimitedTimeline from '../index';

const buildStore = () => {
  const reducer = combineReducers({ timelines, settings });
  let state = reducer(undefined, { type: '@@INIT' });

  state = state.setIn(['timelines', 'limited'], ImmutableMap({
    unread: 0,
    online: true,
    top: false,
    isLoading: false,
    hasMore: true,
    isPartial: false,
    pendingItems: ImmutableList(['110']),
    items: ImmutableList(['100', '90']),
  }));

  return createStore(reducer, state, applyMiddleware(thunk));
};

describe('LimitedTimeline split', () => {
  beforeEach(() => {
    mockGet.mockClear();
  });

  it('loads history into the temporary timeline and accepts user-stream updates on the live pane', () => {
    const store = buildStore();
    const { container } = render(
      <Provider store={store}>
        <LimitedTimeline columnId='col-a' multiColumn />
      </Provider>,
    );

    expect(container.querySelector('.scrollable').getAttribute('data-timeline')).toBe('limited');

    fireEvent.click(screen.getByRole('button', { name: 'Split timeline' }));
    const splitTimelineId = store.getState().getIn(['timelines', 'limited', 'splitTimelineId']);
    const historyBefore = store.getState().getIn(['timelines', splitTimelineId, 'items']);

    fireEvent.click(container.querySelector('[data-testid="load-history"]'));

    expect(splitTimelineId).toEqual(expect.stringMatching(/^limited:split:col-a:.+/));
    expect(store.getState().getIn(['timelines', splitTimelineId, 'isLoading'])).toBe(true);
    expect(mockGet).toHaveBeenLastCalledWith('/api/v1/timelines/home', expect.objectContaining({
      params: expect.objectContaining({ max_id: '70' }),
    }));

    store.dispatch(updateTimeline('home', {
      id: '200',
      visibility: 'limited',
      media_attachments: [],
    }));

    expect(store.getState().getIn(['timelines', 'limited', 'pendingItems'])).toEqual(ImmutableList(['200', '110']));
    expect(store.getState().getIn(['timelines', 'limited', 'items'])).toEqual(ImmutableList(['100', '90']));
    expect(store.getState().getIn(['timelines', splitTimelineId, 'items'])).toEqual(historyBefore);

    store.dispatch({
      type: 'ACCOUNT_UNFOLLOW_SUCCESS',
      relationship: { id: '2' },
      statuses: fromJS({
        '200': { id: '200', account: '2' },
        '110': { id: '110', account: '2' },
        '100': { id: '100', account: '2' },
        '90': { id: '90', account: '3' },
      }),
    });

    expect(store.getState().getIn(['timelines', 'limited', 'items'])).toEqual(ImmutableList(['90']));
    expect(store.getState().getIn(['timelines', 'limited', 'pendingItems'])).toEqual(ImmutableList());
    expect(store.getState().getIn(['timelines', splitTimelineId, 'items']).filter(id => id !== null)).toEqual(ImmutableList(['90']));
  });
});
