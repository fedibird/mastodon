/* eslint-disable react/prop-types, react/jsx-no-bind */

import { act, render } from '@testing-library/react';
import { Map as ImmutableMap, fromJS } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { MemoryRouter } from 'react-router-dom';
import { applyMiddleware, createStore } from 'redux';
import { combineReducers } from 'redux-immutable';
import thunk from 'redux-thunk';

import { EMOJI_MUTES_APPLY, EMOJI_MUTES_DISABLE, EMOJI_MUTES_IGNORE, EMOJI_MUTES_RESET, EMOJI_MUTES_REVISION } from 'mastodon/actions/emoji_mutes';
import { createUnverifiedEmojiGuard } from 'mastodon/features/emoji/emoji_mute_live_dom';
import { resetEmojiMuteTextForTests } from 'mastodon/features/emoji/emoji_mute_text';
import emojiMutes from 'mastodon/reducers/emoji_mutes';

jest.mock('react-intl', () => {
  const React = require('react');
  const catalog = {
    'column.home': 'Home',
    'column.lists': 'Lists',
  };
  const intl = {
    formatMessage: message => catalog[message.id] || message.defaultMessage || message.id,
  };

  return {
    defineMessages: messages => messages,
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    FormattedMessage: ({ defaultMessage, children }) => (typeof children === 'function' ? children(defaultMessage) : defaultMessage),
  };
});

import ColumnLoading from '../column_loading';
import TabsBar, { getSwipeableIndex, getSwipeableLinks, swipeLoadingTitle } from '../tabs_bar';

const THUMB = '👍';
const CAT = '😺';
const PLACEHOLDER = '\u25FB';
const LISTS = 'Lists';

const rule = (emoji, replacement) => ({
  id: `rule-${replacement}`,
  emoji,
  replacement,
  effects: {
    replace_in_text: true,
    hide_reactions: false,
    reject_reactions_to_own_posts: false,
    hide_in_picker: false,
  },
});

const lists = (state = ImmutableMap(), action) => (
  action.type === 'LISTS_SET' ? action.lists : state
);

const favourite = (id, title) => fromJS({ id, title, favourite: true });

const buildStore = (records) => {
  const reducer = combineReducers({ emojiMutes, lists });
  let state = reducer(undefined, { type: '@@INIT' });

  state = state.set('lists', ImmutableMap(records));
  return createStore(reducer, state, applyMiddleware(thunk));
};

const renderTabs = (store, ui) => {
  const privacy = document.createElement('div');
  const mount = document.createElement('div');

  privacy.className = 'emoji-mutes-privacy-portal';
  privacy.appendChild(mount);
  document.body.appendChild(privacy);

  const view = render(
    <Provider store={store}>
      <MemoryRouter>
        {ui}
      </MemoryRouter>
    </Provider>,
    { container: mount },
  );

  return { ...view, privacy };
};

const tab = (container, id) => container.querySelector(`a[href="/timelines/list/${id}"]`);
const label = (node, kind) => node.querySelector(`.tabs-bar__link__${kind}-label`).textContent;
const previewButton = container => container.querySelector('h1 button');

describe('favourite list tabs', () => {
  beforeEach(() => {
    resetEmojiMuteTextForTests();
  });

  afterEach(() => {
    document.body.innerHTML = '';
  });

  it('projects both labels and the preview from the stored title without using it as an id', () => {
    const raw = `Friends ${THUMB} :blob:`;
    const store = buildStore({
      m: favourite('m', 'M'),
      z: favourite('z', raw),
    });

    act(() => {
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '2',
        availability: 'enabled',
        mutes: [rule({ kind: 'unicode', native: THUMB }, '[ok]')],
      });
    });

    const favouriteLists = store.getState().get('lists').toList().filter(item => item.get('favourite')).sort((a, b) => a.get('title').localeCompare(b.get('title')));
    const links = getSwipeableLinks(favouriteLists);
    const listLinks = links.filter(link => String(link.props.to).indexOf('/timelines/list/') === 0);
    const friendLink = listLinks.find(link => link.props.to === '/timelines/list/z');
    const { container } = renderTabs(store, (
      <React.Fragment>
        <TabsBar />
        <ColumnLoading title={swipeLoadingTitle(friendLink, message => message.defaultMessage || message.id)} icon='list-ul' />
      </React.Fragment>
    ));
    const friend = tab(container, 'z');
    const home = container.querySelector('a[href="/timelines/home"]');

    expect(listLinks.map(link => link.props.to)).toEqual(['/timelines/list/z', '/timelines/list/m']);
    expect(listLinks.map(link => link.props['data-preview-title-id'])).toEqual(['list/z', 'list/m']);
    expect(listLinks.every(link => link.props['data-preview-title'] === undefined)).toBe(true);
    expect(getSwipeableIndex(favouriteLists, '/timelines/list/z')).toBe(links.findIndex(link => link.props.to === '/timelines/list/z'));
    expect(friend.getAttribute('data-preview-title-id')).toBe('list/z');
    expect(friend.getAttribute('href')).toBe('/timelines/list/z');
    expect(label(friend, 'full')).toBe('Friends [ok] :blob:');
    expect(label(friend, 'short')).toBe('Friends [ok] :blob:');
    expect(friend.getAttribute('aria-label')).toBe('Friends [ok] :blob:');
    expect(friend.getAttribute('data-preview-title')).toBe('Friends [ok] :blob:');
    expect(friend.getAttribute('data-preview-title')).not.toContain(THUMB);
    expect(previewButton(container).textContent).toBe('Friends [ok] :blob:');
    expect(previewButton(container).getAttribute('aria-label')).toBe('Friends [ok] :blob:');
    expect(home.getAttribute('aria-label')).toBe('Home');
    expect(home.hasAttribute('data-preview-title')).toBe(false);
    const homePreview = swipeLoadingTitle(
      links.find(item => item.props.to === '/timelines/home'),
      message => (message.id === 'column.home' ? 'Home' : message.id),
    );

    expect(homePreview).toBe('Home');
    expect(store.getState().getIn(['lists', 'z', 'title'])).toBe(raw);
  });

  it('keeps list order when a replacement would sort earlier', () => {
    const store = buildStore({
      m: favourite('m', 'M'),
      z: favourite('z', THUMB),
    });
    const { container } = renderTabs(store, <TabsBar />);

    act(() => {
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '2',
        availability: 'enabled',
        mutes: [rule({ kind: 'unicode', native: THUMB }, 'Z')],
      });
    });

    const hrefs = Array.from(container.querySelectorAll('a[href^="/timelines/list/"]')).map(node => node.getAttribute('href'));

    expect(hrefs).toEqual(['/timelines/list/z', '/timelines/list/m']);
    expect(tab(container, 'z').getAttribute('aria-label')).toBe('Z');
    expect(tab(container, 'z').getAttribute('data-preview-title-id')).toBe('list/z');
  });

  it('gives a blank list an accessible name and the same preview without the raw title', () => {
    const store = buildStore({ z: favourite('z', THUMB) });
    const favouriteLists = store.getState().get('lists').toList();
    const link = getSwipeableLinks(favouriteLists).find(item => item.props.to === '/timelines/list/z');
    const { container } = renderTabs(store, (
      <React.Fragment>
        <TabsBar />
        <ColumnLoading title={swipeLoadingTitle(link, message => (message.id === 'column.lists' ? 'Lists' : (message.defaultMessage || message.id)))} icon='list-ul' />
      </React.Fragment>
    ));

    act(() => {
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '2',
        availability: 'enabled',
        mutes: [rule({ kind: 'unicode', native: THUMB }, '   ')],
      });
    });

    const friend = tab(container, 'z');

    expect(label(friend, 'full')).toBe('   ');
    expect(label(friend, 'short')).toBe('   ');
    expect(friend.getAttribute('aria-label')).toBe(LISTS);
    expect(friend.getAttribute('data-preview-title')).toBe(LISTS);
    expect(friend.outerHTML).not.toContain(THUMB);
    expect(previewButton(container).textContent).toBe('   ');
    expect(previewButton(container).getAttribute('aria-label')).toBe(LISTS);
    expect(previewButton(container).outerHTML).not.toContain(THUMB);
  });

  it('suppresses the tab and the loading preview before React commits, once', () => {
    const raw = `Name ${THUMB}`;
    const store = buildStore({ z: favourite('z', raw) });
    const guard = createUnverifiedEmojiGuard();
    const during = { title: '', name: '', preview: '', previewName: '' };
    const favouriteLists = store.getState().get('lists').toList();
    const link = getSwipeableLinks(favouriteLists).find(item => item.props.to === '/timelines/list/z');

    store.subscribe(() => guard(store.getState()));
    store.subscribe(() => {
      const node = document.querySelector('a[href="/timelines/list/z"]');
      const button = document.querySelector('h1 button');

      during.title = node?.querySelector('.tabs-bar__link__full-label')?.textContent || '';
      during.name = node?.getAttribute('data-preview-title') || '';
      during.preview = button?.textContent || '';
      during.previewName = button?.getAttribute('aria-label') || '';
    });

    const { container } = renderTabs(store, (
      <React.Fragment>
        <TabsBar />
        <ColumnLoading title={swipeLoadingTitle(link, message => (message.id === 'column.lists' ? 'Lists' : (message.defaultMessage || message.id)))} icon='list-ul' />
      </React.Fragment>
    ));

    act(() => {
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '2',
        availability: 'enabled',
        mutes: [
          rule({ kind: 'unicode', native: THUMB }, CAT),
          rule({ kind: 'unicode', native: CAT }, '[cat]'),
        ],
      });
    });

    expect(label(tab(container, 'z'), 'full')).toBe(`Name ${CAT}`);
    expect(tab(container, 'z').getAttribute('data-preview-title')).toBe(`Name ${CAT}`);
    expect(previewButton(container).textContent).toBe(`Name ${CAT}`);

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_REVISION, revision: '3' });
      expect(during.title).toBe(`Name ${PLACEHOLDER}`);
      expect(during.name).toBe(`Name ${PLACEHOLDER}`);
      expect(during.preview).toBe(`Name ${PLACEHOLDER}`);
      expect(during.previewName).toBe(`Name ${PLACEHOLDER}`);
      expect(during.title).not.toContain(THUMB);
      expect(during.name).not.toContain(THUMB);
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '3',
        availability: 'enabled',
        mutes: [
          rule({ kind: 'unicode', native: THUMB }, CAT),
          rule({ kind: 'unicode', native: CAT }, '[cat]'),
        ],
      });
      expect(during.title).toBe(`Name ${CAT}`);
      expect(during.name).toBe(`Name ${CAT}`);
      expect(during.preview).toBe(`Name ${CAT}`);
      expect(during.name).not.toContain('[cat]');
    });

    expect(tab(container, 'z').getAttribute('aria-label')).toBe(`Name ${CAT}`);
    expect(previewButton(container).getAttribute('aria-label')).toBe(`Name ${CAT}`);

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_IGNORE });
    });

    expect(label(tab(container, 'z'), 'full')).toBe(raw);
    expect(tab(container, 'z').getAttribute('data-preview-title')).toBe(raw);

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_DISABLE });
    });

    expect(label(tab(container, 'z'), 'short')).toBe(raw);

    act(() => {
      store.dispatch({ type: 'LISTS_SET', lists: ImmutableMap({ z: favourite('z', `Next ${THUMB}`) }) });
    });

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_RESET });
    });

    expect(label(tab(container, 'z'), 'full')).toBe(`Next ${THUMB}`);
    expect(tab(container, 'z').getAttribute('data-preview-title-id')).toBe('list/z');
  });
});
