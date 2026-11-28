/* eslint-disable react/prop-types, react/jsx-no-bind */

import { act, render } from '@testing-library/react';
import { List as ImmutableList, Map as ImmutableMap, fromJS } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { MemoryRouter } from 'react-router-dom';
import { applyMiddleware, createStore } from 'redux';
import { combineReducers } from 'redux-immutable';
import thunk from 'redux-thunk';

import { EMOJI_MUTES_APPLY, EMOJI_MUTES_DISABLE, EMOJI_MUTES_ENABLE } from 'mastodon/actions/emoji_mutes';
import { createUnverifiedEmojiGuard } from 'mastodon/features/emoji/emoji_mute_live_dom';
import { resetEmojiMuteTextForTests } from 'mastodon/features/emoji/emoji_mute_text';
import emojiMutes from 'mastodon/reducers/emoji_mutes';

jest.mock('react-intl', () => {
  const React = require('react');
  const catalog = {
    'column.lists': 'Lists',
    'lists.favourite': 'Favourite list',
    'lists.edit': 'Edit list',
    'lists.account.add': 'Add to list',
    'lists.account.remove': 'Remove from list',
  };
  const intl = {
    formatMessage: message => catalog[message.id] || message.defaultMessage || message.id,
  };

  return {
    defineMessages: messages => messages,
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    FormattedMessage: ({ defaultMessage }) => defaultMessage,
  };
});

jest.mock('mastodon/initial_state', () => ({
  ...jest.requireActual('mastodon/initial_state'),
  me: '1',
  showTrends: false,
  trendsEnabled: false,
  profile_directory: false,
  enableEmptyColumn: false,
}));

jest.mock('mastodon/actions/lists', () => ({
  fetchLists: () => ({ type: 'LISTS_FETCH' }),
  favouriteList: id => ({ type: 'LIST_FAVOURITE', id }),
  unfavouriteList: id => ({ type: 'LIST_UNFAVOURITE', id }),
}));

jest.mock('mastodon/actions/accounts', () => ({
  fetchFollowRequests: () => ({ type: 'TEST_FOLLOW' }),
  subscribeAccount: () => ({ type: 'TEST_SUBSCRIBE' }),
  unsubscribeAccount: () => ({ type: 'TEST_UNSUBSCRIBE' }),
}));

jest.mock('mastodon/actions/favourite_domains', () => ({
  fetchFavouriteDomains: () => ({ type: 'TEST_DOMAINS' }),
}));

jest.mock('mastodon/actions/favourite_tags', () => ({
  fetchFavouriteTags: () => ({ type: 'TEST_TAGS' }),
}));

jest.mock('mastodon/actions/scheduled_statuses', () => ({
  fetchScheduledStatuses: () => ({ type: 'TEST_SCHEDULED' }),
}));

jest.mock('../../../components/scrollable_list', () => {
  const React = require('react');

  return ({ children }) => <div>{children}</div>;
});

jest.mock('../../ui/components/link_footer', () => () => null);
jest.mock('../../getting_started/containers/trends_container', () => () => null);
jest.mock('../../compose/containers/navigation_container', () => () => null);

import GettingStarted from '../../getting_started';
import ListAdderRow from '../../list_adder/components/list';
import ListRow from '../components/list';
import Lists from '../index';
import ListPanel from '../../ui/components/list_panel';

const THUMB = '👍';
const PLACEHOLDER = '\u25FB';

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

const record = (id, title) => fromJS({ id, title, favourite: true, replies_policy: 'list' });

const passthrough = (key) => (state = ImmutableMap(), action) => (
  action.type === 'SET_SLICE' && action.key === key ? action.value : state
);

const buildStore = (records, extra = {}) => {
  const reducer = combineReducers({
    emojiMutes,
    lists: passthrough('lists'),
    listAdder: passthrough('listAdder'),
    accounts: passthrough('accounts'),
    settings: passthrough('settings'),
    user_lists: passthrough('user_lists'),
    scheduled_statuses: passthrough('scheduled_statuses'),
  });
  let state = reducer(undefined, { type: '@@INIT' });

  state = reducer(state, { type: 'SET_SLICE', key: 'lists', value: ImmutableMap(records) });
  state = reducer(state, {
    type: 'SET_SLICE',
    key: 'listAdder',
    value: fromJS({ lists: { items: extra.added || [] } }),
  });
  state = reducer(state, {
    type: 'SET_SLICE',
    key: 'accounts',
    value: ImmutableMap({
      1: fromJS({ id: '1', username: 'me', acct: 'me@example.com', display_name: 'Me' }),
      9: extra.account || fromJS({ id: '9' }),
    }),
  });
  state = reducer(state, { type: 'SET_SLICE', key: 'settings', value: ImmutableMap({ columns: ImmutableList() }) });
  state = reducer(state, { type: 'SET_SLICE', key: 'user_lists', value: ImmutableMap() });
  state = reducer(state, { type: 'SET_SLICE', key: 'scheduled_statuses', value: ImmutableMap({ items: ImmutableList() }) });

  return createStore(reducer, state, applyMiddleware(thunk));
};

const renderInRouter = (store, ui) => render(
  <Provider store={store}>
    <MemoryRouter>{ui}</MemoryRouter>
  </Provider>,
);

const apply = (store, mutes, revision = '2') => {
  act(() => {
    store.dispatch({ type: EMOJI_MUTES_APPLY, revision, mutes, availability: 'enabled' });
  });
};

describe('list names in navigation', () => {
  beforeEach(() => {
    resetEmojiMuteTextForTests();
  });

  it('projects the lists column, the navigation panel, and getting started from the stored title', () => {
    const raw = `Friends ${THUMB} :blob:`;
    const store = buildStore({
      7: record('7', raw),
      8: record('8', 'Alpha'),
    });

    apply(store, [
      rule({ kind: 'unicode', native: THUMB }, '[ok]'),
      rule({ kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' }, '[local]'),
    ]);

    const { container } = renderInRouter(store, (
      <React.Fragment>
        <Lists params={{}} multiColumn />
        <ListPanel />
        <GettingStarted multiColumn />
      </React.Fragment>
    ));
    const links = Array.from(container.querySelectorAll('a[href="/timelines/list/7"]'));

    expect(links).toHaveLength(3);
    links.forEach(link => {
      expect(link.textContent).toContain('Friends [ok] :blob:');
      expect(link.getAttribute('aria-label')).toBe('Friends [ok] :blob:');
      expect(link.getAttribute('href')).toBe('/timelines/list/7');
      expect(link.innerHTML).not.toContain(THUMB);
      expect(link.innerHTML).not.toContain('[local]');
    });
    expect(store.getState().getIn(['lists', '7', 'title'])).toBe(raw);

    const hrefs = Array.from(container.querySelectorAll('.list-panel a, .column-link[href^="/timelines/list/"]')).map(node => node.getAttribute('href'));

    expect(hrefs.filter(href => href === '/timelines/list/8').length).toBeGreaterThan(0);
    expect(container.querySelector('a[href="/timelines/list/8"]').compareDocumentPosition(container.querySelector('a[href="/timelines/list/7"]')) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
  });

  it('names a blank list link without exposing the stored title, and keeps the row actions', () => {
    const store = buildStore({ 7: record('7', THUMB) });
    const { container } = renderInRouter(store, <ListRow id='7' text={THUMB} favourite={false} />);

    apply(store, [rule({ kind: 'unicode', native: THUMB }, '')]);

    const link = container.querySelector('a.column-link');

    expect(link.textContent.trim()).toBe('');
    expect(link.getAttribute('aria-label')).toBe('Lists');
    expect(link.getAttribute('href')).toBe('/timelines/list/7');
    expect(link.outerHTML).not.toContain(THUMB);
    expect(container.querySelector('button[title="Favourite list"]')).not.toBeNull();
    expect(container.querySelector('button[title="Edit list"]')).not.toBeNull();
  });

  it('projects the list adder name and leaves add and remove labels alone', () => {
    const raw = `Crew ${THUMB}`;
    const store = buildStore({ 7: record('7', raw) });
    const guard = createUnverifiedEmojiGuard();
    const during = { text: '' };
    const privacy = document.createElement('div');
    const mount = document.createElement('div');

    store.subscribe(() => guard(store.getState()));
    store.subscribe(() => {
      during.text = document.querySelector('.list__display-name')?.textContent || '';
    });
    privacy.className = 'emoji-mutes-privacy-portal';
    privacy.appendChild(mount);
    document.body.appendChild(privacy);

    const { container } = render(
      <Provider store={store}>
        <MemoryRouter>
          <ListAdderRow listId='7' account={fromJS({ id: '9' })} />
        </MemoryRouter>
      </Provider>,
      { container: mount },
    );

    expect(container.querySelector('.list__display-name').textContent).toContain(raw);

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_ENABLE });
      expect(during.text).toContain(PLACEHOLDER);
      expect(during.text).not.toContain(THUMB);
      store.dispatch({
        type: EMOJI_MUTES_APPLY,
        revision: '2',
        availability: 'enabled',
        mutes: [rule({ kind: 'unicode', native: THUMB }, '[ok]')],
      });
      expect(during.text).toContain('Crew [ok]');
      expect(during.text).not.toContain(THUMB);
    });

    expect(container.querySelector('.list__display-name').innerHTML).not.toContain(THUMB);
    expect(container.querySelector('button[title="Add to list"]')).not.toBeNull();
    expect(store.getState().getIn(['lists', '7', 'title'])).toBe(raw);

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_DISABLE });
    });

    expect(container.querySelector('.list__display-name').textContent).toContain(raw);
  });
});
