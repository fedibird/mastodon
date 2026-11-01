/* eslint-disable react/prop-types */

import { render, screen } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';
import { applyMiddleware, createStore } from 'redux';
import thunk from 'redux-thunk';
import { Provider } from 'react-redux';

jest.mock('mastodon/initial_state', () => ({
  displayMedia: 'default',
  enableReaction: false,
  compactReaction: false,
  show_reply_tree_button: false,
  enableStatusReference: false,
  disableRelativeTime: true,
  hideLinkPreview: true,
  hidePhotoPreview: true,
  hideVideoPreview: true,
  hideRebloggedBy: false,
  me: '1',
  autoPlayEmoji: false,
  disableReactions: true,
  expandSpoilers: false,
  translationBarVisibility: 'always',
  translationPreferredMode: 'original',
  languages: [['en', 'English', 'English']],
}));

jest.mock('react-intl', () => {
  const intl = {
    locale: 'en',
    formatMessage: ({ defaultMessage }, values) => {
      if (!values) {
        return defaultMessage;
      }

      return Object.keys(values).reduce((message, key) => message.replace(`{${key}}`, values[key]), defaultMessage);
    },
    formatDate: () => '',
  };

  return {
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    defineMessages: messages => messages,
    FormattedMessage: ({ defaultMessage, values }) => intl.formatMessage({ defaultMessage }, values),
  };
});

jest.mock('react-hotkeys', () => ({
  HotKeys: ({ children }) => children,
}));

jest.mock('react-overlays/Overlay', () => {
  const Overlay = ({ show, children }) => (show ? children({ props: { style: {} }, arrowProps: {}, placement: 'bottom' }) : null);
  return Overlay;
});

jest.mock('../account_action_bar', () => () => null);
jest.mock('../status_action_bar', () => () => null);
jest.mock('../avatar', () => () => null);
jest.mock('../avatar_overlay', () => () => null);
jest.mock('../avatar_composite', () => () => null);
jest.mock('../display_name', () => () => <span>name</span>);
jest.mock('../absolute_timestamp', () => () => <span>time</span>);
jest.mock('../relative_timestamp', () => () => <span>time</span>);
jest.mock('../icon', () => () => null);
jest.mock('mastodon/components/icon', () => () => null);
jest.mock('mastodon/components/emoji_reactions_bar', () => () => null);
jest.mock('mastodon/components/picture_in_picture_placeholder', () => () => null);
jest.mock('../../features/ui/components/bundle', () => () => null);
jest.mock('../../features/status/components/card', () => () => null);
jest.mock('mastodon/containers/poll_container', () => () => null);
jest.mock('../permalink', () => ({ children }) => <span>{children}</span>);
jest.mock('mastodon/components/external_status_media', () => () => null);
jest.mock('mastodon/components/status_media', () => ({
  __esModule: true,
  default: () => null,
  hotkeyMediaRoot: () => null,
  openMediaFromHotkey: () => {},
  externalMediaBlocks: () => [],
  LocalMediaPlayer: () => null,
}));
jest.mock('../../features/account_context/components/actions', () => () => null);
jest.mock('../external_source_identity', () => ({
  __esModule: true,
  default: () => null,
  TimeLink: ({ children }) => <span>{children}</span>,
}));

import { importFetchedStatuses } from 'mastodon/actions/importer';
import { makeGetStatus } from 'mastodon/selectors';
import accountsReducer from 'mastodon/reducers/accounts';
import statusesReducer from 'mastodon/reducers/statuses';
import Status from '../status';
import HashtagMenuController from 'mastodon/features/ui/components/hashtag_menu_controller';

const pictureInPicture = fromJS({ inUse: false, available: false });

function reducer(state, action) {
  const current = state || fromJS({
    statuses: {},
    accounts: {},
    relationships: {},
    filters: {},
  });

  return current
    .set('statuses', statusesReducer(current.get('statuses'), action))
    .set('accounts', accountsReducer(current.get('accounts'), action));
}

function account(id, username) {
  return {
    id,
    username,
    acct: `${username}@remote.example`,
    display_name: username,
    note: '',
    followed_message: '',
    emojis: [],
    fields: [],
    url: `https://remote.example/@${username}`,
    uri: `https://remote.example/users/${username}`,
  };
}

function hashtagHtml(name) {
  return `<a href="https://remote.example/tags/${name}" class="mention hashtag" rel="tag">#<span>${name}</span></a>`;
}

function apiStatus(overrides) {
  return {
    id: overrides.id,
    created_at: '2024-01-01T00:00:00.000Z',
    content: overrides.content,
    spoiler_text: '',
    visibility: 'public',
    emojis: [],
    media_attachments: [],
    mentions: [],
    tags: overrides.tags || [],
    account: overrides.account,
    reblog: overrides.reblog || null,
    quote: overrides.quote || null,
    quote_id: overrides.quote_id || null,
  };
}

function importStatuses(payloads) {
  const store = createStore(reducer, undefined, applyMiddleware(thunk));
  store.dispatch(importFetchedStatuses(payloads));
  return store;
}

function renderImported(store, id) {
  const status = makeGetStatus()(store.getState(), { id });

  return render(
    <Provider store={store}>
      <Status
        status={status}
        pictureInPicture={pictureInPicture}
        onTranslate={jest.fn()}
        onToggleHidden={jest.fn()}
        onToggleCollapsed={jest.fn()}
        onAddToList={jest.fn()}
        addEmojiReaction={jest.fn()}
        removeEmojiReaction={jest.fn()}
      />
      <HashtagMenuController />
    </Provider>,
  );
}

function clickHashtag(container, name) {
  const link = container.querySelector(`[data-menu-hashtag="${name}"]`);
  const event = new MouseEvent('click', { bubbles: true, cancelable: true, button: 0 });
  link.dispatchEvent(event);
  return link;
}

describe('hashtag account_url from the API through Redux', () => {
  it('points a normal post and its trailing badge at that post', () => {
    const store = importStatuses([
      apiStatus({
        id: 'normal',
        account: account('author', 'alice'),
        content: `<p>Hello<br><br>${hashtagHtml('rails')}</p>`,
        tags: [{ name: 'rails', url: 'https://fedibird.example/tags/rails', account_url: 'https://remote.example/@alice/tagged/rails' }],
      }),
    ]);

    expect(store.getState().getIn(['statuses', 'normal', 'tags', 0, 'account_url'])).toBe('https://remote.example/@alice/tagged/rails');

    const view = renderImported(store, 'normal');
    const links = view.container.querySelectorAll('[data-menu-hashtag="rails"]');

    expect(links.length).toBeGreaterThan(0);
    links.forEach(link => expect(link).toHaveAttribute('data-status-id', 'normal'));

    clickHashtag(view.container, 'rails');
    expect(screen.getByRole('button', { name: /alice/ })).toHaveAttribute('href', 'https://remote.example/@alice/tagged/rails');
  });

  it('uses the boosted status id, not the boost wrapper', () => {
    const store = importStatuses([
      apiStatus({
        id: 'boost',
        account: account('booster', 'booster'),
        content: '<p>boost</p>',
        tags: [],
        reblog: apiStatus({
          id: 'original',
          account: account('author', 'alice'),
          content: `<p>${hashtagHtml('photo')}</p>`,
          tags: [{ name: 'photo', url: 'https://fedibird.example/tags/photo', account_url: 'https://remote.example/@alice/tagged/photo' }],
        }),
      }),
    ]);

    expect(store.getState().getIn(['statuses', 'original', 'tags', 0, 'account_url'])).toBe('https://remote.example/@alice/tagged/photo');
    expect(store.getState().getIn(['statuses', 'boost', 'reblog'])).toBe('original');

    const view = renderImported(store, 'boost');
    const link = view.container.querySelector('[data-menu-hashtag="photo"]');

    expect(link).toHaveAttribute('data-status-id', 'original');
    expect(link).not.toHaveAttribute('data-status-id', 'boost');

    clickHashtag(view.container, 'photo');
    expect(screen.getByRole('button', { name: /alice/ })).toHaveAttribute('href', 'https://remote.example/@alice/tagged/photo');
  });

  it('uses the quoted status id, not the quoting post', () => {
    const quote = apiStatus({
      id: 'quoted',
      account: account('quoted-author', 'quoter'),
      content: `<p>${hashtagHtml('city')}</p>`,
      tags: [{ name: 'city', url: 'https://fedibird.example/tags/city', account_url: 'https://remote.example/@quoter/tagged/city' }],
    });
    const store = importStatuses([
      apiStatus({
        id: 'parent',
        account: account('parent-author', 'parent'),
        content: `<p>${hashtagHtml('outer')}</p>`,
        tags: [{ name: 'outer', url: 'https://fedibird.example/tags/outer', account_url: 'https://remote.example/@parent/tagged/outer' }],
        quote,
        quote_id: 'quoted',
      }),
    ]);

    expect(store.getState().getIn(['statuses', 'quoted', 'tags', 0, 'account_url'])).toBe('https://remote.example/@quoter/tagged/city');

    const view = renderImported(store, 'parent');
    const outer = view.container.querySelector('[data-menu-hashtag="outer"]');
    const inner = view.container.querySelector('[data-menu-hashtag="city"]');

    expect(outer).toHaveAttribute('data-status-id', 'parent');
    expect(inner).toHaveAttribute('data-status-id', 'quoted');

    clickHashtag(view.container, 'city');
    expect(screen.getByRole('button', { name: /quoter/ })).toHaveAttribute('href', 'https://remote.example/@quoter/tagged/city');
  });

  it('resolves a compact boost through referenced_statuses, not the wrapper id', () => {
    const store = importStatuses([
      apiStatus({
        id: 'boost',
        account: account('booster', 'booster'),
        content: '<p></p>',
        tags: [],
        reblog: 'original',
      }),
      apiStatus({
        id: 'original',
        account: account('author', 'alice'),
        content: `<p>${hashtagHtml('photo')}</p>`,
        tags: [{ name: 'photo', url: 'https://fedibird.example/tags/photo', account_url: 'https://remote.example/@alice/tagged/photo' }],
        quote_id: 'quoted',
        quote: 'quoted',
      }),
      apiStatus({
        id: 'quoted',
        account: account('quoted-author', 'quoter'),
        content: `<p>${hashtagHtml('city')}</p>`,
        tags: [{ name: 'city', url: 'https://fedibird.example/tags/city', account_url: 'https://remote.example/@quoter/tagged/city' }],
      }),
    ]);

    const view = renderImported(store, 'boost');
    const photo = view.container.querySelector('[data-menu-hashtag="photo"]');
    const city = view.container.querySelector('[data-menu-hashtag="city"]');

    expect(photo).toHaveAttribute('data-status-id', 'original');
    expect(city).toHaveAttribute('data-status-id', 'quoted');

    clickHashtag(view.container, 'city');
    expect(screen.getByRole('button', { name: /quoter/ })).toHaveAttribute('href', 'https://remote.example/@quoter/tagged/city');
  });
});
