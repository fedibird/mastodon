/**
 * @jest-environment jsdom
 */

import { act, fireEvent, render } from '@testing-library/react';
import { List as ImmutableList, Map as ImmutableMap, fromJS } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { applyMiddleware, createStore } from 'redux';
import { combineReducers } from 'redux-immutable';
import thunk from 'redux-thunk';

jest.mock('react-intl', () => {
  const React = require('react');
  const intl = {
    formatMessage: ({ defaultMessage }) => defaultMessage,
    formatDate: () => '',
  };

  return {
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    defineMessages: messages => messages,
    FormattedMessage: ({ defaultMessage }) => defaultMessage,
    IntlProvider: ({ children }) => children,
  };
});

jest.mock('../../../containers/status_container', () => () => null);
jest.mock('../../../containers/scroll_container', () => ({ children }) => children);
jest.mock('../../../components/regeneration_indicator', () => () => null);
jest.mock('../../../components/load_gap', () => () => null);
jest.mock('../../../components/reload_zone', () => () => null);
jest.mock('../../../components/load_window_edge', () => () => null);
jest.mock('../../../filter_reconciliation/surface', () => ({
  FilterSurface: class {

    update () {}

    destroy () {}

    intersection () {}

    prepare () {}

  },
}));

import AccountContextLayer from '..';
import timelines from '../../../reducers/timelines';
import accountContextViews from '../../../reducers/account_context_views';
import { accountContextHostId } from '../../../timeline_seek/account_context';
import { seekSourceKey } from '../../../timeline_seek/query';
import { accountHistoryContract } from '../../../windowed_history/sources';
import { accountContextFilters } from '../../../timeline_seek/account_context';

const anchor = '9007199254740993';
const hostKey = 'home:split:column:session';
const otherHost = 'column:other';
const profileId = 'account:42';
const contract = accountHistoryContract('42', accountContextFilters({ reblog: true }));
const sourceKey = seekSourceKey(contract);

const rect = (top, height) => ({
  top,
  bottom: top + height,
  left: 0,
  right: 320,
  width: 320,
  height,
  x: 0,
  y: top,
  toJSON () {},
});

const layoutArticles = (list, heights) => {
  const articles = Array.from(list.querySelectorAll('article[data-id]'));

  articles.forEach((article) => {
    article.getBoundingClientRect = () => {
      let offset = 0;

      articles.some((item) => {
        if (item === article) {
          return true;
        }

        offset += heights[item.getAttribute('data-id')] || 0;

        return false;
      });

      return rect(offset - list.scrollTop, heights[article.getAttribute('data-id')] || 0);
    };
  });
  list.getBoundingClientRect = () => rect(0, 500);
};

const session = (host, statusId) => ImmutableMap({
  hostKey: host,
  generation: 1,
  kind: 'boost',
  accountId: '42',
  statusId,
  reply: false,
  reblog: true,
  sourceKey,
  phase: 'ready',
  notice: null,
  seekSessionId: `seek-${host}`,
  scrollRevision: 1,
  previousItems: null,
  previousWindow: null,
});

const hostedTimeline = (statusId, sessionId) => ImmutableMap({
  contextHost: true,
  contextSource: sourceKey,
  unread: 0,
  online: false,
  top: false,
  isLoading: false,
  hasMore: false,
  pendingItems: ImmutableList(),
  items: ImmutableList(['9007199254740996', '9007199254740995', '9007199254740994', statusId]),
  window: fromJS({
    generation: 1,
    revision: 1,
    anchorId: statusId,
    anchorResolution: 'exact',
    unbounded: false,
    hasNewer: false,
    hasOlder: false,
    seeking: false,
    newer: { status: 'exhausted', requestId: null, cursor: '9007199254740996' },
    older: { status: 'exhausted', requestId: null, cursor: statusId },
  }),
  seek: fromJS({
    id: sessionId,
    phase: 'resolved',
    source: sourceKey,
    anchorId: statusId,
    scrollStatus: 'pending',
    scrollRevision: 1,
  }),
});

const buildStore = () => createStore(combineReducers({
  dropdown_menu: (state = ImmutableMap({ openId: null })) => state,
  height_cache: (state = ImmutableMap()) => state,
  timelines,
  accountContextViews,
}), ImmutableMap({
  dropdown_menu: ImmutableMap({ openId: null }),
  height_cache: ImmutableMap(),
  timelines: ImmutableMap({
    [profileId]: ImmutableMap({
      items: ImmutableList(['100', '90']),
      pendingItems: ImmutableList(['800']),
      isLoading: false,
      hasMore: true,
    }),
    [accountContextHostId(hostKey)]: hostedTimeline(anchor, `seek-${hostKey}`),
    [accountContextHostId(otherHost)]: hostedTimeline('9007199254740990', `seek-${otherHost}`),
  }),
  accountContextViews: ImmutableMap({
    order: ImmutableList([otherHost, hostKey]),
    sessions: ImmutableMap({
      [otherHost]: session(otherHost, '9007199254740990'),
      [hostKey]: session(hostKey, anchor),
    }),
  }),
}), applyMiddleware(thunk));

describe('AccountContextLayer', () => {
  let frames;

  beforeEach(() => {
    frames = [];
    global.IntersectionObserver = class {

      observe () {}

      unobserve () {}

      disconnect () {}

      takeRecords () {
        return [];
      }

    };
    jest.spyOn(window, 'requestAnimationFrame').mockImplementation((callback) => {
      frames.push(callback);

      return frames.length;
    });
    jest.spyOn(window, 'cancelAnimationFrame').mockImplementation((id) => {
      frames[id - 1] = null;
    });
  });

  afterEach(() => {
    document.body.innerHTML = '';
    jest.restoreAllMocks();
  });

  const flushFrames = () => {
    const batch = frames.splice(0, frames.length);

    act(() => {
      batch.forEach(callback => callback && callback(0));
    });
  };

  it('scrolls the anchor article and returns without replacing the profile timeline', () => {
    const store = buildStore();
    const view = render(
      <Provider store={store}>
        <AccountContextLayer />
      </Provider>,
    );
    const panel = view.container.querySelectorAll('.account-context-panel');
    const list = panel[panel.length - 1].querySelector('.scrollable');

    layoutArticles(list, {
      '9007199254740996': 100,
      '9007199254740995': 100,
      '9007199254740994': 100,
      [anchor]: 120,
    });

    expect(list.querySelector(`article[data-id="${anchor}"]`)).not.toBeNull();
    expect(list.scrollTop).toBe(0);

    flushFrames();

    expect(list.scrollTop).toBe(300);
    expect(store.getState().getIn(['timelines', accountContextHostId(hostKey), 'seek', 'scrollStatus'])).toBe('loaded');
    expect(store.getState().getIn(['timelines', profileId, 'items']).toArray()).toEqual(['100', '90']);
    expect(store.getState().getIn(['timelines', profileId, 'pendingItems']).toArray()).toEqual(['800']);

    const buttons = view.getAllByRole('button', { name: 'Back' });

    fireEvent.click(buttons[buttons.length - 1]);

    expect(store.getState().get('timelines').has(accountContextHostId(hostKey))).toBe(false);
    expect(store.getState().get('timelines').has(accountContextHostId(otherHost))).toBe(true);
    expect(store.getState().getIn(['timelines', profileId, 'items']).toArray()).toEqual(['100', '90']);
    expect(store.getState().getIn(['accountContextViews', 'order']).toArray()).toEqual([otherHost]);
  });
});
