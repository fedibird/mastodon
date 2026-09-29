/* eslint-disable react/prop-types */

import { fireEvent, render, screen, within } from '@testing-library/react';
import { fromJS, Set as ImmutableSet } from 'immutable';
import React from 'react';
import PropTypes from 'prop-types';
import { Provider } from 'react-redux';
import { createStore } from 'redux';

jest.mock('mastodon/initial_state', () => ({
  me: '1',
  isStaff: false,
  autoPlayEmoji: false,
  disableReactions: false,
  translationPrivateContentAllowed: false,
  translationBarVisibility: 'target',
  translationPreferredMode: 'both',
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
    ['de', 'German', 'Deutsch'],
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

import { STATUS_IMPORT } from '../../actions/importer';
import { SETTING_CHANGE } from '../../actions/settings';
import { STATUS_TRANSLATION_ASSUMPTION } from '../../actions/statuses';
import StatusActionBar from '../status_action_bar';
import StatusContent from '../status_content';
import DetailedActionBar from '../../features/status/components/action_bar';
import settingsReducer from '../../reducers/settings';
import translationAssumptions from '../../reducers/translation_assumptions';
import translationBarOverrides from '../../reducers/translation_bar_overrides';

const LANGUAGES = {
  en: ['ja', 'en'],
  ja: ['en'],
  fr: ['ja'],
  und: ['en'],
  'zh-Hans': ['ja'],
  'zh-Hant': ['ja'],
};

const reducer = (state, action) => state
  .set('settings', settingsReducer(state.get('settings'), action))
  .set('translation_assumptions', translationAssumptions(state.get('translation_assumptions'), action))
  .set('translation_bar_overrides', translationBarOverrides(state.get('translation_bar_overrides'), action));

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

const createStoreFor = (statuses, { target, revealed = [] } = {}) => {
  let settings = settingsReducer(undefined, { type: '@@INIT' });

  if (target) {
    settings = settings.setIn(['translation', 'targetLanguage'], target);
  }

  const state = Object.entries(statuses).reduce((next, [id, status]) => (
    next.setIn(['statuses', id], status)
  ), fromJS({
    server: { translationLanguages: { items: LANGUAGES } },
    statuses: {},
    translation_assumptions: {},
    compose: { references: [], privacy: 'public' },
  }).set('settings', settings).set('translation_bar_overrides', ImmutableSet(revealed)));

  return createStore(reducer, state.setIn(['compose', 'references'], ImmutableSet()));
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

const actionProps = {
  onReply: jest.fn(),
  onFavourite: jest.fn(),
  onReblog: jest.fn(),
  onQuote: jest.fn(),
  onBookmark: jest.fn(),
  onEdit: jest.fn(),
  onDelete: jest.fn(),
  onExpire: jest.fn(),
  onDirect: jest.fn(),
  onMemberList: jest.fn(),
  onMention: jest.fn(),
  addEmojiReaction: jest.fn(),
  removeEmojiReaction: jest.fn(),
};

const renderSurfaces = (store, status) => render(
  <Provider store={store}>
    <RouterProvider>
      <div data-testid='timeline'>
        <StatusContent status={status} onTranslate={jest.fn()} onClick={jest.fn()} />
        <StatusActionBar status={status} {...actionProps} />
      </div>
      <div data-testid='detail'>
        <StatusContent status={status} onTranslate={jest.fn()} onClick={jest.fn()} />
        <DetailedActionBar status={status} {...actionProps} />
      </div>
    </RouterProvider>
  </Provider>,
);

const hasBar = (root) => within(root).queryByRole('button', { name: /Source language/ }) !== null;
const hasMenu = (root) => Array.from(within(root).getByTestId('more-menu').querySelectorAll('button')).some(button => button.textContent === 'Show Translation Bar');

describe('conditional translation bar visibility', () => {
  beforeEach(() => {
    initialState.translationBarVisibility = 'target';
    initialState.translationPreferredMode = 'both';
  });

  it('hides a same-language post and offers the menu on the timeline and the detail view', () => {
    const status = buildStatus('same', 'ja');
    renderSurfaces(createStoreFor({ same: status }), status);

    expect(hasBar(screen.getByTestId('timeline'))).toBe(false);
    expect(hasBar(screen.getByTestId('detail'))).toBe(false);
    expect(hasMenu(screen.getByTestId('timeline'))).toBe(true);
    expect(hasMenu(screen.getByTestId('detail'))).toBe(true);
  });

  it('shows a different language, an unknown language, and bare Chinese without hiding them for provider support', () => {
    const foreign = buildStatus('foreign', 'en');
    const unknown = buildStatus('unknown', 'und');
    const chinese = buildStatus('chinese', 'zh');
    const store = createStoreFor({ foreign, unknown, chinese });

    render(
      <Provider store={store}>
        <RouterProvider>
          {['foreign', 'unknown', 'chinese'].map(id => (
            <div key={id} data-testid={id}>
              <StatusContent status={store.getState().get('statuses').get(id)} onTranslate={jest.fn()} onClick={jest.fn()} />
              <StatusActionBar status={store.getState().get('statuses').get(id)} {...actionProps} />
            </div>
          ))}
        </RouterProvider>
      </Provider>,
    );

    expect(hasBar(screen.getByTestId('foreign'))).toBe(true);
    expect(hasMenu(screen.getByTestId('foreign'))).toBe(false);
    expect(within(screen.getByTestId('unknown')).getByRole('button', { name: 'Translate' })).toBeTruthy();
    expect(hasMenu(screen.getByTestId('unknown'))).toBe(false);
    expect(within(screen.getByTestId('chinese')).getByText('Choose Simplified Chinese or Traditional Chinese as the source language.')).toBeTruthy();
    expect(hasMenu(screen.getByTestId('chinese'))).toBe(false);
  });

  it('follows a per-status source assumption and a global target change', () => {
    const same = buildStatus('same', 'ja');
    const foreign = buildStatus('foreign', 'en');
    const store = createStoreFor({ same, foreign });

    render(
      <Provider store={store}>
        <RouterProvider>
          <div data-testid='same'>
            <StatusContent status={same} onTranslate={jest.fn()} onClick={jest.fn()} />
            <StatusActionBar status={same} {...actionProps} />
          </div>
          <div data-testid='foreign'>
            <StatusContent status={foreign} onTranslate={jest.fn()} onClick={jest.fn()} />
            <StatusActionBar status={foreign} {...actionProps} />
          </div>
        </RouterProvider>
      </Provider>,
    );

    expect(hasBar(screen.getByTestId('same'))).toBe(false);
    expect(hasBar(screen.getByTestId('foreign'))).toBe(true);

    store.dispatch({ type: STATUS_TRANSLATION_ASSUMPTION, id: 'same', source: 'en' });

    expect(hasBar(screen.getByTestId('same'))).toBe(true);
    expect(hasMenu(screen.getByTestId('same'))).toBe(false);

    store.dispatch({ type: SETTING_CHANGE, path: ['translation', 'targetLanguage'], value: 'en' });

    expect(hasBar(screen.getByTestId('same'))).toBe(false);
    expect(hasMenu(screen.getByTestId('same'))).toBe(true);
    expect(hasBar(screen.getByTestId('foreign'))).toBe(false);
    expect(hasMenu(screen.getByTestId('foreign'))).toBe(true);
    expect(within(screen.getByTestId('foreign')).getByRole('button', { name: 'Show Translation Bar' })).toBeTruthy();
  });

  it('shows every post for always and none for never until that post is revealed', () => {
    const status = buildStatus('post', 'ja');

    initialState.translationBarVisibility = 'always';
    const always = renderSurfaces(createStoreFor({ post: status }), status);
    expect(hasBar(screen.getByTestId('timeline'))).toBe(true);
    expect(hasMenu(screen.getByTestId('timeline'))).toBe(false);
    expect(hasMenu(screen.getByTestId('detail'))).toBe(false);
    always.unmount();

    initialState.translationBarVisibility = 'never';
    const hidden = renderSurfaces(createStoreFor({ post: status }), status);
    expect(hasBar(screen.getByTestId('timeline'))).toBe(false);
    expect(hasMenu(screen.getByTestId('timeline'))).toBe(true);
    expect(hasMenu(screen.getByTestId('detail'))).toBe(true);

    fireEvent.click(within(screen.getByTestId('timeline')).getByRole('button', { name: 'Show Translation Bar' }));

    expect(hasBar(screen.getByTestId('timeline'))).toBe(true);
    expect(hasMenu(screen.getByTestId('timeline'))).toBe(false);
    expect(hasBar(screen.getByTestId('detail'))).toBe(true);
    expect(hasMenu(screen.getByTestId('detail'))).toBe(false);
    hidden.unmount();
  });

  it('keeps a revealed bar after the status is imported again', () => {
    const status = buildStatus('post', 'ja');
    const store = createStoreFor({ post: status }, { revealed: ['post'] });
    initialState.translationBarVisibility = 'target';

    renderSurfaces(store, status);
    expect(hasBar(screen.getByTestId('timeline'))).toBe(true);
    expect(hasMenu(screen.getByTestId('timeline'))).toBe(false);
    expect(hasMenu(screen.getByTestId('detail'))).toBe(false);

    store.dispatch({
      type: STATUS_IMPORT,
      status: status.set('contentHtml', '<p>again</p>').toJS(),
    });

    expect(store.getState().get('translation_bar_overrides').has('post')).toBe(true);
    expect(hasBar(screen.getByTestId('timeline'))).toBe(true);
    expect(hasMenu(screen.getByTestId('detail'))).toBe(false);
  });
});
