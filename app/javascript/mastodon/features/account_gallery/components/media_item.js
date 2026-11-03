import AltTextBadge from 'mastodon/components/alt_text_badge';
import Blurhash from 'mastodon/components/blurhash';
import Thumbhash from 'mastodon/components/thumbhash';
import classNames from 'classnames';
import Icon from 'mastodon/components/icon';
import { autoPlayMedia, useBlurhash } from 'mastodon/initial_state';
import { isIOS } from 'mastodon/is_mobile';
import { defaultMediaVisibility, mediaAspectRatio, mediaIsConcealed } from 'mastodon/utils/media_display';
import PropTypes from 'prop-types';
import React from 'react';
import { defineMessages, injectIntl } from 'react-intl';
import ImmutablePropTypes from 'react-immutable-proptypes';
import ImmutablePureComponent from 'react-immutable-pure-component';

const messages = defineMessages({
  reveal: { id: 'timeline.media.reveal', defaultMessage: 'Reveal media' },
  open: { id: 'timeline.media.open', defaultMessage: 'Open media' },
});

export default @injectIntl
class MediaItem extends ImmutablePureComponent {

  static propTypes = {
    attachment: ImmutablePropTypes.map.isRequired,
    onOpenMedia: PropTypes.func.isRequired,
    shape: PropTypes.oneOf(['square', 'original']),
    visibility: PropTypes.oneOf(['hide_sensitive', 'show_all', 'hide_all']),
    intl: PropTypes.object.isRequired,
  };

  state = {
    revealed: false,
    loaded: false,
    policy: this.props.visibility,
    attachmentId: this.props.attachment.get('id'),
  };

  static getDerivedStateFromProps(nextProps, prevState) {
    const id = nextProps.attachment.get('id');
    if (id !== prevState.attachmentId || nextProps.visibility !== prevState.policy) {
      return { attachmentId: id, policy: nextProps.visibility, revealed: false, loaded: false };
    }

    return null;
  }

  handleImageLoad = () => {
    this.setState({ loaded: true });
  }

  handleMouseEnter = e => {
    if (this.hoverToPlay()) {
      e.target.play();
    }
  }

  handleMouseLeave = e => {
    if (this.hoverToPlay()) {
      e.target.pause();
      e.target.currentTime = 0;
    }
  }

  hoverToPlay () {
    return !autoPlayMedia && ['gifv', 'video'].includes(this.props.attachment.get('type'));
  }

  handleClick = e => {
    if (e.button !== 0 || e.ctrlKey || e.metaKey) {
      return;
    }

    e.preventDefault();

    if (this.isConcealed()) {
      this.setState({ revealed: true });
    } else {
      this.props.onOpenMedia(this.props.attachment);
    }
  }

  isConcealed () {
    const status = this.props.attachment.get('status');
    const policy = this.props.visibility || defaultMediaVisibility();
    const sensitive = status && status.get('sensitive');
    return mediaIsConcealed(policy, sensitive, this.state.revealed);
  }

  render () {
    const { attachment, shape, intl } = this.props;
    const { loaded } = this.state;
    const status = attachment.get('status');
    const description = attachment.get('description');
    const type = attachment.get('type');
    const original = shape === 'original';
    const concealed = this.isConcealed();
    const aspect = original ? mediaAspectRatio(attachment) : null;
    const itemStyle = aspect ? { aspectRatio: String(aspect) } : undefined;
    const blurred = concealed && useBlurhash && (attachment.get('blurhash') || attachment.get('thumbhash'));

    let content;
    if (!concealed) {
      if (['audio', 'video', 'image'].includes(type)) {
        const preview = attachment.get('preview_url') ||
          (type === 'image' ? attachment.get('url') : attachment.getIn(['account', 'avatar_static']));
        if (preview) {
          const focusX = attachment.getIn(['meta', 'focus', 'x']) || 0;
          const focusY = attachment.getIn(['meta', 'focus', 'y']) || 0;
          const x = ((focusX / 2) + 0.5) * 100;
          const y = ((focusY / -2) + 0.5) * 100;
          content = <img src={preview} alt={description || ''} style={{ objectPosition: `${x}% ${y}%` }} onLoad={this.handleImageLoad} loading='lazy' />;
        }
      } else if (type === 'gifv') {
        content = (
          <video
            className='media-gallery__item-gifv-thumbnail'
            aria-label={description || undefined}
            role='application'
            src={attachment.get('url')}
            onMouseEnter={this.handleMouseEnter}
            onMouseLeave={this.handleMouseLeave}
            onLoadedMetadata={this.handleImageLoad}
            autoPlay={!isIOS() && autoPlayMedia}
            loop
            muted
          />
        );
      }
    }

    return (
      <div className='account-gallery__item timeline-media-tile timeline-media-tile--account'>
        <div className='timeline-media-tile__preview'>
          <a
            className={classNames('timeline-media-tile__open', { 'timeline-media-tile__open--original': original })}
            style={itemStyle}
            href={status.get('url')}
            onClick={this.handleClick}
            target='_blank'
            rel='noopener noreferrer'
            aria-label={concealed ? intl.formatMessage(messages.reveal) : (description || intl.formatMessage(messages.open))}
          >
            {attachment.get('blurhash') ?
              <Blurhash hash={attachment.get('blurhash')} className={classNames('media-gallery__preview', { 'media-gallery__preview--hidden': !concealed && loaded })} dummy={!useBlurhash} /> :
              attachment.get('thumbhash') && <Thumbhash hash={attachment.get('thumbhash')} className={classNames('media-gallery__preview', { 'media-gallery__preview--hidden': !concealed && loaded })} dummy={!useBlurhash} />}
            {content || (!blurred && <span className='timeline-media-tile__placeholder'>
              <Icon id={concealed ? 'eye-slash' : type === 'audio' ? 'music' : 'file-o'} />
            </span>)}
            {blurred && <span className='timeline-media-tile__concealed-icon'><Icon id='eye-slash' /></span>}
            {!concealed && ['audio', 'video'].includes(type) && <span className='timeline-media-tile__play'><Icon id={type === 'audio' ? 'music' : 'play'} /></span>}
          </a>
          {description && <div className='media-gallery__item__badges'><AltTextBadge description={description} /></div>}
        </div>
      </div>
    );
  }

}
