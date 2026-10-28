import React from 'react';
import PropTypes from 'prop-types';
import ImmutablePropTypes from 'react-immutable-proptypes';
import { List as ImmutableList } from 'immutable';
import { FormattedMessage } from 'react-intl';
import Bundle from '../features/ui/components/bundle';
import { MediaGallery, Video, Audio } from '../features/ui/util/async-components';
import { attachmentAccessibility } from 'mastodon/utils/translation_view';

// image and gifv stay in one gallery. gifv is a muted looping video inside
// that gallery, not a standalone player. video and audio keep their original
// relative order and render as full-width players under the gallery.
// MediaGallery still applies maxAttachments to the gallery list. Players are
// not capped: every video and audio attachment is shown.
const GALLERY_TYPES = {
  image: true,
  gifv: true,
};

const PLAYER_TYPES = {
  video: true,
  audio: true,
};

const noop = () => {};

const read = (item, key) => {
  if (!item) {
    return undefined;
  }

  return typeof item.get === 'function' ? item.get(key) : item[key];
};

const attachmentList = (media) => (
  media && typeof media.forEach === 'function' ? media : ImmutableList()
);

export const isGalleryType = (type) => !!GALLERY_TYPES[type];

export const isPlayerType = (type) => !!PLAYER_TYPES[type];

export const partitionStatusMedia = (media) => {
  const gallery = [];
  const unknown = [];
  const players = [];

  attachmentList(media).forEach(attachment => {
    if (!attachment || typeof attachment.get !== 'function') {
      return;
    }

    const type = attachment.get('type');
    if (isPlayerType(type)) {
      players.push(attachment);
    } else if (isGalleryType(type)) {
      gallery.push(attachment);
    } else {
      unknown.push(attachment);
    }
  });

  return {
    gallery: ImmutableList(gallery),
    unknown: ImmutableList(unknown),
    players: ImmutableList(players),
  };
};

// Images and GIF keep their relative order and come before uncached
// placeholders so a long unknown run cannot push a picture out of the gallery.
export const galleryMediaFor = (parts) => parts.gallery.concat(parts.unknown);

export const firstOpenableMedia = (media) => {
  const parts = partitionStatusMedia(media);
  const gallery = galleryMediaFor(parts);

  if (parts.gallery.size > 0) {
    return { kind: 'gallery', media: gallery, index: 0 };
  }

  const video = parts.players.find(attachment => attachment.get('type') === 'video');
  if (video) {
    return { kind: 'video', attachment: video };
  }

  if (gallery.size > 0) {
    return { kind: 'gallery', media: gallery, index: 0 };
  }

  if (parts.players.size > 0) {
    return { kind: 'audio', media: parts.players, index: 0 };
  }

  return null;
};

const remember = (seen, id) => {
  if (id === undefined || id === null || id === '') {
    return true;
  }

  const key = String(id);
  if (seen[key]) {
    return false;
  }

  seen[key] = true;
  return true;
};

// One image/GIF gallery, then video, audio, remote players, and embeds in
// sequence order. A missing local file is skipped. A repeated attachment id
// is drawn once. Returns null when the payload has no sequence.
export const externalMediaBlocks = (status) => {
  const sequence = status && status.getIn && status.getIn(['fedibird_external', 'sequence']);
  if (!sequence || typeof sequence.forEach !== 'function' || sequence.size === 0) {
    return null;
  }

  const attachments = {};
  const media = (status.get && status.get('media_attachments')) || ImmutableList();
  if (media && typeof media.forEach === 'function') {
    media.forEach(item => {
      if (!item || typeof item.get !== 'function') {
        return;
      }

      const id = item.get('id');
      if (id === undefined || id === null || id === '') {
        return;
      }

      attachments[String(id)] = item;
    });
  }

  const seen = {};
  const images = [];
  const unknown = [];
  const players = [];

  sequence.forEach(entry => {
    const type = read(entry, 'type');
    const delivery = read(entry, 'delivery');

    if (delivery === 'local') {
      const attachmentId = read(entry, 'attachment_id');
      const attachment = attachments[String(attachmentId)];
      if (!attachment || !remember(seen, attachment.get('id'))) {
        return;
      }

      const attachmentType = attachment.get('type') || type;
      if (isPlayerType(attachmentType)) {
        players.push({ kind: attachmentType, attachment });
      } else if (isGalleryType(attachmentType)) {
        images.push(attachment);
      } else {
        unknown.push(attachment);
      }
      return;
    }

    if (delivery === 'remote' && type === 'embed') {
      if (remember(seen, read(entry, 'id'))) {
        players.push({ kind: 'embed', entry });
      }
      return;
    }

    if (delivery === 'remote' && isPlayerType(type)) {
      if (remember(seen, read(entry, 'id'))) {
        players.push({ kind: 'remote', entry });
      }
    }
  });

  const blocks = [];
  const gallery = images.concat(unknown);
  if (gallery.length > 0) {
    blocks.push({ kind: 'images', items: ImmutableList(gallery) });
  }

  return blocks.concat(players);
};

const LoadingGallery = () => <div className='media-gallery' style={{ height: '110px' }} />;

const LoadingVideo = () => <div className='video-player' style={{ height: '110px' }} />;

const LoadingAudio = () => <div className='audio-player' style={{ height: '110px' }} />;

const AudioConcealed = ({ sensitive, onToggleVisibility }) => (
  <div className='status-media-stack__audio-hidden'>
    <button type='button' className='spoiler-button__overlay' onClick={onToggleVisibility}>
      <span className='spoiler-button__overlay__label'>
        {sensitive ? (
          <FormattedMessage id='status.sensitive_warning' defaultMessage='Sensitive content' />
        ) : (
          <FormattedMessage id='status.media_hidden' defaultMessage='Media hidden' />
        )}
      </span>
    </button>
  </div>
);

AudioConcealed.propTypes = {
  sensitive: PropTypes.bool,
  onToggleVisibility: PropTypes.func,
};

export const LocalMediaPlayer = ({
  attachment,
  Video: VideoComponent,
  Audio: AudioComponent,
  sensitive,
  visible,
  onToggleVisibility,
  onOpenVideo,
  width,
  height,
  audioHeight,
  cacheWidth,
  deployPictureInPicture,
  posterFallback,
  quote,
  translationMode,
  sourceLang,
  targetLang,
}) => {
  const described = attachmentAccessibility(attachment, {
    mode: translationMode,
    sourceLang,
    targetLang,
  });
  const type = attachment.get('type');

  if (type === 'audio') {
    if (visible === false) {
      return <AudioConcealed sensitive={sensitive} onToggleVisibility={onToggleVisibility} />;
    }

    return (
      <AudioComponent
        src={attachment.get('url')}
        alt={described.text}
        lang={described.lang}
        poster={attachment.get('preview_url') || posterFallback}
        backgroundColor={attachment.getIn(['meta', 'colors', 'background'])}
        foregroundColor={attachment.getIn(['meta', 'colors', 'foreground'])}
        accentColor={attachment.getIn(['meta', 'colors', 'accent'])}
        duration={attachment.getIn(['meta', 'original', 'duration'], 0)}
        width={width}
        height={audioHeight || height}
        cacheWidth={cacheWidth}
        deployPictureInPicture={deployPictureInPicture}
      />
    );
  }

  return (
    <VideoComponent
      preview={attachment.get('preview_url')}
      frameRate={attachment.getIn(['meta', 'original', 'frame_rate'])}
      thumbhash={attachment.get('thumbhash')}
      blurhash={attachment.get('blurhash')}
      src={attachment.get('url')}
      alt={described.text}
      lang={described.lang}
      width={width}
      height={height}
      inline
      sensitive={sensitive}
      onOpenVideo={onOpenVideo}
      cacheWidth={cacheWidth}
      deployPictureInPicture={deployPictureInPicture}
      visible={visible}
      onToggleVisibility={onToggleVisibility}
      quote={quote}
    />
  );
};

LocalMediaPlayer.propTypes = {
  attachment: ImmutablePropTypes.map.isRequired,
  Video: PropTypes.func,
  Audio: PropTypes.func,
  sensitive: PropTypes.bool,
  visible: PropTypes.bool,
  onToggleVisibility: PropTypes.func,
  onOpenVideo: PropTypes.func,
  width: PropTypes.number,
  height: PropTypes.number,
  audioHeight: PropTypes.number,
  cacheWidth: PropTypes.func,
  deployPictureInPicture: PropTypes.func,
  posterFallback: PropTypes.string,
  quote: PropTypes.bool,
  translationMode: PropTypes.string,
  sourceLang: PropTypes.string,
  targetLang: PropTypes.string,
};

export default class StatusMediaStack extends React.PureComponent {

  static propTypes = {
    media: ImmutablePropTypes.list,
    sensitive: PropTypes.bool,
    visible: PropTypes.bool,
    onToggleVisibility: PropTypes.func,
    onOpenMedia: PropTypes.func,
    onOpenVideo: PropTypes.func,
    height: PropTypes.number,
    videoHeight: PropTypes.number,
    audioHeight: PropTypes.number,
    defaultWidth: PropTypes.number,
    cacheWidth: PropTypes.func,
    standalone: PropTypes.bool,
    quote: PropTypes.bool,
    lang: PropTypes.string,
    translationMode: PropTypes.string,
    sourceLang: PropTypes.string,
    targetLang: PropTypes.string,
    deployPictureInPicture: PropTypes.func,
    posterFallback: PropTypes.string,
    Gallery: PropTypes.func,
    Video: PropTypes.func,
    Audio: PropTypes.func,
  };

  static defaultProps = {
    height: 110,
  };

  openPlayer = (attachment) => (options) => {
    if (this.props.onOpenVideo) {
      this.props.onOpenVideo(attachment, options);
    }
  };

  usesProvidedPlayers () {
    return !!(this.props.Gallery && this.props.Video && this.props.Audio);
  }

  renderGallery (key, media, Gallery) {
    return (
      <Gallery
        key={key}
        media={media}
        sensitive={this.props.sensitive}
        height={this.props.height}
        onOpenMedia={this.props.onOpenMedia || noop}
        defaultWidth={this.props.defaultWidth}
        cacheWidth={this.props.cacheWidth}
        visible={this.props.visible}
        onToggleVisibility={this.props.onToggleVisibility}
        standalone={this.props.standalone}
        quote={this.props.quote}
        lang={this.props.lang}
        translationMode={this.props.translationMode}
        sourceLang={this.props.sourceLang}
        targetLang={this.props.targetLang}
      />
    );
  }

  renderPlayer (attachment, components, key) {
    const height = attachment.get('type') === 'audio'
      ? (this.props.audioHeight || this.props.height)
      : (this.props.videoHeight || this.props.height);

    return (
      <LocalMediaPlayer
        key={key}
        attachment={attachment}
        Video={components.Video}
        Audio={components.Audio}
        sensitive={this.props.sensitive}
        visible={this.props.visible}
        onToggleVisibility={this.props.onToggleVisibility}
        onOpenVideo={this.openPlayer(attachment)}
        width={this.props.defaultWidth}
        height={height}
        audioHeight={this.props.audioHeight || height}
        cacheWidth={this.props.cacheWidth}
        deployPictureInPicture={this.props.deployPictureInPicture}
        posterFallback={this.props.posterFallback}
        quote={this.props.quote}
        translationMode={this.props.translationMode}
        sourceLang={this.props.sourceLang}
        targetLang={this.props.targetLang}
      />
    );
  }

  renderResolvedPlayer = (attachment, Component) => {
    const components = attachment.get('type') === 'audio'
      ? { Audio: Component, Video: this.props.Video }
      : { Video: Component, Audio: this.props.Audio };

    return this.renderPlayer(attachment, components);
  };

  renderGalleryNode (key, media) {
    if (this.usesProvidedPlayers()) {
      return this.renderGallery(key, media, this.props.Gallery);
    }

    return (
      <Bundle key={key} fetchComponent={MediaGallery} loading={LoadingGallery}>
        {Gallery => this.renderGallery(key, media, Gallery)}
      </Bundle>
    );
  }

  renderPlayerNode (attachment, index) {
    const key = `${attachment.get('id')}-${index}`;
    if (this.usesProvidedPlayers()) {
      return this.renderPlayer(attachment, {
        Video: this.props.Video,
        Audio: this.props.Audio,
      }, key);
    }

    const audio = attachment.get('type') === 'audio';
    return (
      <Bundle
        key={key}
        fetchComponent={audio ? Audio : Video}
        loading={audio ? LoadingAudio : LoadingVideo}
      >
        {Component => this.renderResolvedPlayer(attachment, Component)}
      </Bundle>
    );
  }

  render () {
    const parts = partitionStatusMedia(this.props.media);
    const gallery = galleryMediaFor(parts);
    const blockCount = (gallery.size > 0 ? 1 : 0) + parts.players.size;

    if (blockCount === 0) {
      return null;
    }

    const nodes = [];
    if (gallery.size > 0) {
      nodes.push(this.renderGalleryNode('gallery', gallery));
    }
    parts.players.forEach((attachment, index) => {
      nodes.push(this.renderPlayerNode(attachment, index));
    });

    if (blockCount === 1) {
      return nodes[0];
    }

    return (
      <div className='status-media-stack'>
        {nodes}
      </div>
    );
  }

}
