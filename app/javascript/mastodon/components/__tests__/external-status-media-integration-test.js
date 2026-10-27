/* eslint-disable react/prop-types */

import { fireEvent, render, screen } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { createStore } from 'redux';

jest.mock('mastodon/initial_state', () => ({
  displayMedia: 'default',
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
  new_features_policy: 'stable',
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
jest.mock('mastodon/components/alt_text_badge', () => ({ description, mode, sourceLang, targetLang }) => (
  <span data-testid='alt-badge' data-mode={mode || ''} data-source-lang={sourceLang || ''} data-target-lang={targetLang || ''}>{description}</span>
));
jest.mock('../../features/status/components/card', () => () => null);
jest.mock('mastodon/containers/poll_container', () => () => null);
jest.mock('../permalink', () => ({ children }) => <span>{children}</span>);
jest.mock('react-router-dom', () => ({
  Link: ({ children }) => <a href='https://example.test/'>{children}</a>,
}));

import Status, { nextShownMediaState } from '../status';
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

const image = {
  id: 'img',
  type: 'image',
  url: 'https://cb.example/system/still.png',
  preview_url: 'https://cb.example/system/still-small.png',
  remote_url: '',
  description: 'Still',
  translation: { description: 'ねこ' },
  meta: {
    small: { width: 100 },
    original: { width: 200 },
    focus: { x: 0, y: 0 },
  },
};

const video = {
  id: 'vid',
  type: 'video',
  url: 'https://cb.example/system/clip.webm',
  preview_url: 'https://cb.example/system/clip.jpg',
  remote_url: '',
  description: 'Clip',
  translation: { description: '動画' },
  meta: { original: { duration: 3, frame_rate: '30' } },
};

const sequence = [
  { type: 'image', delivery: 'local', attachment_id: 'img', position: 0 },
  { type: 'video', delivery: 'local', attachment_id: 'vid', position: 1 },
  { id: 'remote-clip', type: 'video', delivery: 'remote', url: 'https://cdn.example/clip.mp4', position: 2 },
];

const baseStatus = (extra = {}) => fromJS({
  id: 'story',
  account,
  content: '<p>Story</p>',
  contentHtml: '<p>Story</p>',
  spoilerHtml: extra.spoiler_text ? `<p>${extra.spoiler_text}</p>` : '',
  spoiler_text: '',
  search_index: 'Story',
  language: 'en',
  visibility: 'public',
  hidden: false,
  sensitive: false,
  mentions: [],
  media_attachments: [image, video],
  reblog: null,
  created_at: '2024-01-01T00:00:00.000Z',
  url: 'https://example.test/story',
  translationPending: false,
  translationMode: 'translated',
  translation: {
    detected_source_language: 'en',
    language: 'ja',
    provider: 'DeepL',
    requested_source_language: 'en',
    requested_target_language: 'ja',
    contentHtml: '<p>記事</p>',
    spoilerHtml: '',
    spoiler_text: '',
    media_attachments: [
      { id: 'img', description: 'ねこ' },
      { id: 'vid', description: '動画' },
    ],
  },
  fedibird_external: { sequence },
  ...extra,
});

const callbacks = () => ({
  onOpenMedia: jest.fn(),
  onOpenVideo: jest.fn(),
  onOpenMediaQuote: jest.fn(),
  onOpenVideoQuote: jest.fn(),
  onToggleHidden: jest.fn(),
  onToggleMediaVisibility: jest.fn(),
  onTranslate: jest.fn(),
  addEmojiReaction: jest.fn(),
  removeEmojiReaction: jest.fn(),
  onAddToList: jest.fn(),
  onToggleCollapsed: jest.fn(),
});

const renderTimeline = (status, handlers = callbacks()) => ({
  ...render(
    <Provider store={store}>
      <Status status={status} pictureInPicture={pictureInPicture} {...handlers} />
    </Provider>,
  ),
  handlers,
});

const renderDetailed = (status, props = {}) => {
  const handlers = { ...callbacks(), ...props };
  return {
    ...render(
      <Provider store={store}>
        <DetailedStatus
          status={status}
          pictureInPicture={pictureInPicture}
          domain='example.test'
          showMedia={false}
          {...handlers}
        />
      </Provider>,
    ),
    handlers,
  };
};

beforeAll(() => {
  window.HTMLMediaElement.prototype.pause = () => {};
  window.HTMLMediaElement.prototype.play = () => Promise.resolve();
  Object.defineProperty(window.HTMLMediaElement.prototype, 'volume', {
    configurable: true,
    writable: true,
    value: 1,
  });
});

describe('external status media with the real gallery', () => {
  it('hides sensitive images and saved videos until reveal, then opens the modal for the clicked file', () => {
    const { container, handlers } = renderTimeline(baseStatus({ sensitive: true }));

    expect(container.querySelector('img')).toBeNull();
    expect(container.querySelector('video')).toBeNull();
    expect(container.innerHTML).not.toContain('https://cdn.example/clip.mp4');
    expect(container.querySelector('.media-gallery').style.height).toBe('110px');
    expect(screen.getAllByText('Sensitive content').length).toBeGreaterThan(0);

    fireEvent.click(screen.getAllByRole('button', { name: 'Sensitive content' })[0]);

    const galleryImage = container.querySelector('.media-gallery__item-thumbnail img');
    expect(galleryImage).not.toBeNull();
    expect(galleryImage.getAttribute('alt')).toBe('ねこ');
    expect(galleryImage.getAttribute('lang')).toBe('ja');
    expect(container.querySelector('.external-status-media__saved video').getAttribute('src')).toBe('https://cb.example/system/clip.webm');
    expect(container.querySelector('[data-testid="alt-badge"]').getAttribute('data-mode')).toBe('translated');
    expect(container.querySelector('[data-testid="alt-badge"]').getAttribute('data-source-lang')).toBe('en');
    expect(container.querySelector('[data-testid="alt-badge"]').getAttribute('data-target-lang')).toBe('ja');
    expect(container.innerHTML).not.toContain('https://cdn.example/clip.mp4');

    fireEvent.click(container.querySelector('.media-gallery__item-thumbnail'));
    expect(handlers.onOpenMedia).toHaveBeenCalledTimes(1);
    const [statusId, media, index, lang] = handlers.onOpenMedia.mock.calls[0];
    expect(statusId).toBe('story');
    expect(media.getIn([0, 'id'])).toBe('img');
    expect(index).toBe(0);
    expect(lang).toBe('ja');

    fireEvent.click(screen.getByRole('button', { name: 'Expand video' }));
    expect(handlers.onOpenVideo).toHaveBeenCalledTimes(1);
    const [videoStatusId, attachment, options, videoLang] = handlers.onOpenVideo.mock.calls[0];
    expect(videoStatusId).toBe('story');
    expect(attachment.get('id')).toBe('vid');
    expect(options).toEqual(expect.objectContaining({ startTime: 0 }));
    expect(videoLang).toBe('ja');

    fireEvent.click(screen.getByRole('button', { name: 'External video' }));
    expect(container.querySelector('video[src="https://cdn.example/clip.mp4"]')).not.toBeNull();
  });

  it('omits external media while the content warning is collapsed', () => {
    const { container } = renderTimeline(baseStatus({ sensitive: true, hidden: true, spoiler_text: 'spoiler' }));

    expect(container.querySelector('.media-gallery')).toBeNull();
    expect(container.querySelector('video')).toBeNull();
    expect(container.querySelector('.external-remote-media')).toBeNull();
    expect(container.innerHTML).not.toContain('https://cdn.example/clip.mp4');
    expect(container.innerHTML).not.toContain('https://cb.example/system/still-small.png');
  });

  it('follows the detailed status visibility flag for images and saved videos', () => {
    const hidden = renderDetailed(baseStatus({ sensitive: false }), { showMedia: false });

    expect(hidden.container.querySelector('img')).toBeNull();
    expect(hidden.container.querySelector('video')).toBeNull();
    expect(hidden.container.querySelector('.media-gallery').style.height).toBe('300px');
    expect(screen.getAllByText('Media hidden').length).toBeGreaterThan(0);

    hidden.rerender(
      <Provider store={store}>
        <DetailedStatus
          {...hidden.handlers}
          status={baseStatus({ sensitive: true })}
          pictureInPicture={pictureInPicture}
          domain='example.test'
          showMedia
        />
      </Provider>,
    );

    const imageNode = hidden.container.querySelector('.media-gallery__item-thumbnail img');
    expect(imageNode).not.toBeNull();
    expect(imageNode.getAttribute('alt')).toBe('ねこ');
    expect(hidden.container.querySelector('.external-status-media__saved video')).not.toBeNull();

    fireEvent.click(hidden.container.querySelector('.media-gallery__item-thumbnail'));
    const [media, index, lang, statusId] = hidden.handlers.onOpenMedia.mock.calls[0];
    expect(media.getIn([0, 'id'])).toBe('img');
    expect(index).toBe(0);
    expect(lang).toBe('ja');
    expect(statusId).toBe('story');

    fireEvent.click(screen.getByRole('button', { name: 'Expand video' }));
    expect(hidden.handlers.onOpenVideo.mock.calls[0][0].get('id')).toBe('vid');
    expect(hidden.handlers.onOpenVideo.mock.calls[0][3]).toBe('story');
  });

  it('switches the warning and remote video when the same status is updated', () => {
    const view = renderTimeline(baseStatus());

    expect(screen.getByRole('button', { name: 'External video' })).toBeTruthy();
    expect(view.container.innerHTML).not.toContain('https://cdn.example/clip.mp4');

    const handlers = view.handlers;
    const draw = (extra) => {
      view.rerender(
        <Provider store={store}>
          <Status status={baseStatus(extra)} pictureInPicture={pictureInPicture} {...handlers} />
        </Provider>,
      );
    };

    draw({ hidden: true, spoiler_text: '旅行記', spoilerHtml: '旅行記' });
    expect(view.container.textContent).toContain('旅行記');
    expect(view.container.querySelector('.external-remote-media')).toBeNull();
    expect(view.container.innerHTML).not.toContain('https://cdn.example/clip.mp4');

    draw({ hidden: false, sensitive: true, spoiler_text: '旅行記', spoilerHtml: '旅行記' });
    expect(view.container.innerHTML).not.toContain('https://cdn.example/clip.mp4');
    expect(screen.getAllByText('Sensitive content').length).toBeGreaterThan(0);

    draw({});
    expect(screen.getByRole('button', { name: 'External video' })).toBeTruthy();
    expect(view.container.innerHTML).not.toContain('https://cdn.example/clip.mp4');
  });

  it('hides a boosted status when that status becomes sensitive', () => {
    const boosted = baseStatus({ id: 'inner', sensitive: false });
    const wrapper = boosted.merge({
      id: 'boost',
      reblog: boosted,
      fedibird_external: null,
    });
    const view = renderTimeline(wrapper);
    expect(screen.getByRole('button', { name: 'External video' })).toBeTruthy();
    expect(view.container.innerHTML).not.toContain('https://cdn.example/clip.mp4');

    view.rerender(
      <Provider store={store}>
        <Status
          status={wrapper.set('reblog', boosted.set('sensitive', true))}
          pictureInPicture={pictureInPicture}
          {...view.handlers}
        />
      </Provider>,
    );

    expect(view.container.innerHTML).not.toContain('https://cdn.example/clip.mp4');
    expect(screen.getAllByText('Sensitive content').length).toBeGreaterThan(0);
  });

  it('hides quoted media on the detail column when only the quote becomes sensitive', () => {
    const quote = baseStatus({
      id: 'quoted',
      sensitive: false,
      hidden: false,
      spoiler_text: '',
      fedibird_external: null,
      media_attachments: [video],
    });
    const detail = baseStatus({ quote, fedibird_external: null, media_attachments: [] });
    const prev = {
      loadedStatusId: 'story',
      showMedia: true,
      showQuoteMedia: true,
      sensitive: false,
      quoteSensitive: false,
    };
    const opened = renderDetailed(detail, { showQuoteMedia: true });
    expect(opened.container.querySelector('video')).not.toBeNull();

    const next = nextShownMediaState(prev, detail.set('quote', quote.set('sensitive', true)), 'loadedStatusId');
    expect(next.showQuoteMedia).toBe(false);
    expect(next.showMedia).toBeUndefined();

    opened.rerender(
      <Provider store={store}>
        <DetailedStatus
          {...opened.handlers}
          status={detail.set('quote', quote.set('sensitive', true))}
          pictureInPicture={pictureInPicture}
          domain='example.test'
          showMedia
          showQuoteMedia={next.showQuoteMedia}
        />
      </Provider>,
    );
    expect(opened.container.querySelector('video')).toBeNull();
    expect(opened.container.innerHTML).not.toContain('https://cb.example/system/clip.webm');
  });

  it('hides the detailed status media while its content warning is collapsed', () => {
    const { container } = renderDetailed(baseStatus({ hidden: true, spoiler_text: 'spoiler', sensitive: true }), { showMedia: true });

    expect(container.querySelector('.media-gallery')).toBeNull();
    expect(container.querySelector('video')).toBeNull();
    expect(container.innerHTML).not.toContain('https://cdn.example/clip.mp4');
  });
});
