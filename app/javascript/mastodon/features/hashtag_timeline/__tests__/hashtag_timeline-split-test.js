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
  new_features_policy: 'tester',
}));

const mockGet = jest.fn(() => new Promise(() => {}));

jest.mock('mastodon/api', () => ({
  __esModule: true,
  default: jest.fn(() => ({ get: mockGet, put: jest.fn(() => Promise.resolve({ data: {} })) })),
  getLinks: () => ({ refs: [] }),
}));

const streamLog = [];

jest.mock('mastodon/actions/streaming', () => ({
  connectHashtagStream: (id, tag) => () => {
    streamLog.push(`connect:${id}:${tag}`);

    return () => {
      streamLog.push(`disconnect:${id}:${tag}`);
    };
  },
}));

jest.mock('mastodon/actions/tags', () => ({
  fetchHashtag: id => ({ type: 'HASHTAG_FETCH', id }),
  followHashtag: id => ({ type: 'HASHTAG_FOLLOW', id }),
  unfollowHashtag: id => ({ type: 'HASHTAG_UNFOLLOW', id }),
}));

jest.mock('../containers/column_settings_container', () => () => null);
jest.mock('../../compose/portable_composer', () => {
  const React = require('react');

  return function PortableComposer ({ composerId }) {
    return <div data-testid='portable-composer' data-composer-id={composerId} />;
  };
});
jest.mock('../../ui/containers/status_list_container', () => require('../../ui/components/__tests__/status_list_split_mock'));

import HashtagTimeline from '../index';

const tags = (state = ImmutableMap()) => state;

const buildStore = () => {
  const reducer = combineReducers({ timelines, settings, tags });
  let state = reducer(undefined, { type: '@@INIT' });

  state = state.setIn(['tags', 'ruby'], fromJS({ name: 'ruby', following: false }));
  state = state.setIn(['timelines', 'hashtag:ruby'], ImmutableMap({
    unread: 0,
    online: true,
    top: false,
    isLoading: false,
    hasMore: true,
    isPartial: false,
    pendingItems: ImmutableList(),
    items: ImmutableList(['100', '90']),
  }));

  return createStore(reducer, state, applyMiddleware(thunk));
};

const renderTag = (store, params, extra = {}) => render(
  <Provider store={store}>
    <HashtagTimeline params={params} columnId='col-a' multiColumn location={{ key: 'A', pathname: '/timelines/tag/ruby' }} {...extra} />
  </Provider>,
);

describe('HashtagTimeline split', () => {
  beforeEach(() => {
    streamLog.length = 0;
    mockGet.mockClear();
  });

  it('keeps the follow button and puts the composer on the live pane only', () => {
    const store = buildStore();
    const { container } = renderTag(store, { id: 'ruby' });

    expect(container.querySelector('.scrollable').getAttribute('data-timeline')).toBe('hashtag:ruby');
    expect(screen.getByRole('button', { name: 'Follow hashtag' })).toBeTruthy();
    expect(container.querySelectorAll('[data-testid="portable-composer"]')).toHaveLength(1);
    expect(container.querySelector('[data-testid="portable-composer"]').getAttribute('data-composer-id')).toBe('portable:hashtag-column:col-a');
    expect(streamLog).toEqual(['connect:ruby:ruby']);

    fireEvent.click(screen.getByRole('button', { name: 'Split timeline' }));

    expect(container.querySelectorAll('.timeline-split__pane--live [data-testid="portable-composer"]')).toHaveLength(1);
    expect(container.querySelectorAll('.timeline-split__pane--history [data-testid="portable-composer"]')).toHaveLength(0);
    expect(container.querySelector('.timeline-split__pane--history .scrollable').getAttribute('data-prepend')).toBe('false');
    expect(screen.getByRole('button', { name: 'Follow hashtag' })).toBeTruthy();
    expect(streamLog).toEqual(['connect:ruby:ruby']);
  });

  it('drops the split, temporary timeline, and return anchor when additional filters change', () => {
    const store = buildStore();
    const view = renderTag(store, { id: 'ruby' });

    fireEvent.click(screen.getByRole('button', { name: 'Split timeline' }));
    const splitTimelineId = store.getState().getIn(['timelines', 'hashtag:ruby', 'splitTimelineId']);

    store.dispatch({
      type: 'TIMELINE_SPLIT_SAVE_RETURN_ANCHOR',
      timeline: 'hashtag:ruby',
      anchor: { locationKey: 'A', id: '90', offset: 1, fallbackOffset: 10 },
    });

    view.rerender(
      <Provider store={store}>
        <HashtagTimeline
          params={{ id: 'ruby', tags: { any: [{ value: 'a' }] } }}
          columnId='col-a'
          multiColumn
          location={{ key: 'A', pathname: '/timelines/tag/ruby' }}
        />
      </Provider>,
    );

    expect(view.container.querySelector('.timeline-split')).toBeNull();
    expect(view.container.querySelector('.scrollable').getAttribute('data-timeline')).toBe('hashtag:ruby');
    expect(store.getState().get('timelines').has(splitTimelineId)).toBe(false);
    expect(store.getState().getIn(['timelines', 'hashtag:ruby', 'splitTimelineId'])).toBeUndefined();
    expect(store.getState().getIn(['timelines', 'hashtag:ruby', 'splitReturnAnchor'])).toBeUndefined();
    expect(streamLog).toEqual([
      'connect:ruby:ruby',
      'disconnect:ruby:ruby',
      'connect:ruby:ruby',
      'connect:ruby:a',
    ]);
    expect(screen.getByRole('button', { name: 'Follow hashtag' })).toBeTruthy();
    expect(view.container.querySelectorAll('[data-testid="portable-composer"]')).toHaveLength(1);
  });
});
