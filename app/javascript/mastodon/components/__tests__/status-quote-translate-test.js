/* eslint-disable react/prop-types */

import { fireEvent, render, screen, within } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { createStore } from 'redux';

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
  disableReactions: false,
  translationBarVisibility: 'always',
  translationPreferredMode: 'translated',
  languages: [
    ['en', 'English', 'English'],
    ['ja', 'Japanese', '日本語'],
  ],
}));

jest.mock('react-intl', () => {
  const React = require('react');
  const intl = {
    locale: 'ja',
    formatMessage: ({ defaultMessage }, values) => {
      let message = defaultMessage;

      if (values) {
        Object.keys(values).forEach(key => {
          message = message.replace(`{${key}}`, values[key]);
        });
      }

      return message;
    },
    formatDate: () => '',
    now: () => Date.now(),
  };

  return {
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    defineMessages: messages => messages,
    FormattedMessage: ({ defaultMessage, values }) => intl.formatMessage({ defaultMessage }, values),
    FormattedDate: () => 'date',
  };
});

jest.mock('react-hotkeys', () => ({
  HotKeys: ({ children }) => children,
}));

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
jest.mock('mastodon/components/media_gallery', () => () => null);
jest.mock('mastodon/features/video', () => () => null);
jest.mock('mastodon/features/audio', () => () => null);

import Status from '../status';
import DetailedStatus from '../../features/status/components/detailed_status';

const store = createStore(() => fromJS({
  relationships: {},
  server: {
    translationLanguages: {
      items: { en: ['ja'] },
    },
  },
}));

const pictureInPicture = fromJS({ inUse: false, available: false });

const account = {
  id: 'a1',
  acct: 'alice',
  username: 'alice',
  display_name: 'Alice',
  display_name_html: 'Alice',
  url: 'https://example.test/alice',
  avatar: '',
  group: false,
};

const quoteStatus = (translation) => ({
  id: 'q1',
  account,
  contentHtml: '<p>Hello quote</p>',
  spoilerHtml: '',
  spoiler_text: '',
  search_index: 'Hello quote',
  language: 'en',
  visibility: 'public',
  hidden: false,
  mentions: [],
  media_attachments: [],
  poll: 'p1',
  url: 'https://example.test/q1',
  translation,
});

const parentStatus = (translation) => fromJS({
  id: 's1',
  account,
  content: 'outer',
  contentHtml: '<p>外側</p>',
  spoilerHtml: '',
  spoiler_text: '',
  search_index: '外側',
  language: 'ja',
  visibility: 'public',
  hidden: false,
  reblog: null,
  quote: quoteStatus(translation),
  quote_id: 'q1',
  media_attachments: [],
  created_at: '2024-01-01T00:00:00.000Z',
  url: 'https://example.test/s1',
  in_reply_to_id: null,
  in_reply_to_account_id: null,
  matched_filters: false,
  reblogs_count: 0,
  favourites_count: 0,
  emoji_reactions_count: 0,
  status_referred_by_count: 0,
});

const translation = {
  contentHtml: '<p>引用こんにちは</p>',
  spoilerHtml: '',
  spoiler_text: '',
  language: 'ja',
  detected_source_language: 'en',
  provider: 'DeepL',
};

const renderTimeline = (status, onTranslate) => render(
  <Provider store={store}>
    <Status
      status={status}
      pictureInPicture={pictureInPicture}
      addEmojiReaction={jest.fn()}
      removeEmojiReaction={jest.fn()}
      onAddToList={jest.fn()}
      onToggleCollapsed={jest.fn()}
      onTranslate={onTranslate}
    />
  </Provider>,
);

const renderDetail = (status, onTranslate) => render(
  <Provider store={store}>
    <DetailedStatus
      status={status}
      pictureInPicture={pictureInPicture}
      domain='example.test'
      onTranslate={onTranslate}
      onOpenMedia={jest.fn()}
      onOpenVideo={jest.fn()}
      onOpenMediaQuote={jest.fn()}
      onOpenVideoQuote={jest.fn()}
      onToggleHidden={jest.fn()}
      addEmojiReaction={jest.fn()}
      removeEmojiReaction={jest.fn()}
    />
  </Provider>,
);

describe.each([
  ['timeline status', renderTimeline],
  ['detailed status', renderDetail],
])('%s embedded quote translation', (_label, renderStatus) => {
  it('does not offer Translate when the quote has no translation', () => {
    renderStatus(parentStatus(null), jest.fn());
    const quote = within(document.querySelector('.quote-status'));

    expect(screen.getByText('Hello quote')).toBeTruthy();
    expect(quote.queryByRole('button', { name: 'Translate' })).toBeNull();
    expect(quote.queryByRole('button', { name: 'Show original' })).toBeNull();
    expect(screen.getByRole('button', { name: 'Translate' })).toBeDisabled();
  });

  it('shows the translated quote and undoes that quote status', () => {
    const onTranslate = jest.fn();
    renderStatus(parentStatus(translation), onTranslate);
    const quote = within(document.querySelector('.quote-status'));

    expect(screen.getByText('引用こんにちは')).toBeTruthy();
    expect(screen.queryByText('Hello quote')).toBeNull();
    expect(quote.queryByRole('button', { name: 'Translate' })).toBeNull();
    expect(quote.getByRole('button', { name: 'Translated', pressed: true })).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Original' }));

    expect(onTranslate).toHaveBeenCalledTimes(1);
    expect(onTranslate.mock.calls[0][0].get('id')).toBe('q1');
    expect(onTranslate.mock.calls[0][0].get('poll')).toBe('p1');
    expect(onTranslate.mock.calls[0][1]).toBe('original');
  });

  it('keeps quote translation data available while showing bilingual controls', () => {
    renderStatus(parentStatus({
      ...translation,
      contentHtml: '<p>引用こんにちは</p>',
    }).setIn(['quote', 'translationMode'], 'bilingual'), jest.fn());

    expect(screen.getByText('Hello quote')).toBeTruthy();
    expect(screen.getByText('引用こんにちは')).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Bilingual', pressed: true })).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Original' })).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Translated' })).toBeTruthy();
    expect(document.querySelector('.quote-status .status__translation-controls')).toBeTruthy();
  });
});
