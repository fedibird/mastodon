import { fireEvent, render, screen } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';

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

const status = ({ sequence, attachments }) => fromJS({
  id: '1',
  media_attachments: attachments,
  fedibird_external: { sequence },
});

describe('ExternalStatusMedia', () => {
  it('shows images and a saved video in article order', () => {
    const { container } = render(
      <ExternalStatusMedia status={status({
        attachments: [
          { id: 'img', type: 'image', url: 'https://cb.example/system/img.png', description: 'Still' },
          { id: 'vid', type: 'video', url: 'https://cb.example/system/clip.webm', description: 'Clip' },
        ],
        sequence: [
          { type: 'image', delivery: 'local', attachment_id: 'img', position: 0 },
          { type: 'video', delivery: 'local', attachment_id: 'vid', position: 1 },
        ],
      })}
      />,
    );

    expect(screen.getByTestId('gallery').textContent).toBe('img');
    const video = container.querySelector('video');
    expect(video.getAttribute('src')).toBe('https://cb.example/system/clip.webm');
    expect(container.querySelector('button')).toBeNull();
  });

  it('keeps a remote video between images and withholds its URL until click', () => {
    const { container } = render(
      <ExternalStatusMedia status={status({
        attachments: [
          { id: 'before', type: 'image', url: 'https://cb.example/system/a.png' },
          { id: 'after', type: 'image', url: 'https://cb.example/system/b.png' },
        ],
        sequence: [
          { type: 'image', delivery: 'local', attachment_id: 'before', position: 0 },
          { id: 'remote-clip', type: 'video', delivery: 'remote', url: 'https://cdn.example/clip.mp4', position: 1 },
          { type: 'image', delivery: 'local', attachment_id: 'after', position: 2 },
        ],
      })}
      />,
    );

    expect(screen.getAllByTestId('gallery').map(node => node.textContent)).toEqual(['before', 'after']);
    expect(container.querySelector('video')).toBeNull();
    expect(container.innerHTML).not.toContain('https://cdn.example/clip.mp4');

    fireEvent.click(screen.getByRole('button'));
    expect(container.querySelector('video').getAttribute('src')).toBe('https://cdn.example/clip.mp4');
  });

  it('replaces a remote player that errors with the media and article links', () => {
    const { container } = render(
      <ExternalStatusMedia status={fromJS({
        id: '1',
        media_attachments: [],
        fedibird_external: {
          canonical_url: 'https://example.com/story',
          sequence: [
            { id: 'remote-clip', type: 'video', delivery: 'remote', url: 'https://cdn.example/clip.mp4', position: 0 },
          ],
        },
      })}
      />,
    );

    expect(container.innerHTML).not.toContain('https://cdn.example/clip.mp4');
    fireEvent.click(screen.getByRole('button'));
    fireEvent.error(container.querySelector('video'));

    expect(container.querySelector('video')).toBeNull();
    expect(screen.getByRole('link', { name: 'Open media file' }).getAttribute('href')).toBe('https://cdn.example/clip.mp4');
    expect(screen.getByRole('link', { name: 'Open article' }).getAttribute('href')).toBe('https://example.com/story');
  });

  it('passes the article URL when media is present and sequence is not', () => {
    const { container } = render(
      <ExternalStatusMedia status={fromJS({
        id: '1',
        media_attachments: [],
        fedibird_external: {
          canonical_url: 'https://example.com/legacy-story',
          media: [
            { id: 'talk', type: 'audio', url: 'https://cdn.example/talk.mp3' },
          ],
        },
      })}
      />,
    );

    expect(container.querySelector('audio')).toBeNull();
    expect(container.innerHTML).not.toContain('https://cdn.example/talk.mp3');

    fireEvent.click(screen.getByRole('button', { name: 'External audio' }));
    const audio = container.querySelector('audio');
    expect(audio.getAttribute('src')).toBe('https://cdn.example/talk.mp3');
    expect(audio.hasAttribute('autoplay')).toBe(false);

    fireEvent.error(audio);

    expect(container.querySelector('audio')).toBeNull();
    expect(screen.getByRole('link', { name: 'Open media file' }).getAttribute('href')).toBe('https://cdn.example/talk.mp3');
    expect(screen.getByRole('link', { name: 'Open article' }).getAttribute('href')).toBe('https://example.com/legacy-story');
  });

  it('keeps saved audio and a remote file out of the document while sensitive content is hidden', () => {
    const { container } = render(
      <ExternalStatusMedia
        sensitive
        visible={false}
        status={status({
          attachments: [
            { id: 'talk', type: 'audio', url: 'https://cb.example/system/talk.mp3', preview_url: 'https://cb.example/system/poster.jpg' },
          ],
          sequence: [
            { type: 'audio', delivery: 'local', attachment_id: 'talk', position: 0 },
            { id: 'remote-clip', type: 'video', delivery: 'remote', url: 'https://cdn.example/clip.mp4', position: 1 },
          ],
        })}
      />,
    );

    expect(container.querySelector('audio')).toBeNull();
    expect(container.querySelector('video')).toBeNull();
    expect(container.innerHTML).not.toContain('cb.example');
    expect(container.innerHTML).not.toContain('cdn.example');
    expect(screen.getAllByRole('button').length).toBeGreaterThan(0);
  });

  it('does not write a legacy remote URL while sensitive content is hidden', () => {
    const { container } = render(
      <ExternalStatusMedia
        sensitive
        visible={false}
        status={fromJS({
          id: '1',
          media_attachments: [],
          fedibird_external: {
            canonical_url: 'https://example.com/story',
            media: [
              { id: 'talk', type: 'audio', url: 'https://cdn.example/talk.mp3' },
            ],
          },
        })}
      />,
    );

    expect(container.querySelector('audio')).toBeNull();
    expect(container.innerHTML).not.toContain('cdn.example');
    expect(container.innerHTML).not.toContain('example.com/story');

    fireEvent.click(screen.getByRole('button'));
    expect(container.innerHTML).not.toContain('cdn.example');
  });

  it('drops an unsafe article URL on a payload that has media and no sequence', () => {
    const { container } = render(
      <ExternalStatusMedia status={fromJS({
        id: '1',
        media_attachments: [],
        fedibird_external: {
          canonical_url: 'javascript:alert(1)',
          media: [
            { id: 'talk', type: 'audio', url: 'https://cdn.example/talk.mp3' },
          ],
        },
      })}
      />,
    );

    fireEvent.click(screen.getByRole('button', { name: 'External audio' }));
    fireEvent.error(container.querySelector('audio'));

    expect(screen.getByRole('link', { name: 'Open media file' }).getAttribute('href')).toBe('https://cdn.example/talk.mp3');
    expect(screen.queryByRole('link', { name: 'Open article' })).toBeNull();
  });
});
