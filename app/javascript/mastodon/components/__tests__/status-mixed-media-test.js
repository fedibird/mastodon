/* eslint-disable react/prop-types */

import { fireEvent, render, screen, waitFor } from '@testing-library/react';
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
  languages: [['en', 'English', 'English']],
  new_features_policy: 'stable',
}));

jest.mock('react-intl', () => {
  const React = require('react');
  const intl = {
    locale: 'en',
    formatMessage: ({ defaultMessage }, values) => {
      let message = defaultMessage || '';
      if (values) {
        Object.keys(values).forEach(key => {
          message = message.replace(`{${key}}`, values[key]);
        });
      }
      return message;
    },
    formatDate: () => 'date',
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
  HotKeys: ({ handlers, children }) => {
    global.__statusHotkeys = handlers;
    return children;
  },
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
jest.mock('mastodon/components/edited_timestamp', () => () => null);
jest.mock('mastodon/components/animated_number', () => () => null);
jest.mock('mastodon/components/blurhash', () => () => null);
jest.mock('mastodon/components/thumbhash', () => () => null);
jest.mock('mastodon/components/alt_text_badge', () => ({ description }) => <span>{description}</span>);
jest.mock('../../features/status/components/card', () => () => null);
jest.mock('mastodon/containers/poll_container', () => () => null);
jest.mock('mastodon/features/ui/components/column', () => ({ children }) => <div>{children}</div>);
jest.mock('mastodon/components/column_header', () => () => null);
jest.mock('mastodon/components/column_back_button', () => () => null);
jest.mock('mastodon/containers/scroll_container', () => ({ children }) => <div>{children}</div>);
jest.mock('mastodon/features/status/containers/header_container', () => () => null);
jest.mock('mastodon/containers/status_container', () => () => null);
jest.mock('mastodon/components/missing_indicator', () => () => null);
jest.mock('mastodon/features/status/components/action_bar', () => () => null);
jest.mock('../permalink', () => ({ children }) => <span>{children}</span>);
jest.mock('react-router-dom', () => ({
  Link: ({ children }) => <a href='https://example.test/'>{children}</a>,
}));

jest.mock('mastodon/features/video', () => {
  const React = require('react');

  class VideoProbe extends React.PureComponent {

    handleOpen = () => {
      if (this.props.onOpenVideo) {
        this.props.onOpenVideo({ startTime: 2 });
      }
    };

    render () {
      if (this.props.visible === false) {
        return null;
      }

      return (
        <button type='button' data-src={this.props.src} onClick={this.handleOpen}>
          Expand video
        </button>
      );
    }

  }

  return VideoProbe;
});

jest.mock('mastodon/features/audio', () => {
  const AudioProbe = ({ src }) => (
    <div className='audio-player' tabIndex='0'>
      <audio src={src} />
    </div>
  );
  return AudioProbe;
});

import Status from '../status';
import DetailedStatus from '../../features/status/components/detailed_status';
import { Status as StatusColumn } from '../../features/status';

const store = createStore(() => fromJS({ relationships: {} }));
const pictureInPicture = fromJS({ inUse: false, available: true });

const account = {
  id: '1',
  acct: 'alice',
  username: 'alice',
  display_name: 'Alice',
  display_name_html: 'Alice',
  url: 'https://example.test/alice',
  avatar: '',
  avatar_static: 'https://example.test/alice.png',
  group: false,
};

const file = (id, type) => ({
  id,
  type,
  url: `https://cdn.example/${id}`,
  preview_url: `https://cdn.example/${id}.jpg`,
  remote_url: '',
  description: id,
  meta: {
    small: { width: 100, aspect: 1.5 },
    original: { width: 200, duration: 3, frame_rate: '30' },
    focus: { x: 0, y: 0 },
  },
});

const base = (extra = {}) => fromJS({
  id: 'status-1',
  account,
  content: '<p>Hello</p>',
  contentHtml: '<p>Hello</p>',
  spoilerHtml: '',
  spoiler_text: '',
  search_index: 'Hello',
  language: 'en',
  visibility: 'public',
  hidden: false,
  sensitive: false,
  mentions: [],
  media_attachments: [],
  reblog: null,
  quote: null,
  created_at: '2024-01-01T00:00:00.000Z',
  url: 'https://example.test/status-1',
  ...extra,
});

const handlers = () => ({
  onOpenMedia: jest.fn(),
  onOpenVideo: jest.fn(),
  onOpenMediaQuote: jest.fn(),
  onOpenVideoQuote: jest.fn(),
  onToggleHidden: jest.fn(),
  onToggleCollapsed: jest.fn(),
  onTranslate: jest.fn(),
  onAddToList: jest.fn(),
  addEmojiReaction: jest.fn(),
  removeEmojiReaction: jest.fn(),
});

const renderTimeline = (status, extra = {}) => render(
  <Provider store={store}>
    <Status status={status} pictureInPicture={pictureInPicture} {...handlers()} {...extra} />
  </Provider>,
);

const renderDetail = (status, extra = {}) => render(
  <Provider store={store}>
    <DetailedStatus
      status={status}
      pictureInPicture={pictureInPicture}
      domain='example.test'
      showMedia
      {...handlers()}
      {...extra}
    />
  </Provider>,
);

describe('mixed attachments on a timeline status', () => {
  const attachments = [
    file('second-video', 'video'),
    file('photo', 'image'),
    file('first-video', 'video'),
    file('talk', 'audio'),
  ];

  it('opens the second video from a boosted status and keeps the image gallery first', async () => {
    const onOpenVideo = jest.fn();
    const onOpenMedia = jest.fn();
    const boosted = base({ id: 'inner', media_attachments: attachments });
    const { container } = renderTimeline(boosted.merge({
      id: 'boost',
      account,
      reblog: boosted,
      media_attachments: [],
    }), { onOpenVideo, onOpenMedia });

    const videos = await screen.findAllByRole('button', { name: 'Expand video' });
    expect(videos).toHaveLength(2);
    expect(videos[0].getAttribute('data-src')).toBe('https://cdn.example/second-video');
    expect(videos[1].getAttribute('data-src')).toBe('https://cdn.example/first-video');
    expect(container.querySelector('.media-gallery img').getAttribute('alt')).toBe('photo');
    expect(container.querySelector('.status-media-stack')).not.toBeNull();
    expect(container.querySelector('audio').getAttribute('src')).toBe('https://cdn.example/talk');

    const gallery = container.querySelector('.media-gallery');
    expect(gallery.compareDocumentPosition(videos[0]) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();

    fireEvent.click(container.querySelector('.media-gallery__item-thumbnail'));
    expect(onOpenMedia.mock.calls[0][0]).toBe('inner');
    expect(onOpenMedia.mock.calls[0][1].map(item => item.get('id')).toArray()).toEqual(['photo']);
    expect(onOpenMedia.mock.calls[0][2]).toBe(0);

    fireEvent.click(videos[1]);
    expect(onOpenVideo.mock.calls[0][0]).toBe('inner');
    expect(onOpenVideo.mock.calls[0][1].get('id')).toBe('first-video');
    expect(onOpenVideo.mock.calls[0][2]).toEqual({ startTime: 2 });
  });

  it('stacks quoted players under the quoted images', async () => {
    const quote = base({
      id: 'quoted',
      media_attachments: [file('quote-audio', 'audio'), file('quote-photo', 'image')],
    });
    const { container } = renderTimeline(base({ quote }));

    const image = await screen.findByAltText('quote-photo');
    expect(image.closest('.quote-status')).not.toBeNull();
    const audio = container.querySelector('.quote-status audio');
    expect(audio.getAttribute('src')).toBe('https://cdn.example/quote-audio');
    expect(image.compareDocumentPosition(audio) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
  });

  it('keeps the muted timeline on the thumbnail gallery', async () => {
    const { container } = renderTimeline(base({ media_attachments: attachments }), { muted: true });

    await waitFor(() => {
      expect(container.querySelector('.thumbnail-gallery')).not.toBeNull();
    });
    expect(container.querySelector('audio')).toBeNull();
    expect(container.querySelector('[data-src]')).toBeNull();
    expect(screen.queryByRole('button', { name: 'Expand video' })).toBeNull();
  });

  it('replaces in-use picture-in-picture media with the placeholder', () => {
    const { container } = renderTimeline(base({ media_attachments: attachments }), {
      pictureInPicture: pictureInPicture.set('inUse', true),
    });

    expect(container.querySelector('.picture-in-picture-placeholder')).not.toBeNull();
    expect(container.querySelector('.media-gallery')).toBeNull();
    expect(container.querySelector('audio')).toBeNull();
  });

  it('does not load a sensitive audio file until it is revealed', async () => {
    const { container } = renderTimeline(base({
      sensitive: true,
      media_attachments: [file('secret', 'audio'), file('secret-photo', 'image')],
    }));

    expect(container.querySelector('audio')).toBeNull();
    expect(container.querySelector('img')).toBeNull();
    expect(container.innerHTML).not.toContain('https://cdn.example/secret');

    fireEvent.click(container.querySelector('.spoiler-button__overlay'));

    expect(await screen.findByAltText('secret-photo')).toBeTruthy();
    expect(container.querySelector('audio').getAttribute('src')).toBe('https://cdn.example/secret');
  });
});

const pressHotkey = (container, selector) => {
  global.__statusHotkeys.openMedia({
    preventDefault: jest.fn(),
    target: container.querySelector(selector),
  });
};

describe('media hotkey on a timeline status', () => {
  it('opens an image or GIF in the media modal', async () => {
    const onOpenMedia = jest.fn();
    const onOpenVideo = jest.fn();
    const { container } = renderTimeline(base({
      media_attachments: [file('loop', 'gifv'), file('photo', 'image')],
    }), { onOpenMedia, onOpenVideo });

    await screen.findByAltText('photo');
    pressHotkey(container, '.status__wrapper');

    expect(onOpenVideo).not.toHaveBeenCalled();
    expect(onOpenMedia.mock.calls[0][1].map(item => item.get('id')).toArray()).toEqual(['loop', 'photo']);
    expect(onOpenMedia.mock.calls[0][2]).toBe(0);
  });

  it('opens a video in the video modal', async () => {
    const onOpenMedia = jest.fn();
    const onOpenVideo = jest.fn();
    const { container } = renderTimeline(base({
      media_attachments: [file('talk', 'audio'), file('clip', 'video')],
    }), { onOpenMedia, onOpenVideo });

    await screen.findByRole('button', { name: 'Expand video' });
    pressHotkey(container, '.status__wrapper');

    expect(onOpenMedia).not.toHaveBeenCalled();
    expect(onOpenVideo.mock.calls[0][1].get('id')).toBe('clip');
    expect(onOpenVideo.mock.calls[0][2]).toEqual({ startTime: 0 });
  });

  it('focuses the audio player and does not open a modal', async () => {
    const onOpenMedia = jest.fn();
    const onOpenVideo = jest.fn();
    const { container } = renderTimeline(base({
      media_attachments: [file('talk', 'audio')],
    }), { onOpenMedia, onOpenVideo });

    await waitFor(() => {
      expect(container.querySelector('.audio-player')).not.toBeNull();
    });
    pressHotkey(container, '.status__wrapper');

    expect(onOpenMedia).not.toHaveBeenCalled();
    expect(onOpenVideo).not.toHaveBeenCalled();
    expect(document.activeElement.classList.contains('audio-player')).toBe(true);
  });

  it('focuses a safe unknown link and leaves an unsafe one alone', async () => {
    const onOpenMedia = jest.fn();
    const onOpenVideo = jest.fn();
    const safe = renderTimeline(base({
      media_attachments: [{
        id: 'gone',
        type: 'unknown',
        remote_url: 'https://remote.example/gone',
        description: 'Missing',
      }],
    }), { onOpenMedia, onOpenVideo });

    const link = await screen.findByRole('link', { name: 'Missing' });
    pressHotkey(safe.container, '.status__wrapper');
    expect(onOpenMedia).not.toHaveBeenCalled();
    expect(onOpenVideo).not.toHaveBeenCalled();
    expect(document.activeElement).toBe(link);

    const unsafe = renderTimeline(base({
      id: 'status-2',
      media_attachments: [{
        id: 'bad',
        type: 'unknown',
        remote_url: 'javascript:alert(1)',
        description: 'Bad',
      }],
    }), { onOpenMedia, onOpenVideo });
    await screen.findByRole('link', { name: 'Bad' });
    pressHotkey(unsafe.container, '.status__wrapper');
    expect(onOpenMedia).not.toHaveBeenCalled();
    expect(document.activeElement).not.toBe(unsafe.container.querySelector('a'));
  });
});

describe('media hotkey on the detail column', () => {
  const renderColumn = (attachments) => {
    const dispatch = jest.fn();
    const view = render(
      <Provider store={store}>
        <StatusColumn
          dispatch={dispatch}
          params={{ statusId: 'status-1' }}
          status={base({ media_attachments: attachments })}
          ancestorsIds={fromJS([])}
          descendantsIds={fromJS([])}
          intl={{
            formatMessage: ({ defaultMessage }, values) => {
              let message = defaultMessage || '';
              if (values) {
                Object.keys(values).forEach(key => {
                  message = message.replace(`{${key}}`, values[key]);
                });
              }
              return message;
            },
            formatDate: () => 'date',
            now: () => Date.now(),
          }}
          domain='example.test'
          pictureInPicture={pictureInPicture}
        />
      </Provider>,
    );
    return { ...view, dispatch };
  };

  const modalCalls = (dispatch) => dispatch.mock.calls
    .map(call => call[0])
    .filter(action => action && action.type === 'MODAL_OPEN');

  it('opens an image in MEDIA and a video in VIDEO', async () => {
    const images = renderColumn([file('loop', 'gifv'), file('photo', 'image')]);
    await screen.findByAltText('photo');
    pressHotkey(images.container, '.detailed-status__wrapper');
    expect(modalCalls(images.dispatch).map(action => action.modalType)).toEqual(['MEDIA']);
    expect(modalCalls(images.dispatch)[0].modalProps.media.map(item => item.get('id')).toArray()).toEqual(['loop', 'photo']);

    const videos = renderColumn([file('clip', 'video')]);
    await screen.findByRole('button', { name: 'Expand video' });
    pressHotkey(videos.container, '.detailed-status__wrapper');
    const opened = modalCalls(videos.dispatch);
    expect(opened.map(action => action.modalType)).toEqual(['VIDEO']);
    expect(opened[0].modalProps.media.get('id')).toBe('clip');
  });

  it('focuses audio and an unknown link without MODAL_OPEN', async () => {
    const audio = renderColumn([file('talk', 'audio')]);
    expect(audio.container.querySelector('.audio-player')).not.toBeNull();
    pressHotkey(audio.container, '.detailed-status__wrapper');
    expect(modalCalls(audio.dispatch)).toEqual([]);
    expect(document.activeElement.classList.contains('audio-player')).toBe(true);

    const unknown = renderColumn([{
      id: 'gone',
      type: 'unknown',
      remote_url: 'https://remote.example/gone',
      description: 'Missing',
    }]);
    const link = await screen.findByRole('link', { name: 'Missing' });
    pressHotkey(unknown.container, '.detailed-status__wrapper');
    expect(modalCalls(unknown.dispatch)).toEqual([]);
    expect(document.activeElement).toBe(link);
  });
});

describe('mixed attachments on a detailed status', () => {
  it('opens the second quoted video as that video', () => {
    const onOpenVideoQuote = jest.fn();
    const quote = base({
      id: 'quoted',
      media_attachments: [
        file('quote-video-a', 'video'),
        file('quote-photo', 'image'),
        file('quote-video-b', 'video'),
      ],
    });

    renderDetail(base({ quote, media_attachments: [] }), {
      showQuoteMedia: true,
      onOpenVideoQuote,
    });

    const videos = screen.getAllByRole('button', { name: 'Expand video' });
    expect(videos.map(node => node.getAttribute('data-src'))).toEqual([
      'https://cdn.example/quote-video-a',
      'https://cdn.example/quote-video-b',
    ]);
    expect(screen.getByAltText('quote-photo')).toBeTruthy();

    fireEvent.click(videos[1]);
    expect(onOpenVideoQuote.mock.calls[0][0].get('id')).toBe('quote-video-b');
    expect(onOpenVideoQuote.mock.calls[0][3]).toBe('quoted');
  });

  it('hides a detailed audio file while media is concealed', () => {
    const { container } = renderDetail(base({
      media_attachments: [file('detail-audio', 'audio')],
    }), { showMedia: false });

    expect(container.querySelector('audio')).toBeNull();
    expect(container.innerHTML).not.toContain('https://cdn.example/detail-audio');
    expect(screen.getByRole('button', { name: 'Media hidden' })).toBeTruthy();
  });
});
