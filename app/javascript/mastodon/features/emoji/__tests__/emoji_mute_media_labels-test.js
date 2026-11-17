/* eslint-disable react/prop-types, react/jsx-no-bind */

import { act, fireEvent, render } from '@testing-library/react';
import { Set as ImmutableSet, fromJS } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { createStore } from 'redux';

import { EMOJI_MUTES_APPLY, EMOJI_MUTES_RESET } from 'mastodon/actions/emoji_mutes';
import { resetEmojiMuteTextForTests } from 'mastodon/features/emoji/emoji_mute_text';
import emojiMutes from 'mastodon/reducers/emoji_mutes';

jest.mock('mastodon/initial_state', () => ({
  ...jest.requireActual('mastodon/initial_state'),
  displayMedia: 'show_all',
  autoPlayMedia: false,
  cropImages: true,
  useBlurhash: true,
  useLowResolutionThumbnails: false,
  maxAttachments: 4,
  disableSwiping: true,
  enableReaction: false,
  me: '1',
}));

jest.mock('react-intl', () => {
  const React = require('react');
  const intl = {
    locale: 'en',
    formatMessage: ({ defaultMessage }, values = {}) => String(defaultMessage || '').replace(/\{(\w+)\}/g, (_, key) => (
      values[key] === undefined || values[key] === null ? '' : String(values[key])
    )),
    formatDate: () => 'Jan 1',
  };

  return {
    defineMessages: messages => messages,
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    FormattedMessage: ({ defaultMessage }) => defaultMessage,
  };
});

jest.mock('react-hotkeys', () => ({
  HotKeys: ({ children }) => children,
}));

jest.mock('mastodon/is_mobile', () => ({ isIOS: () => false }));
jest.mock('mastodon/components/blurhash', () => () => <canvas data-testid='blurhash' />);
jest.mock('mastodon/components/thumbhash', () => () => null);
jest.mock('mastodon/components/icon', () => () => null);
jest.mock('mastodon/features/ui/components/image_loader', () => ({ alt, lang, src }) => <img alt={alt || ''} lang={lang || ''} src={src || ''} />);
jest.mock('mastodon/features/video', () => ({ alt }) => <video aria-label={alt || ''} title={alt || ''} />);
jest.mock('mastodon/features/audio', () => ({ alt }) => <canvas data-testid='audio-player' aria-label={alt || ''} title={alt || ''} />);
jest.mock('mastodon/features/picture_in_picture/components/footer', () => () => null);
jest.mock('react-swipeable-views', () => ({ children }) => <div>{children}</div>);

import MediaGallery from 'mastodon/components/media_gallery';
import ThumbnailGallery from 'mastodon/components/thumbnail_gallery';
import { LocalMediaPlayer } from 'mastodon/components/status_media';
import Status from 'mastodon/components/status';
import MediaItem from 'mastodon/features/account_gallery/components/media_item';
import { PublicMediaModal } from 'mastodon/features/ui/components/media_modal';
import VideoModal from 'mastodon/features/ui/components/video_modal';
import AudioModal from 'mastodon/features/ui/components/audio_modal';

const THUMB = '👍';
const THUMB_LIGHT = '👍🏻';
const FAMILY = '👨‍👩‍👧‍👧';

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

const makeStore = () => createStore((state, action) => {
  const current = state || fromJS({
    emojiMutes: { revision: null, rules: [] },
    statuses: { s1: { id: 's1', account: 'a1' } },
    accounts: { a1: { id: 'a1', avatar_static: '/avatar.png' } },
    relationships: {},
    polls: {},
    filters: {},
    filterMatches: {},
  }).setIn(['compose', 'references'], ImmutableSet()).setIn(['compose', 'context_references'], ImmutableSet());

  return current.set('emojiMutes', emojiMutes(current.get('emojiMutes'), action));
});

const apply = (store, mutes, revision = '2') => {
  act(() => {
    store.dispatch({ type: EMOJI_MUTES_APPLY, revision, mutes });
  });
};

const unicodeRules = () => ([
  rule({ kind: 'unicode', native: THUMB }, '[ok]'),
  rule({ kind: 'unicode', native: THUMB_LIGHT }, '[skin]'),
  rule({ kind: 'unicode', native: FAMILY }, '<img src=x onerror=alert(1)>'),
  rule({ kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' }, '[local]'),
]);

const description = `Photo ${THUMB} ${THUMB_LIGHT}\n:blob: ${FAMILY} <tag>`;
const projected = 'Photo [ok] [skin]\n:blob: <img src=x onerror=alert(1)> <tag>';

const imageAttachment = (extra = {}) => fromJS({
  id: 'm1',
  type: 'image',
  url: 'https://example.test/cat.jpg',
  preview_url: 'https://example.test/cat-small.jpg',
  remote_url: 'https://example.test/cat.jpg',
  description,
  meta: { small: { width: 100, aspect: 1 }, original: { width: 200, height: 200 }, focus: { x: 0, y: 0 } },
  ...extra,
});

const renderInStore = (store, ui, container) => render(<Provider store={store}>{ui}</Provider>, container ? { container } : undefined);

describe('emoji mute media labels', () => {
  beforeEach(() => {
    resetEmojiMuteTextForTests();
  });

  it('projects the same Unicode description onto gallery alt, title, and badge without guessing shortcodes', () => {
    const store = makeStore();
    const media = imageAttachment({
      translation: { description: `訳 ${THUMB} :blob:` },
    });
    const { container } = renderInStore(store, (
      <MediaGallery
        media={fromJS([
          media,
          media.set('id', 'gif').set('type', 'gifv').set('url', 'https://example.test/cat.mp4'),
          media.set('id', 'file').set('type', 'unknown'),
        ])}
        height={200}
        visible
        onOpenMedia={() => {}}
        lang='en'
        translationMode='bilingual'
        sourceLang='en'
        targetLang='ja'
      />
    ));
    const translatedSource = `訳 ${THUMB} :blob:`;
    const image = container.querySelector('img');

    expect(image.getAttribute('alt')).toBe(translatedSource);
    expect(image.getAttribute('title')).toBe(translatedSource);

    apply(store, unicodeRules());

    const translated = '訳 [ok] :blob:';
    const sameImage = container.querySelector('img');

    expect(sameImage).toBe(image);
    expect(sameImage.getAttribute('alt')).toBe(translated);
    expect(sameImage.getAttribute('title')).toBe(translated);
    expect(sameImage.getAttribute('alt')).toBe(container.querySelector('video').getAttribute('aria-label'));
    expect(container.querySelector('video').getAttribute('title')).toBe(translated);
    expect(container.querySelector('a.media-gallery__item-thumbnail[title]').getAttribute('title')).toBe(translated);
    expect(container.querySelector('img[onerror]')).toBeNull();
    expect(media.get('description')).toBe(description);
    expect(media.getIn(['translation', 'description'])).toBe(`訳 ${THUMB} :blob:`);

    fireEvent.click(container.querySelector('.media-gallery__alt__label'));

    const popover = document.querySelector('.media-gallery__alt__popover');

    expect(popover.textContent).toContain('訳 [ok] :blob:');
    expect(popover.textContent).toContain('Photo [ok] [skin]');
    expect(popover.textContent).not.toContain(THUMB);
  });

  it('keeps a hidden sensitive tile free of the description until it is revealed', () => {
    const store = makeStore();
    const media = imageAttachment();
    const view = renderInStore(store, (
      <MediaGallery media={fromJS([media])} height={200} sensitive visible={false} onOpenMedia={() => {}} />
    ));

    apply(store, unicodeRules());

    expect(view.container.querySelector('img')).toBeNull();
    expect(view.container.querySelector('video')).toBeNull();
    expect(view.container.textContent).not.toContain(THUMB);

    fireEvent.click(view.container.querySelector('.media-gallery__alt__label'));
    expect(document.querySelector('.media-gallery__alt__popover').textContent).toContain('[ok]');
    expect(document.querySelector('.media-gallery__alt__popover').textContent).not.toContain(THUMB);

    view.rerender(
      <Provider store={store}>
        <MediaGallery media={fromJS([media])} height={200} sensitive visible onOpenMedia={() => {}} />
      </Provider>,
    );

    expect(view.container.querySelector('img').getAttribute('alt')).toBe(projected);
    expect(view.container.querySelector('img').getAttribute('title')).toBe(projected);
  });

  it('projects thumbnail and player labels, including an empty and a newline description', () => {
    const store = makeStore();
    const video = imageAttachment({ id: 'video', type: 'video', description: `Clip ${THUMB}` });
    const audio = imageAttachment({ id: 'audio', type: 'audio', description: '' });
    const { container } = renderInStore(store, (
      <React.Fragment>
        <ThumbnailGallery media={fromJS([video, audio])} visible />
        <LocalMediaPlayer attachment={video} visible Video={({ alt }) => <video data-testid='player' aria-label={alt} title={alt} />} Audio={() => null} />
      </React.Fragment>
    ));

    apply(store, unicodeRules());

    const thumb = container.querySelector('.thumbnail-gallery__item-thumbnail');

    expect(thumb.getAttribute('alt')).toBe('Clip [ok]');
    expect(thumb.getAttribute('title')).toBe('Clip [ok]');
    expect(container.querySelector('[data-testid="player"]').getAttribute('aria-label')).toBe('Clip [ok]');
    expect(container.querySelector('[data-testid="player"]').getAttribute('title')).toBe('Clip [ok]');
    expect(container.querySelectorAll('.thumbnail-gallery__item-thumbnail')[1].getAttribute('alt')).toBe('');
  });

  it('updates an account gallery image, gifv, and badge together and withholds the alt while concealed', () => {
    const store = makeStore();
    const attachment = imageAttachment().set('status', fromJS({
      id: '10',
      url: '/statuses/10',
      sensitive: true,
    }));
    const gif = attachment.set('id', 'gif').set('type', 'gifv').set('url', 'https://example.test/cat.mp4');
    const { container } = renderInStore(store, (
      <React.Fragment>
        <MediaItem attachment={attachment} visibility='hide_sensitive' onOpenMedia={() => {}} />
        <MediaItem attachment={gif.setIn(['status', 'sensitive'], false)} visibility='show_all' onOpenMedia={() => {}} />
      </React.Fragment>
    ));

    apply(store, unicodeRules());

    const hiddenLink = container.querySelectorAll('a')[0];

    expect(hiddenLink.getAttribute('aria-label')).toBe('Reveal media');
    expect(container.querySelector('img')).toBeNull();
    expect(container.querySelector('video').getAttribute('aria-label')).toBe(projected);
    expect(container.textContent).not.toContain(THUMB);

    fireEvent.click(hiddenLink);

    const revealed = container.querySelector('img');

    expect(revealed.getAttribute('alt')).toBe(projected);
    expect(hiddenLink.getAttribute('aria-label')).toBe(projected);
    expect(container.querySelector('.media-gallery__alt__label').textContent).toBe('ALT');
  });

  it('projects a masonry tile description and a display-name fallback from its HTML identity', () => {
    const store = makeStore();
    const displayHtml = `<img draggable="false" class="emojione" alt="${THUMB}" src="/emoji/thumb.svg"><img draggable="false" class="emojione custom-emoji" alt=":blob:" data-shortcode="blob" data-domain="" data-emoji-id="10">`;
    const status = fromJS({
      id: 's1',
      account: {
        id: '1',
        acct: 'alice',
        username: 'alice',
        display_name: `${THUMB} :blob:`,
        display_name_html: displayHtml,
        url: 'https://example.test/alice',
        avatar: '',
        avatar_static: '',
      },
      content: 'hello',
      contentHtml: '<p>hello</p>',
      visibility: 'public',
      created_at: '2026-11-18T00:00:00.000Z',
      media_attachments: [imageAttachment({ description: `Tile ${THUMB} :blob:` })],
      sensitive: false,
    });
    const fallbackStatus = status.set('media_attachments', fromJS([imageAttachment({ description: null })]));
    const { container } = renderInStore(store, (
      <React.Fragment>
        <Status status={status} layoutMode='media' mediaIndex={0} mediaVisibility='show_all' />
        <Status status={fallbackStatus} layoutMode='media' mediaIndex={0} mediaVisibility='show_all' />
      </React.Fragment>
    ));

    apply(store, unicodeRules());

    const images = container.querySelectorAll('img');
    const described = images[0];
    const fallback = images[1];

    expect(described.getAttribute('alt')).toBe('Tile [ok] :blob:');
    expect(described.closest('button').getAttribute('aria-label')).toBe('Tile [ok] :blob:');
    expect(fallback.getAttribute('alt')).toBe('[ok][local]');
    expect(fallback.closest('button').getAttribute('aria-label')).toBe('[ok][local]');
    expect(container.querySelector('img[onerror]')).toBeNull();
    expect(status.getIn(['media_attachments', 0, 'description'])).toBe(`Tile ${THUMB} :blob:`);
    expect(status.getIn(['account', 'display_name_html'])).toBe(displayHtml);
  });

  it('projects modal alt text and keeps an open badge inside the privacy portal', () => {
    const store = makeStore();
    const portal = document.createElement('div');
    portal.className = 'emoji-mutes-privacy-portal';
    document.body.appendChild(portal);
    const media = fromJS([imageAttachment({ type: 'image' })]);
    const video = imageAttachment({ id: 'video', type: 'video', description: `Clip ${THUMB}` });
    const audio = imageAttachment({ id: 'audio', type: 'audio', description: `Sound ${THUMB}` });

    renderInStore(store, (
      <div>
        <PublicMediaModal
          media={media}
          index={0}
          lang='en'
          onClose={() => {}}
          onChangeBackgroundColor={() => {}}
        />
        <VideoModal media={video} onClose={() => {}} onChangeBackgroundColor={() => {}} />
        <AudioModal media={audio} statusId='s1' accountStaticAvatar='' onClose={() => {}} onChangeBackgroundColor={() => {}} />
        <MediaGallery media={fromJS([imageAttachment({ description: `Badge ${THUMB}` })])} height={80} visible onOpenMedia={() => {}} />
      </div>
    ), portal);

    apply(store, unicodeRules());

    expect(portal.querySelector('img').getAttribute('alt')).toBe(projected);
    expect(portal.querySelector('video').getAttribute('aria-label')).toBe('Clip [ok]');
    expect(portal.querySelector('video').getAttribute('title')).toBe('Clip [ok]');
    expect(portal.querySelector('[data-testid="audio-player"]').getAttribute('aria-label')).toBe('Sound [ok]');
    expect(document.body.querySelector(':scope > img, :scope > video')).toBeNull();

    fireEvent.click(portal.querySelector('.media-gallery__alt__label'));

    const popover = document.querySelector('.media-gallery__alt__popover');

    expect(portal.contains(popover)).toBe(true);
    expect(popover.textContent).toContain('Badge [ok]');
    expect(popover.textContent).not.toContain(THUMB);
    expect(popover.querySelector('img')).toBeNull();

    portal.remove();

    expect(document.body.textContent).not.toContain('Badge [ok]');
    expect(document.body.textContent).not.toContain(THUMB);
  });

  it('does not project before a document is applied and clears the previous account rules', () => {
    const store = makeStore();
    const media = imageAttachment({ description: `Only ${THUMB}` });
    const { container } = renderInStore(store, (
      <ThumbnailGallery media={fromJS([media])} visible />
    ));
    const thumb = container.querySelector('img');

    expect(thumb.getAttribute('alt')).toBe(`Only ${THUMB}`);

    apply(store, [rule({ kind: 'unicode', native: THUMB }, '[nope]', { replace_in_text: false })], '2');
    expect(thumb.getAttribute('alt')).toBe(`Only ${THUMB}`);

    apply(store, unicodeRules(), '3');
    expect(thumb.getAttribute('alt')).toBe('Only [ok]');

    act(() => {
      store.dispatch({ type: EMOJI_MUTES_RESET });
    });

    expect(thumb.getAttribute('alt')).toBe(`Only ${THUMB}`);
    expect(thumb.getAttribute('title')).toBe(`Only ${THUMB}`);
  });
});
