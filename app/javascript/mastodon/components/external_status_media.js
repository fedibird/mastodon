import React from 'react';
import PropTypes from 'prop-types';
import ImmutablePropTypes from 'react-immutable-proptypes';
import { List as ImmutableList, fromJS } from 'immutable';
import MediaGallery from 'mastodon/components/media_gallery';
import ExternalRemoteMedia from 'mastodon/components/external_remote_media';

// External articles can contain images and a saved or remote video in any
// order. The ordinary status renderer keeps only the first attachment type,
// so a saved video next to images would disappear. This list follows
// fedibird_external.sequence instead.
const read = (item, key) => (item && typeof item.get === 'function' ? item.get(key) : item[key]);

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
  };

  renderLocal (block) {
    const url = block.attachment.get('url');
    const description = block.attachment.get('description') || '';
    if (block.kind === 'audio') {
      return <audio src={url} controls preload='metadata' aria-label={description} />;
    }

    return (
      <video src={url} controls preload='metadata' playsInline aria-label={description} />
    );
  }

  render () {
    if (this.props.muted || !this.props.status) {
      return null;
    }

    const blocks = externalMediaBlocks(this.props.status);
    if (!blocks) {
      return <ExternalRemoteMedia status={this.props.status} />;
    }
    if (blocks.length === 0) {
      return null;
    }

    return (
      <div className='external-status-media'>
        {blocks.map((block, index) => {
          if (block.kind === 'images') {
            return <MediaGallery key={`images-${index}`} media={block.items} />;
          }
          if (block.kind === 'remote') {
            const remoteStatus = fromJS({ fedibird_external: { media: [block.entry] } });
            return <ExternalRemoteMedia key={read(block.entry, 'id') || `remote-${index}`} status={remoteStatus} />;
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
