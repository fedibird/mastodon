/* eslint-disable react/prop-types */

import { fireEvent, render, waitFor } from '@testing-library/react';
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
  enableReaction: true,
  cropCardImages: false,
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
jest.mock('../status_action_bar', () => {
  const ReactMock = require('react');
  return ({ compactCardMode }) => compactCardMode ? ReactMock.createElement('span', { 'data-compact-card-mode': compactCardMode }) : null;
});
jest.mock('../avatar', () => () => null);
jest.mock('../avatar_overlay', () => () => null);
jest.mock('../avatar_composite', () => () => null);
jest.mock('../display_name', () => () => <span>name</span>);
jest.mock('../absolute_timestamp', () => () => <span>time</span>);
jest.mock('../relative_timestamp', () => () => <span>time</span>);
jest.mock('../icon', () => () => null);
jest.mock('mastodon/components/icon', () => () => null);
jest.mock('mastodon/components/emoji_reactions_bar', () => {
  const ReactMock = require('react');
  return () => ReactMock.createElement('span', { 'data-testid': 'emoji-reaction-bar' });
});
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

const renderTimeline = (status, options = {}) => render(
  <Provider store={store}>
    <Status
      {...options}
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

describe('compact timeline card context', () => {
  it('displays the booster attribution immediately above the card author row', () => {
    const { container } = renderTimeline(personalBoost('original'), { layoutMode: 'card-2' });
    const context = container.querySelector('.timeline-card__context');
    const author = container.querySelector('.timeline-card__author');

    expect(context).not.toBeNull();
    expect(context.textContent).toContain('boosted');
    expect(author).not.toBeNull();
    expect(context.nextElementSibling).toBe(author);
  });

  it('displays the pinned context instead of boost attribution for featured cards', () => {
    const { container } = renderTimeline(personalBoost('original'), { layoutMode: 'card-1', featured: true });
    const context = container.querySelector('.timeline-card__context');

    expect(context).not.toBeNull();
    expect(context.textContent).toContain('Pinned toot');
    expect(context.textContent).not.toContain('boosted');
  });

  it('does not add attribution to ordinary, non-pinned cards', () => {
    const { container } = renderTimeline(properStatus, { layoutMode: 'card-3' });
    expect(container.querySelector('.timeline-card__context')).toBeNull();
  });
});

describe('temporary media tile reveal', () => {
  it('adds an individually revealed sensitive tile to the cross-post viewer without opening it on first click', () => {
    const onMediaTileReveal = jest.fn();
    const onOpenMedia = jest.fn();
    const sensitive = properStatus.set('sensitive', true);
    const sequence = {
      media: fromJS([attachment]),
      statusIds: fromJS(['proper']),
      positions: { 'proper:0': 0 },
    };
    const { container } = renderTimeline(sensitive, {
      layoutMode: 'media',
      mediaIndex: 0,
      mediaRowKey: 'proper:0',
      mediaVisibility: 'hide_sensitive',
      mediaTimeline: sequence,
      onMediaTileReveal,
      onOpenMedia,
    });
    const tile = container.querySelector('.timeline-media-tile__open');

    expect(tile).not.toBeNull();
    fireEvent.click(tile);
    expect(onMediaTileReveal).toHaveBeenCalledWith('proper:0');
    expect(onOpenMedia).not.toHaveBeenCalled();

    fireEvent.click(tile);
    expect(onOpenMedia).toHaveBeenCalledTimes(1);
    expect(onOpenMedia.mock.calls[0][0]).toBe('proper');
    expect(onOpenMedia.mock.calls[0][1]).toBe(sequence.media);
    expect(onOpenMedia.mock.calls[0][2]).toBe(0);
    expect(onOpenMedia.mock.calls[0][4]).toBe(sequence.statusIds);
  });
});

describe('compact card reaction placement', () => {
  it('renders star then plus at the end of the author row when no reactions exist', () => {
    const { container } = renderTimeline(properStatus, { layoutMode: 'card-1' });
    const author = container.querySelector('.timeline-card__author');
    const actions = author.querySelector('.timeline-card__author-actions');

    expect(actions).not.toBeNull();
    expect(Array.from(actions.querySelectorAll('[data-compact-card-mode]')).map(item => item.dataset.compactCardMode)).toEqual(['favourite', 'reactions']);
    expect(container.querySelector('.timeline-card__reactions')).toBeNull();
  });

  it('still collapses the empty row when reaction records all have count zero', () => {
    const zero = properStatus.set('emoji_reactions', fromJS([{ name: ':test:', count: 0 }]));
    const { container } = renderTimeline(zero, { layoutMode: 'card-2' });

    expect(container.querySelector('.timeline-card__reactions')).toBeNull();
    expect(container.querySelector('.timeline-card__author-actions [data-compact-card-mode="reactions"]')).not.toBeNull();
  });

  it('keeps an independent reactions row with plus when a visible reaction exists', () => {
    const reacted = properStatus.set('emoji_reactions', fromJS([{ name: ':test:', count: 2 }]));
    const { container } = renderTimeline(reacted, { layoutMode: 'card-3' });
    const actions = container.querySelector('.timeline-card__author-actions');
    const reactions = container.querySelector('.timeline-card__reactions');

    expect(Array.from(actions.querySelectorAll('[data-compact-card-mode]')).map(item => item.dataset.compactCardMode)).toEqual(['favourite']);
    expect(reactions).not.toBeNull();
    expect(reactions.querySelector('[data-testid="emoji-reaction-bar"]')).not.toBeNull();
    expect(reactions.querySelector('[data-compact-card-mode="reactions"]')).not.toBeNull();
  });
});

describe('card crop preference propagation', () => {
  it('uses its own uncropped aspect ratio instead of the standard timeline crop preference', async () => {
    const portrait = properStatus.setIn(['media_attachments', 0, 'meta', 'small', 'aspect'], 0.5);
    const { container } = renderTimeline(portrait, { layoutMode: 'card-1', cachedMediaWidth: 300 });

    await waitFor(() => {
      const gallery = container.querySelector('.timeline-card__media .media-gallery');
      expect(gallery).not.toBeNull();
      expect(Number(gallery.style.aspectRatio)).toBeCloseTo(0.5);
      expect(gallery.style.height).toBe('');
    });
  });
});

describe('compact card attachment count indicator', () => {
  it('does not add an overlay to a single-attachment card or a regular status', () => {
    const card = renderTimeline(properStatus, { layoutMode: 'card-1' });
    expect(card.container.querySelector('.timeline-card__media-count')).toBeNull();
    card.unmount();

    const regular = renderTimeline(properStatus);
    expect(regular.container.querySelector('.timeline-card__media-count')).toBeNull();
  });

  it('shows an accessible but non-interactive count for a multi-image card', async () => {
    const multi = properStatus.set('media_attachments', fromJS([
      attachment,
      { ...attachment, id: 'm2', description: 'second' },
      { ...attachment, id: 'm3', description: 'third' },
    ]));
    const { container } = renderTimeline(multi, { layoutMode: 'card-2' });
    const count = container.querySelector('.timeline-card__media-count');

    expect(count).not.toBeNull();
    expect(count.getAttribute('aria-label')).toBe('3 media attachments');
    expect(count.getAttribute('role')).toBe('img');
    expect(count.textContent).toContain('3');
    expect(count.querySelector('a, button')).toBeNull();

    // The compact card still renders just the first attachment.
    await waitFor(() => expect(container.querySelectorAll('.timeline-card__media .media-gallery__item')).toHaveLength(1));
  });

  it('opens all four attached images from the single card thumbnail', async () => {
    const images = fromJS([
      attachment,
      { ...attachment, id: 'm2', description: 'second' },
      { ...attachment, id: 'm3', description: 'third' },
      { ...attachment, id: 'm4', description: 'fourth' },
    ]);
    const onOpenMedia = jest.fn();
    const { container } = renderTimeline(properStatus.set('media_attachments', images), {
      layoutMode: 'card-2',
      onOpenMedia,
    });

    await waitFor(() => expect(container.querySelectorAll('.timeline-card__media .media-gallery__item')).toHaveLength(1));
    expect(container.querySelector('.timeline-card__media-count').textContent).toContain('4');

    fireEvent.click(container.querySelector('.timeline-card__media .media-gallery__item-thumbnail'));

    expect(onOpenMedia).toHaveBeenCalledTimes(1);
    const [statusId, modalMedia, index] = onOpenMedia.mock.calls[0];
    expect(statusId).toBe('proper');
    expect(modalMedia.map(item => item.get('id')).toArray()).toEqual(['m1', 'm2', 'm3', 'm4']);
    expect(index).toBe(0);
  });

  it('opens all images on a boosted card using the original status id', async () => {
    const media = fromJS([attachment, { ...attachment, id: 'm2', description: 'second' }]);
    const status = personalBoost('original').setIn(['reblog', 'media_attachments'], media);
    const onOpenMedia = jest.fn();
    const { container } = renderTimeline(status, { layoutMode: 'card-1', onOpenMedia });

    await waitFor(() => expect(container.querySelectorAll('.timeline-card__media .media-gallery__item')).toHaveLength(1));
    fireEvent.click(container.querySelector('.timeline-card__media .media-gallery__item-thumbnail'));

    const [statusId, modalMedia, index] = onOpenMedia.mock.calls[0];
    expect(statusId).toBe('proper');
    expect(modalMedia.map(item => item.get('id')).toArray()).toEqual(['m1', 'm2']);
    expect(index).toBe(0);
  });

  it('counts mixed image, GIF, and video attachments without displaying them all', async () => {
    const mixed = properStatus.set('media_attachments', fromJS([
      attachment,
      { ...attachment, id: 'gif', type: 'gifv' },
      { ...attachment, id: 'movie', type: 'video' },
    ]));
    const onOpenMedia = jest.fn();
    const { container } = renderTimeline(mixed, { layoutMode: 'card-3', onOpenMedia });

    expect(container.querySelector('.timeline-card__media-count').getAttribute('aria-label')).toBe('3 media attachments');
    await waitFor(() => expect(container.querySelectorAll('.timeline-card__media .media-gallery__item')).toHaveLength(1));
    expect(container.querySelector('.timeline-card__media .video-player')).toBeNull();

    fireEvent.click(container.querySelector('.timeline-card__media .media-gallery__item-thumbnail'));

    expect(onOpenMedia).toHaveBeenCalledTimes(1);
    expect(onOpenMedia.mock.calls[0][1].map(item => item.get('id')).toArray()).toEqual(['m1', 'gif']);
    expect(onOpenMedia.mock.calls[0][2]).toBe(0);
  });

  it('does not expose the attachment indicator while the CW is collapsed', () => {
    const multi = properStatus
      .set('media_attachments', fromJS([attachment, { ...attachment, id: 'm2' }]))
      .set('spoiler_text', 'Hidden')
      .set('hidden', true);
    const { container } = renderTimeline(multi, { layoutMode: 'card-1' });

    expect(container.querySelector('.timeline-card__media')).toBeNull();
    expect(container.querySelector('.timeline-card__media-count')).toBeNull();
  });
});
