import React from 'react';
import PropTypes from 'prop-types';
import ImmutablePropTypes from 'react-immutable-proptypes';
import { FormattedMessage } from 'react-intl';

import { safeMediaUrl } from 'mastodon/components/external_remote_media';
import ExternalPlayerSurface from 'mastodon/external_player/surface';
import {
  getSessionByIdentity,
  openSession,
  subscribeExternalPlayers,
} from 'mastodon/external_player/session';

// Click to mount one cross-origin player. The iframe is not in the document
// until then, so the player host is not contacted earlier. The host, not this
// row, owns the frame from that click onward. sandbox keeps the frame from
// navigating this tab. allow-scripts and allow-same-origin are both set
// because a publisher player will not start without them; that pair is unsafe
// for a same-origin URL, which the server rejects before this component sees
// it. allow does not include autoplay. iframe load is not treated as playback
// success. A saved poster is our file, not the publisher URL. Signature query
// names are refused here so a publisher URL cannot be used as that image.
const SIGNATURE_QUERY = /(?:^|&)(?:hash|validto|hdnea|exp)=/i;
const MAX_DURATION = 48 * 60 * 60;

const read = (entry, key) => (entry && typeof entry.get === 'function' ? entry.get(key) : entry[key]);

export const formatDuration = (value) => {
  if (value === null || value === undefined || value === '') {
    return null;
  }

  const total = typeof value === 'number' ? value : Number(value);
  if (!Number.isInteger(total) || total < 0 || total > MAX_DURATION) {
    return null;
  }

  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const seconds = total % 60;
  const pad = (part) => String(part).padStart(2, '0');
  if (hours > 0) {
    return `${hours}:${pad(minutes)}:${pad(seconds)}`;
  }

  return `${minutes}:${pad(seconds)}`;
};

export const safePosterUrl = (value, playerUrl) => {
  if (!value || typeof value !== 'string' || value === playerUrl) {
    return null;
  }

  if (value.startsWith('/') && !value.startsWith('//') && !value.includes('\\') && !SIGNATURE_QUERY.test(value)) {
    return value;
  }

  const url = safeMediaUrl(value);
  if (!url || SIGNATURE_QUERY.test(url)) {
    return null;
  }

  return url;
};

export default class ExternalEmbedPlayer extends React.PureComponent {

  static propTypes = {
    entry: PropTypes.oneOfType([ImmutablePropTypes.map, PropTypes.object]),
    articleUrl: PropTypes.string,
    statusId: PropTypes.string,
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

  playerUrl () {
    return safeMediaUrl(read(this.props.entry, 'url'));
  }

  mediaId () {
    const id = read(this.props.entry, 'id');
    return id === undefined || id === null || id === '' ? null : String(id);
  }

  session () {
    return getSessionByIdentity(this.props.statusId, this.mediaId());
  }

  handleArm = () => {
    const url = this.playerUrl();
    const mediaId = this.mediaId();

    if (!url || !mediaId || !this.props.statusId || this.session()) {
      return;
    }

    this.didOpen = true;
    openSession({
      statusId: this.props.statusId,
      mediaId,
      kind: 'iframe',
      url,
    });
  };

  renderPoster (poster) {
    if (!poster) {
      return null;
    }

    return <img className='external-embed-player__poster' src={poster} alt='' />;
  }

  renderLaunch (poster, duration) {
    return (
      <button type='button' className='external-embed-player__launch' onClick={this.handleArm}>
        {this.renderPoster(poster)}
        <span className='external-embed-player__meta'>
          <span className='external-embed-player__badge'>
            <FormattedMessage id='external_media.embed_video' defaultMessage='External video' />
          </span>
          {duration ? <span className='external-embed-player__duration'>{duration}</span> : null}
        </span>
      </button>
    );
  }

  renderArticle (articleUrl) {
    if (!articleUrl) {
      return null;
    }

    return (
      <a className='external-embed-player__article' href={articleUrl} target='_blank' rel='noopener noreferrer'>
        <FormattedMessage id='external_media.open_article' defaultMessage='Open article' />
      </a>
    );
  }

  render () {
    const url = this.playerUrl();
    if (!url || !this.mediaId()) {
      return null;
    }

    const poster = safePosterUrl(read(this.props.entry, 'poster'), url);
    const duration = formatDuration(read(this.props.entry, 'duration'));
    const articleUrl = safeMediaUrl(this.props.articleUrl);
    const session = this.session();

    return (
      <div className='external-embed-player'>
        {session ? (
          <ExternalPlayerSurface
            session={session}
            prefer={this.didOpen === true}
            releaseSignal={this.props.releaseSignal}
            frameClassName='external-embed-player__frame'
            footer={this.renderArticle(articleUrl)}
          />
        ) : (
          <React.Fragment>
            {this.renderLaunch(poster, duration)}
            {this.renderArticle(articleUrl)}
          </React.Fragment>
        )}
      </div>
    );
  }

}
