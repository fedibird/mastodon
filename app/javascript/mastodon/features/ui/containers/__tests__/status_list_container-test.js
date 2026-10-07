/* eslint-disable react/prop-types */

import { render, waitFor } from '@testing-library/react';
import { List as ImmutableList, Map as ImmutableMap } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { combineReducers } from 'redux-immutable';
import { createStore } from 'redux';

jest.mock('react-intl', () => ({
  FormattedMessage: ({ defaultMessage }) => defaultMessage,
  defineMessages: messages => messages,
  injectIntl: Component => Component,
}));

jest.mock('mastodon/components/status_list', () => {
  const React = require('react');

  return class StatusList extends React.Component {

    componentDidMount () {
      if (this.props.onScrollToTop) {
        this.props.onScrollToTop();
      }
    }

    render () {
      const ids = this.props.statusIds || [];

      return (
        <div>
          {this.props.numPending > 0 && <button className='load-gap' type='button'>pending</button>}
          {ids.map(id => (
            <article key={String(id)} data-testid='status' data-id={id} data-context-type={this.props.timelineId} />
          ))}
        </div>
      );
    }

  };
});

import timelines from 'mastodon/reducers/timelines';
import StatusListContainer from '../status_list_container';

const identity = (state = ImmutableMap()) => state;

const status = (id, overrides = {}) => ImmutableMap({
  id,
  account: '1',
  visibility: 'public',
  reblog: null,
  in_reply_to_id: null,
  in_reply_to_account_id: null,
  ...overrides,
});

const buildStore = ({ homeItems, homePending = [], splitItems = [], shows = {} }) => {
  const statuses = {};

  [...homePending, ...homeItems, ...splitItems].forEach((id) => {
    if (id && !statuses[id]) {
      statuses[id] = status(id);
    }
  });

  if (shows.reblogStatus) {
    statuses.reblog = status('reblog', { reblog: '1' });
  }

  if (shows.replyStatus) {
    statuses.reply = status('reply', { in_reply_to_id: '1', in_reply_to_account_id: '9' });
  }

  return createStore(combineReducers({
    timelines,
    settings: identity,
    statuses: identity,
  }), ImmutableMap({
    timelines: ImmutableMap({
      home: ImmutableMap({
        items: ImmutableList(homeItems),
        pendingItems: ImmutableList(homePending),
        isLoading: false,
        isPartial: false,
        hasMore: true,
        top: false,
        unread: homePending.length,
        splitTimelineId: 'home:split:X',
      }),
      'home:split:X': ImmutableMap({
        items: ImmutableList(splitItems),
        pendingItems: ImmutableList(),
        isLoading: false,
        isPartial: false,
        hasMore: true,
        top: false,
        unread: 0,
      }),
    }),
    settings: ImmutableMap({
      home: ImmutableMap({
        shows: ImmutableMap({
          reblog: shows.reblog !== false,
          reply: shows.reply !== false,
        }),
      }),
    }),
    statuses: ImmutableMap(statuses),
  }));
};

const renderList = (store, props) => render(
  <Provider store={store}>
    <StatusListContainer scrollKey='home-test' timelineId='home' {...props} />
  </Provider>,
);

const statusIds = (container) => Array.from(container.querySelectorAll('[data-testid="status"]'), node => node.getAttribute('data-id'));

describe('StatusListContainer timeline selection', () => {
  it('reads items from dataTimelineId while keeping the home context and scroll target', async () => {
    const store = buildStore({
      homeItems: ['home-only'],
      splitItems: ['100', 'reblog', 'reply', '90'],
      shows: { reblog: false, reply: false, reblogStatus: true, replyStatus: true },
    });

    const { container } = renderList(store, {
      dataTimelineId: 'home:split:X',
      trackScroll: false,
    });

    expect(statusIds(container)).toEqual(['100', '90']);
    expect(container.querySelector('[data-context-type="home"]')).not.toBeNull();
    expect(container.querySelector('[data-id="home-only"]')).toBeNull();
    expect(container.querySelector('[data-id="reblog"]')).toBeNull();
    expect(container.querySelector('[data-id="reply"]')).toBeNull();

    await waitFor(() => {
      expect(store.getState().getIn(['timelines', 'home:split:X', 'top'])).toBe(true);
    });
    expect(store.getState().getIn(['timelines', 'home', 'top'])).toBe(false);
  });

  it('shows pending items inline in live mode and limits the filtered list', () => {
    const ids = [];
    const statuses = {};

    for (let index = 0; index < 50; index += 1) {
      const id = String(1000 - index).padStart(4, '0');
      ids.push(id);
      statuses[id] = status(id, index % 5 === 0 ? { reblog: '1' } : {});
    }

    const store = createStore(combineReducers({
      timelines,
      settings: identity,
      statuses: identity,
    }), ImmutableMap({
      timelines: ImmutableMap({
        home: ImmutableMap({
          items: ImmutableList(ids),
          pendingItems: ImmutableList(['1200', '1100']),
          isLoading: false,
          hasMore: true,
          top: false,
        }),
      }),
      settings: ImmutableMap({
        home: ImmutableMap({
          shows: ImmutableMap({ reblog: false, reply: true }),
        }),
      }),
      statuses: ImmutableMap({
        ...statuses,
        '1200': status('1200'),
        '1100': status('1100'),
      }),
    }));

    const { container } = renderList(store, {
      includePendingItems: true,
      statusLimit: 40,
      manageTimelineScrollState: false,
      trackScroll: false,
      trackIntersection: false,
    });

    const rendered = statusIds(container);

    expect(rendered.slice(0, 2)).toEqual(['1200', '1100']);
    expect(rendered).toHaveLength(40);
    expect(rendered.every(id => statuses[id] ? statuses[id].get('reblog') === null : true)).toBe(true);
    expect(container.querySelector('.load-gap')).toBeNull();
    expect(store.getState().getIn(['timelines', 'home', 'pendingItems'])).toEqual(ImmutableList(['1200', '1100']));
    expect(store.getState().getIn(['timelines', 'home', 'top'])).toBe(false);
  });
});
