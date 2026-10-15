/* eslint-disable react/prop-types */

import { render, screen, within } from '@testing-library/react';
import { fromJS, Map as ImmutableMap, Set as ImmutableSet } from 'immutable';
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
}));

jest.mock('react-overlays/Overlay', () => {
  return ({ show, children }) => (show ? children({ props: { style: {} }, placement: 'bottom' }) : null);
});

const initialState = jest.requireMock('mastodon/initial_state');

jest.mock('react-intl', () => {
  const React = require('react');
  const intl = {
    locale: 'ja-JP',
    formatMessage: ({ defaultMessage }) => defaultMessage,
  };

  return {
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    defineMessages: messages => messages,
    FormattedMessage: ({ defaultMessage }) => defaultMessage,
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

import { STATUS_TRANSLATION_BAR_REVEAL } from '../../actions/translation_bar';
import {
  USER_PREFERENCES_FETCH_REQUEST,
  USER_PREFERENCES_FETCH_SUCCESS,
} from '../../actions/user_preferences';
import StatusContent from '../status_content';
import StatusActionBar from '../status_action_bar';
import settingsReducer from '../../reducers/settings';
import translationAssumptions from '../../reducers/translation_assumptions';
import translationBarOverrides from '../../reducers/translation_bar_overrides';
import userPreferences from '../../reducers/user_preferences';

const LANGUAGES = {
  en: ['ja', 'en'],
  ja: ['en'],
};

const preference = (key, publicValue, valid = true) => ({
  key,
  state: 'set',
  configured: publicValue,
  effective: publicValue,
  public_value: publicValue,
  public_valid: valid,
  validation_errors: [],
});

const documentFor = ({ visibility = 'always', mode = 'translated', policy = 'default', visibilityValid = true, modeValid = true } = {}) => ({
  version: 1,
  preferences: {
    'user.show_translation_bar': preference('user.show_translation_bar', visibility, visibilityValid),
    'user.translation_preferred_mode': preference('user.translation_preferred_mode', mode, modeValid),
    'user.new_features_policy': preference('user.new_features_policy', policy),
  },
});

const reducer = (state, action) => state
  .set('settings', settingsReducer(state.get('settings'), action))
  .set('translation_assumptions', translationAssumptions(state.get('translation_assumptions'), action))
  .set('translation_bar_overrides', translationBarOverrides(state.get('translation_bar_overrides'), action))
  .set('user_preferences', userPreferences(state.get('user_preferences'), action));

const buildStatus = (id, language, extra = {}) => fromJS({
  id,
  contentHtml: `<p>${extra.content || id}</p>`,
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
  ...extra,
});

const createStoreFor = (status) => {
  const state = fromJS({
    server: { translationLanguages: { items: LANGUAGES } },
    settings: {},
    translation_assumptions: {},
    compose: { references: [] },
  }).set('settings', settingsReducer(undefined, { type: '@@INIT' }))
    .set('translation_bar_overrides', ImmutableSet())
    .set('user_preferences', userPreferences(undefined, { type: '@@INIT' }))
    .setIn(['compose', 'references'], ImmutableSet());

  return createStore(reducer, state.set('statuses', ImmutableMap({ [status.get('id')]: status })));
};

const acceptDocument = (store, document) => {
  const serial = store.getState().getIn(['user_preferences', 'issuedSerial']) + 1;

  store.dispatch({ type: USER_PREFERENCES_FETCH_REQUEST, serial });
  store.dispatch({ type: USER_PREFERENCES_FETCH_SUCCESS, serial, document });
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

const hasBar = () => screen.queryByRole('button', { name: /Source language/ }) !== null;
const requestLabels = () => Array.from(document.querySelectorAll('.status__content__translate-button')).map(button => button.textContent);

describe('accepted translation preferences', () => {
  beforeEach(() => {
    initialState.translationBarVisibility = 'target';
    initialState.translationPreferredMode = 'both';
  });

  it('falls back to the static visibility until a document is accepted', () => {
    const status = buildStatus('same', 'ja');
    const store = createStoreFor(status);

    render(
      <Provider store={store}>
        <RouterProvider>
          <StatusContent status={status} onTranslate={jest.fn()} onClick={jest.fn()} />
          <StatusActionBar status={status} {...actionProps} />
        </RouterProvider>
      </Provider>,
    );

    expect(hasBar()).toBe(false);
    expect(within(screen.getByTestId('more-menu')).getByRole('button', { name: 'Show Translation Bar' })).toBeTruthy();
  });

  it('updates an already displayed post without clearing a manual translation', () => {
    const onTranslate = jest.fn();
    const status = buildStatus('post', 'en', {
      content: 'Hello',
      translationMode: 'bilingual',
      translation: {
        contentHtml: '<p>こんにちは</p>',
        spoilerHtml: '',
        language: 'ja',
        detected_source_language: 'en',
        requested_source_language: 'en',
        requested_target_language: 'ja',
      },
    });
    const store = createStoreFor(status);
    const before = store.getState().getIn(['statuses', 'post']);

    render(
      <Provider store={store}>
        <RouterProvider>
          <StatusContent status={status} onTranslate={onTranslate} onClick={jest.fn()} />
          <StatusActionBar status={status} {...actionProps} />
        </RouterProvider>
      </Provider>,
    );

    expect(screen.getByText('こんにちは')).toBeTruthy();
    expect(screen.getByText('Hello')).toBeTruthy();

    acceptDocument(store, documentFor({ visibility: 'never', mode: 'translated' }));

    expect(hasBar()).toBe(false);
    expect(onTranslate).not.toHaveBeenCalled();
    expect(status.get('translationMode')).toBe('bilingual');
    expect(status.getIn(['translation', 'contentHtml'])).toBe('<p>こんにちは</p>');
    expect(store.getState().getIn(['statuses', 'post'])).toBe(before);
    expect(screen.getByText('こんにちは')).toBeTruthy();

    store.dispatch({ type: STATUS_TRANSLATION_BAR_REVEAL, id: 'post' });

    expect(hasBar()).toBe(true);
    expect(screen.getByText('こんにちは')).toBeTruthy();
    expect(onTranslate).not.toHaveBeenCalled();
  });

  it('uses the accepted mode unless the status passes its own mode', () => {
    const status = buildStatus('foreign', 'en');
    const store = createStoreFor(status);

    const view = render(
      <Provider store={store}>
        <StatusContent status={status} onTranslate={jest.fn()} onClick={jest.fn()} />
      </Provider>,
    );

    expect(requestLabels()).toEqual(['Translate', 'Bilingual']);

    acceptDocument(store, documentFor({ visibility: 'always', mode: 'translated' }));
    expect(requestLabels()).toEqual(['Translate']);

    acceptDocument(store, documentFor({ visibility: 'always', mode: 'bilingual' }));
    expect(requestLabels()).toEqual(['Bilingual']);

    acceptDocument(store, documentFor({ visibility: 'always', mode: 'both' }));
    expect(requestLabels()).toEqual(['Translate', 'Bilingual']);

    view.rerender(
      <Provider store={store}>
        <StatusContent status={status} onTranslate={jest.fn()} onClick={jest.fn()} translationPreferredMode='translated' />
      </Provider>,
    );

    expect(requestLabels()).toEqual(['Translate']);

    acceptDocument(store, documentFor({
      visibility: 'always',
      mode: 'original',
      modeValid: false,
      visibilityValid: false,
      policy: 'conservative',
    }));

    view.rerender(
      <Provider store={store}>
        <StatusContent status={status} onTranslate={jest.fn()} onClick={jest.fn()} />
      </Provider>,
    );

    expect(hasBar()).toBe(false);
    expect(requestLabels()).toEqual([]);
  });

  it('ignores a stale fetch when showing the bar', () => {
    const status = buildStatus('foreign', 'en');
    const store = createStoreFor(status);

    render(
      <Provider store={store}>
        <StatusContent status={status} onTranslate={jest.fn()} onClick={jest.fn()} />
      </Provider>,
    );

    acceptDocument(store, documentFor({ visibility: 'always', mode: 'translated' }));
    expect(hasBar()).toBe(true);

    store.dispatch({
      type: USER_PREFERENCES_FETCH_SUCCESS,
      serial: 1,
      document: documentFor({ visibility: 'never', mode: 'bilingual' }),
    });

    expect(hasBar()).toBe(true);
    expect(requestLabels()).toEqual(['Translate']);
    expect(store.getState().getIn(['user_preferences', 'document']).preferences['user.show_translation_bar'].public_value).toBe('always');
  });
});
