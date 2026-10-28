import React from 'react';
import PropTypes from 'prop-types';
import ImmutablePropTypes from 'react-immutable-proptypes';
import { FormattedMessage } from 'react-intl';

import { safeMediaUrl } from 'mastodon/components/external_remote_media';

// Click to mount one cross-origin player. The iframe is not in the document
// until then, so the player host is not contacted earlier. sandbox keeps the
// frame from navigating this tab. allow-scripts and allow-same-origin are
// both set because a publisher player will not start without them; that pair
// is unsafe for a same-origin URL, which the server rejects before this
// component sees it. allow does not include autoplay. iframe load is not
// treated as playback success. A saved poster is our file, not the publisher
// URL. Signature query names are refused here so a publisher URL cannot be
// used as that image.
//
// Fullscreen on this iframe is `fullscreen *`. An omitted allowlist means
// 'src' (the origin of the src URL). Naming fullscreen in allow also
// disables allowfullscreen, whose allowlist is *. A generic player may
// redirect or nest an origin we cannot list here. `fullscreen *` is that
// same per-iframe delegation, written explicitly so it cannot collapse
// back to 'src'. allowFullScreen remains for agents that ignore allow.
// This does not override a parent Permissions-Policy denial, a denial
// from the embedded document, or the user-gesture requirement.
// externalEmbedFrameProps is the creation-time contract. This component
// spreads it into React. The pinned host (#625, session.js createFrame)
// builds the one live iframe and reuses that node for the inline slot and
// the fixed dock, so it must copy these fields when the node is created:
// sandbox and allow through setAttribute, referrerPolicy through
// setAttribute('referrerpolicy'), and allowFullScreen through the DOM
// property allowFullscreen. Object.assign does not set that property.
// Copying the React key allowFullScreen does not either. Writing allow
// after the framed document has loaded does not update the container
// policy, and a second allow string must not be introduced for the dock.
const SIGNATURE_QUERY = /(?:^|&)(?:hash|validto|hdnea|exp)=/i;
const MAX_DURATION = 48 * 60 * 60;

export const externalEmbedFrameProps = {
  sandbox: 'allow-scripts allow-same-origin allow-presentation allow-popups allow-popups-to-escape-sandbox',
  allow: 'fullscreen *; encrypted-media; picture-in-picture',
  referrerPolicy: 'no-referrer',
  allowFullScreen: true,
};

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
  };

  state = {
    armed: false,
  };

  handleArm = () => {
    this.setState({ armed: true });
  };

  playerUrl () {
    return safeMediaUrl(read(this.props.entry, 'url'));
  }

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

  renderFrame (url) {
    return (
      <div className='external-embed-player__frame'>
        <iframe
          src={url}
          title='External video'
          className='external-embed-player__iframe'
          {...externalEmbedFrameProps}
        />
      </div>
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
    if (!url) {
      return null;
    }

    const poster = safePosterUrl(read(this.props.entry, 'poster'), url);
    const duration = formatDuration(read(this.props.entry, 'duration'));
    const articleUrl = safeMediaUrl(this.props.articleUrl);

    return (
      <div className='external-embed-player'>
        {this.state.armed ? this.renderFrame(url) : this.renderLaunch(poster, duration)}
        {this.renderArticle(articleUrl)}
      </div>
    );
  }

}
