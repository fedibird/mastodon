import React from 'react';
import PropTypes from 'prop-types';
import ImmutablePropTypes from 'react-immutable-proptypes';
import { FormattedMessage } from 'react-intl';

// Remote article video and audio. The media URL is not written into the
// document until the owner clicks. preload=none is not enough: some browsers
// still request a src that is already on the element. There is no extra
// consent step. referrerPolicy is best-effort; HTML media does not guarantee
// it, and a redirect target is chosen by the browser, not by Fedibird.
// Device playback, HLS, and Range/seek are recorded in
// docs/external_rss_media_playback.md. They are not claimed from this file.
const safeMediaUrl = (value) => {
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

export default class ExternalRemoteMedia extends React.PureComponent {

  static propTypes = {
    status: ImmutablePropTypes.map,
    muted: PropTypes.bool,
    articleUrl: PropTypes.string,
  };

  state = {
    armedId: null,
    failedId: null,
  };

  handleArm = (event) => {
    this.setState({ armedId: event.currentTarget.getAttribute('data-media-id') });
  };

  handleError = (event) => {
    this.setState({ failedId: event.currentTarget.getAttribute('data-media-id') });
  };

  articleUrl () {
    return safeMediaUrl(this.props.articleUrl);
  }

  renderItem (item) {
    const armed = this.state.armedId === item.id;
    const label = item.type === 'audio' ? (
      <FormattedMessage id='external_media.remote_audio' defaultMessage='External audio' />
    ) : (
      <FormattedMessage id='external_media.remote_video' defaultMessage='External video' />
    );

    if (!armed) {
      return (
        <button
          type='button'
          className='external-remote-media__launch'
          data-media-id={item.id}
          onClick={this.handleArm}
        >
          <span className='external-remote-media__badge'>{label}</span>
          {item.description ? <span className='external-remote-media__description'>{item.description}</span> : null}
        </button>
      );
    }

    if (this.state.failedId === item.id) {
      return this.renderFallback(item);
    }

    if (item.type === 'audio') {
      return (
        <audio
          src={item.url}
          controls
          autoPlay={false}
          preload='none'
          referrerPolicy='no-referrer'
          data-media-id={item.id}
          onError={this.handleError}
        />
      );
    }

    return (
      <React.Fragment>
        <span className='external-remote-media__badge'>{label}</span>
        <video
          src={item.url}
          controls
          autoPlay={false}
          preload='none'
          playsInline
          referrerPolicy='no-referrer'
          data-media-id={item.id}
          onError={this.handleError}
        />
      </React.Fragment>
    );
  }

  renderFallback (item) {
    const articleUrl = this.articleUrl();

    return (
      <div className='external-remote-media__fallback'>
        <p>
          <FormattedMessage id='external_media.playback_failed' defaultMessage='This browser could not play the file.' />
        </p>
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
    if (this.props.muted) {
      return null;
    }

    const items = remoteMediaItems(this.props.status);
    if (items.length === 0) {
      return null;
    }

    return (
      <div className='external-remote-media'>
        {items.map(item => (
          <div className='external-remote-media__item' key={item.id}>
            {this.renderItem(item)}
          </div>
        ))}
      </div>
    );
  }

}
