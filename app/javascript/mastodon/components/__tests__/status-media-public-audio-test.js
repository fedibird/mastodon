/* eslint-disable react/prop-types */

import { fireEvent, render, screen } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';

const mockMediaState = { displayMedia: 'default' };

jest.mock('../../initial_state', () => ({
  get displayMedia() {
    return mockMediaState.displayMedia;
  },
  autoPlayMedia: false,
  cropImages: true,
  useBlurhash: false,
  useLowResolutionThumbnails: false,
  maxAttachments: 4,
}));

jest.mock('react-intl', () => ({
  injectIntl: Component => props => <Component {...props} intl={{ formatMessage: ({ defaultMessage }) => defaultMessage }} />,
  defineMessages: messages => messages,
  FormattedMessage: ({ defaultMessage }) => defaultMessage,
}));

import StatusMediaStack from '../status_media';
import { handlePublicQuoteClick } from 'mastodon/utils/public_quote_navigation';

const attachment = (id, type) => fromJS({
  id,
  type,
  url: `https://cdn.example/${id}.${type === 'audio' ? 'mp3' : 'bin'}`,
  preview_url: `https://cdn.example/${id}.jpg`,
  description: `${id} alt`,
});

const AudioProbe = ({ src }) => <audio className='audio-player' data-testid='audio' src={src} />;

const VideoProbe = ({ detailed, src }) => (
  <button type='button' className='video-player' autoFocus={!!detailed} data-detailed={detailed ? 'yes' : 'no'} data-src={src}>
    Play
  </button>
);

const GalleryProbe = ({ media }) => (
  <div className='media-gallery' data-testid='gallery'>
    {media.map(item => item.get('id')).join(',')}
  </div>
);

const renderPublic = (media, props = {}) => render(
  <StatusMediaStack
    media={fromJS(media)}
    Gallery={GalleryProbe}
    Video={VideoProbe}
    Audio={AudioProbe}
    onOpenMedia={jest.fn()}
    onOpenVideo={jest.fn()}
    height={110}
    {...props}
  />,
);

describe('public StatusMediaStack audio visibility', () => {
  let open;

  beforeEach(() => {
    mockMediaState.displayMedia = 'default';
    open = jest.fn();
    window.open = open;
    document.addEventListener('click', handlePublicQuoteClick);
  });

  afterEach(() => {
    document.removeEventListener('click', handlePublicQuoteClick);
  });

  it('keeps a sensitive audio URL out of the document until the visitor reveals it', () => {
    const { container } = renderPublic([attachment('talk', 'audio')], { sensitive: true });

    expect(container.querySelector('audio')).toBeNull();
    expect(container.innerHTML).not.toContain('https://cdn.example/talk.mp3');

    fireEvent.click(screen.getByRole('button', { name: 'Sensitive content' }));

    expect(container.querySelector('audio').getAttribute('src')).toBe('https://cdn.example/talk.mp3');
  });

  it('hides every audio URL when several are attached and the post is sensitive', () => {
    const { container } = renderPublic([
      attachment('talk-a', 'audio'),
      attachment('talk-b', 'audio'),
    ], { sensitive: true });

    expect(container.querySelectorAll('audio')).toHaveLength(0);
    expect(container.innerHTML).not.toContain('.mp3');
    expect(screen.getAllByRole('button', { name: 'Sensitive content' })).toHaveLength(2);

    fireEvent.click(screen.getAllByRole('button', { name: 'Sensitive content' })[0]);

    expect(Array.from(container.querySelectorAll('audio')).map(node => node.getAttribute('src'))).toEqual([
      'https://cdn.example/talk-a.mp3',
      'https://cdn.example/talk-b.mp3',
    ]);
  });

  it('hides the audio under a picture without writing its URL', () => {
    const { container } = renderPublic([
      attachment('photo', 'image'),
      attachment('talk', 'audio'),
    ], { sensitive: true });

    expect(screen.getByTestId('gallery').textContent).toBe('photo');
    expect(container.querySelector('audio')).toBeNull();
    expect(container.innerHTML).not.toContain('https://cdn.example/talk.mp3');
  });

  it('hides audio when the visitor hides all media, and shows it when they show all', () => {
    mockMediaState.displayMedia = 'hide_all';
    const hidden = renderPublic([attachment('talk', 'audio')], { sensitive: false });
    expect(hidden.container.querySelector('audio')).toBeNull();
    expect(screen.getByRole('button', { name: 'Media hidden' })).toBeTruthy();
    hidden.unmount();

    mockMediaState.displayMedia = 'show_all';
    const shown = renderPublic([attachment('talk', 'audio')], { sensitive: true });
    expect(shown.container.querySelector('audio').getAttribute('src')).toBe('https://cdn.example/talk.mp3');
  });

  it('follows a parent visibility flag instead of the public default', () => {
    const onToggleVisibility = jest.fn();
    const { container } = renderPublic([attachment('talk', 'audio')], {
      sensitive: true,
      visible: false,
      onToggleVisibility,
    });

    expect(container.querySelector('audio')).toBeNull();
    fireEvent.click(screen.getByRole('button', { name: 'Sensitive content' }));
    expect(onToggleVisibility).toHaveBeenCalledTimes(1);
    expect(container.querySelector('audio')).toBeNull();
  });

  it('does not open the quote from a concealed audio control, a player, or a video', () => {
    const onQuote = jest.fn();
    const { container } = render(
      {/* eslint-disable-next-line jsx-a11y/no-static-element-interactions, jsx-a11y/click-events-have-key-events */}
      <div className='quote-status' dataurl='https://remote.example/users/bob/1' onClick={onQuote}>
        <p>Quoted text</p>
        <StatusMediaStack
          media={fromJS([
            attachment('talk', 'audio'),
            attachment('clip', 'video'),
          ])}
          Gallery={GalleryProbe}
          Video={VideoProbe}
          Audio={AudioProbe}
          onOpenMedia={jest.fn()}
          onOpenVideo={jest.fn()}
          sensitive
          quote
          height={110}
        />
      </div>,
    );

    fireEvent.click(screen.getByRole('button', { name: 'Sensitive content' }));
    expect(open).not.toHaveBeenCalled();
    expect(onQuote).not.toHaveBeenCalled();
    expect(container.querySelector('audio').getAttribute('src')).toBe('https://cdn.example/talk.mp3');

    fireEvent.click(container.querySelector('audio'));
    fireEvent.click(screen.getByRole('button', { name: 'Play' }));
    expect(open).not.toHaveBeenCalled();

    fireEvent.click(screen.getByText('Quoted text'));
    expect(open).toHaveBeenCalledWith('https://remote.example/users/bob/1', 'blank');
  });

  it('autoFocuses a single detailed video and none of several videos', () => {
    const single = renderPublic([attachment('only', 'video')], { detailed: true });
    expect(single.container.querySelector('[data-detailed="yes"]')).not.toBeNull();
    expect(document.activeElement).toBe(single.container.querySelector('button'));
    single.unmount();

    const many = renderPublic([
      attachment('clip-a', 'video'),
      attachment('clip-b', 'video'),
    ], { detailed: true });
    expect(many.container.querySelector('[data-detailed="yes"]')).toBeNull();
    expect(many.container.querySelectorAll('[data-detailed="no"]')).toHaveLength(2);
    expect(document.activeElement).not.toBe(many.container.querySelector('button'));
  });
});
