import React, { Fragment } from 'react';
import ImmutablePropTypes from 'react-immutable-proptypes';
import PropTypes from 'prop-types';
import { is } from 'immutable';
import classNames from 'classnames';
import { displayMedia, useBlurhash, maxAttachments } from '../initial_state';
import Blurhash from 'mastodon/components/blurhash';
import Thumbhash from 'mastodon/components/thumbhash';
import { FormattedMessage } from 'react-intl';
import { withEmojiMuteTextIndex } from 'mastodon/components/emoji_muted_html';
import { presentEmojiMutePlain } from 'mastodon/features/emoji/emoji_mute_text';

class Item extends React.PureComponent {

  static propTypes = {
    attachment: ImmutablePropTypes.map.isRequired,
    visible: PropTypes.bool.isRequired,
    autoplay: PropTypes.bool,
    emojiMuteTextIndex: PropTypes.object,
  };

  state = {
    loaded: false,
  };

  handleImageLoad = () => {
    this.setState({ loaded: true });
  }

  render () {
    const { attachment, visible } = this.props;

    let thumbnail = '';
    let typeLabel = '';

    const id          = attachment.get('id');
    const type        = attachment.get('type');
    const blurhash    = attachment.get('blurhash');
    const thumbhash   = attachment.get('thumbhash');
    const preview     = attachment.get('preview_url');
    const rawDescription = attachment.get('description');
    const description = typeof rawDescription === 'string' ? presentEmojiMutePlain(rawDescription, this.props.emojiMuteTextIndex) : rawDescription;

    switch(type) {
    case 'image':
      const focusX = attachment.getIn(['meta', 'focus', 'x']) || 0;
      const focusY = attachment.getIn(['meta', 'focus', 'y']) || 0;
      const x      = ((focusX /  2) + .5) * 100;
      const y      = ((focusY / -2) + .5) * 100;

      thumbnail = (
        <img
          className='thumbnail-gallery__item-thumbnail'
          src={preview}
          alt={description}
          title={description}
          style={{ objectPosition: `${x}% ${y}%` }}
          onLoad={this.handleImageLoad}
        />
      );
      break;

    case 'gifv':
      thumbnail = (
        <div className='thumbnail-gallery__gifv'>
          <video
            className='thumbnail-gallery__item-gifv-thumbnail'
            aria-label={description}
            title={description}
            role='application'
            src={attachment.get('url')}
            autoPlay={false}
            muted
          />
        </div>
      );
      typeLabel = <FormattedMessage id='thumbnail.type.gif' defaultMessage='(GIF)' />;
      break;

    case 'audio':
      thumbnail = preview ? (
        <img
          className='thumbnail-gallery__item-thumbnail'
          src={preview}
          alt={description}
          title={description}
          onLoad={this.handleImageLoad}
        />
      ) : null;
      typeLabel = <FormattedMessage id='thumbnail.type.audio' defaultMessage='(Audio)' />;
      break;

    case 'video':
      thumbnail = (
        <img
          className='thumbnail-gallery__item-thumbnail'
          src={preview}
          alt={description}
          title={description}
          onLoad={this.handleImageLoad}
        />
      );
      typeLabel = <FormattedMessage id='thumbnail.type.video' defaultMessage='(Video)' />;
      break;

    default:
      return thumbhash || blurhash ? (
        <div className='thumbnail-gallery__item' key={id}>
          {thumbhash ?
            <Thumbhash
              hash={thumbhash}
              className='thumbnail-gallery__preview'
              dummy={!useBlurhash}
            />
            :
            <Blurhash
              hash={blurhash}
              className='thumbnail-gallery__preview'
              dummy={!useBlurhash}
            />
          }
        </div>
      ) : null;
    }

    return (
      <Fragment>
        <div className='thumbnail-gallery__item' key={id}>
          {(thumbhash || blurhash) &&
            thumbhash ?
            (<Thumbhash
              hash={thumbhash}
              dummy={!useBlurhash}
              className={classNames('thumbnail-gallery__preview', {
                'thumbnail-gallery__preview--hidden': visible && this.state.loaded,
              })}
            />)
            :
            (<Blurhash
              hash={blurhash}
              dummy={!useBlurhash}
              className={classNames('thumbnail-gallery__preview', {
                'thumbnail-gallery__preview--hidden': visible && this.state.loaded,
              })}
            />)
          }
          {visible && thumbnail}
        </div>
        {typeLabel && <div className='thumbnail-gallery__type' key='type'>{typeLabel}</div>}
      </Fragment>
    );
  }

}

class ThumbnailGallery extends React.PureComponent {

  static propTypes = {
    sensitive: PropTypes.bool,
    media: ImmutablePropTypes.list.isRequired,
    visible: PropTypes.bool,
    emojiMuteTextIndex: PropTypes.object,
  };

  state = {
    visible: this.props.visible !== undefined ? this.props.visible : (displayMedia !== 'hide_all' && !this.props.sensitive || displayMedia === 'show_all'),
  };

  componentWillReceiveProps (nextProps) {
    if (!is(nextProps.media, this.props.media) && nextProps.visible === undefined) {
      this.setState({ visible: displayMedia !== 'hide_all' && !nextProps.sensitive || displayMedia === 'show_all' });
    } else if (!is(nextProps.visible, this.props.visible) && nextProps.visible !== undefined) {
      this.setState({ visible: nextProps.visible });
    }
  }

  render () {
    const { media } = this.props;
    const { visible } = this.state;

    const uncached = media.every(attachment => attachment.get('type') === 'unknown');
    const children = media.take(maxAttachments).map((attachment) => <Item key={attachment.get('id')} attachment={attachment} visible={visible || uncached} emojiMuteTextIndex={this.props.emojiMuteTextIndex} />);

    return (
      <div className='thumbnail-gallery' ref={this.handleRef}>
        {children}
      </div>
    );
  }

}

export default withEmojiMuteTextIndex(ThumbnailGallery);
