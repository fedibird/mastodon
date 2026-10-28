import { fireEvent, render, screen } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';

jest.mock('mastodon/initial_state', () => {
  const settings = { displayMedia: 'default', useBlurhash: true };
  global.__externalMediaHashSettings = settings;
  return {
    get displayMedia() {
      return settings.displayMedia;
    },
    get useBlurhash() {
      return settings.useBlurhash;
    },
  };
});

jest.mock('react-intl', () => ({
  FormattedMessage: ({ defaultMessage }) => defaultMessage,
}));

/* eslint-disable react/prop-types */
jest.mock('mastodon/components/media_gallery', () => ({ media, visible }) => (
  <div data-testid='gallery' data-visible={String(visible)} data-thumbhash={media.map(item => item.get('thumbhash') || '').join('|')} data-blurhash={media.map(item => item.get('blurhash') || '').join('|')}>
    {visible === false ? null : <img alt='' src={media.getIn([0, 'preview_url'])} />}
  </div>
));

jest.mock('mastodon/features/video', () => ({ thumbhash, blurhash, visible, src, preview }) => (
  <div data-testid='saved-video' data-visible={String(visible)} data-thumbhash={thumbhash || ''} data-blurhash={blurhash || ''}>
    {visible === false ? null : <video src={src} poster={preview} />}
  </div>
));

jest.mock('mastodon/features/audio', () => ({ src }) => <audio src={src} />);

jest.mock('mastodon/components/thumbhash', () => ({ hash, dummy, className }) => (
  <canvas data-testid='thumbhash' data-hash={hash} data-dummy={dummy ? 'yes' : 'no'} className={className} />
));

jest.mock('mastodon/components/blurhash', () => ({ hash, dummy, className }) => (
  <canvas data-testid='blurhash' data-hash={hash} data-dummy={dummy ? 'yes' : 'no'} className={className} />
));
/* eslint-enable react/prop-types */

import ExternalStatusMedia from '../external_status_media';
import { connectedPlayerNodes, resetExternalPlayersForTests } from 'mastodon/external_player/session';

afterEach(() => {
  resetExternalPlayersForTests();
});

const THUMB = '3OcRJYB4d3hwiIeHeEh3eIhw';
const BLUR = 'LEHV6nWB2yk8pyo0adR*.7kCMdnj';
const OTHER = 'YJqGPQw7sFlsl9l9h3eIeHiPd4h3iIAH';
const CLIP = 'https://cdn.example/clip.mp4';
const OTHER_CLIP = 'https://cdn.example/other.mp4';
const PLAYER = 'https://player.example/embed/abc123';
const POSTER = 'https://cb.example/system/poster.png';

const settings = () => global.__externalMediaHashSettings;

const status = ({ sequence, attachments, media, canonical }) => fromJS({
  id: 'story',
  media_attachments: attachments || [],
  fedibird_external: {
    canonical_url: canonical || 'https://watch.example/watch?id=abc123',
    sequence,
    media,
  },
});

const mixed = () => status({
  attachments: [
    { id: 'img', type: 'image', url: 'https://cb.example/system/still.png', preview_url: 'https://cb.example/system/still-small.png', thumbhash: 'image-thumb', blurhash: 'image-blur' },
    { id: 'vid', type: 'video', url: 'https://cb.example/system/clip.webm', preview_url: 'https://cb.example/system/clip.jpg', thumbhash: 'video-thumb', blurhash: 'video-blur' },
  ],
  sequence: [
    { type: 'image', delivery: 'local', attachment_id: 'img', position: 0 },
    { type: 'video', delivery: 'local', attachment_id: 'vid', position: 1 },
    { id: 'remote-clip', type: 'video', delivery: 'remote', url: CLIP, position: 2, poster_thumbhash: THUMB, poster_blurhash: BLUR },
    { id: 'rss-embed', type: 'embed', delivery: 'remote', url: PLAYER, poster: POSTER, position: 3, poster_blurhash: BLUR },
    { id: 'remote-plain', type: 'video', delivery: 'remote', url: OTHER_CLIP, position: 4 },
    { id: 'remote-audio', type: 'audio', delivery: 'remote', url: 'https://cdn.example/talk.mp3', position: 5, poster_thumbhash: 'https://cdn.example/should-not-load' },
  ],
});

describe('ExternalStatusMedia sensitive hashes', () => {
  beforeEach(() => {
    settings().displayMedia = 'default';
    settings().useBlurhash = true;
  });

  it('keeps saved files on the existing gallery and video, and paints only a real hash while concealed', () => {
    const toggle = jest.fn();
    const { container } = render(
      <ExternalStatusMedia sensitive visible={false} onToggleVisibility={toggle} status={mixed()} />,
    );

    const gallery = screen.getByTestId('gallery');
    expect(gallery.getAttribute('data-visible')).toBe('false');
    expect(gallery.getAttribute('data-thumbhash')).toBe('image-thumb');
    expect(gallery.getAttribute('data-blurhash')).toBe('image-blur');
    expect(gallery.querySelector('img')).toBeNull();

    const saved = screen.getByTestId('saved-video');
    expect(saved.getAttribute('data-visible')).toBe('false');
    expect(saved.getAttribute('data-thumbhash')).toBe('video-thumb');
    expect(saved.getAttribute('data-blurhash')).toBe('video-blur');
    expect(saved.querySelector('video')).toBeNull();

    const thumbs = screen.getAllByTestId('thumbhash');
    expect(thumbs).toHaveLength(1);
    expect(thumbs[0].getAttribute('data-hash')).toBe(THUMB);
    expect(thumbs[0].getAttribute('data-dummy')).toBe('no');
    expect(screen.getByTestId('blurhash').getAttribute('data-hash')).toBe(BLUR);
    expect(container.querySelectorAll('.external-status-media__concealed')).toHaveLength(2);
    expect(container.querySelector('iframe')).toBeNull();
    expect(container.querySelector('img')).toBeNull();
    expect(container.innerHTML).not.toContain(CLIP);
    expect(container.innerHTML).not.toContain(OTHER_CLIP);
    expect(container.innerHTML).not.toContain(PLAYER);
    expect(container.innerHTML).not.toContain(POSTER);
    expect(container.innerHTML).not.toContain('https://cdn.example/talk.mp3');
    expect(container.innerHTML).not.toContain('https://cdn.example/should-not-load');

    const reveal = screen.getAllByRole('button', { name: 'Sensitive content' })[2];
    reveal.focus();
    expect(document.activeElement).toBe(reveal);
    fireEvent.click(reveal);
    expect(toggle).toHaveBeenCalledTimes(1);
  });

  it('leaves the hash unpainted when blurhash placeholders are disabled', () => {
    settings().useBlurhash = false;
    render(<ExternalStatusMedia sensitive visible={false} status={mixed()} />);

    expect(screen.getByTestId('thumbhash').getAttribute('data-dummy')).toBe('yes');
    expect(screen.getByTestId('blurhash').getAttribute('data-dummy')).toBe('yes');
    expect(document.body.innerHTML).not.toContain(CLIP);
  });

  it('arms a remote file only after the sensitive media is revealed', () => {
    const remote = status({
      sequence: [
        { id: 'remote-clip', type: 'video', delivery: 'remote', url: CLIP, poster_thumbhash: THUMB },
      ],
    });
    const view = render(<ExternalStatusMedia sensitive visible={false} status={remote} />);

    expect(view.container.querySelector('video')).toBeNull();
    expect(view.container.innerHTML).not.toContain(CLIP);

    view.rerender(<ExternalStatusMedia visible status={remote} />);
    expect(view.container.querySelector('[data-testid="thumbhash"]')).toBeNull();
    expect(view.container.querySelector('video')).toBeNull();
    expect(view.container.innerHTML).not.toContain(CLIP);

    fireEvent.click(screen.getByRole('button', { name: 'External video' }));
    const video = connectedPlayerNodes('video')[0];
    expect(view.container.querySelector('video')).toBeNull();
    expect(video.getAttribute('src')).toBe(CLIP);
    expect(video.hasAttribute('autoplay')).toBe(false);
  });

  it('mounts an embed only after reveal and keeps autoplay off', () => {
    const embed = status({
      sequence: [
        { id: 'rss-embed', type: 'embed', delivery: 'remote', url: PLAYER, poster: POSTER, poster_blurhash: BLUR, duration: 61 },
      ],
    });
    const view = render(<ExternalStatusMedia sensitive visible={false} status={embed} />);
    expect(view.container.querySelector('iframe')).toBeNull();
    expect(view.container.querySelector('img')).toBeNull();
    expect(view.container.innerHTML).not.toContain(PLAYER);
    expect(view.container.innerHTML).not.toContain(POSTER);

    view.rerender(<ExternalStatusMedia visible status={embed} />);
    expect(view.container.querySelector('iframe')).toBeNull();
    expect(view.container.querySelector('img').getAttribute('src')).toBe(POSTER);
    fireEvent.click(screen.getByRole('button', { name: 'External video 1:01' }));
    const frame = connectedPlayerNodes('iframe')[0];
    expect(view.container.querySelector('iframe')).toBeNull();
    expect(frame.getAttribute('src')).toBe(PLAYER);
    expect(frame.getAttribute('allow')).not.toContain('autoplay');
    expect(frame.hasAttribute('autoplay')).toBe(false);
  });

  it('switches the placeholder when the same status changes sensitivity or hash', () => {
    const first = status({
      sequence: [{ id: 'remote-clip', type: 'video', delivery: 'remote', url: CLIP, poster_thumbhash: THUMB }],
    });
    const second = status({
      sequence: [{ id: 'remote-clip', type: 'video', delivery: 'remote', url: CLIP, poster_blurhash: OTHER }],
    });
    const view = render(<ExternalStatusMedia sensitive visible={false} status={first} />);
    expect(screen.getByTestId('thumbhash').getAttribute('data-hash')).toBe(THUMB);

    view.rerender(<ExternalStatusMedia sensitive visible={false} status={second} />);
    expect(screen.queryByTestId('thumbhash')).toBeNull();
    expect(screen.getByTestId('blurhash').getAttribute('data-hash')).toBe(OTHER);
    expect(view.container.innerHTML).not.toContain(CLIP);

    view.rerender(<ExternalStatusMedia visible status={second} />);
    expect(screen.queryByTestId('blurhash')).toBeNull();
    expect(screen.getByRole('button', { name: 'External video' })).toBeTruthy();
    expect(view.container.querySelector('video')).toBeNull();
  });

  it('hides every remote file when the display setting is hide all, and shows it for show all', () => {
    settings().displayMedia = 'hide_all';
    const remote = status({
      sequence: [{ id: 'remote-clip', type: 'video', delivery: 'remote', url: CLIP, poster_thumbhash: THUMB }],
    });
    const hidden = render(<ExternalStatusMedia status={remote} />);
    expect(screen.getByRole('button', { name: 'Media hidden' })).toBeTruthy();
    expect(screen.getByTestId('thumbhash')).toBeTruthy();
    expect(hidden.container.innerHTML).not.toContain(CLIP);

    settings().displayMedia = 'show_all';
    const shown = render(<ExternalStatusMedia sensitive status={remote} />);
    expect(shown.container.querySelector('[data-testid="thumbhash"]')).toBeNull();
    expect(screen.getByRole('button', { name: 'External video' })).toBeTruthy();
    expect(shown.container.querySelector('video')).toBeNull();
    expect(shown.container.innerHTML).not.toContain(CLIP);
  });

  it('shows one legacy hash and skips a combined placeholder when several files are hidden', () => {
    const one = fromJS({
      id: 'story',
      media_attachments: [],
      fedibird_external: {
        media: [{ id: 'clip', type: 'video', url: CLIP, poster_thumbhash: THUMB }],
      },
    });
    const single = render(<ExternalStatusMedia sensitive visible={false} status={one} />);
    expect(single.container.querySelector('[data-testid="thumbhash"]').getAttribute('data-hash')).toBe(THUMB);
    expect(single.container.innerHTML).not.toContain(CLIP);

    const many = fromJS({
      id: 'story',
      media_attachments: [],
      fedibird_external: {
        media: [
          { id: 'clip', type: 'video', url: CLIP, poster_thumbhash: THUMB },
          { id: 'other', type: 'video', url: OTHER_CLIP, poster_thumbhash: OTHER },
        ],
      },
    });
    const combined = render(<ExternalStatusMedia sensitive visible={false} status={many} />);
    expect(combined.container.querySelector('canvas')).toBeNull();
    expect(combined.container.querySelector('button')).not.toBeNull();
    expect(combined.container.innerHTML).not.toContain(CLIP);
    expect(combined.container.innerHTML).not.toContain(OTHER_CLIP);
  });
});
