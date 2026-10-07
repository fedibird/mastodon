/* eslint-disable react/prop-types, react/jsx-no-bind */

import { act, fireEvent, render, screen } from '@testing-library/react';
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

const buildStore = (onAction) => {
  const baseReducer = combineReducers({ timelines, settings, tags });
  const reducer = (state, action) => {
    if (onAction) {
      onAction(action);
    }

    return baseReducer(state, action);
  };
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
    expect(store.getState().getIn(['timelines', 'hashtag:ruby', 'items'])).toEqual(ImmutableList());
    expect(streamLog).toEqual([
      'connect:ruby:ruby',
      'disconnect:ruby:ruby',
      'connect:ruby:ruby',
      'connect:ruby:a',
    ]);
    expect(screen.getByRole('button', { name: 'Follow hashtag' })).toBeTruthy();
    expect(view.container.querySelectorAll('[data-testid="portable-composer"]')).toHaveLength(1);
  });

  it('keeps the ruby return anchor across a hashtag route change and restores it on back', () => {
    const clears = [];
    const store = buildStore(action => {
      if (action.type === 'TIMELINE_CLEAR') {
        clears.push(action.timeline);
      }
    });
    const rubyItems = ImmutableList(['100', '90']);

    store.dispatch({
      type: 'TIMELINE_EXPAND_SUCCESS',
      timeline: 'hashtag:javascript',
      statuses: [{ id: '50' }, { id: '40' }],
      next: null,
      partial: false,
      isLoadingRecent: false,
      usePendingItems: false,
    });

    const javascriptItems = store.getState().getIn(['timelines', 'hashtag:javascript', 'items']);

    const portal = document.createElement('div');
    portal.id = 'tabs-bar__portal';
    document.body.appendChild(portal);
    const wrapper = document.createElement('div');
    wrapper.className = 'tabs-bar__wrapper';
    wrapper.getBoundingClientRect = () => box(0, 64);
    portal.parentNode.insertBefore(wrapper, portal);
    wrapper.appendChild(portal);

    const frames = [];
    const spy = jest.spyOn(window, 'requestAnimationFrame').mockImplementation(callback => {
      frames.push(callback);
      return frames.length;
    });
    let restoreRects = () => {};

    try {
      restoreRects = installRects(element => {
        if (element.classList.contains('scrollable')) {
          return element.getAttribute('data-pane') === 'history' ? box(100, 700) : box(0, 900);
        }

        if (element.tagName === 'ARTICLE' && element.getAttribute('data-id') === '90') {
          const pane = element.parentElement && element.parentElement.getAttribute('data-pane');

          if (pane === 'history') {
            return box(92.16, 200);
          }

          const top = 400 - scroller().scrollTop;

          return box(top, top + 120);
        }

        if (element.tagName === 'ARTICLE') {
          return box(-40, 10);
        }

        return box(0, 0);
      });

      const view = render(
        <Provider store={store}>
          <HashtagTimeline params={{ id: 'ruby' }} multiColumn={false} location={{ key: 'A', pathname: '/timelines/tag/ruby' }} />
        </Provider>,
      );

      fireEvent.click(screen.getByRole('button', { name: 'Split timeline' }));
      flushQueuedFrames(frames);
      flushQueuedFrames(frames);

      const history = view.container.querySelector('.timeline-split__pane--history .scrollable');
      const splitTimelineId = store.getState().getIn(['timelines', 'hashtag:ruby', 'splitTimelineId']);

      history.scrollTop = 2386;
      view.rerender(
        <Provider store={store}>
          <HashtagTimeline params={{ id: 'javascript' }} multiColumn={false} location={{ key: 'B', pathname: '/timelines/tag/javascript' }} />
        </Provider>,
      );

      const rubyAnchor = store.getState().getIn(['timelines', 'hashtag:ruby', 'splitReturnAnchor']);

      expect(store.getState().get('timelines').has(splitTimelineId)).toBe(false);
      expect(store.getState().getIn(['timelines', 'hashtag:ruby', 'items'])).toEqual(rubyItems);
      expect(store.getState().getIn(['timelines', 'hashtag:ruby', 'splitTimelineId'])).toBeUndefined();
      expect(rubyAnchor.get('locationKey')).toBe('A');
      expect(rubyAnchor.get('id')).toBe('90');
      expect(rubyAnchor.get('offset')).toBeCloseTo(-7.84);
      expect(rubyAnchor.get('fallbackOffset')).toBe(2386);
      expect(store.getState().getIn(['timelines', 'hashtag:javascript', 'items'])).toEqual(javascriptItems);
      expect(javascriptItems.toArray()).toEqual(expect.arrayContaining(['50', '40']));
      expect(clears).toEqual([]);
      expect(streamLog).toEqual([
        'connect:ruby:ruby',
        'disconnect:ruby:ruby',
        'connect:javascript:javascript',
      ]);

      scroller().scrollTop = 0;
      view.rerender(
        <Provider store={store}>
          <HashtagTimeline params={{ id: 'ruby' }} multiColumn={false} location={{ key: 'A', pathname: '/timelines/tag/ruby' }} />
        </Provider>,
      );
      flushQueuedFrames(frames);
      flushQueuedFrames(frames);

      expect(clears).toEqual([]);
      expect(store.getState().getIn(['timelines', 'hashtag:ruby', 'items'])).toEqual(rubyItems);
      expect(view.container.querySelector('.timeline-split')).toBeNull();
      expect(scroller().scrollTop).toBeCloseTo(343.84);
      expect(store.getState().getIn(['timelines', 'hashtag:ruby', 'splitReturnAnchor'])).toBeUndefined();
      expect(streamLog).toEqual([
        'connect:ruby:ruby',
        'disconnect:ruby:ruby',
        'connect:javascript:javascript',
        'disconnect:javascript:javascript',
        'connect:ruby:ruby',
      ]);
    } finally {
      spy.mockRestore();
      restoreRects();
      wrapper.remove();
      document.body.classList.remove('status-timeline-split');
    }
  });
});

const box = (top, bottom) => ({
  top,
  bottom,
  left: 0,
  width: 320,
  height: Math.max(0, bottom - top),
  right: 320,
  x: 0,
  y: top,
  toJSON () {},
});

const scroller = () => document.scrollingElement || document.body;

const flushQueuedFrames = (frames) => {
  const batch = frames.splice(0, frames.length);

  act(() => {
    batch.forEach(callback => callback(0));
  });
};

const installRects = (resolver) => {
  const original = HTMLElement.prototype.getBoundingClientRect;

  HTMLElement.prototype.getBoundingClientRect = function () {
    return resolver(this) || box(0, 0);
  };

  return () => {
    HTMLElement.prototype.getBoundingClientRect = original;
  };
};
