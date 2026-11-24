/* eslint-disable react/prop-types, react/jsx-no-bind */

import { act, render } from '@testing-library/react';
import { Map as ImmutableMap, fromJS } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { applyMiddleware, createStore } from 'redux';
import { combineReducers } from 'redux-immutable';
import thunk from 'redux-thunk';

import { EMOJI_MUTES_APPLY, EMOJI_MUTES_DISABLE, EMOJI_MUTES_FAIL, EMOJI_MUTES_IGNORE, EMOJI_MUTES_RESET, EMOJI_MUTES_REVISION } from 'mastodon/actions/emoji_mutes';
import { createUnverifiedEmojiGuard } from 'mastodon/features/emoji/emoji_mute_live_dom';
import { groupTimelineId } from 'mastodon/actions/timeline_ids';
import { resetEmojiMuteTextForTests } from 'mastodon/features/emoji/emoji_mute_text';
import emojiMutes from 'mastodon/reducers/emoji_mutes';
import settings from 'mastodon/reducers/settings';

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

jest.mock('../../../actions/accounts', () => ({
  fetchAccount: id => ({ type: 'ACCOUNT_FETCH', id }),
}));

jest.mock('../../../actions/posting_contexts', () => ({
  fetchPostingContext: id => ({ type: 'POSTING_CONTEXT_FETCH', id }),
}));

jest.mock('../../../actions/streaming', () => ({
  connectGroupStream: () => () => () => {},
}));

jest.mock('../containers/column_settings_container', () => () => null);
jest.mock('../components/group_detail', () => () => <div data-testid='group-detail' />);
jest.mock('../../compose/portable_composer', () => () => null);

jest.mock('../../ui/containers/status_list_container', () => {
  const React = require('react');
  const state = { renders: 0 };
  global.__groupStatusListRenders = state;

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

import GroupTimeline from '../index';

const THUMB = '👍';
const THUMB_LIGHT = '👍🏻';
const FAMILY = '👨‍👩‍👧‍👧';

const unicodeImg = native => (
  `<img draggable="false" class="emojione" alt="${native}" title="${native}" src="/emoji/${encodeURIComponent(native)}.svg">`
);

const localImg = (id, shortcode = 'blob') => (
  `<img draggable="false" class="emojione custom-emoji" alt=":${shortcode}:" title="${shortcode}" src="https://cdn.example/${id}.svg" data-shortcode="${shortcode}" data-domain="" data-emoji-id="${id}">`
);

const localImgWithoutId = (shortcode = 'blob') => (
  `<img draggable="false" class="emojione custom-emoji" alt=":${shortcode}:" title="${shortcode}" src="https://cdn.example/legacy.svg" data-shortcode="${shortcode}" data-domain="">`
);

const remoteImg = (domain, shortcode = 'blob') => (
  `<img draggable="false" class="emojione custom-emoji" alt=":${shortcode}:" title="${shortcode}" src="https://cdn.example/${domain}/${shortcode}.svg" data-shortcode="${shortcode}" data-domain="${domain}">`
);

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

const accounts = (state = ImmutableMap()) => state;
const posting_contexts = (state = ImmutableMap()) => state;
const timelines = (state = ImmutableMap(), action) => (
  action.type === 'TEST_UNREAD' ? state.setIn([action.id, 'unread'], action.unread) : state
);

const account = (id, fields) => fromJS({
  id: String(id),
  username: 'group',
  acct: 'group@example.com',
  group: true,
  display_name: 'Group',
  display_name_html: 'Group',
  ...fields,
});

const buildStore = (record) => {
  const reducer = combineReducers({ timelines, settings, accounts, posting_contexts, emojiMutes });
  let state = reducer(undefined, { type: '@@INIT' });
  state = state.setIn(['accounts', '7'], record);
  return createStore(reducer, state, applyMiddleware(thunk));
};

const renderGroup = (store) => render(
  <Provider store={store}>
    <GroupTimeline params={{ id: '7' }} multiColumn={false} location={{ key: 'loc-7', pathname: '/timelines/groups/7' }} />
  </Provider>,
);

const headingButton = () => document.querySelector('#tabs-bar__portal h1 button');
const headingText = () => headingButton().textContent;
const region = container => container.querySelector('[role="region"]');

const PLACEHOLDER = '\u25FB';

const apply = (store, mutes, revision = '2') => {
  act(() => {
    store.dispatch({ type: EMOJI_MUTES_APPLY, revision, mutes, availability: 'enabled' });
  });
};

describe('group column emoji mute landmark', () => {
  beforeEach(() => {
    resetEmojiMuteTextForTests();
    global.__groupStatusListRenders.renders = 0;
    global.__groupStatusListRenders.mounts = 0;
    const portal = document.createElement('div');
    portal.id = 'tabs-bar__portal';
    document.body.appendChild(portal);
  });

  afterEach(() => {
    document.getElementById('tabs-bar__portal')?.remove();
  });

  it('projects the region label on first mount when the rules are already applied', () => {
    const plain = `Group ${THUMB}`;
    const html = `Group ${unicodeImg(THUMB)}`;
    const store = buildStore(account('7', { display_name: plain, display_name_html: html }));

    apply(store, [
      rule({ kind: 'unicode', native: THUMB }, '[on]'),
    ], '2');

    const { container } = renderGroup(store);

    expect(headingText()).toBe('Group [on]');
    expect(region(container).getAttribute('aria-label')).toBe('Group [on]');
    expect(store.getState().getIn(['accounts', '7', 'display_name'])).toBe(plain);
    expect(store.getState().getIn(['accounts', '7', 'display_name_html'])).toBe(html);
  });

  it('keeps the visible title and the region label on the same projection', () => {
    const plain = `Group ${THUMB} ${THUMB_LIGHT} ${FAMILY}`;
    const html = `Group ${unicodeImg(THUMB)} ${unicodeImg(THUMB_LIGHT)} ${unicodeImg(FAMILY)} ${localImg('10')} ${localImg('11')} ${localImgWithoutId()} ${remoteImg('a.test')} ${remoteImg('b.test')}`;
    const store = buildStore(account('7', { display_name: plain, display_name_html: html }));
    const { container } = renderGroup(store);
    const button = headingButton();
    const mountedList = document.querySelector('[data-testid="status-list"]');

    expect(headingText(container)).toBe(plain);
    expect(region(container).getAttribute('aria-label')).toBe(plain);
    expect(store.getState().getIn(['accounts', '7', 'display_name_html'])).toBe(html);

    button.focus();
    apply(store, [
      rule({ kind: 'unicode', native: THUMB_LIGHT }, '[skin]'),
      rule({ kind: 'unicode', native: THUMB }, '[base]'),
      rule({ kind: 'unicode', native: FAMILY }, '<img src=x onerror=alert(1)>'),
      rule({ kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' }, '[local]'),
      rule({ kind: 'custom', scope: 'remote', domain: 'a.test', shortcode: 'blob' }, '[remote]'),
    ]);

    const projected = 'Group [base] [skin] <img src=x onerror=alert(1)> [local] :blob: :blob: [remote] :blob:';

    expect(headingText(container)).toBe(projected);
    expect(region(container).getAttribute('aria-label')).toBe(projected);
    expect(container.querySelector('h1 img')).toBeNull();
    expect(container.querySelector('img[onerror]')).toBeNull();
    expect(document.activeElement).toBe(button);
    expect(document.querySelector('[data-testid="status-list"]')).toBe(mountedList);
    expect(mountedList.getAttribute('data-mount')).toBe('1');
    expect(store.getState().getIn(['accounts', '7', 'display_name'])).toBe(plain);

    act(() => {
      store.dispatch({ type: 'TEST_UNREAD', id: groupTimelineId('7', {}), unread: 2 });
    });

    expect(region(container).getAttribute('aria-label')).toBe(projected);
    expect(headingText()).toBe(projected);
    expect(document.querySelector('[data-testid="status-list"]')).toBe(mountedList);
  });

  it('leaves an empty display name on the acct fallback', () => {
    const html = localImg('10');
    const store = buildStore(account('7', { display_name: '', display_name_html: html, acct: 'named-group@example.com' }));
    const { container } = renderGroup(store);

    apply(store, [
      rule({ kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' }, '[local]'),
    ]);

    expect(headingText(container)).toBe('named-group');
    expect(region(container).getAttribute('aria-label')).toBe('named-group');
  });

  it('ignores replace_in_text false and restores the name when the rule is removed', () => {
    const plain = `Group ${THUMB}`;
    const html = `Group ${unicodeImg(THUMB)}`;
    const store = buildStore(account('7', { display_name: plain, display_name_html: html }));
    const { container } = renderGroup(store);

    apply(store, [
      rule({ kind: 'unicode', native: THUMB }, '[off]', { replace_in_text: false }),
    ], '2');

    expect(region(container).getAttribute('aria-label')).toBe(plain);
    expect(headingText(container)).toBe(plain);

    apply(store, [
      rule({ kind: 'unicode', native: THUMB }, '[on]'),
    ], '3');

    expect(region(container).getAttribute('aria-label')).toBe('Group [on]');

    apply(store, [], '4');

    expect(region(container).getAttribute('aria-label')).toBe(plain);
    expect(headingText(container)).toBe(plain);
  });

  it('keeps the applied document through a stale revision and drops it on account reset', () => {
    const plain = `Group ${THUMB}`;
    const html = `Group ${unicodeImg(THUMB)}`;
    const store = buildStore(account('7', { display_name: plain, display_name_html: html }));
    const { container } = renderGroup(store);

    expect(region(container).getAttribute('aria-label')).toBe(plain);

    apply(store, [
      rule({ kind: 'unicode', native: THUMB }, '[first]'),
    ], '1');

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_REVISION, revision: '4' });
    });

    expect(store.getState().getIn(['emojiMutes', 'phase'])).toBe('stale');
    expect(store.getState().getIn(['emojiMutes', 'display'])).toBe('suppress');
    expect(region(container).getAttribute('aria-label')).toBe(`Group ${PLACEHOLDER}`);
    expect(headingText()).toBe(`Group ${PLACEHOLDER}`);
    expect(region(container).getAttribute('aria-label')).not.toContain(THUMB);

    act(() => {
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '2',
        mutes: [rule({ kind: 'unicode', native: THUMB }, '[late]')],
      });
    });

    expect(region(container).getAttribute('aria-label')).toBe(`Group ${PLACEHOLDER}`);

    apply(store, [
      rule({ kind: 'unicode', native: THUMB }, '[second]'),
    ], '4');

    expect(region(container).getAttribute('aria-label')).toBe('Group [second]');

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_RESET });
    });

    expect(region(container).getAttribute('aria-label')).toBe(plain);
    expect(headingText(container)).toBe(plain);
    expect(container.querySelector('[role="region"]').getAttribute('aria-label')).not.toContain('[second]');

    apply(store, [
      rule({ kind: 'unicode', native: THUMB }, '[next-user]'),
    ], '1');

    expect(region(container).getAttribute('aria-label')).toBe('Group [next-user]');
    expect(headingText()).toBe('Group [next-user]');

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_IGNORE });
    });

    expect(store.getState().getIn(['emojiMutes', 'display'])).toBe('show');
    expect(region(container).getAttribute('aria-label')).toBe(plain);
    expect(headingText()).toBe(plain);

    apply(store, [
      rule({ kind: 'unicode', native: THUMB }, '[again]'),
    ], '2');

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_FAIL, failure: 'unavailable' });
    });

    expect(store.getState().getIn(['emojiMutes', 'display'])).toBe('suppress');
    expect(region(container).getAttribute('aria-label')).toBe(`Group ${PLACEHOLDER}`);
    expect(headingText()).not.toContain(THUMB);

    apply(store, [
      rule({ kind: 'unicode', native: THUMB }, '[again]'),
    ], '3');

    expect(region(container).getAttribute('aria-label')).toBe('Group [again]');

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_DISABLE });
    });

    expect(store.getState().getIn(['emojiMutes', 'display'])).toBe('show');
    expect(region(container).getAttribute('aria-label')).toBe(plain);
    expect(headingText()).toBe(plain);
  });

  it('hides a custom display name before React commits and does not reproject the replacement', () => {
    const plain = ':blob: :blob:';
    const html = `${localImg('10')} ${remoteImg('a.test')}`;
    const store = buildStore(account('7', { display_name: plain, display_name_html: html }));
    const guard = createUnverifiedEmojiGuard();
    let during = null;

    store.subscribe(() => guard(store.getState()));
    store.subscribe(() => {
      during = {
        region: document.querySelector('.emoji-mutes-privacy-portal [role="region"]')?.getAttribute('aria-label'),
        heading: document.querySelector('#tabs-bar__portal h1 button')?.textContent,
      };
    });

    const privacy = document.createElement('div');
    const mount = document.createElement('div');

    privacy.className = 'emoji-mutes-privacy-portal';
    privacy.appendChild(mount);
    privacy.appendChild(document.getElementById('tabs-bar__portal'));
    document.body.appendChild(privacy);

    const { container } = render(
      <Provider store={store}>
        <GroupTimeline params={{ id: '7' }} multiColumn={false} location={{ key: 'loc-7', pathname: '/timelines/groups/7' }} />
      </Provider>,
      { container: mount },
    );

    apply(store, [
      rule({ kind: 'unicode', native: '😺' }, '[cat]'),
      rule({ kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' }, '😺'),
      rule({ kind: 'custom', scope: 'remote', domain: 'b.test', shortcode: 'blob' }, '[other]'),
    ], '2');

    expect(headingText()).toBe('😺 :blob:');
    expect(region(container).getAttribute('aria-label')).toBe('😺 :blob:');
    expect(store.getState().getIn(['accounts', '7', 'display_name_html'])).toBe(html);

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_REVISION, revision: '3' });
      expect(during.region).not.toContain(':blob:');
      expect(during.heading).not.toContain(':blob:');
      expect(during.region).toBe(during.heading);
      store.dispatch({ type: EMOJI_MUTES_APPLY, revision: '3', mutes: [
        rule({ kind: 'unicode', native: '😺' }, '[cat]'),
        rule({ kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' }, '😺'),
      ], availability: 'enabled' });
      expect(during.region).toBe('😺 :blob:');
      expect(during.heading).toBe('😺 :blob:');
      expect(during.region).not.toContain('[cat]');
    });

    expect(region(container).getAttribute('aria-label')).toBe('😺 :blob:');
    expect(headingText()).toBe('😺 :blob:');
  });
});
