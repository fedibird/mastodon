import { fireEvent, render, screen } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';

jest.mock('mastodon/components/blurhash', () => () => null);
jest.mock('mastodon/components/thumbhash', () => () => null);

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

const image = (id) => ({ id, type: 'image', url: `https://cb.example/system/${id}.png`, description: id });

const mixedStatus = (visibleProps = {}) => fromJS({
  id: 'mixed',
  sensitive: visibleProps.sensitive || false,
  spoiler_text: visibleProps.spoiler || '',
  media_attachments: [
    image('img-3'),
    image('poster'),
    image('img-1'),
    image('img-2'),
  ],
  fedibird_external: {
    canonical_url: 'https://example.com/mixed-story',
    sequence: [
      { type: 'image', delivery: 'local', attachment_id: 'img-1', position: 0, description: 'One' },
      { id: 'clip-a', type: 'video', delivery: 'remote', url: 'https://cdn.example/mixed-secret/clip-a.mp4', description: 'Clip A', position: 1 },
      { type: 'image', delivery: 'local', attachment_id: 'img-2', position: 2, description: 'Two' },
      { id: 'clip-b', type: 'video', delivery: 'remote', url: 'https://cdn.example/mixed-secret/clip-b.mp4', description: 'Clip B', position: 3 },
      { type: 'image', delivery: 'local', attachment_id: 'img-3', position: 4, description: 'Three' },
      { id: 'talk', type: 'audio', delivery: 'remote', url: 'https://cdn.example/mixed-secret/talk.mp3', description: 'Talk', position: 5 },
    ],
  },
});

const blockOrder = (container) => (
  Array.from(container.querySelectorAll('[data-testid="gallery"], .external-remote-media, .external-embed-player, video, audio'))
    .map(node => node.getAttribute('data-testid') || node.className || node.tagName.toLowerCase())
);

describe('ExternalStatusMedia RSS mixed attachments', () => {
  it('lifts the three images and stacks the two videos and the audio in candidate order', () => {
    const { container } = render(<ExternalStatusMedia visible status={mixedStatus()} />);

    expect(screen.getByTestId('gallery').textContent).toBe('img-1,img-2,img-3');
    expect(screen.getByTestId('gallery').textContent).not.toContain('poster');
    expect(container.innerHTML).not.toContain('mixed-secret');
    expect(blockOrder(container)).toEqual([
      'gallery',
      'external-remote-media',
      'external-remote-media',
      'external-remote-media',
    ]);

    fireEvent.click(screen.getByRole('button', { name: /Clip B/ }));
    expect(container.querySelector('video').getAttribute('src')).toBe('https://cdn.example/mixed-secret/clip-b.mp4');
    expect(container.innerHTML).not.toContain('clip-a.mp4');
    expect(container.innerHTML).not.toContain('talk.mp3');
  });

  it('does not mount remote sources while the article is sensitive or behind a content warning', () => {
    const hidden = render(
      <ExternalStatusMedia sensitive visible={false} status={mixedStatus({ sensitive: true, spoiler: 'CW' })} />,
    );

    expect(hidden.container.querySelector('video')).toBeNull();
    expect(hidden.container.querySelector('audio')).toBeNull();
    expect(hidden.container.querySelector('iframe')).toBeNull();
    expect(hidden.container.innerHTML).not.toContain('mixed-secret');
    expect(hidden.container.innerHTML).not.toContain('cdn.example');

    hidden.rerender(<ExternalStatusMedia sensitive visible status={mixedStatus({ sensitive: true, spoiler: 'CW' })} />);
    fireEvent.click(screen.getByRole('button', { name: /Clip A/ }));
    expect(hidden.container.querySelector('video').getAttribute('src')).toBe('https://cdn.example/mixed-secret/clip-a.mp4');
    expect(hidden.container.innerHTML).not.toContain('clip-b.mp4');
  });

  it('keeps a saved video, a remote video, audio, and one embed in sequence order', () => {
    const status = fromJS({
      id: 'hybrid',
      media_attachments: [
        { id: 'saved', type: 'video', url: 'https://cb.example/system/saved.webm', description: 'Saved' },
      ],
      fedibird_external: {
        canonical_url: 'https://watch.example.com/watch?id=abc123',
        sequence: [
          { type: 'video', delivery: 'local', attachment_id: 'saved', position: 0, description: 'Saved' },
          { id: 'remote-b', type: 'video', delivery: 'remote', url: 'https://cdn.example/mixed-secret/clip-b.mp4', description: 'Remote', position: 1 },
          { id: 'talk', type: 'audio', delivery: 'remote', url: 'https://cdn.example/mixed-secret/talk.mp3', description: 'Talk', position: 2 },
          { id: 'player', type: 'embed', delivery: 'remote', url: 'https://player.example.com/embed/abc123', position: 3 },
        ],
      },
    });
    const { container } = render(<ExternalStatusMedia visible status={status} />);

    expect(container.querySelector('video').getAttribute('src')).toBe('https://cb.example/system/saved.webm');
    expect(container.innerHTML).not.toContain('clip-b.mp4');
    expect(container.innerHTML).not.toContain('talk.mp3');
    expect(container.querySelector('iframe')).toBeNull();
    expect(blockOrder(container)).toEqual([
      'video',
      'external-remote-media',
      'external-remote-media',
      'external-embed-player',
    ]);

    const remoteButtons = screen.getAllByRole('button', { name: /External video/ });
    fireEvent.click(remoteButtons[0]);
    const sources = Array.from(container.querySelectorAll('video')).map(node => node.getAttribute('src'));
    expect(sources).toEqual([
      'https://cb.example/system/saved.webm',
      'https://cdn.example/mixed-secret/clip-b.mp4',
    ]);
    expect(container.querySelector('iframe')).toBeNull();
    expect(container.innerHTML).not.toContain('talk.mp3');
  });
});
