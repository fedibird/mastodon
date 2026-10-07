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

jest.mock('mastodon/initial_state', () => ({
  ...jest.requireActual('mastodon/initial_state'),
  isAdministrator: true,
}));

const mockGet = jest.fn(() => new Promise(() => {}));

jest.mock('mastodon/api', () => ({
  __esModule: true,
  default: jest.fn(() => ({ get: mockGet, put: jest.fn(() => Promise.resolve({ data: {} })) })),
  getLinks: () => ({ refs: [] }),
}));

const streamLog = [];

jest.mock('../../../actions/streaming', () => ({
  connectGroupStream: (id, options) => () => {
    streamLog.push(`connect:${id}:${options && options.tagged ? options.tagged : ''}`);

    return () => {
      streamLog.push(`disconnect:${id}`);
    };
  },
}));

jest.mock('../../../actions/accounts', () => ({
  fetchAccount: id => ({ type: 'ACCOUNT_FETCH', id }),
  fetchRelationshipsSuccess: () => ({ type: 'REL_SUCCESS' }),
  fetchRelationshipsFromStatus: () => ({ type: 'REL_STATUS' }),
  fetchRelationshipsFromStatuses: () => ({ type: 'REL_STATUSES' }),
}));

jest.mock('../../../actions/posting_contexts', () => ({
  fetchPostingContext: id => ({ type: 'POSTING_CONTEXT_FETCH', id }),
}));

jest.mock('../containers/column_settings_container', () => () => null);
jest.mock('../components/group_detail', () => () => <div data-testid='group-detail' />);
jest.mock('../../compose/portable_composer', () => {
  const React = require('react');

  return function PortableComposer ({ composerId }) {
    return <div data-testid='portable-composer' data-composer-id={composerId} />;
  };
});
jest.mock('../../ui/containers/status_list_container', () => require('../../ui/components/__tests__/status_list_split_mock'));

import GroupTimeline from '../index';

const accounts = (state = ImmutableMap()) => state;
const posting_contexts = (state = ImmutableMap()) => state;

const buildStore = () => {
  const reducer = combineReducers({ timelines, settings, accounts, posting_contexts });
  let state = reducer(undefined, { type: '@@INIT' });

  state = state.setIn(['accounts', '7'], fromJS({
    id: '7',
    display_name: 'Group',
    acct: 'group@example.com',
    username: 'group',
  }));
  state = state.setIn(['posting_contexts', '7'], fromJS({
    status: 'resolved',
    context: { kind: 'group' },
  }));
  state = state.setIn(['timelines', 'group:7'], ImmutableMap({
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

const renderGroup = (store, params, extra = {}) => render(
  <Provider store={store}>
    <GroupTimeline params={params} columnId='col-a' multiColumn location={{ key: 'A', pathname: `/timelines/groups/${params.id}` }} {...extra} />
  </Provider>,
);

describe('GroupTimeline split', () => {
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

  it('splits the canonical group source with the composer and detail button on the live column', () => {
    const store = buildStore();
    const { container } = renderGroup(store, { id: '7' });

    expect(container.querySelector('.scrollable').getAttribute('data-timeline')).toBe('group:7');
    expect(streamLog).toEqual(['connect:7:']);
    expect(container.querySelector('[data-testid="portable-composer"]')).toBeNull();
    const headerLabels = [];

    for (let child = container.querySelector('.column-header__buttons').firstElementChild; child; child = child.nextElementSibling) {
      headerLabels.push(child.getAttribute('aria-label'));
    }

    expect(headerLabels.slice(0, 3)).toEqual([
      'Split timeline',
      'Show composer',
      'Show group detail',
    ]);

    fireEvent.click(screen.getByRole('button', { name: 'Show composer' }));

    expect(container.querySelector('[data-testid="portable-composer"]').getAttribute('data-composer-id')).toBe('portable:group-column:col-a');
    expect(screen.getByRole('button', { name: 'Show group detail' })).toBeTruthy();

    const frames = [];
    const spy = jest.spyOn(window, 'requestAnimationFrame').mockImplementation(callback => {
      frames.push(callback);
      return frames.length;
    });

    fireEvent.click(screen.getByRole('button', { name: 'Split timeline' }));
    act(() => {
      frames.splice(0).forEach(callback => callback(0));
    });
    spy.mockRestore();

    const history = container.querySelector('.timeline-split__pane--history .scrollable');

    expect(store.getState().getIn(['timelines', 'group:7', 'splitTimelineId'])).toEqual(expect.stringMatching(/^group:7:split:col-a:.+/));
    expect(container.querySelectorAll('.timeline-split__pane--live [data-testid="portable-composer"]')).toHaveLength(1);
    expect(container.querySelectorAll('.timeline-split__pane--history [data-testid="portable-composer"]')).toHaveLength(0);
    expect(store.getState().getIn(['settings', 'portableComposerVisibility', 'portable:group-column:col-a'])).toBe(true);
    expect(container.querySelector('[data-testid="group-detail"]')).toBeTruthy();

    fireEvent.click(screen.getByRole('button', { name: 'Hide composer' }));

    expect(container.querySelectorAll('.timeline-split__pane--live [data-testid="portable-composer"]')).toHaveLength(0);
    expect(container.querySelectorAll('.timeline-split__pane--history [data-testid="portable-composer"]')).toHaveLength(0);
    expect(store.getState().getIn(['settings', 'portableComposerVisibility', 'portable:group-column:col-a'])).toBe(false);
    expect(screen.getByRole('button', { name: 'Show group detail' })).toBeTruthy();
    expect(streamLog).toEqual(['connect:7:']);

    history.scrollTop = 640;
    fireEvent.click(screen.getByRole('button', { name: 'Show group detail' }));

    expect(container.querySelector('.timeline-split__pane--history .scrollable').scrollTop).toBe(640);
    expect(streamLog).toEqual(['connect:7:']);
  });

  it('clears a media-filter return anchor and keeps one saved by a tagged route change', () => {
    const store = buildStore();
    const view = renderGroup(store, { id: '7' }, { columnId: undefined, multiColumn: false });

    fireEvent.click(screen.getByRole('button', { name: 'Split timeline' }));
    act(() => {
      store.dispatch(changeSetting(['group', 'other', 'onlyMedia'], true));
    });

    expect(view.container.querySelector('.scrollable').getAttribute('data-timeline')).toBe('group:7:media');
    expect(store.getState().getIn(['timelines', 'group:7', 'splitReturnAnchor'])).toBeUndefined();

    fireEvent.click(screen.getByRole('button', { name: 'Split timeline' }));
    view.rerender(
      <Provider store={store}>
        <GroupTimeline params={{ id: '7', tagged: 'news' }} multiColumn={false} location={{ key: 'A', pathname: '/timelines/groups/7/news' }} />
      </Provider>,
    );

    expect(view.container.querySelector('.scrollable').getAttribute('data-timeline')).toBe('group:7:media:news');
    expect(store.getState().getIn(['timelines', 'group:7:media', 'splitReturnAnchor', 'locationKey'])).toBe('A');
    expect(streamLog.filter(entry => entry.startsWith('connect'))).toEqual(['connect:7:', 'connect:7:', 'connect:7:news']);
  });
});
