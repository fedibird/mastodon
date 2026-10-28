import React from 'react';
import PropTypes from 'prop-types';
import ImmutablePropTypes from 'react-immutable-proptypes';
import { FormattedMessage } from 'react-intl';

import ExternalPlayerSurface from 'mastodon/external_player/surface';
import {
  dismissFailedSession,
  getSessionByIdentity,
  openSession,
  subscribeExternalPlayers,
} from 'mastodon/external_player/session';

// Remote article video and audio. The media URL is not written into the
// document until the owner clicks. preload=none is not enough: some browsers
// still request a src that is already on the element. There is no extra
// consent step. referrerPolicy is best-effort; HTML media does not guarantee
// it, and a redirect target is chosen by the browser, not by Fedibird.
// Device playback, HLS, and Range/seek are recorded in
// docs/external_rss_media_playback.md. They are not claimed from this file.
// The element is created in the persistent player host, not in this row.
export const safeMediaUrl = (value) => {
  if (!value || typeof value !== 'string') {
    return null;
  }

  try {
    const url = new URL(value);
    if (url.username || url.password) {
      return null;
    }
    if (url.protocol !== 'https:' && url.protocol !== 'http:') {
      return null;
    }
    return url.toString();
  } catch (_error) {
    return null;
  }
};

const read = (item, key) => (typeof item.get === 'function' ? item.get(key) : item[key]);

export const remoteMediaItems = (status) => {
  if (!status || typeof status.getIn !== 'function') {
    return [];
  }

  const media = status.getIn(['fedibird_external', 'media']);
  if (!media || typeof media.map !== 'function') {
    return [];
  }

  const items = [];
  media.forEach(item => {
    if (!item) {
      return;
    }
    const type = read(item, 'type');
    const url = safeMediaUrl(read(item, 'url'));
    if ((type === 'video' || type === 'audio') && url) {
      items.push({
        id: read(item, 'id') || url,
        type,
        url,
        description: read(item, 'description') || '',
      });
    }
  });
  return items;
};

class RemoteMediaItem extends React.PureComponent {

  static propTypes = {
    item: PropTypes.shape({
      id: PropTypes.oneOfType([PropTypes.string, PropTypes.number]).isRequired,
      type: PropTypes.string.isRequired,
      url: PropTypes.string.isRequired,
      description: PropTypes.string,
    }).isRequired,
    statusId: PropTypes.string,
    articleUrl: PropTypes.string,
    releaseSignal: PropTypes.shape({
      mode: PropTypes.string,
    }),
  };

  componentDidMount () {
    this.unsubscribe = subscribeExternalPlayers(() => {
      if (!this.unmounted) {
        this.forceUpdate();
      }
    });
  }

  componentWillUnmount () {
    this.unmounted = true;

    if (this.unsubscribe) {
      this.unsubscribe();
    }
  }

  session () {
    return getSessionByIdentity(this.props.statusId, this.props.item.id);
  }

  handleArm = () => {
    if (!this.props.statusId || this.session()) {
      return;
    }

    this.didOpen = true;
    openSession({
      statusId: this.props.statusId,
      mediaId: this.props.item.id,
      kind: this.props.item.type,
      url: this.props.item.url,
    });
  };

  handleRetry = () => {
    const session = this.session();

    if (session) {
      dismissFailedSession(session.key);
    }
  };

  renderFallback (item) {
    const articleUrl = safeMediaUrl(this.props.articleUrl);

    return (
      <div className='external-remote-media__fallback'>
        <p>
          <FormattedMessage id='external_media.playback_failed' defaultMessage='This browser could not play the file.' />
        </p>
        <button type='button' className='external-remote-media__retry' onClick={this.handleRetry}>
          <FormattedMessage id='external_media.retry' defaultMessage='Try again' />
        </button>
        <a href={item.url} target='_blank' rel='noopener noreferrer'>
          <FormattedMessage id='external_media.open_media' defaultMessage='Open media file' />
        </a>
        {articleUrl ? (
          <a href={articleUrl} target='_blank' rel='noopener noreferrer'>
            <FormattedMessage id='external_media.open_article' defaultMessage='Open article' />
          </a>
        ) : null}
      </div>
    );
  }

  render () {
    const { item } = this.props;
    const session = this.session();
    const label = item.type === 'audio' ? (
      <FormattedMessage id='external_media.remote_audio' defaultMessage='External audio' />
    ) : (
      <FormattedMessage id='external_media.remote_video' defaultMessage='External video' />
    );

    if (session && session.failed) {
      return this.renderFallback(item);
    }

    if (session) {
      return (
        <ExternalPlayerSurface
          session={session}
          prefer={this.didOpen === true}
          releaseSignal={this.props.releaseSignal}
          frameClassName={`external-remote-media__slot external-remote-media__slot--${item.type}`}
          footer={<span className='external-remote-media__badge'>{label}</span>}
        />
      );
    }

    return (
      <button
        type='button'
        className='external-remote-media__launch'
        onClick={this.handleArm}
      >
        <span className='external-remote-media__badge'>{label}</span>
        {item.description ? <span className='external-remote-media__description'>{item.description}</span> : null}
      </button>
    );
  }

}

export default class ExternalRemoteMedia extends React.PureComponent {

  static propTypes = {
    status: ImmutablePropTypes.map,
    statusId: PropTypes.string,
    muted: PropTypes.bool,
    articleUrl: PropTypes.string,
    releaseSignal: PropTypes.shape({
      mode: PropTypes.string,
    }),
  };

  render () {
    if (this.props.muted) {
      return null;
    }

    const items = remoteMediaItems(this.props.status);
    if (items.length === 0) {
      return null;
    }

    const statusId = this.props.statusId || (this.props.status && this.props.status.get('id'));
    const id = statusId === undefined || statusId === null ? null : String(statusId);

    return (
      <div className='external-remote-media'>
        {items.map(item => (
          <div className='external-remote-media__item' key={String(item.id)}>
            <RemoteMediaItem
              item={item}
              statusId={id}
              articleUrl={this.props.articleUrl}
              releaseSignal={this.props.releaseSignal}
            />
          </div>
        ))}
      </div>
    );
  }

}
