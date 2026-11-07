/* eslint-disable react/prop-types, react/jsx-no-bind */
import React from 'react';
import { fireEvent, render } from '@testing-library/react';
import { Provider } from 'react-redux';
import { createStore, applyMiddleware } from 'redux';
import thunk from 'redux-thunk';
import { Router } from 'react-router-dom';
import { createMemoryHistory } from 'history';
import { IntlProvider } from 'react-intl';
import { HotKeys } from 'react-hotkeys';
import { fromJS, Map as ImmutableMap } from 'immutable';
import fullscreenColumn from 'mastodon/reducers/fullscreen_column';

jest.mock('mastodon/containers/account_container', () => () => null);
jest.mock('mastodon/containers/status_container', () => () => null);
jest.mock('mastodon/features/notifications/containers/follow_request_container', () => () => null);

import NotificationContainer from '../notification_container';

const reducer = (state, action) => state.set('fullscreenColumn', fullscreenColumn(state.get('fullscreenColumn'), action));

const account = fromJS({
  id: '7',
  acct: 'ada',
  url: 'https://example.test/ada',
  display_name_html: 'Ada',
  group: false,
});

const notification = fromJS({
  id: 'n1',
  type: 'follow',
  created_at: '2026-11-07T00:00:00.000Z',
  account: '7',
});

const initialState = (composerId) => ImmutableMap({
  accounts: fromJS({ '7': account }),
  compose: fromJS({ text: 'primary draft', dirty: true, mounted: true }),
  composers: fromJS({
    byId: {
      'fullscreen:notes': { text: '', dirty: false, mounted: true },
    },
  }),
  fullscreenColumn: composerId ? fromJS({
    open: true,
    viewId: 'view-1',
    composerId,
    composerOpen: false,
    paths: [],
    source: { kind: 'notifications' },
    presentation: { appearance: 'normal' },
  }) : null,
});

const press = (node, key) => {
  const payload = { key, code: `Key${key.toUpperCase()}`, keyCode: key === 'r' ? 82 : 77, which: key === 'r' ? 82 : 77, charCode: key.charCodeAt(0) };

  fireEvent.keyDown(node, payload);
  fireEvent.keyPress(node, payload);
  fireEvent.keyUp(node, payload);
};

const renderFollow = (composerId) => {
  const actions = [];
  const store = createStore(reducer, initialState(composerId), applyMiddleware(
    thunk,
    () => (next) => (action) => {
      if (action && action.type) {
        actions.push(action);
      }

      return next(action);
    },
  ));
  const history = createMemoryHistory({ initialEntries: ['/timelines/home'] });
  const view = render(
    <Provider store={store}>
      <IntlProvider locale='en'>
        <Router history={history}>
          <HotKeys keyMap={{ reply: 'r', mention: 'm' }}>
            <NotificationContainer
              notification={notification}
              accountId='7'
              composerId={composerId}
              onMoveUp={() => {}}
              onMoveDown={() => {}}
              unread={false}
            />
          </HotKeys>
        </Router>
      </IntlProvider>
    </Provider>,
  );

  return { actions, store, view };
};

describe('follow notification hotkeys', () => {
  it('mentions into the fullscreen composer from R and M', () => {
    const { actions, store, view } = renderFollow('fullscreen:notes');
    const row = view.container.querySelector('.notification-follow');

    row.focus();
    press(row, 'r');

    const mention = actions.filter(action => action.type === 'COMPOSE_MENTION');

    expect(mention).toHaveLength(1);
    expect(mention[0].meta.composerId).toBe('fullscreen:notes');
    expect(store.getState().getIn(['fullscreenColumn', 'composerOpen'])).toBe(true);
    expect(store.getState().getIn(['compose', 'text'])).toBe('primary draft');

    actions.length = 0;
    store.dispatch({ type: 'FULLSCREEN_COLUMN_PATCH', patch: { composerOpen: false } });
    press(row, 'm');

    const second = actions.filter(action => action.type === 'COMPOSE_MENTION');

    expect(second).toHaveLength(1);
    expect(second[0].meta.composerId).toBe('fullscreen:notes');
    expect(store.getState().getIn(['fullscreenColumn', 'composerOpen'])).toBe(true);
  });

  it('keeps a normal follow notification on the primary composer', () => {
    const { actions, store, view } = renderFollow(null);
    const row = view.container.querySelector('.notification-follow');

    row.focus();
    press(row, 'm');

    const mention = actions.filter(action => action.type === 'COMPOSE_MENTION');

    expect(mention).toHaveLength(1);
    expect(mention[0].meta.composerId).toBe('primary');
    expect(store.getState().get('fullscreenColumn')).toBeNull();
  });
});
