/* eslint-disable react/prop-types, react/jsx-no-bind */

import { act, fireEvent, render, screen } from '@testing-library/react';
import { List as ImmutableList, Map as ImmutableMap, fromJS } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { applyMiddleware, createStore } from 'redux';
import { combineReducers } from 'redux-immutable';
import thunk from 'redux-thunk';

import { changeSetting } from '../../../actions/settings';
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

const streamLog = [];

jest.mock('../../../actions/streaming', () => ({
  connectPublicStream: () => () => {
    streamLog.push('connect');

    return () => {
      streamLog.push('disconnect');
    };
  },
}));

jest.mock('../containers/column_settings_container', () => () => null);
jest.mock('../../ui/containers/status_list_container', () => require('../../ui/components/__tests__/status_list_split_mock'));

import PublicTimeline from '../index';

const buildStore = (mutate) => {
  const reducer = combineReducers({ timelines, settings });
  let state = reducer(undefined, { type: '@@INIT' });

  state = state.setIn(['timelines', 'public:bot'], ImmutableMap({
    unread: 0,
    online: true,
    top: false,
    isLoading: false,
    hasMore: true,
    isPartial: false,
    pendingItems: ImmutableList(['120']),
    items: ImmutableList(['100', '90', '80']),
  }));

  if (mutate) {
    state = mutate(state);
  }

  return createStore(reducer, state, applyMiddleware(thunk));
};

const renderPublic = (store, props) => render(
  <Provider store={store}>
    <PublicTimeline {...props} />
  </Provider>,
);

describe('PublicTimeline split', () => {
  beforeEach(() => {
    streamLog.length = 0;
    mockGet.mockClear();
    const portal = document.createElement('div');
    portal.id = 'tabs-bar__portal';
    document.body.appendChild(portal);
  });

  afterEach(() => {
    document.getElementById('tabs-bar__portal')?.remove();
    document.body.classList.remove('status-timeline-split');
  });

  it('uses the canonical public timeline for live and the temporary timeline for history', () => {
    const store = buildStore();
    const { container } = renderPublic(store, { columnId: 'col-a', multiColumn: true });

    expect(container.querySelector('.scrollable').getAttribute('data-timeline')).toBe('public:bot');
    expect(streamLog).toEqual(['connect']);

    fireEvent.click(screen.getByRole('button', { name: 'Split timeline' }));

    const splitTimelineId = store.getState().getIn(['timelines', 'public:bot', 'splitTimelineId']);
    const live = container.querySelector('.timeline-split__pane--live .scrollable');
    const history = container.querySelector('.timeline-split__pane--history .scrollable');

    expect(splitTimelineId).toEqual(expect.stringMatching(/^public:bot:split:col-a:.+/));
    expect(live.getAttribute('data-timeline')).toBe('public:bot');
    expect(live.getAttribute('data-context')).toBe('public:bot');
    expect(history.getAttribute('data-timeline')).toBe(splitTimelineId);
    expect(history.getAttribute('data-context')).toBe('public:bot');
    expect(streamLog).toEqual(['connect']);

    fireEvent.click(container.querySelector('[data-testid="load-history"]'));

    expect(store.getState().getIn(['timelines', splitTimelineId, 'isLoading'])).toBe(true);
    expect(store.getState().getIn(['timelines', 'public:bot', 'items'])).toEqual(ImmutableList(['100', '90', '80']));
    expect(mockGet).toHaveBeenLastCalledWith('/api/v1/timelines/public', expect.objectContaining({
      params: expect.objectContaining({ max_id: '70', remote: false }),
    }));
    expect(streamLog).toEqual(['connect']);
  });

  it('clears the previous return anchor when a source filter changes', () => {
    const store = buildStore();
    const view = renderPublic(store, { multiColumn: false, location: { key: 'A', pathname: '/timelines/public' } });

    fireEvent.click(screen.getByRole('button', { name: 'Split timeline' }));
    const splitTimelineId = store.getState().getIn(['timelines', 'public:bot', 'splitTimelineId']);

    act(() => {
      store.dispatch(changeSetting(['public', 'other', 'onlyMedia'], true));
    });

    expect(view.container.querySelector('.timeline-split')).toBeNull();
    expect(view.container.querySelector('.scrollable').getAttribute('data-timeline')).toBe('public:bot:media');
    expect(store.getState().getIn(['timelines', 'public:bot', 'splitReturnAnchor'])).toBeUndefined();
    expect(store.getState().getIn(['timelines', 'public:bot', 'splitTimelineId'])).toBeUndefined();
    expect(store.getState().get('timelines').has(splitTimelineId)).toBe(false);
    expect(streamLog.filter(entry => entry === 'connect').length).toBe(2);
  });

  it('disables a second column when the public source is already split', () => {
    const store = buildStore();

    render(
      <Provider store={store}>
        <PublicTimeline columnId='col-a' multiColumn />
        <PublicTimeline columnId='col-b' multiColumn />
      </Provider>,
    );

    fireEvent.click(screen.getAllByRole('button', { name: 'Split timeline' })[0]);

    expect(screen.getByRole('button', { name: 'This timeline is already split in another column' })).toBeDisabled();
    expect(store.getState().getIn(['timelines', 'public:bot', 'splitTimelineId'])).toEqual(expect.stringMatching(/^public:bot:split:col-a:.+/));
  });

  it('allows a remote public source to split beside the local public source', () => {
    const store = buildStore(state => state
      .setIn(['settings', 'public', 'splitRatio'], 40)
      .setIn(['settings', 'columns'], fromJS([
        { uuid: 'local', params: { other: { onlyRemote: false } } },
        { uuid: 'remote', params: { other: { onlyRemote: true } } },
      ]))
      .setIn(['timelines', 'public:remote:bot'], ImmutableMap({
        unread: 0,
        online: true,
        top: false,
        isLoading: false,
        hasMore: true,
        isPartial: false,
        pendingItems: ImmutableList(),
        items: ImmutableList(['50']),
      })));
    const { container } = render(
      <Provider store={store}>
        <PublicTimeline columnId='local' multiColumn />
        <PublicTimeline columnId='remote' multiColumn />
      </Provider>,
    );

    const sources = Array.from(container.querySelectorAll('.scrollable')).map(node => node.getAttribute('data-timeline'));

    expect(sources).toEqual(['public:bot', 'public:remote:bot']);

    fireEvent.click(screen.getAllByRole('button', { name: 'Split timeline' })[0]);

    expect(screen.getByRole('button', { name: 'Split timeline' })).toBeEnabled();

    fireEvent.click(screen.getByRole('button', { name: 'Split timeline' }));

    expect(screen.getAllByRole('button', { name: 'Remove timeline split', pressed: true })).toHaveLength(2);
    expect(store.getState().getIn(['timelines', 'public:bot', 'splitTimelineId'])).toEqual(expect.stringMatching(/^public:bot:split:local:.+/));
    expect(store.getState().getIn(['timelines', 'public:remote:bot', 'splitTimelineId'])).toEqual(expect.stringMatching(/^public:remote:bot:split:remote:.+/));
    expect(container.querySelector('[role="separator"]').getAttribute('aria-valuenow')).toBe('40');
    expect(store.getState().getIn(['settings', 'home', 'splitRatio'])).toBe(35);
    expect(store.getState().getIn(['settings', 'public', 'splitRatio'])).toBe(40);
  });
});
