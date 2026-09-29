/* eslint-disable react/prop-types */

import { render } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { createStore } from 'redux';

jest.mock('mastodon/initial_state', () => ({
  displayMedia: 'show_all',
  autoPlayMedia: false,
  cropImages: true,
  useBlurhash: false,
  useLowResolutionThumbnails: false,
  maxAttachments: 4,
  enableReaction: false,
  compactReaction: false,
  show_reply_tree_button: false,
  enableStatusReference: false,
  disableRelativeTime: true,
  hideLinkPreview: true,
  hidePhotoPreview: true,
  hideVideoPreview: true,
  hideRebloggedBy: false,
  hideListOfEmojiReactionsToPosts: false,
  hideListOfFavouritesToPosts: false,
  hideListOfReblogsToPosts: false,
  hideListOfReferredByToPosts: false,
  me: '1',
  autoPlayEmoji: false,
  disableReactions: false,
  translationPrivateContentAllowed: false,
  translationBarVisibility: 'always',
  translationPreferredMode: 'both',
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
jest.mock('mastodon/components/edited_timestamp', () => () => null);
jest.mock('mastodon/components/animated_number', () => () => null);
jest.mock('mastodon/components/blurhash', () => () => null);
jest.mock('mastodon/components/thumbhash', () => () => null);
jest.mock('mastodon/components/alt_text_badge', () => ({ description, mode, originalDescription, translatedDescription }) => (
  <span data-mode={mode || ''} data-original={originalDescription || ''} data-translated={translatedDescription || ''}>{description}</span>
));
jest.mock('../../features/status/components/card', () => () => null);
jest.mock('mastodon/containers/poll_container', () => () => null);
jest.mock('../permalink', () => ({ children }) => <span>{children}</span>);
jest.mock('mastodon/features/video', () => () => null);
jest.mock('mastodon/features/audio', () => () => null);
jest.mock('react-router-dom', () => ({
  Link: ({ children }) => <a href='https://example.test/'>{children}</a>,
}));

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
  id: '1',
  acct: 'alice',
  username: 'alice',
  display_name: 'Alice',
  display_name_html: 'Alice',
  url: 'https://example.test/alice',
  avatar: '',
  avatar_static: '',
  group: false,
};

const attachment = {
  id: 'm1',
  type: 'image',
  url: 'https://example.test/cat.jpg',
  preview_url: 'https://example.test/cat-small.jpg',
  remote_url: 'https://example.test/cat.jpg',
  description: 'a cat',
  meta: {
    small: { width: 100 },
    original: { width: 200 },
    focus: { x: 0, y: 0 },
  },
};

const translatedHtml = '<p>こんにちは <img draggable="false" class="emojione custom-emoji" alt=":blob:" title="blob" data-shortcode="blob" src="https://example.test/blob.png" /></p>';

const properStatus = fromJS({
  id: 'proper',
  account,
  content: '<p>Hello :blob:</p>',
  contentHtml: '<p>Hello :blob:</p>',
  spoilerHtml: '',
  spoiler_text: '',
  search_index: 'Hello :blob:',
  language: 'en',
  visibility: 'private',
  hidden: false,
  sensitive: false,
  mentions: [],
  media_attachments: [attachment],
  reblog: null,
  created_at: '2024-01-01T00:00:00.000Z',
  url: 'https://example.test/proper',
});

const personalBoost = (mode) => fromJS({
  id: 'wrap',
  account,
  content: '',
  contentHtml: '',
  spoilerHtml: '',
  spoiler_text: '',
  search_index: '',
  language: null,
  visibility: 'personal',
  hidden: false,
  sensitive: false,
  mentions: [],
  emojis: [],
  media_attachments: [],
  reblog: properStatus,
  created_at: '2024-01-01T00:00:00.000Z',
  url: 'https://example.test/wrap',
  translationPending: false,
  translationMode: mode,
  translation: {
    detected_source_language: 'en',
    language: 'ja',
    provider: 'DeepL',
    requested_source_language: 'en',
    requested_target_language: 'ja',
    contentHtml: translatedHtml,
    spoilerHtml: '',
    spoiler_text: '',
    media_attachments: [{ id: 'm1', description: 'ねこ' }],
  },
});

const renderDetailed = (status) => render(
  <Provider store={store}>
    <DetailedStatus
      status={status}
      pictureInPicture={pictureInPicture}
      domain='example.test'
      showMedia
      onTranslate={jest.fn()}
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

const renderTimeline = (status) => render(
  <Provider store={store}>
    <Status
      status={status}
      pictureInPicture={pictureInPicture}
      addEmojiReaction={jest.fn()}
      removeEmojiReaction={jest.fn()}
      onAddToList={jest.fn()}
      onToggleCollapsed={jest.fn()}
      onTranslate={jest.fn()}
    />
  </Provider>,
);

const expectTranslatedAlt = (container, mode) => {
  const galleryImage = container.querySelector('.media-gallery__item-thumbnail img');
  const badge = container.querySelector('.media-gallery__item__badges [data-mode]');

  expect(galleryImage).not.toBeNull();
  expect(galleryImage.getAttribute('alt')).toBe('ねこ');
  expect(galleryImage.getAttribute('lang')).toBe('ja');
  expect(badge.getAttribute('data-mode')).toBe(mode);
  expect(badge.getAttribute('data-original')).toBe('a cat');
  expect(badge.getAttribute('data-translated')).toBe('ねこ');
  expect(container.innerHTML).toContain('data-shortcode="blob"');
};

describe('personal boost translated media', () => {
  it.each([
    ['translated'],
    ['bilingual'],
  ])('shows translated alt text in %s mode without writing it onto the boosted status', (mode) => {
    const status = personalBoost(mode);
    const detailed = renderDetailed(status);

    expectTranslatedAlt(detailed.container, mode);
    expect(status.getIn(['reblog', 'media_attachments', 0, 'translation'])).toBeUndefined();
    expect(status.getIn(['reblog', 'translation'])).toBeUndefined();
    detailed.unmount();

    const alone = renderDetailed(status.get('reblog'));
    expect(alone.container.querySelector('.media-gallery__item-thumbnail img').getAttribute('alt')).toBe('a cat');
    alone.unmount();
  });

  it('hides a stale wrapper translation after the boosted status source changes', () => {
    const current = personalBoost('translated').setIn(['reblog', 'contentHtml'], '<p>Hello again</p>').setIn(['reblog', 'content'], '<p>Hello again</p>').setIn(['reblog', 'media_attachments', 0, 'description'], 'a kitten');
    const stale = current.set('translationStatusSignature', 'stale');
    const { container } = renderDetailed(stale);

    expect(container.innerHTML).toContain('Hello again');
    expect(container.innerHTML).not.toContain('こんにちは');
    expect(container.querySelector('.media-gallery__item-thumbnail img').getAttribute('alt')).toBe('a kitten');
    expect(container.querySelector('[data-translated="ねこ"]')).toBeNull();
  });

  it('shows translated alt text for a personal boost in the timeline', async () => {
    const { container, findByRole } = renderTimeline(personalBoost('translated'));
    const image = await findByRole('img', { name: 'ねこ' });

    expect(image.getAttribute('alt')).toBe('ねこ');
    expect(container.innerHTML).toContain('data-shortcode="blob"');
  });
});
