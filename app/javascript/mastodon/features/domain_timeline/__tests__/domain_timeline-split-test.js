/* eslint-disable react/prop-types, react/jsx-no-bind */

import { act, fireEvent, render, screen } from '@testing-library/react';
import { List as ImmutableList, Map as ImmutableMap } from 'immutable';
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
  connectDomainStream: (domain) => () => {
    streamLog.push(`connect:${domain}`);

    return () => {
      streamLog.push(`disconnect:${domain}`);
    };
  },
}));

jest.mock('../containers/column_settings_container', () => () => null);
jest.mock('../../ui/containers/status_list_container', () => require('../../ui/components/__tests__/status_list_split_mock'));

import DomainTimeline from '../index';

const buildStore = () => {
  const reducer = combineReducers({ timelines, settings });
  let state = reducer(undefined, { type: '@@INIT' });

  ['domain:bot:example.com', 'domain:bot:example.net'].forEach(id => {
    state = state.setIn(['timelines', id], ImmutableMap({
      unread: 0,
      online: true,
      top: false,
      isLoading: false,
      hasMore: true,
      isPartial: false,
      pendingItems: ImmutableList(),
      items: ImmutableList(['100', '90']),
    }));
  });

  return createStore(reducer, state, applyMiddleware(thunk));
};

const renderDomain = (store, domain, extra = {}) => render(
  <Provider store={store}>
    <DomainTimeline params={{ domain }} multiColumn location={{ key: 'A', pathname: `/timelines/public/domain/${domain}` }} {...extra} />
  </Provider>,
);

describe('DomainTimeline split', () => {
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

  it('uses the domain source for live and writes history load-more to the temporary timeline', () => {
    const store = buildStore();
    const { container } = renderDomain(store, 'example.com', { columnId: 'col-a', multiColumn: true });

    expect(container.querySelector('.scrollable').getAttribute('data-timeline')).toBe('domain:bot:example.com');
    expect(streamLog).toEqual(['connect:example.com']);

    fireEvent.click(screen.getByRole('button', { name: 'Split timeline' }));
    const splitTimelineId = store.getState().getIn(['timelines', 'domain:bot:example.com', 'splitTimelineId']);

    expect(splitTimelineId).toEqual(expect.stringMatching(/^domain:bot:example.com:split:col-a:.+/));
    expect(container.querySelector('.timeline-split__pane--history .scrollable').getAttribute('data-timeline')).toBe(splitTimelineId);
    expect(streamLog).toEqual(['connect:example.com']);

    fireEvent.click(container.querySelector('[data-testid="load-history"]'));

    expect(store.getState().getIn(['timelines', splitTimelineId, 'isLoading'])).toBe(true);
    expect(mockGet).toHaveBeenLastCalledWith('/api/v1/timelines/public', expect.objectContaining({
      params: expect.objectContaining({ domain: 'example.com', local: false, max_id: '70' }),
    }));
  });

  it('keeps the previous domain return anchor and drops it when only the media filter changes', () => {
    const store = buildStore();
    const view = renderDomain(store, 'example.com', { multiColumn: false });

    fireEvent.click(screen.getByRole('button', { name: 'Split timeline' }));

    view.rerender(
      <Provider store={store}>
        <DomainTimeline params={{ domain: 'example.net' }} multiColumn={false} location={{ key: 'A', pathname: '/timelines/public/domain/example.net' }} />
      </Provider>,
    );

    expect(view.container.querySelector('.timeline-split')).toBeNull();
    expect(view.container.querySelector('.scrollable').getAttribute('data-timeline')).toBe('domain:bot:example.net');
    expect(store.getState().getIn(['timelines', 'domain:bot:example.com', 'splitReturnAnchor', 'locationKey'])).toBe('A');
    expect(store.getState().getIn(['timelines', 'domain:bot:example.net', 'splitTimelineId'])).toBeUndefined();

    fireEvent.click(screen.getByRole('button', { name: 'Split timeline' }));
    act(() => {
      store.dispatch(changeSetting(['domain', 'other', 'onlyMedia'], true));
    });

    expect(view.container.querySelector('.scrollable').getAttribute('data-timeline')).toBe('domain:bot:media:example.net');
    expect(store.getState().getIn(['timelines', 'domain:bot:example.net', 'splitReturnAnchor'])).toBeUndefined();
    expect(store.getState().getIn(['timelines', 'domain:bot:example.com', 'splitReturnAnchor', 'locationKey'])).toBe('A');
  });
});
