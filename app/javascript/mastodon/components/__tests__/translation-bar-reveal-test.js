/* eslint-disable react/prop-types */

import { fireEvent, render, screen, within } from '@testing-library/react';
import { fromJS, Set as ImmutableSet } from 'immutable';
import React from 'react';
import PropTypes from 'prop-types';
import { Provider } from 'react-redux';
import { applyMiddleware, createStore } from 'redux';

jest.mock('mastodon/api', () => ({
  __esModule: true,
  default: jest.fn(),
}));

jest.mock('mastodon/initial_state', () => ({
  me: '1',
  isStaff: false,
  autoPlayEmoji: false,
  disableReactions: false,
  translationPrivateContentAllowed: false,
  showTranslationBar: false,
  show_bookmark_button: true,
  show_quote_button: true,
  show_share_button: false,
  enableReaction: true,
  compactReaction: false,
  enableStatusReference: false,
  maxReferences: 5,
  matchVisibilityOfReferences: false,
  addReferenceModal: false,
  disablePost: false,
  disableBlock: false,
  disableDomainBlock: false,
  disableReport: false,
  hideListOfEmojiReactionsToPosts: false,
  hideListOfFavouritesToPosts: false,
  hideListOfReblogsToPosts: false,
  hideListOfReferredByToPosts: false,
  languages: [
    ['en', 'English', 'English'],
    ['ja', 'Japanese', '日本語'],
    ['fr', 'French', 'Français'],
  ],
}));

jest.mock('react-overlays/Overlay', () => {
  return ({ show, children }) => (show ? children({ props: { style: {} }, placement: 'bottom' }) : null);
});

const initialState = jest.requireMock('mastodon/initial_state');

jest.mock('react-intl', () => {
  const React = require('react');
  const intl = {
    locale: 'ja-JP',
    formatMessage: ({ defaultMessage }, values) => {
      let message = defaultMessage;

      if (values) {
        Object.keys(values).forEach(key => {
          message = message.replace(`{${key}}`, values[key]);
        });
      }

      return message;
    },
    now: () => Date.now(),
  };

  return {
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    defineMessages: messages => messages,
    FormattedMessage: ({ defaultMessage, values }) => intl.formatMessage({ defaultMessage }, values),
  };
});

jest.mock('mastodon/containers/dropdown_menu_container', () => ({ items }) => (
  <div data-testid='more-menu'>
    {(items || []).map((item, index) => item ? (
      <button key={index} type='button' onClick={item.action}>{item.text}</button>
    ) : (
      <hr key={index} />
    ))}
  </div>
));
jest.mock('mastodon/containers/reaction_picker_dropdown_container', () => () => null);
jest.mock('mastodon/containers/poll_container', () => () => null);
jest.mock('../permalink', () => ({ children }) => <span>{children}</span>);
jest.mock('mastodon/components/icon', () => () => null);
jest.mock('mastodon/actions/modal', () => ({ openModal: jest.fn() }));
jest.mock('mastodon/actions/filters', () => ({ initAddFilter: jest.fn() }));

import api from 'mastodon/api';
import { STATUS_IMPORT, STATUSES_IMPORT } from '../../actions/importer';
import { TIMELINE_DELETE } from '../../actions/timelines';
import StatusActionBar from '../status_action_bar';
import StatusContent from '../status_content';
import DetailedActionBar from '../../features/status/components/action_bar';
import settingsReducer from '../../reducers/settings';
import statusesReducer from '../../reducers/statuses';
import translationAssumptions from '../../reducers/translation_assumptions';
import translationBarOverrides from '../../reducers/translation_bar_overrides';

const thunk = ({ dispatch, getState }) => next => action => (
  typeof action === 'function' ? action(dispatch, getState) : next(action)
);

const reducer = (state, action) => state
  .set('statuses', statusesReducer(state.get('statuses'), action))
  .set('translation_assumptions', translationAssumptions(state.get('translation_assumptions'), action))
  .set('translation_bar_overrides', translationBarOverrides(state.get('translation_bar_overrides'), action))
  .set('settings', settingsReducer(state.get('settings'), action));

const buildStatus = (id, language) => fromJS({
  id,
  contentHtml: `<p>${id}</p>`,
  spoilerHtml: '',
  spoiler_text: '',
  search_index: id,
  language,
  visibility: 'public',
  mentions: [],
  muted: false,
  reblogged: false,
  favourited: false,
  bookmarked: false,
  reblogs_count: 0,
  favourites_count: 0,
  replies_count: 0,
  status_referred_by_count: 0,
  emoji_reactions_count: 0,
  emoji_reactions: [],
  in_reply_to_id: null,
  in_reply_to_account_id: null,
  url: `https://example.test/${id}`,
  expires_at: null,
  reblog: null,
  account: {
    id: '1',
    acct: 'alice',
    username: 'alice',
    url: 'https://example.test/alice',
  },
});

const createRevealStore = (statuses, { revealed = [] } = {}) => {
  const settings = settingsReducer(undefined, { type: '@@INIT' });
  const state = Object.entries(statuses).reduce((next, [id, status]) => (
    next.setIn(['statuses', id], status)
  ), fromJS({
    server: {
      translationLanguages: {
        items: { en: ['ja', 'fr'], ja: ['en'], fr: ['en'], und: ['ja'] },
      },
    },
    statuses: {},
    translation_assumptions: {},
    relationships: {},
    compose: {
      references: [],
      privacy: 'public',
    },
  }).set('settings', settings).set('translation_bar_overrides', ImmutableSet(revealed)));

  return createStore(reducer, state.setIn(['compose', 'references'], ImmutableSet()), applyMiddleware(thunk));
};

class RouterProvider extends React.Component {

  static childContextTypes = {
    router: PropTypes.object,
  };

  getChildContext () {
    return { router: { history: { push: jest.fn() } } };
  }

  render () {
    return this.props.children;
  }

}

const timelineProps = {
  onReply: jest.fn(),
  onFavourite: jest.fn(),
  onReblog: jest.fn(),
  onQuote: jest.fn(),
  onBookmark: jest.fn(),
  onEdit: jest.fn(),
  onDelete: jest.fn(),
  addEmojiReaction: jest.fn(),
  removeEmojiReaction: jest.fn(),
};

const detailProps = {
  ...timelineProps,
  onExpire: jest.fn(),
  onDirect: jest.fn(),
  onMemberList: jest.fn(),
  onMention: jest.fn(),
};

const renderTimeline = (store, statuses) => render(
  <Provider store={store}>
    <RouterProvider>
      {Object.entries(statuses).map(([id, status]) => (
        <div key={id} data-testid={`status-${id}`}>
          <StatusContent status={status} onTranslate={jest.fn()} onClick={jest.fn()} />
          <StatusActionBar status={status} {...timelineProps} />
        </div>
      ))}
    </RouterProvider>
  </Provider>,
);

const renderDetail = (store, status) => render(
  <Provider store={store}>
    <RouterProvider>
      <div data-testid='status-detail'>
        <StatusContent status={status} onTranslate={jest.fn()} onClick={jest.fn()} />
        <DetailedActionBar status={status} {...detailProps} />
      </div>
    </RouterProvider>
  </Provider>,
);

const menuLabels = (root) => within(root).getByTestId('more-menu').querySelectorAll('button');

const expectFullBar = (root) => {
  const bar = within(root);

  expect(bar.getByRole('button', { name: 'Source language, English' })).toBeTruthy();
  expect(bar.getByRole('button', { name: 'Target language, 日本語' })).toBeTruthy();
  expect(bar.getByRole('button', { name: 'Translate' })).toBeEnabled();
  expect(bar.getByRole('button', { name: 'Bilingual' })).toBeEnabled();
};

const expectNoBar = (root) => {
  const bar = within(root);

  expect(bar.queryByRole('button', { name: /Source language/ })).toBeNull();
  expect(bar.queryByRole('button', { name: /Target language/ })).toBeNull();
  expect(bar.queryByRole('button', { name: 'Translate' })).toBeNull();
  expect(root.querySelector('.status__translation-bar')).toBeNull();
};

describe('on-demand translation bar', () => {
  let put;

  beforeEach(() => {
    initialState.showTranslationBar = false;
    put = jest.fn(() => Promise.resolve({}));
    api.mockReset();
    api.mockReturnValue({ put, post: jest.fn(() => Promise.resolve({ data: {} })) });
  });

  it('reveals only the chosen timeline status without saving the global preference', () => {
    const statusA = buildStatus('a', 'en');
    const statusB = buildStatus('b', 'fr');
    const store = createRevealStore({ a: statusA, b: statusB });
    const settingsBefore = store.getState().get('settings');

    renderTimeline(store, { a: statusA, b: statusB });
    const statusANode = screen.getByTestId('status-a');
    const statusBNode = screen.getByTestId('status-b');
    const labels = Array.from(menuLabels(statusANode)).map(button => button.textContent);

    expectNoBar(statusANode);
    expectNoBar(statusBNode);
    expect(labels).toContain('Show Translation Bar');
    expect(labels.indexOf('Embed')).toBeLessThan(labels.indexOf('Show Translation Bar'));
    expect(labels.indexOf('Show Translation Bar')).toBeLessThan(labels.indexOf('Edit'));
    expect(Array.from(menuLabels(statusBNode)).map(button => button.textContent)).toContain('Show Translation Bar');

    fireEvent.click(within(statusANode).getByRole('button', { name: 'Show Translation Bar' }));

    expectFullBar(statusANode);
    expectNoBar(statusBNode);
    expect(store.getState().get('translation_bar_overrides').has('a')).toBe(true);
    expect(store.getState().get('translation_bar_overrides').has('b')).toBe(false);
    expect(store.getState().get('settings')).toBe(settingsBefore);
    expect(store.getState().getIn(['settings', 'translation', 'targetLanguage'])).toBeUndefined();
    expect(store.getState().get('translation_assumptions').isEmpty()).toBe(true);
    expect(store.getState().getIn(['statuses', 'a', 'language'])).toBe('en');
    expect(store.getState().getIn(['statuses', 'b', 'language'])).toBe('fr');
    expect(initialState.showTranslationBar).toBe(false);
    expect(put).not.toHaveBeenCalled();
    expect(within(statusANode).queryByRole('button', { name: 'Show Translation Bar' })).toBeNull();
    expect(within(statusBNode).getByRole('button', { name: 'Show Translation Bar' })).toBeTruthy();

    store.dispatch({
      type: STATUS_IMPORT,
      status: { id: 'a', language: 'en', contentHtml: '<p>Hello again</p>', search_index: 'Hello again', visibility: 'public', account: { id: '1' } },
    });
    store.dispatch({
      type: STATUSES_IMPORT,
      statuses: [{ id: 'a', language: 'en', contentHtml: '<p>Hello again</p>', search_index: 'Hello again', visibility: 'public', account: { id: '1' } }],
    });

    expect(store.getState().get('translation_bar_overrides').has('a')).toBe(true);
    expectFullBar(statusANode);
    expectNoBar(statusBNode);
    expect(put).not.toHaveBeenCalled();

    store.dispatch({ type: TIMELINE_DELETE, id: 'a', references: [], quotes: [] });

    expect(store.getState().get('translation_bar_overrides').has('a')).toBe(false);
    expectNoBar(statusANode);
    expectNoBar(statusBNode);
    expect(within(statusANode).getByRole('button', { name: 'Show Translation Bar' })).toBeTruthy();
  });

  it('reveals a status from the detailed status menu', () => {
    const status = buildStatus('detail', 'en');
    const other = buildStatus('other', 'fr');
    const store = createRevealStore({ detail: status, other });
    const settingsBefore = store.getState().get('settings');

    render(
      <Provider store={store}>
        <RouterProvider>
          <div data-testid='status-detail'>
            <StatusContent status={status} onTranslate={jest.fn()} onClick={jest.fn()} />
            <DetailedActionBar status={status} {...detailProps} />
          </div>
          <div data-testid='status-other'>
            <StatusContent status={other} onTranslate={jest.fn()} onClick={jest.fn()} />
          </div>
        </RouterProvider>
      </Provider>,
    );

    const detail = screen.getByTestId('status-detail');
    const labels = Array.from(menuLabels(detail)).map(button => button.textContent);

    expectNoBar(detail);
    expectNoBar(screen.getByTestId('status-other'));
    expect(labels.indexOf('Embed')).toBeLessThan(labels.indexOf('Show Translation Bar'));
    expect(labels.indexOf('Show Translation Bar')).toBeLessThan(labels.indexOf('Edit'));

    fireEvent.click(within(detail).getByRole('button', { name: 'Show Translation Bar' }));

    expectFullBar(detail);
    expectNoBar(screen.getByTestId('status-other'));
    expect(within(detail).queryByRole('button', { name: 'Show Translation Bar' })).toBeNull();
    expect(store.getState().get('translation_bar_overrides').has('detail')).toBe(true);
    expect(store.getState().get('translation_bar_overrides').has('other')).toBe(false);
    expect(store.getState().get('settings')).toBe(settingsBefore);
    expect(store.getState().getIn(['statuses', 'detail', 'language'])).toBe('en');
    expect(initialState.showTranslationBar).toBe(false);
    expect(put).not.toHaveBeenCalled();
  });

  it('omits the menu item while the global bar is already shown', () => {
    initialState.showTranslationBar = true;
    const status = buildStatus('a', 'en');
    const store = createRevealStore({ a: status });

    renderTimeline(store, { a: status });

    expectFullBar(screen.getByTestId('status-a'));
    expect(within(screen.getByTestId('status-a')).queryByRole('button', { name: 'Show Translation Bar' })).toBeNull();
  });

  it('omits the menu item after the status bar is already revealed', () => {
    const status = buildStatus('a', 'en');
    const store = createRevealStore({ a: status }, { revealed: ['a'] });

    renderTimeline(store, { a: status });
    renderDetail(store, status);

    expectFullBar(screen.getAllByTestId('status-a')[0]);
    expect(screen.queryByRole('button', { name: 'Show Translation Bar' })).toBeNull();
    expect(put).not.toHaveBeenCalled();
  });
});
