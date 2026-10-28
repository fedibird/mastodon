/* eslint-disable react/prop-types */

import { fireEvent, render, screen } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';

jest.mock('../../initial_state', () => ({
  displayMedia: 'show_all',
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

jest.mock('mastodon/components/blurhash', () => () => null);
jest.mock('mastodon/components/thumbhash', () => () => null);
jest.mock('mastodon/components/alt_text_badge', () => () => null);

import MediaGallery from '../media_gallery';
import StatusMediaStack, {
  externalMediaBlocks,
  firstOpenableMedia,
  focusStatusAudio,
  focusStatusUnknownLink,
  openMediaFromHotkey,
  partitionStatusMedia,
} from '../status_media';

const attachment = (id, type, extra = {}) => fromJS({
  id,
  type,
  url: `https://cdn.example/${id}.${type === 'audio' ? 'mp3' : 'bin'}`,
  preview_url: `https://cdn.example/${id}.jpg`,
  remote_url: `https://remote.example/${id}`,
  description: `${id} alt`,
  ...extra,
});

class OpenAttachment extends React.PureComponent {

  handleClick = () => {
    this.props.onOpen(this.props.media, this.props.index);
  };

  render () {
    return (
      <button type='button' onClick={this.handleClick}>
        {this.props.id}
      </button>
    );
  }

}

class VideoProbe extends React.PureComponent {

  handleOpen = () => {
    this.props.onOpenVideo({ startTime: 3 });
  };

  render () {
    return (
      <button type='button' data-src={this.props.src} data-alt={this.props.alt || ''} onClick={this.handleOpen}>
        Expand video
      </button>
    );
  }

}

const AudioProbe = ({ src }) => <audio data-testid='audio' src={src} />;

const GalleryProbe = ({ media, onOpenMedia, quote }) => (
  <div data-testid='gallery' data-quote={quote ? 'yes' : 'no'}>
    {media.map((item, index) => (
      <OpenAttachment key={item.get('id')} id={item.get('id')} media={media} index={index} onOpen={onOpenMedia} />
    ))}
  </div>
);

const renderStack = (media, props = {}) => {
  const onOpenMedia = jest.fn();
  const onOpenVideo = jest.fn();

  const view = render(
    <StatusMediaStack
      media={fromJS(media)}
      Gallery={GalleryProbe}
      Video={VideoProbe}
      Audio={AudioProbe}
      onOpenMedia={onOpenMedia}
      onOpenVideo={onOpenVideo}
      visible
      height={110}
      {...props}
    />,
  );

  return { ...view, onOpenMedia, onOpenVideo };
};

describe('partitionStatusMedia', () => {
  const cases = [
    ['image then video', ['image', 'video'], ['image'], ['video']],
    ['video then image', ['video', 'image'], ['image'], ['video']],
    ['image, video, image, video, audio', ['image', 'video', 'image', 'video', 'audio'], ['image', 'image'], ['video', 'video', 'audio']],
    ['two videos', ['video', 'video'], [], ['video', 'video']],
    ['two audios', ['audio', 'audio'], [], ['audio', 'audio']],
    ['gifv, video, image', ['gifv', 'video', 'image'], ['gifv', 'image'], ['video']],
    ['two gifv', ['gifv', 'gifv'], ['gifv', 'gifv'], []],
    ['two images', ['image', 'image'], ['image', 'image'], []],
    ['image only', ['image'], ['image'], []],
    ['video only', ['video'], [], ['video']],
    ['audio only', ['audio'], [], ['audio']],
    ['no attachments', [], [], []],
    ['unknown then image', ['unknown', 'image'], ['image'], []],
  ];

  it.each(cases)('%s', (_name, types, gallery, players) => {
    const media = fromJS(types.map((type, index) => ({ id: `${type}-${index}`, type })));
    const parts = partitionStatusMedia(media);

    expect(parts.gallery.map(item => item.get('type')).toArray()).toEqual(gallery);
    expect(parts.players.map(item => item.get('type')).toArray()).toEqual(players);
    expect(parts.gallery.map(item => item.get('id')).toArray()).toEqual(
      types.map((type, index) => `${type}-${index}`).filter(id => gallery.includes(id.split('-')[0]) && id.split('-')[0] !== 'unknown'),
    );
  });

  it('keeps unknown placeholders after images so pictures are not crowded out', () => {
    const parts = partitionStatusMedia(fromJS([
      { id: 'missing', type: 'unknown' },
      { id: 'photo', type: 'image' },
      { id: 'other', type: 'unknown' },
    ]));

    expect(parts.gallery.map(item => item.get('id')).toArray()).toEqual(['photo']);
    expect(parts.unknown.map(item => item.get('id')).toArray()).toEqual(['missing', 'other']);
  });

  it('returns empty collections for a missing list', () => {
    const parts = partitionStatusMedia(undefined);

    expect(parts.gallery.size).toBe(0);
    expect(parts.players.size).toBe(0);
    expect(firstOpenableMedia(undefined)).toBeNull();
  });
});

describe('firstOpenableMedia', () => {
  const media = types => fromJS(types.map((type, index) => ({ id: `${type}-${index}`, type })));

  it('opens the image gallery when a video is stored first and does not treat a GIF as video', () => {
    const target = firstOpenableMedia(media(['video', 'gifv', 'image']));

    expect(target.kind).toBe('gallery');
    expect(target.index).toBe(0);
    expect(target.media.map(item => item.get('id')).toArray()).toEqual(['gifv-1', 'image-2']);
  });

  it('opens the first video when the post has no images', () => {
    const target = firstOpenableMedia(media(['audio', 'video', 'video']));

    expect(target.kind).toBe('video');
    expect(target.attachment.get('id')).toBe('video-1');
  });

  it('points at the first audio player and does not build a gallery list', () => {
    const target = firstOpenableMedia(media(['audio', 'audio']));

    expect(target.kind).toBe('audio');
    expect(target.attachment.get('id')).toBe('audio-0');
    expect(target.media).toBeUndefined();
  });

  it('does not treat an uncached file as a gallery page', () => {
    const target = firstOpenableMedia(media(['unknown']));

    expect(target.kind).toBe('unknown');
    expect(target.attachment.get('id')).toBe('unknown-0');
  });

  it('drops unknown files from the gallery hotkey list', () => {
    const target = firstOpenableMedia(fromJS([
      { id: 'gone', type: 'unknown' },
      { id: 'photo', type: 'image' },
    ]));

    expect(target.kind).toBe('gallery');
    expect(target.media.map(item => item.get('id')).toArray()).toEqual(['photo']);
  });
});

describe('openMediaFromHotkey', () => {
  const press = (attachments, root) => {
    const openGallery = jest.fn();
    const openVideo = jest.fn();
    const result = openMediaFromHotkey({ attachments, root, openGallery, openVideo });
    return { result, openGallery, openVideo };
  };

  it('opens image and GIF in the media modal and video in the video modal', () => {
    const images = fromJS([
      { id: 'clip', type: 'video' },
      { id: 'loop', type: 'gifv' },
      { id: 'photo', type: 'image' },
    ]);
    const gallery = press(images, null);
    expect(gallery.result).toBe('gallery');
    expect(gallery.openVideo).not.toHaveBeenCalled();
    expect(gallery.openGallery.mock.calls[0][0].map(item => item.get('id')).toArray()).toEqual(['loop', 'photo']);
    expect(gallery.openGallery.mock.calls[0][1]).toBe(0);

    const video = press(fromJS([{ id: 'clip', type: 'video' }, { id: 'talk', type: 'audio' }]), null);
    expect(video.result).toBe('video');
    expect(video.openGallery).not.toHaveBeenCalled();
    expect(video.openVideo.mock.calls[0][0].get('id')).toBe('clip');
    expect(video.openVideo.mock.calls[0][1]).toEqual({ startTime: 0 });
  });

  it('focuses the status audio player and skips a quoted one', () => {
    const { container } = render(
      <div>
        <div className='quote-status'><div className='audio-player' tabIndex='0' id='quoted' /></div>
        <div className='audio-player' tabIndex='0' id='own' />
      </div>,
    );
    const { result, openGallery, openVideo } = press(fromJS([{ id: 'talk', type: 'audio' }]), container);

    expect(result).toBe('audio');
    expect(openGallery).not.toHaveBeenCalled();
    expect(openVideo).not.toHaveBeenCalled();
    expect(document.activeElement.id).toBe('own');
  });

  it('focuses a hidden audio reveal control instead of opening a modal', () => {
    const { container } = render(
      <div className='status-media-stack__audio-hidden'><button type='button'>Media hidden</button></div>,
    );
    const { result, openGallery } = press(fromJS([{ id: 'talk', type: 'audio' }]), container);

    expect(result).toBe('audio');
    expect(openGallery).not.toHaveBeenCalled();
    expect(document.activeElement.textContent).toBe('Media hidden');
  });

  it('focuses an http unknown link and ignores a javascript link', () => {
    const safe = render(
      <div>
        <div className='quote-status'><a className='media-gallery__item-thumbnail' href='https://remote.example/quoted'>quoted</a></div>
        <a className='media-gallery__item-thumbnail' href='https://remote.example/gone'>gone</a>
      </div>,
    );
    expect(focusStatusUnknownLink(safe.container)).toBe(true);
    expect(document.activeElement.textContent).toBe('gone');

    const unsafeRoot = document.createElement('div');
    const unsafeLink = document.createElement('a');
    unsafeLink.className = 'media-gallery__item-thumbnail';
    unsafeLink.setAttribute('href', ['java', 'script:alert(1)'].join(''));
    unsafeLink.textContent = 'bad';
    unsafeRoot.appendChild(unsafeLink);
    document.body.appendChild(unsafeRoot);
    const pressed = press(fromJS([{ id: 'gone', type: 'unknown' }]), unsafeRoot);
    expect(pressed.result).toBe('unknown-inert');
    expect(pressed.openGallery).not.toHaveBeenCalled();
    expect(pressed.openVideo).not.toHaveBeenCalled();
    expect(document.activeElement).not.toBe(unsafeLink);
    document.body.removeChild(unsafeRoot);
  });

  it('does nothing when the audio player is not mounted', () => {
    const { result, openGallery, openVideo } = press(fromJS([{ id: 'talk', type: 'audio' }]), document.createElement('div'));

    expect(result).toBe('audio-unavailable');
    expect(openGallery).not.toHaveBeenCalled();
    expect(openVideo).not.toHaveBeenCalled();
    expect(focusStatusAudio(null)).toBe(false);
  });
});

describe('externalMediaBlocks', () => {
  it('returns null for a legacy payload without a sequence', () => {
    expect(externalMediaBlocks(fromJS({
      media_attachments: [],
      fedibird_external: { media: [{ id: 'talk', type: 'audio', url: 'https://cdn.example/talk.mp3' }] },
    }))).toBeNull();
  });

  it('groups images and GIFs first and keeps every later player in sequence order', () => {
    const blocks = externalMediaBlocks(fromJS({
      media_attachments: [
        { id: 'img-a', type: 'image' },
        { id: 'gif', type: 'gifv' },
        { id: 'vid', type: 'video' },
        { id: 'talk', type: 'audio' },
        { id: 'dup', type: 'image' },
      ],
      fedibird_external: {
        sequence: [
          { id: 'remote-video', type: 'video', delivery: 'remote' },
          { type: 'image', delivery: 'local', attachment_id: 'img-a' },
          { id: 'embed-1', type: 'embed', delivery: 'remote' },
          { type: 'video', delivery: 'local', attachment_id: 'vid' },
          { id: 'remote-audio', type: 'audio', delivery: 'remote' },
          { type: 'audio', delivery: 'local', attachment_id: 'talk' },
          { type: 'gifv', delivery: 'local', attachment_id: 'gif' },
          { type: 'image', delivery: 'local', attachment_id: 'missing' },
          { type: 'image', delivery: 'local', attachment_id: 'dup' },
          { type: 'image', delivery: 'local', attachment_id: 'dup' },
          { id: 'remote-video', type: 'video', delivery: 'remote' },
        ],
      },
    }));

    expect(blocks.map(block => block.kind)).toEqual(['images', 'remote', 'embed', 'video', 'remote', 'audio']);
    expect(blocks[0].items.map(item => item.get('id')).toArray()).toEqual(['img-a', 'gif', 'dup']);
    expect(blocks[1].entry.get('id')).toBe('remote-video');
    expect(blocks[3].attachment.get('id')).toBe('vid');
    expect(blocks[5].attachment.get('id')).toBe('talk');
  });
});

describe('StatusMediaStack', () => {
  it('puts images and GIFs in one gallery and stacks every player underneath', () => {
    const { container, onOpenMedia, onOpenVideo } = renderStack([
      attachment('vid-a', 'video'),
      attachment('photo-a', 'image'),
      attachment('loop', 'gifv'),
      attachment('vid-b', 'video'),
      attachment('photo-b', 'image'),
      attachment('talk-a', 'audio'),
      attachment('talk-b', 'audio'),
    ], { quote: true });

    expect(screen.getByTestId('gallery').textContent).toBe('photo-aloopphoto-b');
    expect(screen.getByTestId('gallery').getAttribute('data-quote')).toBe('yes');
    expect(container.querySelector('.status-media-stack')).not.toBeNull();
    expect(Array.from(container.querySelectorAll('[data-src], audio')).map(node => node.getAttribute('data-src') || node.getAttribute('src'))).toEqual([
      'https://cdn.example/vid-a.bin',
      'https://cdn.example/vid-b.bin',
      'https://cdn.example/talk-a.mp3',
      'https://cdn.example/talk-b.mp3',
    ]);

    fireEvent.click(screen.getAllByRole('button', { name: 'photo-b' })[0]);
    expect(onOpenMedia).toHaveBeenCalledTimes(1);
    const [opened, index] = onOpenMedia.mock.calls[0];
    expect(opened.map(item => item.get('id')).toArray()).toEqual(['photo-a', 'loop', 'photo-b']);
    expect(index).toBe(2);
    expect(opened.getIn([index, 'id'])).toBe('photo-b');

    fireEvent.click(screen.getAllByRole('button', { name: 'Expand video' })[1]);
    expect(onOpenVideo).toHaveBeenCalledTimes(1);
    expect(onOpenVideo.mock.calls[0][0].get('id')).toBe('vid-b');
    expect(onOpenVideo.mock.calls[0][1]).toEqual({ startTime: 3 });
  });

  it('renders one video without an extra stack wrapper', () => {
    const { container } = renderStack([attachment('only', 'video')]);

    expect(container.querySelector('.status-media-stack')).toBeNull();
    expect(screen.getByRole('button', { name: 'Expand video' }).getAttribute('data-src')).toBe('https://cdn.example/only.bin');
  });

  it('renders one image gallery without an extra stack wrapper', () => {
    const { container } = renderStack([
      attachment('a', 'image'),
      attachment('b', 'image'),
    ]);

    expect(container.querySelector('.status-media-stack')).toBeNull();
    expect(screen.getByTestId('gallery').textContent).toBe('ab');
  });

  it('shows every video even when there are more than the image cap', () => {
    renderStack(['1', '2', '3', '4', '5'].map(id => attachment(`vid-${id}`, 'video')));

    expect(screen.getAllByRole('button', { name: 'Expand video' })).toHaveLength(5);
  });

  it('does not write a hidden audio URL into the document', () => {
    const { container } = renderStack([
      attachment('talk', 'audio'),
    ], { visible: false, sensitive: true });

    expect(container.querySelector('audio')).toBeNull();
    expect(container.innerHTML).not.toContain('https://cdn.example/talk.mp3');
    expect(screen.getByRole('button', { name: 'Sensitive content' })).toBeTruthy();
  });

  it('passes translated alt text to each player', () => {
    renderStack([
      attachment('clip', 'video', { description: 'Cat', translation: { description: 'ねこ' } }),
    ], {
      translationMode: 'translated',
      sourceLang: 'en',
      targetLang: 'ja',
    });

    expect(screen.getByRole('button', { name: 'Expand video' }).getAttribute('data-alt')).toBe('ねこ');
  });

  it('lets the existing gallery cap images and still shows a video and an unknown file', () => {
    const media = fromJS([
      { id: 'v', type: 'video', url: 'https://cdn.example/v.mp4', preview_url: 'https://cdn.example/v.jpg', description: 'Clip' },
      ...['a', 'b', 'c', 'd', 'e'].map(id => ({
        id,
        type: 'image',
        url: `https://cdn.example/${id}.jpg`,
        preview_url: `https://cdn.example/${id}-small.jpg`,
        remote_url: `https://remote.example/${id}.jpg`,
        description: id,
        meta: { small: { width: 50, aspect: 1 }, original: { width: 100 }, focus: { x: 0, y: 0 } },
      })),
      { id: 'gone', type: 'unknown', remote_url: 'https://remote.example/gone', description: 'Missing' },
    ]);

    const { container } = render(
      <StatusMediaStack
        media={media}
        Gallery={MediaGallery}
        Video={VideoProbe}
        Audio={AudioProbe}
        onOpenMedia={jest.fn()}
        onOpenVideo={jest.fn()}
        visible
        height={110}
        defaultWidth={320}
      />,
    );

    const images = Array.from(container.querySelectorAll('.media-gallery img')).map(image => image.getAttribute('alt'));
    expect(images).toEqual(['a', 'b', 'c', 'd']);
    expect(container.querySelector('.media-gallery a[href="https://remote.example/gone"]')).toBeNull();
    expect(screen.getByRole('button', { name: 'Expand video' }).getAttribute('data-src')).toBe('https://cdn.example/v.mp4');
    expect(container.querySelector('.status-media-stack')).not.toBeNull();
  });

  it('keeps an unknown file link when there is no image to fill the cap', () => {
    const { container } = render(
      <StatusMediaStack
        media={fromJS([
          { id: 'gone', type: 'unknown', remote_url: 'https://remote.example/gone', description: 'Missing' },
          { id: 'talk', type: 'audio', url: 'https://cdn.example/talk.mp3', description: 'Talk' },
        ])}
        Gallery={MediaGallery}
        Video={VideoProbe}
        Audio={AudioProbe}
        onOpenMedia={jest.fn()}
        onOpenVideo={jest.fn()}
        visible
        height={110}
        defaultWidth={320}
      />,
    );

    expect(container.querySelector('.media-gallery a').getAttribute('href')).toBe('https://remote.example/gone');
    expect(container.querySelector('audio').getAttribute('src')).toBe('https://cdn.example/talk.mp3');
  });

  it('opens only image and GIF pages, including images past the gallery cap', () => {
    const onOpenMedia = jest.fn();
    const media = fromJS([
      ...['a', 'b', 'c', 'd', 'e'].map(id => ({
        id,
        type: 'image',
        url: `https://cdn.example/${id}.jpg`,
        preview_url: `https://cdn.example/${id}-small.jpg`,
        remote_url: `https://remote.example/${id}.jpg`,
        description: id,
        meta: { small: { width: 50, aspect: 1 }, original: { width: 100 }, focus: { x: 0, y: 0 } },
      })),
      { id: 'gone', type: 'unknown', remote_url: 'https://remote.example/gone', url: 'https://cdn.example/gone', description: 'Missing' },
      { id: 'loop', type: 'gifv', url: 'https://cdn.example/loop.mp4', preview_url: 'https://cdn.example/loop.jpg', description: 'Loop' },
    ]);
    const { container } = render(
      <StatusMediaStack
        media={media}
        Gallery={MediaGallery}
        Video={VideoProbe}
        Audio={AudioProbe}
        onOpenMedia={onOpenMedia}
        onOpenVideo={jest.fn()}
        visible
        height={110}
        defaultWidth={320}
      />,
    );

    expect(container.querySelectorAll('.media-gallery img')).toHaveLength(4);
    fireEvent.click(container.querySelectorAll('.media-gallery__item-thumbnail')[3]);

    const [opened, index] = onOpenMedia.mock.calls[0];
    expect(opened.map(item => item.get('type')).toArray().every(type => type === 'image' || type === 'gifv')).toBe(true);
    expect(opened.map(item => item.get('id')).toArray()).toEqual(['a', 'b', 'c', 'd', 'e', 'loop']);
    expect(index).toBe(3);
    expect(opened.getIn([index, 'id'])).toBe('d');
  });
});
