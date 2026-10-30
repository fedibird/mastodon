import React from 'react';
import PropTypes from 'prop-types';
import ImmutablePropTypes from 'react-immutable-proptypes';
import { fromJS } from 'immutable';
import { FormattedMessage } from 'react-intl';
import MediaGallery from 'mastodon/components/media_gallery';
import Blurhash from 'mastodon/components/blurhash';
import Thumbhash from 'mastodon/components/thumbhash';
import ExternalRemoteMedia, { remoteMediaItems } from 'mastodon/components/external_remote_media';
import ExternalEmbedPlayer from 'mastodon/components/external_embed_player';
import { assignRelease } from 'mastodon/external_player/session';
import Video from 'mastodon/features/video';
import Audio from 'mastodon/features/audio';
import { displayMedia, useBlurhash } from 'mastodon/initial_state';
import StatusMediaStack, { externalMediaBlocks, LocalMediaPlayer } from 'mastodon/components/status_media';

export { externalMediaBlocks };

// External articles use the same presentation as an ordinary status: every
// local image and GIF is one gallery, then local and remote video, audio,
// and embeds stay in sequence order underneath it.
const read = (item, key) => {
  if (!item) {
    return undefined;
  }

  return typeof item.get === 'function' ? item.get(key) : item[key];
};

const defaultVisible = (sensitive) => (
  (displayMedia !== 'hide_all' && !sensitive) || displayMedia === 'show_all'
);

// Owner sequence hashes only. A URL-shaped value is not a placeholder and
// must not be written into the document.
const hashText = (value) => {
  if (typeof value !== 'string') {
    return null;
  }

  const text = value.trim();
  if (!text || text.length > 100 || text.includes('://') || text.startsWith('/')) {
    return null;
  }

  return text;
};

const placeholderHash = (entry) => {
  const thumbhash = hashText(read(entry, 'poster_thumbhash'));
  if (thumbhash) {
    return { kind: 'thumbhash', hash: thumbhash };
  }

  const blurhash = hashText(read(entry, 'poster_blurhash'));
  if (blurhash) {
    return { kind: 'blurhash', hash: blurhash };
  }

  return null;
};

export default class ExternalStatusMedia extends React.PureComponent {

  static propTypes = {
    status: ImmutablePropTypes.map,
    muted: PropTypes.bool,
    sensitive: PropTypes.bool,
    visible: PropTypes.bool,
    onToggleVisibility: PropTypes.func,
    onOpenMedia: PropTypes.func,
    onOpenVideo: PropTypes.func,
    height: PropTypes.number,
    videoHeight: PropTypes.number,
    defaultWidth: PropTypes.number,
    cacheWidth: PropTypes.func,
    standalone: PropTypes.bool,
    lang: PropTypes.string,
    translationMode: PropTypes.string,
    sourceLang: PropTypes.string,
    targetLang: PropTypes.string,
    deployPictureInPicture: PropTypes.func,
    quote: PropTypes.bool,
    releaseSignal: PropTypes.shape({
      mode: PropTypes.string,
    }),
  };

  static defaultProps = {
    height: 110,
  };

  legacyConcealedEntry () {
    const items = remoteMediaItems(this.props.status);
    if (items.length !== 1 || !this.props.status || typeof this.props.status.getIn !== 'function') {
      return null;
    }

    const media = this.props.status.getIn(['fedibird_external', 'media']);
    if (!media || typeof media.get !== 'function' || media.size !== 1) {
      return null;
    }

    return media.get(0);
  }

  articleUrl () {
    if (!this.props.status || typeof this.props.status.getIn !== 'function') {
      return undefined;
    }

    return this.props.status.getIn(['fedibird_external', 'canonical_url']);
  }

  concealed () {
    const visible = this.props.visible !== undefined ? this.props.visible : defaultVisible(this.props.sensitive);
    return !visible;
  }

  openSavedVideo = (attachment) => (options) => {
    if (this.props.onOpenVideo) {
      this.props.onOpenVideo(attachment, options);
    }
  };

  renderHashCanvas (entry) {
    const chosen = placeholderHash(entry);
    if (!chosen) {
      return null;
    }

    if (chosen.kind === 'thumbhash') {
      return (
        <Thumbhash
          hash={chosen.hash}
          dummy={!useBlurhash}
          className='media-gallery__preview'
        />
      );
    }

    return (
      <Blurhash
        hash={chosen.hash}
        dummy={!useBlurhash}
        className='media-gallery__preview'
      />
    );
  }

  renderConcealed (key, entry) {
    const warning = this.props.sensitive ? (
      <FormattedMessage id='status.sensitive_warning' defaultMessage='Sensitive content' />
    ) : (
      <FormattedMessage id='status.media_hidden' defaultMessage='Media hidden' />
    );
    const canvas = this.renderHashCanvas(entry);
    const button = (
      <button type='button' className='spoiler-button__overlay' onClick={this.props.onToggleVisibility} key={canvas ? undefined : key}>
        <span className='spoiler-button__overlay__label'>{warning}</span>
      </button>
    );

    if (!canvas) {
      return button;
    }

    return (
      <div className='external-status-media__concealed' key={key}>
        {canvas}
        <div className='spoiler-button'>
          {button}
        </div>
      </div>
    );
  }

  renderGallery (block) {
    return (
      <MediaGallery
        media={block.items}
        sensitive={this.props.sensitive}
        height={this.props.height}
        onOpenMedia={this.props.onOpenMedia}
        defaultWidth={this.props.defaultWidth}
        cacheWidth={this.props.cacheWidth}
        visible={this.props.visible}
        onToggleVisibility={this.props.onToggleVisibility}
        standalone={this.props.standalone}
        lang={this.props.lang}
        translationMode={this.props.translationMode}
        sourceLang={this.props.sourceLang}
        targetLang={this.props.targetLang}
        quote={this.props.quote}
      />
    );
  }

  renderLocal (block) {
    if (block.kind === 'audio' && this.concealed()) {
      return this.renderConcealed(block.attachment.get('id'));
    }

    const height = this.props.videoHeight || this.props.height;

    return (
      <LocalMediaPlayer
        attachment={block.attachment}
        Video={Video}
        Audio={Audio}
        sensitive={this.props.sensitive}
        visible={this.props.visible}
        onToggleVisibility={this.props.onToggleVisibility}
        onOpenVideo={this.openSavedVideo(block.attachment)}
        width={this.props.defaultWidth}
        height={height}
        audioHeight={height}
        cacheWidth={this.props.cacheWidth}
        deployPictureInPicture={this.props.deployPictureInPicture}
        quote={this.props.quote}
        translationMode={this.props.translationMode}
        sourceLang={this.props.sourceLang}
        targetLang={this.props.targetLang}
      />
    );
  }

  statusId () {
    const id = this.props.status && this.props.status.get('id');
    return id === undefined || id === null || id === '' ? null : String(id);
  }

  playerSignal () {
    const signal = this.props.releaseSignal || assignRelease(this, 'ownRelease', false);
    signal.mode = (this.props.muted || this.concealed()) ? 'end' : 'detach';
    return signal;
  }

  renderEmbed (block, index) {
    const key = read(block.entry, 'id') || `embed-${index}`;
    if (this.concealed()) {
      return this.renderConcealed(key, block.entry);
    }

    return (
      <ExternalEmbedPlayer
        key={key}
        statusId={this.statusId()}
        entry={block.entry}
        articleUrl={this.articleUrl()}
        releaseSignal={this.playerSignal()}
      />
    );
  }

  renderRemote (block, index) {
    const key = read(block.entry, 'id') || `remote-${index}`;
    if (this.concealed()) {
      return this.renderConcealed(key, block.entry);
    }

    const remoteStatus = fromJS({ fedibird_external: { media: [block.entry] } });
    return (
      <ExternalRemoteMedia
        key={key}
        statusId={this.statusId()}
        status={remoteStatus}
        articleUrl={this.articleUrl()}
        releaseSignal={this.playerSignal()}
      />
    );
  }

  renderLegacyMedia () {
    const attachments = this.props.status.get('media_attachments');
    const hasLocal = !!(attachments && attachments.size > 0);
    const remotes = remoteMediaItems(this.props.status);
    // Nothing playable must not grow a "media hidden" control.
    if (!hasLocal && remotes.length === 0) {
      return null;
    }

    const revealed = !this.concealed();
    let remote = null;
    if (remotes.length > 0 && revealed) {
      remote = <ExternalRemoteMedia statusId={this.statusId()} status={this.props.status} articleUrl={this.articleUrl()} releaseSignal={this.playerSignal()} />;
    } else if (remotes.length > 0) {
      remote = this.renderConcealed('legacy-remote', this.legacyConcealedEntry());
    }

    if (!hasLocal) {
      return remote;
    }

    return (
      <div className='external-status-media status-media-stack'>
        <StatusMediaStack
          media={attachments}
          Gallery={MediaGallery}
          Video={Video}
          Audio={Audio}
          sensitive={this.props.sensitive}
          visible={revealed}
          onToggleVisibility={this.props.onToggleVisibility}
          onOpenMedia={this.props.onOpenMedia}
          onOpenVideo={this.props.onOpenVideo}
          height={this.props.height}
          videoHeight={this.props.videoHeight || this.props.height}
          audioHeight={this.props.videoHeight || this.props.height}
          defaultWidth={this.props.defaultWidth}
          cacheWidth={this.props.cacheWidth}
          standalone={this.props.standalone}
          quote={this.props.quote}
          lang={this.props.lang}
          translationMode={this.props.translationMode}
          sourceLang={this.props.sourceLang}
          targetLang={this.props.targetLang}
          deployPictureInPicture={this.props.deployPictureInPicture}
        />
        {remote}
      </div>
    );
  }

  render () {
    this.playerSignal();

    if (this.props.muted || !this.props.status) {
      return null;
    }

    const blocks = externalMediaBlocks(this.props.status);
    // A response from the current serializer includes sequence whenever a
    // linked local file or a remote player exists. Sequence is omitted when
    // that list is empty, and an older or partial payload can still carry
    // media_attachments and/or fedibird_external.media without it. Local
    // files then use the same gallery and player stack. Remote files stay
    // behind the click-to-load player. Without sequence, local players follow
    // attachment order and remote players follow the legacy media list.
    if (!blocks) {
      return this.renderLegacyMedia();
    }
    if (blocks.length === 0) {
      return null;
    }

    return (
      <div className='external-status-media status-media-stack'>
        {blocks.map((block, index) => {
          if (block.kind === 'images') {
            return <React.Fragment key={`images-${index}`}>{this.renderGallery(block)}</React.Fragment>;
          }
          if (block.kind === 'embed') {
            return <React.Fragment key={read(block.entry, 'id') || `embed-${index}`}>{this.renderEmbed(block, index)}</React.Fragment>;
          }
          if (block.kind === 'remote') {
            return <React.Fragment key={read(block.entry, 'id') || `remote-${index}`}>{this.renderRemote(block, index)}</React.Fragment>;
          }
          return (
            <div className='external-status-media__saved' key={block.frameId || block.attachment.get('id')}>
              {this.renderLocal(block)}
            </div>
          );
        })}
      </div>
    );
  }

}
