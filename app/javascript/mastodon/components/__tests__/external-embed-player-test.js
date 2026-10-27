import { fireEvent, render, screen } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';

jest.mock('mastodon/components/blurhash', () => () => null);
jest.mock('mastodon/components/thumbhash', () => () => null);

import { formatDuration } from '../external_embed_player';
import ExternalStatusMedia from '../external_status_media';

jest.mock('react-intl', () => ({
  FormattedMessage: ({ defaultMessage }) => defaultMessage,
}));

/* eslint-disable react/prop-types */
jest.mock('mastodon/components/media_gallery', () => ({ media }) => (
  <div data-testid='gallery'>{media.map(item => item.get('id')).join(',')}</div>
));

jest.mock('mastodon/features/video', () => ({ src, visible }) => (
  visible === false ? null : <video src={src} />
));

jest.mock('mastodon/features/audio', () => ({ src }) => <audio src={src} />);
/* eslint-enable react/prop-types */

const player = 'https://player.example/embed/abc123';
const poster = 'https://cb.example/system/poster.png';

const status = (sequence, extra = {}) => fromJS({
  id: '1',
  media_attachments: extra.attachments || [],
  fedibird_external: {
    canonical_url: 'https://watch.example/watch?id=abc123',
    sequence,
    ...extra.external,
  },
});

describe('formatDuration', () => {
  it('renders seconds as a clock', () => {
    expect(formatDuration(0)).toBe('0:00');
    expect(formatDuration(59)).toBe('0:59');
    expect(formatDuration(61)).toBe('1:01');
    expect(formatDuration(1081)).toBe('18:01');
    expect(formatDuration(3600)).toBe('1:00:00');
    expect(formatDuration(-1)).toBeNull();
    expect(formatDuration(172801)).toBeNull();
  });
});

describe('ExternalStatusMedia embed player', () => {
  const sequence = [
    { type: 'image', delivery: 'local', attachment_id: 'still', position: 0 },
    {
      id: 'rss-embed',
      type: 'embed',
      delivery: 'remote',
      url: player,
      poster,
      duration: 1081,
      position: 1,
      external: true,
    },
    { id: 'remote-clip', type: 'video', delivery: 'remote', url: 'https://cdn.example/clip.mp4', position: 2 },
  ];

  it('shows the poster and duration and mounts the iframe only after a click', () => {
    const { container } = render(
      <ExternalStatusMedia
        visible
        status={status(sequence, {
          attachments: [{ id: 'still', type: 'image', url: 'https://cb.example/system/still.png' }],
        })}
      />,
    );

    expect(screen.getByTestId('gallery').textContent).toBe('still');
    expect(container.querySelector('iframe')).toBeNull();
    expect(container.innerHTML).not.toContain(player);
    expect(screen.getByText('18:01')).toBeTruthy();
    expect(container.querySelector('img').getAttribute('src')).toBe(poster);
    expect(screen.getByRole('link', { name: 'Open article' }).getAttribute('href')).toBe('https://watch.example/watch?id=abc123');

    fireEvent.click(screen.getByRole('button', { name: 'External video 18:01' }));

    const frame = container.querySelector('iframe');
    expect(frame.getAttribute('src')).toBe(player);
    expect(frame.getAttribute('sandbox')).toContain('allow-scripts');
    expect(frame.getAttribute('sandbox')).not.toContain('allow-top-navigation');
    expect(frame.getAttribute('referrerpolicy')).toBe('no-referrer');
    expect(frame.getAttribute('allow')).not.toContain('autoplay');
    expect(frame.hasAttribute('autoplay')).toBe(false);
    expect(container.querySelector('video')).toBeNull();
  });

  it('removes the iframe when the media is concealed again or the status is removed', () => {
    const view = render(
      <ExternalStatusMedia visible status={status(sequence.slice(1, 2))} />,
    );

    fireEvent.click(screen.getByRole('button', { name: 'External video 18:01' }));
    expect(view.container.querySelector('iframe')).not.toBeNull();

    view.rerender(<ExternalStatusMedia visible={false} sensitive status={status(sequence.slice(1, 2))} />);
    expect(view.container.querySelector('iframe')).toBeNull();
    expect(view.container.innerHTML).not.toContain(player);

    view.rerender(<ExternalStatusMedia visible status={status(sequence.slice(1, 2))} />);
    fireEvent.click(screen.getByRole('button', { name: 'External video 18:01' }));
    expect(view.container.querySelector('iframe')).not.toBeNull();
    view.unmount();
    expect(view.container.querySelector('iframe')).toBeNull();
  });

  it('does not request a signed poster or a javascript player before or after a click', () => {
    const { container } = render(
      <ExternalStatusMedia
        visible
        status={status([
          {
            id: 'rss-embed',
            type: 'embed',
            delivery: 'remote',
            url: 'javascript:alert(1)',
            poster: 'https://images.example/plain/rs:fit:320:240?hash=token&validto=10',
            duration: 1081,
          },
        ], { external: { canonical_url: 'javascript:alert(1)' } })}
      />,
    );

    expect(container.querySelector('iframe')).toBeNull();
    expect(container.querySelector('img')).toBeNull();
    expect(container.querySelector('button')).toBeNull();
    expect(container.innerHTML).not.toContain('hash=token');
    expect(screen.queryByRole('link', { name: 'Open article' })).toBeNull();
  });
});
