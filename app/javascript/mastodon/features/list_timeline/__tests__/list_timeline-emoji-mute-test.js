/* eslint-disable react/prop-types, react/jsx-no-bind */

import { act, render } from '@testing-library/react';
import { List as ImmutableList, Map as ImmutableMap, fromJS } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { applyMiddleware, createStore } from 'redux';
import { combineReducers } from 'redux-immutable';
import thunk from 'redux-thunk';

import { EMOJI_MUTES_APPLY, EMOJI_MUTES_DISABLE, EMOJI_MUTES_ENABLE, EMOJI_MUTES_IGNORE, EMOJI_MUTES_RESET, EMOJI_MUTES_REVISION } from 'mastodon/actions/emoji_mutes';
import { createUnverifiedEmojiGuard } from 'mastodon/features/emoji/emoji_mute_live_dom';
import { resetEmojiMuteTextForTests } from 'mastodon/features/emoji/emoji_mute_text';
import emojiMutes from 'mastodon/reducers/emoji_mutes';
import settings from 'mastodon/reducers/settings';
import timelines from 'mastodon/reducers/timelines';

jest.mock('react-intl', () => {
  const React = require('react');
  const intl = { formatMessage: message => message.defaultMessage || message.id, formatDate: () => '' };

  return {
    defineMessages: messages => messages,
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    FormattedMessage: ({ defaultMessage }) => defaultMessage,
  };
});

jest.mock('mastodon/initial_state', () => ({
  ...jest.requireActual('mastodon/initial_state'),
  isAdministrator: false,
}));

jest.mock('mastodon/api', () => ({
  __esModule: true,
  default: jest.fn(() => ({ get: jest.fn(() => new Promise(() => {})), put: jest.fn(() => new Promise(() => {})) })),
  getLinks: () => ({ refs: [] }),
}));

jest.mock('../../../actions/streaming', () => ({
  connectListStream: () => () => () => {},
}));

jest.mock('../../../actions/external_feeds', () => ({
  openExternalFeedView: () => () => 'feed-token',
  closeExternalFeedView: () => () => {},
  resumeExternalFeedViews: () => () => {},
}));

jest.mock('../../../components/missing_indicator', () => () => null);
jest.mock('../../../components/loading_indicator', () => () => null);

jest.mock('../../compose/portable_composer', () => () => null);

jest.mock('../../ui/containers/status_list_container', () => {
  const React = require('react');
  const state = { renders: 0, mounts: 0 };
  global.__listStatusListRenders = state;

  return function StatusListContainer () {
    const mountId = React.useRef(0);

    if (mountId.current === 0) {
      state.mounts += 1;
      mountId.current = state.mounts;
    }

    state.renders += 1;
    return React.createElement('div', {
      className: 'scrollable',
      'data-testid': 'status-list',
      'data-mount': String(mountId.current),
      'data-renders': String(state.renders),
    });
  };
});

import ListTimeline from '../index';

const THUMB = '👍';
const FAMILY = '👨‍👩‍👧‍👧';
const PLACEHOLDER = '\u25FB';
const COLUMN_TITLE = 'Lists';

const rule = (emoji, replacement, effects = {}) => ({
  id: `rule-${replacement}`,
  emoji,
  replacement,
  effects: {
    replace_in_text: true,
    hide_reactions: false,
    reject_reactions_to_own_posts: false,
    hide_in_picker: false,
    ...effects,
  },
});

const lists = (state = ImmutableMap(), action) => (
  action.type === 'LIST_TEST_SET' ? action.lists : state
);

const friendList = (title) => fromJS({ id: '42', title, replies_policy: 'list' });

const buildStore = (title = `Friends ${THUMB}`) => {
  const reducer = combineReducers({ timelines, settings, lists, emojiMutes });
  let state = reducer(undefined, { type: '@@INIT' });

  state = state.set('lists', ImmutableMap({ 42: friendList(title) }));
  state = state.setIn(['timelines', 'list:42'], ImmutableMap({
    unread: 0,
    online: true,
    top: false,
    isLoading: false,
    hasMore: true,
    isPartial: false,
    pendingItems: ImmutableList(),
    items: ImmutableList(['100']),
  }));

  return createStore(reducer, state, applyMiddleware(thunk));
};

const renderList = (store, props = {}) => render(
  <Provider store={store}>
    <ListTimeline
      params={{ id: '42' }}
      multiColumn
      columnId='col-a'
      location={{ key: 'loc-42', pathname: '/timelines/list/42' }}
      {...props}
    />
  </Provider>,
);

const headingText = container => container.querySelector('h1 button').textContent;
const region = container => container.querySelector('[role="region"]');

const apply = (store, mutes, revision = '2') => {
  act(() => {
    store.dispatch({ type: EMOJI_MUTES_APPLY, revision, mutes, availability: 'enabled' });
  });
};

const mountGuarded = (store, props) => {
  const guard = createUnverifiedEmojiGuard();
  const during = { region: '', heading: '' };

  store.subscribe(() => guard(store.getState()));
  store.subscribe(() => {
    during.region = document.querySelector('.emoji-mutes-privacy-portal [role="region"]')?.getAttribute('aria-label') || '';
    during.heading = document.querySelector('.emoji-mutes-privacy-portal h1 > button')?.textContent || '';
    during.button = document.querySelector('.emoji-mutes-privacy-portal h1 > button')?.getAttribute('aria-label') || '';
  });

  const privacy = document.createElement('div');
  const mount = document.createElement('div');

  privacy.className = 'emoji-mutes-privacy-portal';
  privacy.appendChild(mount);
  document.body.appendChild(privacy);

  const view = render(
    <Provider store={store}>
      <ListTimeline
        params={{ id: '42' }}
        multiColumn
        columnId='col-a'
        location={{ key: 'loc-guard', pathname: '/timelines/list/42' }}
        {...props}
      />
    </Provider>,
    { container: mount },
  );

  return { during, container: view.container, view };
};

describe('list column emoji mute', () => {
  beforeEach(() => {
    resetEmojiMuteTextForTests();
    global.__listStatusListRenders.renders = 0;
    global.__listStatusListRenders.mounts = 0;
  });

  afterEach(() => {
    document.body.innerHTML = '';
  });

  it('projects the visible heading and the region from the stored title on first mount', () => {
    const title = `Friends ${THUMB} ${FAMILY}`;
    const store = buildStore(title);

    apply(store, [
      rule({ kind: 'unicode', native: THUMB }, '[ok]'),
      rule({ kind: 'unicode', native: FAMILY }, '[family]'),
    ], '2');

    const { container } = renderList(store);

    expect(headingText(container)).toBe('Friends [ok] [family]');
    expect(region(container).getAttribute('aria-label')).toBe('Friends [ok] [family]');
    expect(store.getState().getIn(['lists', '42', 'title'])).toBe(title);
    expect(container.innerHTML).not.toContain('data-emoji-mute');
    expect(container.querySelector('[data-testid="status-list"]').getAttribute('data-mount')).toBe('1');
  });

  it('keeps a literal shortcode and does not rebuild the timeline when rules change', () => {
    const title = `Friends ${THUMB} :blob:`;
    const store = buildStore(title);
    const { container } = renderList(store);
    const mountedList = container.querySelector('[data-testid="status-list"]');

    apply(store, [
      rule({ kind: 'unicode', native: THUMB }, '[ok]'),
      rule({ kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' }, '[local]'),
    ]);

    expect(headingText(container)).toBe('Friends [ok] :blob:');
    expect(container.querySelector('h1 > button').getAttribute('aria-label')).toBe('Friends [ok] :blob:');
    expect(region(container).getAttribute('aria-label')).toBe('Friends [ok] :blob:');
    expect(container.querySelector('[data-testid="status-list"]')).toBe(mountedList);
    expect(mountedList.getAttribute('data-mount')).toBe('1');
    expect(store.getState().getIn(['lists', '42', 'title'])).toBe(title);
  });

  it('uses the column name when the projection is empty or whitespace and restores the title', () => {
    const store = buildStore(THUMB);
    const blank = [rule({ kind: 'unicode', native: THUMB }, '')];
    const spaces = [rule({ kind: 'unicode', native: THUMB }, '   ')];
    const { during, container } = mountGuarded(store);

    apply(store, blank, '2');

    expect(region(container).getAttribute('aria-label')).toBe(COLUMN_TITLE);
    expect(headingText(container)).toBe('');
    expect(container.querySelector('h1 > button').getAttribute('aria-label')).toBe(COLUMN_TITLE);
    expect(container.querySelector('h1 > button').getAttribute('aria-label')).not.toContain(THUMB);

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_REVISION, revision: '3' });
      expect(during.region).not.toContain(THUMB);
      expect(during.heading).not.toContain(THUMB);
      expect(during.button).not.toContain(THUMB);
      store.dispatch({ type: EMOJI_MUTES_APPLY, revision: '3', mutes: blank, availability: 'enabled' });
      expect(during.region).toBe(COLUMN_TITLE);
      expect(during.heading).toBe('');
      expect(during.button).toBe(COLUMN_TITLE);
    });

    apply(store, spaces, '4');

    expect(region(container).getAttribute('aria-label')).toBe(COLUMN_TITLE);
    expect(headingText(container)).toBe('   ');
    expect(container.querySelector('h1 > button').getAttribute('aria-label')).toBe(COLUMN_TITLE);

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_IGNORE });
    });

    expect(region(container).getAttribute('aria-label')).toBe(THUMB);
    expect(headingText(container)).toBe(THUMB);

    apply(store, [rule({ kind: 'unicode', native: THUMB }, '[named]')], '5');

    expect(region(container).getAttribute('aria-label')).toBe('[named]');

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_DISABLE });
    });

    expect(region(container).getAttribute('aria-label')).toBe(THUMB);
    expect(headingText(container)).toBe(THUMB);
  });

  it('projects a plain title once when the guard runs before React', () => {
    const title = `Name ${THUMB}`;
    const store = buildStore(title);
    const { during, container } = mountGuarded(store);

    apply(store, [
      rule({ kind: 'unicode', native: THUMB }, '😺'),
      rule({ kind: 'unicode', native: '😺' }, '[cat]'),
    ], '2');

    expect(headingText(container)).toBe('Name 😺');
    expect(region(container).getAttribute('aria-label')).toBe('Name 😺');

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_REVISION, revision: '3' });
      expect(during.region).not.toContain(THUMB);
      expect(during.heading).not.toContain(THUMB);
      expect(during.region).toBe(during.heading);
      store.dispatch({ type: EMOJI_MUTES_APPLY, revision: '3', mutes: [
        rule({ kind: 'unicode', native: THUMB }, '😺'),
        rule({ kind: 'unicode', native: '😺' }, '[cat]'),
      ], availability: 'enabled' });
      expect(during.region).toBe('Name 😺');
      expect(during.heading).toBe('Name 😺');
      expect(during.region).not.toContain('[cat]');
    });

    expect(region(container).getAttribute('aria-label')).toBe('Name 😺');
    expect(headingText(container)).toBe('Name 😺');
  });

  it('follows a new stored title and clears the previous emoji', () => {
    const store = buildStore(`Old ${THUMB}`);
    const { container } = renderList(store);

    apply(store, [
      rule({ kind: 'unicode', native: THUMB }, '[old]'),
      rule({ kind: 'unicode', native: '✨' }, '[new]'),
    ]);

    expect(headingText(container)).toBe('Old [old]');

    act(() => {
      store.dispatch({ type: 'LIST_TEST_SET', lists: ImmutableMap({ 42: friendList('New ✨') }) });
    });

    expect(headingText(container)).toBe('New [new]');
    expect(region(container).getAttribute('aria-label')).toBe('New [new]');
    expect(headingText(container)).not.toContain(THUMB);
    expect(region(container).getAttribute('aria-label')).not.toContain('[old]');

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_RESET });
    });

    expect(headingText(container)).toBe('New ✨');
    expect(region(container).getAttribute('aria-label')).toBe('New ✨');

    apply(store, [rule({ kind: 'unicode', native: '✨' }, '[next]')], '1');

    expect(headingText(container)).toBe('New [next]');
    expect(region(container).getAttribute('aria-label')).toBe('New [next]');
  });

  it('suppresses the portaled single-column heading before React commits', () => {
    const store = buildStore(`Friends ${THUMB}`);
    const portal = document.createElement('div');
    const privacy = document.createElement('div');
    const mount = document.createElement('div');
    const guard = createUnverifiedEmojiGuard();
    const during = { heading: '', region: '' };

    portal.id = 'tabs-bar__portal';
    privacy.className = 'emoji-mutes-privacy-portal';
    privacy.appendChild(mount);
    privacy.appendChild(portal);
    document.body.appendChild(privacy);
    store.subscribe(() => guard(store.getState()));
    store.subscribe(() => {
      during.heading = document.querySelector('#tabs-bar__portal h1 > button')?.textContent || '';
      during.button = document.querySelector('#tabs-bar__portal h1 > button')?.getAttribute('aria-label') || '';
      during.region = document.querySelector('.emoji-mutes-privacy-portal [role="region"]')?.getAttribute('aria-label') || '';
    });

    render(
      <Provider store={store}>
        <ListTimeline params={{ id: '42' }} multiColumn={false} location={{ key: 'loc-mobile', pathname: '/timelines/list/42' }} />
      </Provider>,
      { container: mount },
    );

    // A newer revision after an applied projection leaves that projection
    // until React commits. Suppress while the raw title is still visible.
    act(() => {
      store.dispatch({ type: EMOJI_MUTES_ENABLE });
      expect(during.heading).toContain(PLACEHOLDER);
      expect(during.button).toContain(PLACEHOLDER);
      expect(during.region).toContain(PLACEHOLDER);
      expect(during.heading).not.toContain(THUMB);
      expect(during.button).not.toContain(THUMB);
      expect(during.region).not.toContain(THUMB);
    });

    const titleButton = document.querySelector('#tabs-bar__portal h1 > button');
    const heading = titleButton.textContent;
    const label = mount.querySelector('[role="region"]').getAttribute('aria-label');

    expect(heading).toBe(`Friends ${PLACEHOLDER}`);
    expect(titleButton.getAttribute('aria-label')).toBe(`Friends ${PLACEHOLDER}`);
    expect(label).toBe(`Friends ${PLACEHOLDER}`);
    expect(heading).not.toContain(THUMB);
  });
});
