import React from 'react';
import PropTypes from 'prop-types';
import ImmutablePropTypes from 'react-immutable-proptypes';
import { List as ImmutableList } from 'immutable';
import { FormattedMessage } from 'react-intl';
import Bundle from '../features/ui/components/bundle';
import { MediaGallery, Video, Audio } from '../features/ui/util/async-components';
import { attachmentAccessibility } from 'mastodon/utils/translation_view';
import { displayMedia } from '../initial_state';

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

// Same rule as MediaGallery and Video. Public pages do not pass `visible`,
// so the stack has to decide before an <audio src> is written.
export const publicMediaVisible = (sensitive, mode = displayMedia) => (
  mode !== 'hide_all' && !sensitive || mode === 'show_all'
);

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
// The media modal only draws image, gifv, and video, so unknown stays in the
// gallery for the link and is not part of the modal list.
export const galleryMediaFor = (parts) => parts.gallery.concat(parts.unknown);

const SAFE_PAGE_LINK = /^https?:\/\//i;

export const firstOpenableMedia = (media) => {
  const parts = partitionStatusMedia(media);

  if (parts.gallery.size > 0) {
    return { kind: 'gallery', media: parts.gallery, index: 0 };
  }

  const video = parts.players.find(attachment => attachment.get('type') === 'video');
  if (video) {
    return { kind: 'video', attachment: video };
  }

  const audio = parts.players.find(attachment => attachment.get('type') === 'audio');
  if (audio) {
    return { kind: 'audio', attachment: audio };
  }

  if (parts.unknown.size > 0) {
    return { kind: 'unknown', attachment: parts.unknown.get(0) };
  }

  return null;
};

export const hotkeyMediaRoot = (event, fallback) => {
  const target = event && event.target;
  if (target && typeof target.closest === 'function') {
    const scoped = target.closest('.detailed-status__wrapper')
      || target.closest('.status__wrapper')
      || target.closest('.detailed-status')
      || target.closest('.status');
    if (scoped) {
      return scoped;
    }
  }

  return fallback || null;
};

const outsideQuote = (node) => !(node.closest && node.closest('.quote-status'));

export const focusStatusAudio = (root) => {
  if (!root || typeof root.querySelectorAll !== 'function') {
    return false;
  }

  const nodes = root.querySelectorAll('.audio-player, .status-media-stack__audio-hidden button');
  for (let i = 0; i < nodes.length; i += 1) {
    const node = nodes[i];
    if (!outsideQuote(node) || typeof node.focus !== 'function') {
      continue;
    }

    node.focus();
    return true;
  }

  return false;
};

// Unknown has no lightbox frame. Focus the http(s) link the gallery already
// rendered. A missing or non-http(s) href is left alone so the hotkey cannot
// open an empty modal or follow a javascript: URL.
export const focusStatusUnknownLink = (root) => {
  if (!root || typeof root.querySelectorAll !== 'function') {
    return false;
  }

  const links = root.querySelectorAll('a.media-gallery__item-thumbnail');
  for (let i = 0; i < links.length; i += 1) {
    const link = links[i];
    if (!outsideQuote(link) || typeof link.focus !== 'function') {
      continue;
    }

    const href = link.getAttribute('href') || '';
    if (!SAFE_PAGE_LINK.test(href)) {
      continue;
    }

    link.focus();
    return true;
  }

  return false;
};

export const openMediaFromHotkey = ({ attachments, root, openGallery, openVideo }) => {
  const target = firstOpenableMedia(attachments);
  if (!target) {
    return 'none';
  }

  if (target.kind === 'gallery') {
    if (openGallery) {
      openGallery(target.media, target.index);
    }
    return 'gallery';
  }

  if (target.kind === 'video') {
    if (openVideo) {
      openVideo(target.attachment, { startTime: 0 });
    }
    return 'video';
  }

  if (target.kind === 'audio') {
    return focusStatusAudio(root) ? 'audio' : 'audio-unavailable';
  }

  if (target.kind === 'unknown') {
    return focusStatusUnknownLink(root) ? 'unknown' : 'unknown-inert';
  }

  return 'none';
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

class AudioConcealed extends React.PureComponent {

  handleClick = (event) => {
    event.preventDefault();
    event.stopPropagation();

    if (this.props.onToggleVisibility) {
      this.props.onToggleVisibility();
    }
  };

  render () {
    const { sensitive } = this.props;

    return (
      <div className='status-media-stack__audio-hidden'>
        <button type='button' className='spoiler-button__overlay' onClick={this.handleClick}>
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
  }

}

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
  detailed,
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
      detailed={detailed}
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
  detailed: PropTypes.bool,
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
    detailed: PropTypes.bool,
    autoplay: PropTypes.bool,
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

  // Public Haml leaves `visible` unset. Owning it here keeps a sensitive or
  // hide_all audio file out of the document until the visitor asks for it.
  // A parent that passes `visible` (the signed-in WebUI) stays in charge.
  state = {
    revealed: publicMediaVisible(this.props.sensitive),
  };

  componentWillReceiveProps (nextProps) {
    if (nextProps.visible === undefined && nextProps.sensitive !== this.props.sensitive) {
      this.setState({ revealed: publicMediaVisible(nextProps.sensitive) });
    }
  }

  toggleRevealed = () => {
    this.setState(({ revealed }) => ({ revealed: !revealed }));
  };

  visibility () {
    if (this.props.visible !== undefined) {
      return {
        visible: this.props.visible,
        onToggleVisibility: this.props.onToggleVisibility,
      };
    }

    return {
      visible: this.state.revealed,
      onToggleVisibility: this.toggleRevealed,
    };
  }

  openPlayer = (attachment) => (options) => {
    if (this.props.onOpenVideo) {
      this.props.onOpenVideo(attachment, options);
    }
  };

  usesProvidedPlayers () {
    return !!(this.props.Gallery && this.props.Video && this.props.Audio);
  }

  renderGallery (key, media, Gallery) {
    const visibility = this.visibility();

    return (
      <Gallery
        key={key}
        media={media}
        sensitive={this.props.sensitive}
        height={this.props.height}
        onOpenMedia={this.props.onOpenMedia || noop}
        defaultWidth={this.props.defaultWidth}
        cacheWidth={this.props.cacheWidth}
        autoplay={this.props.autoplay}
        visible={visibility.visible}
        onToggleVisibility={visibility.onToggleVisibility}
        standalone={this.props.standalone}
        quote={this.props.quote}
        lang={this.props.lang}
        translationMode={this.props.translationMode}
        sourceLang={this.props.sourceLang}
        targetLang={this.props.targetLang}
      />
    );
  }

  renderPlayer (attachment, components, key, videoCount) {
    const height = attachment.get('type') === 'audio'
      ? (this.props.audioHeight || this.props.height)
      : (this.props.videoHeight || this.props.height);
    const visibility = this.visibility();
    // `detailed` also sets autoFocus on every play button. One video may
    // take that. Several would fight for focus while the page hydrates.
    const detailed = !!this.props.detailed && attachment.get('type') === 'video' && videoCount === 1;

    return (
      <LocalMediaPlayer
        key={key}
        attachment={attachment}
        Video={components.Video}
        Audio={components.Audio}
        sensitive={this.props.sensitive}
        visible={visibility.visible}
        onToggleVisibility={visibility.onToggleVisibility}
        onOpenVideo={this.openPlayer(attachment)}
        width={this.props.defaultWidth}
        height={height}
        audioHeight={this.props.audioHeight || height}
        cacheWidth={this.props.cacheWidth}
        deployPictureInPicture={this.props.deployPictureInPicture}
        posterFallback={this.props.posterFallback}
        quote={this.props.quote}
        detailed={detailed}
        translationMode={this.props.translationMode}
        sourceLang={this.props.sourceLang}
        targetLang={this.props.targetLang}
      />
    );
  }

  renderResolvedPlayer = (attachment, Component, videoCount) => {
    const components = attachment.get('type') === 'audio'
      ? { Audio: Component, Video: this.props.Video }
      : { Video: Component, Audio: this.props.Audio };

    return this.renderPlayer(attachment, components, undefined, videoCount);
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

  renderPlayerNode (attachment, index, videoCount) {
    const key = `${attachment.get('id')}-${index}`;
    if (this.usesProvidedPlayers()) {
      return this.renderPlayer(attachment, {
        Video: this.props.Video,
        Audio: this.props.Audio,
      }, key, videoCount);
    }

    const audio = attachment.get('type') === 'audio';
    return (
      <Bundle
        key={key}
        fetchComponent={audio ? Audio : Video}
        loading={audio ? LoadingAudio : LoadingVideo}
      >
        {Component => this.renderResolvedPlayer(attachment, Component, videoCount)}
      </Bundle>
    );
  }

  render () {
    const parts = partitionStatusMedia(this.props.media);
    const gallery = galleryMediaFor(parts);
    const blockCount = (gallery.size > 0 ? 1 : 0) + parts.players.size;
    const videoCount = parts.players.filter(attachment => attachment.get('type') === 'video').size;

    if (blockCount === 0) {
      return null;
    }

    const nodes = [];
    if (gallery.size > 0) {
      nodes.push(this.renderGalleryNode('gallery', gallery));
    }
    parts.players.forEach((attachment, index) => {
      nodes.push(this.renderPlayerNode(attachment, index, videoCount));
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
