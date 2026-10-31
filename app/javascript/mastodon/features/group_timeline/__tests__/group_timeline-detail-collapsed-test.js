/* eslint-disable react/prop-types, react/jsx-no-bind */

import { act, fireEvent, render, screen } from '@testing-library/react';
import { Map as ImmutableMap, fromJS } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { applyMiddleware, createStore } from 'redux';
import { combineReducers } from 'redux-immutable';
import thunk from 'redux-thunk';

import { STORE_HYDRATE } from '../../../actions/store';
import settings from 'mastodon/reducers/settings';

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

const mockPut = jest.fn(() => new Promise(() => {}));

jest.mock('mastodon/api', () => ({
  __esModule: true,
  default: jest.fn(() => ({ get: jest.fn(() => new Promise(() => {})), put: mockPut })),
  getLinks: () => ({ refs: [] }),
}));

jest.mock('../../../actions/streaming', () => ({
  connectGroupStream: () => () => () => {},
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

const detailRenders = [];

jest.mock('../components/group_detail', () => ({ id }) => {
  detailRenders.push(String(id));
  return <div data-testid='group-detail' data-group-id={String(id)} />;
});

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
const timelines = (state = ImmutableMap()) => state;

const account = (id, name) => fromJS({
  id: String(id),
  display_name: name,
  acct: `${name}@example.com`,
  username: name,
  group: true,
});

const hydrateSettings = (rawSettings) => settings(undefined, {
  type: STORE_HYDRATE,
  state: fromJS({ settings: rawSettings }),
});

const buildStore = (rawSettings) => {
  const reducer = combineReducers({ timelines, settings, accounts, posting_contexts });
  let state = reducer(undefined, { type: '@@INIT' });

  state = state.setIn(['accounts', '7'], account('7', 'Group'));
  state = state.setIn(['accounts', '8'], account('8', 'Other'));
  state = state.setIn(['accounts', 7], account(7, 'Numeric'));
  state = state.setIn(['posting_contexts', '7'], fromJS({
    status: 'resolved',
    context: { kind: 'group' },
  }));

  if (rawSettings) {
    state = state.set('settings', hydrateSettings(rawSettings));
  }

  return createStore(reducer, state, applyMiddleware(thunk));
};

const locationFor = (id) => ({ key: `loc-${id}`, pathname: `/timelines/groups/${id}` });

const renderGroups = (store, columns) => {
  const view = render(
    <Provider store={store}>
      {columns.map(column => (
        <GroupTimeline
          key={column.key}
          params={column.params}
          columnId={column.columnId}
          multiColumn={column.multiColumn}
          location={locationFor(column.params.id)}
        />
      ))}
    </Provider>,
  );

  return view;
};

const detailButton = (name) => screen.getByRole('button', { name });

const groupCollapsibles = () => Array.from(document.querySelectorAll('.column > .column-header__collapsible'));

const collapsible = () => {
  const nodes = groupCollapsibles();

  expect(nodes).toHaveLength(1);
  return nodes[0];
};

const savedPayloads = () => mockPut.mock.calls.map(call => call[1].data);

describe('GroupTimeline group detail collapsed setting', () => {
  beforeEach(() => {
    jest.useFakeTimers('modern');
    detailRenders.length = 0;
    mockPut.mockClear();
    const portal = document.createElement('div');
    portal.id = 'tabs-bar__portal';
    document.body.appendChild(portal);
  });

  afterEach(() => {
    act(() => {
      jest.runOnlyPendingTimers();
    });
    jest.useRealTimers();
    document.getElementById('tabs-bar__portal')?.remove();
  });

  it('shows an unset group and does not write the default open state', () => {
    const store = buildStore();

    renderGroups(store, [{ key: 'route', params: { id: '7' }, multiColumn: false }]);

    const button = detailButton('Hide group detail');

    expect(button.getAttribute('title')).toBe('Hide group detail');
    expect(button.getAttribute('aria-pressed')).toBe('true');
    expect(button.classList.contains('active')).toBe(true);
    expect(screen.getByTestId('group-detail')).toBeTruthy();
    expect(collapsible().classList.contains('collapsed')).toBe(false);
    expect(store.getState().getIn(['settings', 'group', 'detailCollapsed'])).toBeUndefined();
    expect(store.getState().getIn(['settings', 'saved'])).toBe(true);
    expect(mockPut).not.toHaveBeenCalled();
  });

  const mountHydrated = (rawSettings) => {
    const base = buildStore();
    const hydrated = createStore(
      combineReducers({ timelines, settings, accounts, posting_contexts }),
      base.getState().set('settings', hydrateSettings(rawSettings)),
      applyMiddleware(thunk),
    );

    return hydrated;
  };

  it('saves a closed state and an explicitly reopened state, then restores both after hydrate', () => {
    const store = buildStore();
    const view = renderGroups(store, [{ key: 'route', params: { id: '7' }, multiColumn: false }]);
    const button = detailButton('Hide group detail');
    const stop = jest.spyOn(Event.prototype, 'stopPropagation');

    fireEvent.click(button);

    expect(stop).toHaveBeenCalled();
    stop.mockRestore();
    expect(store.getState().getIn(['settings', 'group', 'detailCollapsed', '7'])).toBe(true);
    expect(detailButton('Show group detail').getAttribute('aria-pressed')).toBe('false');
    expect(detailButton('Show group detail').classList.contains('active')).toBe(false);
    expect(collapsible().classList.contains('collapsed')).toBe(true);
    expect(collapsible().classList.contains('animating')).toBe(true);
    expect(screen.getByTestId('group-detail')).toBeTruthy();
    expect(savedPayloads()[0].group.detailCollapsed['7']).toBe(true);
    expect(savedPayloads()[0].saved).toBeUndefined();

    act(() => {
      jest.advanceTimersByTime(1000);
    });
    fireEvent.click(detailButton('Show group detail'));

    expect(store.getState().getIn(['settings', 'group', 'detailCollapsed', '7'])).toBe(false);
    expect(detailButton('Hide group detail').getAttribute('title')).toBe('Hide group detail');
    expect(screen.getByTestId('group-detail')).toBeTruthy();

    act(() => {
      jest.advanceTimersByTime(1000);
    });

    const reopenedPayload = savedPayloads()[savedPayloads().length - 1];

    expect(reopenedPayload.group.detailCollapsed['7']).toBe(false);

    fireEvent.transitionEnd(collapsible());
    expect(collapsible().classList.contains('animating')).toBe(false);
    expect(screen.getByTestId('group-detail')).toBeTruthy();

    view.unmount();
    mockPut.mockClear();
    renderGroups(mountHydrated(reopenedPayload), [{ key: 'reopened', params: { id: '7' }, multiColumn: false }]);

    expect(detailButton('Hide group detail').getAttribute('aria-label')).toBe('Hide group detail');
    expect(screen.getByTestId('group-detail')).toBeTruthy();
    expect(mockPut).not.toHaveBeenCalled();

    fireEvent.click(detailButton('Hide group detail'));
    act(() => {
      jest.advanceTimersByTime(1000);
    });
    fireEvent.transitionEnd(collapsible());

    const closedPayload = savedPayloads()[savedPayloads().length - 1];

    expect(closedPayload.group.detailCollapsed['7']).toBe(true);
    expect(screen.queryByTestId('group-detail')).toBeNull();
  });

  it('keeps each group independent and does not carry the collapse animation across a switch', () => {
    const store = buildStore({
      group: { detailCollapsed: { 8: true } },
    });
    const view = renderGroups(store, [{ key: 'route', params: { id: '7' }, multiColumn: false }]);

    expect(screen.getByTestId('group-detail').getAttribute('data-group-id')).toBe('7');
    expect(mockPut).not.toHaveBeenCalled();

    fireEvent.click(detailButton('Hide group detail'));

    expect(collapsible().classList.contains('animating')).toBe(true);
    expect(store.getState().getIn(['settings', 'group', 'detailCollapsed', '7'])).toBe(true);
    detailRenders.length = 0;

    view.rerender(
      <Provider store={store}>
        <GroupTimeline params={{ id: '8' }} multiColumn={false} location={locationFor('8')} />
      </Provider>,
    );

    expect(detailRenders).not.toContain('8');
    expect(screen.queryByTestId('group-detail')).toBeNull();
    expect(collapsible().classList.contains('animating')).toBe(false);
    expect(collapsible().classList.contains('collapsed')).toBe(true);
    expect(detailButton('Show group detail')).toBeTruthy();
    expect(store.getState().getIn(['settings', 'group', 'detailCollapsed', '8'])).toBe(true);
    expect(store.getState().getIn(['settings', 'group', 'detailCollapsed', '7'])).toBe(true);
    expect(mockPut).toHaveBeenCalledTimes(1);

    view.rerender(
      <Provider store={store}>
        <GroupTimeline params={{ id: '7' }} multiColumn={false} location={locationFor('7')} />
      </Provider>,
    );

    expect(screen.queryByTestId('group-detail')).toBeNull();
    expect(detailButton('Show group detail')).toBeTruthy();
    expect(collapsible().classList.contains('animating')).toBe(false);
    expect(mockPut).toHaveBeenCalledTimes(1);
  });

  it('shares one setting across a route, a pinned column, and a filtered view', () => {
    const store = buildStore({
      group: {
        other: { onlyMedia: true },
        detailCollapsed: { 7: true },
      },
      columns: [
        { id: 'GROUP', uuid: 'col-a', params: { id: '7', other: { onlyMedia: false, withoutMedia: true, tagged: 'news' } } },
      ],
    });

    renderGroups(store, [
      { key: 'route', params: { id: '7', tagged: 'news' }, multiColumn: false },
      { key: 'column', params: { id: '7', tagged: 'photos' }, columnId: 'col-a', multiColumn: true },
    ]);

    const buttons = screen.getAllByRole('button', { name: 'Show group detail' });

    expect(buttons).toHaveLength(2);
    expect(groupCollapsibles().every(node => node.classList.contains('collapsed'))).toBe(true);
    expect(document.querySelectorAll('[data-testid="group-detail"]')).toHaveLength(0);

    fireEvent.click(buttons[1]);

    expect(store.getState().getIn(['settings', 'group', 'detailCollapsed', '7'])).toBe(false);
    expect(store.getState().getIn(['settings', 'group', 'detailCollapsed']).keySeq().toArray()).toEqual(['7']);
    expect(screen.getAllByRole('button', { name: 'Hide group detail' })).toHaveLength(2);
    expect(document.querySelectorAll('[data-testid="group-detail"]')).toHaveLength(2);
  });

  it('reads and writes numeric group ids as strings without dropping a saved false', () => {
    const store = buildStore({
      group: { detailCollapsed: { 7: false, 8: true } },
    });

    expect(store.getState().getIn(['settings', 'group', 'detailCollapsed', '7'])).toBe(false);
    expect(store.getState().getIn(['settings', 'group', 'detailCollapsed', '8'])).toBe(true);

    renderGroups(store, [{ key: 'numeric', params: { id: 7 }, multiColumn: true }]);

    expect(detailButton('Hide group detail')).toBeTruthy();
    expect(screen.getByTestId('group-detail')).toBeTruthy();
    expect(mockPut).not.toHaveBeenCalled();

    fireEvent.click(detailButton('Hide group detail'));

    expect(detailButton('Show group detail').getAttribute('aria-label')).toBe('Show group detail');
    expect(collapsible().classList.contains('collapsed')).toBe(true);
    expect(store.getState().getIn(['settings', 'group', 'detailCollapsed', '7'])).toBe(true);
    expect(store.getState().getIn(['settings', 'group', 'detailCollapsed', 7])).toBeUndefined();
    expect(store.getState().getIn(['settings', 'group', 'detailCollapsed', '8'])).toBe(true);
  });

  it('uses separately hydrated settings for each user', () => {
    const userA = hydrateSettings({
      group: { detailCollapsed: { 7: true, 8: false } },
    });
    const userB = hydrateSettings({
      group: { detailCollapsed: { 7: false } },
    });

    expect(userA.getIn(['group', 'detailCollapsed', '7'])).toBe(true);
    expect(userB.getIn(['group', 'detailCollapsed', '7'])).toBe(false);
    expect(userB.getIn(['group', 'detailCollapsed', '8'])).toBeUndefined();

    const mountedA = mountHydrated({
      group: { detailCollapsed: { 7: true, 8: false } },
    });
    const mountedB = mountHydrated({
      group: { detailCollapsed: { 7: false } },
    });

    renderGroups(mountedA, [{ key: 'a', params: { id: '7' }, multiColumn: true }]);
    renderGroups(mountedB, [{ key: 'b', params: { id: '7' }, multiColumn: true }]);

    expect(screen.getAllByRole('button', { name: 'Show group detail' })).toHaveLength(1);
    expect(screen.getAllByRole('button', { name: 'Hide group detail' })).toHaveLength(1);
    expect(mockPut).not.toHaveBeenCalled();
  });
});
