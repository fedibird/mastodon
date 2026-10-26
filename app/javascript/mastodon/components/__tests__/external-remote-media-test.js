import { fireEvent, render, screen } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';

import ExternalRemoteMedia from '../external_remote_media';

jest.mock('react-intl', () => ({
  FormattedMessage: ({ defaultMessage }) => defaultMessage,
}));

const status = (media) => fromJS({
  id: '1',
  fedibird_external: { media },
});

describe('ExternalRemoteMedia', () => {
  it('does not put a remote video URL in the document until the owner clicks', () => {
    const { container } = render(
      <ExternalRemoteMedia status={status([
        { id: 'clip', type: 'video', url: 'https://cdn.example/clip.mp4', description: 'Clip', delivery: 'remote', external: true },
      ])}
      />,
    );

    expect(container.querySelector('video')).toBeNull();
    expect(container.querySelector('audio')).toBeNull();
    expect(container.innerHTML).not.toContain('https://cdn.example/clip.mp4');

    fireEvent.click(screen.getByRole('button'));

    const video = container.querySelector('video');
    expect(video).not.toBeNull();
    expect(video.getAttribute('src')).toBe('https://cdn.example/clip.mp4');
    expect(video.hasAttribute('autoplay')).toBe(false);
    expect(video.getAttribute('preload')).toBe('none');
    expect(video.getAttribute('referrerpolicy')).toBe('no-referrer');

    fireEvent.error(video);

    expect(container.querySelector('video')).toBeNull();
    expect(container.innerHTML).not.toContain('src="https://cdn.example/clip.mp4"');
    const mediaLink = screen.getByRole('link', { name: 'Open media file' });
    expect(mediaLink.getAttribute('href')).toBe('https://cdn.example/clip.mp4');
    expect(mediaLink.getAttribute('rel')).toBe('noopener noreferrer');
  });

  it('offers the article after playback fails and drops an unsafe article URL', () => {
    const { container } = render(
      <ExternalRemoteMedia
        articleUrl='javascript:alert(1)'
        status={status([
          { id: 'clip', type: 'audio', url: 'https://cdn.example/talk.mp3' },
        ])}
      />,
    );

    fireEvent.click(screen.getByRole('button'));
    fireEvent.error(container.querySelector('audio'));

    expect(container.querySelector('audio')).toBeNull();
    expect(screen.getByRole('link', { name: 'Open media file' }).getAttribute('href')).toBe('https://cdn.example/talk.mp3');
    expect(screen.queryByRole('link', { name: 'Open article' })).toBeNull();
  });

  it('drops a javascript URL and renders nothing', () => {
    const { container } = render(
      <ExternalRemoteMedia status={status([
        { id: 'bad', type: 'video', url: 'javascript:alert(1)' },
      ])}
      />,
    );

    expect(container.querySelector('button')).toBeNull();
    expect(container.querySelector('video')).toBeNull();
  });
});
