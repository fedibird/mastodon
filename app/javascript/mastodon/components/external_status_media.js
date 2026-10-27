import React from 'react';
import PropTypes from 'prop-types';
import ImmutablePropTypes from 'react-immutable-proptypes';
import { List as ImmutableList, fromJS } from 'immutable';
import { FormattedMessage } from 'react-intl';
import MediaGallery from 'mastodon/components/media_gallery';
import ExternalRemoteMedia from 'mastodon/components/external_remote_media';
import ExternalEmbedPlayer from 'mastodon/components/external_embed_player';
import Video from 'mastodon/features/video';
import Audio from 'mastodon/features/audio';
import { displayMedia } from 'mastodon/initial_state';
import { attachmentAccessibility } from 'mastodon/utils/translation_view';

// External articles can contain images and a saved or remote video in any
// order. The ordinary status renderer keeps only the first attachment type,
// so a saved video next to images would disappear. This list follows
// fedibird_external.sequence instead.
const read = (item, key) => (item && typeof item.get === 'function' ? item.get(key) : item[key]);

const defaultVisible = (sensitive) => (
  (displayMedia !== 'hide_all' && !sensitive) || displayMedia === 'show_all'
);

export const externalMediaBlocks = (status) => {
  const sequence = status && status.getIn && status.getIn(['fedibird_external', 'sequence']);
  if (!sequence || typeof sequence.forEach !== 'function' || sequence.size === 0) {
    return null;
  }

  const attachments = {};
  const media = status.get('media_attachments') || ImmutableList();
  media.forEach(item => {
    if (item) {
      attachments[String(item.get('id'))] = item;
    }
  });

  const blocks = [];
  let images = [];
  const flush = () => {
    if (images.length > 0) {
      blocks.push({ kind: 'images', items: ImmutableList(images) });
      images = [];
    }
  };

  sequence.forEach(entry => {
    const type = read(entry, 'type');
    const delivery = read(entry, 'delivery');
    if (delivery === 'local' && type === 'image') {
      const attachment = attachments[String(read(entry, 'attachment_id'))];
      if (attachment) {
        images.push(attachment);
      }
      return;
    }

    flush();
    if (delivery === 'remote' && type === 'embed') {
      blocks.push({ kind: 'embed', entry });
      return;
    }

    if (delivery === 'local' && (type === 'video' || type === 'audio')) {
      const attachment = attachments[String(read(entry, 'attachment_id'))];
      if (attachment) {
        blocks.push({ kind: type, attachment });
      }
      return;
    }

    if (delivery === 'remote' && (type === 'video' || type === 'audio')) {
      blocks.push({ kind: 'remote', entry });
    }
  });
  flush();
  return blocks;
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
  };

  static defaultProps = {
    height: 110,
  };

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

  described (attachment) {
    return attachmentAccessibility(attachment, {
      mode: this.props.translationMode,
      sourceLang: this.props.sourceLang,
      targetLang: this.props.targetLang,
    });
  }

  openSavedVideo = (attachment) => (options) => {
    if (this.props.onOpenVideo) {
      this.props.onOpenVideo(attachment, options);
    }
  };

  renderConcealed (key) {
    const warning = this.props.sensitive ? (
      <FormattedMessage id='status.sensitive_warning' defaultMessage='Sensitive content' />
    ) : (
      <FormattedMessage id='status.media_hidden' defaultMessage='Media hidden' />
    );

    return (
      <button type='button' className='spoiler-button__overlay' onClick={this.props.onToggleVisibility} key={key}>
        <span className='spoiler-button__overlay__label'>{warning}</span>
      </button>
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
      />
    );
  }

  renderVideo (attachment) {
    const described = this.described(attachment);
    const height = this.props.videoHeight || this.props.height;

    return (
      <Video
        preview={attachment.get('preview_url')}
        frameRate={attachment.getIn(['meta', 'original', 'frame_rate'])}
        thumbhash={attachment.get('thumbhash')}
        blurhash={attachment.get('blurhash')}
        src={attachment.get('url')}
        alt={described.text}
        lang={described.lang}
        width={this.props.defaultWidth}
        height={height}
        inline
        sensitive={this.props.sensitive}
        onOpenVideo={this.openSavedVideo(attachment)}
        cacheWidth={this.props.cacheWidth}
        deployPictureInPicture={this.props.deployPictureInPicture}
        visible={this.props.visible}
        onToggleVisibility={this.props.onToggleVisibility}
      />
    );
  }

  renderAudio (attachment) {
    if (this.concealed()) {
      return this.renderConcealed(attachment.get('id'));
    }

    const described = this.described(attachment);
    const height = this.props.videoHeight || this.props.height;

    return (
      <Audio
        src={attachment.get('url')}
        alt={described.text}
        lang={described.lang}
        poster={attachment.get('preview_url')}
        backgroundColor={attachment.getIn(['meta', 'colors', 'background'])}
        foregroundColor={attachment.getIn(['meta', 'colors', 'foreground'])}
        accentColor={attachment.getIn(['meta', 'colors', 'accent'])}
        duration={attachment.getIn(['meta', 'original', 'duration'], 0)}
        width={this.props.defaultWidth}
        height={height}
        cacheWidth={this.props.cacheWidth}
      />
    );
  }

  renderLocal (block) {
    if (block.kind === 'audio') {
      return this.renderAudio(block.attachment);
    }

    return this.renderVideo(block.attachment);
  }

  renderEmbed (block, index) {
    const key = read(block.entry, 'id') || `embed-${index}`;
    if (this.concealed()) {
      return this.renderConcealed(key);
    }

    return <ExternalEmbedPlayer key={key} entry={block.entry} articleUrl={this.articleUrl()} />;
  }

  renderRemote (block, index) {
    const key = read(block.entry, 'id') || `remote-${index}`;
    if (this.concealed()) {
      return this.renderConcealed(key);
    }

    const remoteStatus = fromJS({ fedibird_external: { media: [block.entry] } });
    return <ExternalRemoteMedia key={key} status={remoteStatus} articleUrl={this.articleUrl()} />;
  }

  render () {
    if (this.props.muted || !this.props.status) {
      return null;
    }

    const blocks = externalMediaBlocks(this.props.status);
    // No sequence: an older or partial payload can still carry media and
    // canonical_url. The article link uses the same fallback as the sequence path.
    if (!blocks) {
      return <ExternalRemoteMedia status={this.props.status} articleUrl={this.articleUrl()} />;
    }
    if (blocks.length === 0) {
      return null;
    }

    return (
      <div className='external-status-media'>
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
            <div className='external-status-media__saved' key={block.attachment.get('id')}>
              {this.renderLocal(block)}
            </div>
          );
        })}
      </div>
    );
  }

}
