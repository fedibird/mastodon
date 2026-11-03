import React from 'react';
import ReactSwipeableViews from 'react-swipeable-views';
import ImmutablePropTypes from 'react-immutable-proptypes';
import PropTypes from 'prop-types';
import Video from 'mastodon/features/video';
import classNames from 'classnames';
import { defineMessages, injectIntl } from 'react-intl';
import IconButton from 'mastodon/components/icon_button';
import ImmutablePureComponent from 'react-immutable-pure-component';
import ImageLoader from './image_loader';
import Icon from 'mastodon/components/icon';
import GIFV from 'mastodon/components/gifv';
import { disableSwiping } from 'mastodon/initial_state';
import Footer from 'mastodon/features/picture_in_picture/components/footer';
import { getAverageFromBlurhash } from 'mastodon/blurhash';
import { connect } from 'react-redux';
import { attachmentAccessibility, statusTranslationView } from 'mastodon/utils/translation_view';

const messages = defineMessages({
  close: { id: 'lightbox.close', defaultMessage: 'Close' },
  previous: { id: 'lightbox.previous', defaultMessage: 'Previous' },
  next: { id: 'lightbox.next', defaultMessage: 'Next' },
});

const mapStateToProps = (state, props) => {
  const status = props.statusId ? state.getIn(['statuses', props.statusId]) : null;

  const translationView = status ? statusTranslationView(status) : null;

  return {
    translationView,
    lang: translationView ? translationView.mediaLang : props.lang,
    timelineStatuses: props.timelineStatusIds ? state.get('statuses') : null,
  };
};

class MediaModal extends ImmutablePureComponent {

  static propTypes = {
    media: ImmutablePropTypes.list.isRequired,
    statusId: PropTypes.string,
    timelineStatusIds: ImmutablePropTypes.list,
    timelineStatuses: ImmutablePropTypes.map,
    lang: PropTypes.string,
    translationView: PropTypes.shape({
      mode: PropTypes.string,
      sourceLang: PropTypes.string,
      targetLang: PropTypes.string,
      mediaLang: PropTypes.string,
    }),
    index: PropTypes.number.isRequired,
    onClose: PropTypes.func.isRequired,
    intl: PropTypes.object.isRequired,
    onChangeBackgroundColor: PropTypes.func.isRequired,
    currentTime: PropTypes.number,
    autoPlay: PropTypes.bool,
    volume: PropTypes.number,
  };

  state = {
    index: null,
    navigationHidden: false,
    zoomButtonHidden: false,
  };

  isTimelineSequence = () => (
    this.props.timelineStatusIds && this.props.timelineStatusIds.size === this.props.media.size
  )

  statusIdForIndex = index => (
    this.isTimelineSequence() ? this.props.timelineStatusIds.get(index) : this.props.statusId
  )

  clampIndex = index => (
    this.isTimelineSequence()
      ? Math.max(0, Math.min(this.props.media.size - 1, index))
      : (index + this.props.media.size) % this.props.media.size
  )

  handleSwipe = index => {
    this.setState({ index: this.clampIndex(index) });
  }

  handleTransitionEnd = () => {
    this.setState({
      zoomButtonHidden: false,
    });
  }

  handleNextClick = () => {
    const next = this.clampIndex(this.getIndex() + 1);
    if (next !== this.getIndex()) {
      this.setState({ index: next, zoomButtonHidden: true });
    }
  }

  handlePrevClick = () => {
    const previous = this.clampIndex(this.getIndex() - 1);
    if (previous !== this.getIndex()) {
      this.setState({ index: previous, zoomButtonHidden: true });
    }
  }

  handleChangeIndex = (e) => {
    const index = Number(e.currentTarget.getAttribute('data-index'));

    this.setState({
      index: this.clampIndex(index),
      zoomButtonHidden: true,
    });
  }

  handleKeyDown = (e) => {
    switch(e.key) {
    case 'ArrowLeft':
      this.handlePrevClick();
      e.preventDefault();
      e.stopPropagation();
      break;
    case 'ArrowRight':
      this.handleNextClick();
      e.preventDefault();
      e.stopPropagation();
      break;
    }
  }

  componentDidMount () {
    window.addEventListener('keydown', this.handleKeyDown, false);

    this._sendBackgroundColor();
  }

  componentDidUpdate (prevProps, prevState) {
    if (prevState.index !== this.state.index) {
      this._sendBackgroundColor();
    }
  }

  _sendBackgroundColor () {
    const { media, onChangeBackgroundColor } = this.props;
    const index = this.getIndex();
    const blurhash = media.getIn([index, 'blurhash']);

    if (blurhash) {
      const backgroundColor = getAverageFromBlurhash(blurhash);
      onChangeBackgroundColor(backgroundColor);
    }
  }

  componentWillUnmount () {
    window.removeEventListener('keydown', this.handleKeyDown);

    this.props.onChangeBackgroundColor(null);
  }

  getIndex () {
    return this.state.index !== null ? this.state.index : this.props.index;
  }

  toggleNavigation = () => {
    this.setState(prevState => ({
      navigationHidden: !prevState.navigationHidden,
    }));
  };

  handleStatusClick = e => {
    if (e.button === 0 && !(e.ctrlKey || e.metaKey)) {
      e.preventDefault();
      this.context.router.history.push(`/statuses/${this.statusIdForIndex(this.getIndex())}`);
    }
  }

  render () {
    const { media, intl, onClose } = this.props;
    const { navigationHidden } = this.state;

    const index = this.getIndex();
    const timelineSequence = this.isTimelineSequence();
    const statusId = this.statusIdForIndex(index);
    const leftNav  = media.size > 1 && (!timelineSequence || index > 0) && <button tabIndex='0' className='media-modal__nav media-modal__nav--left' onClick={this.handlePrevClick} aria-label={intl.formatMessage(messages.previous)}><Icon id='chevron-left' fixedWidth /></button>;
    const rightNav = media.size > 1 && (!timelineSequence || index < media.size - 1) && <button tabIndex='0' className='media-modal__nav  media-modal__nav--right' onClick={this.handleNextClick} aria-label={intl.formatMessage(messages.next)}><Icon id='chevron-right' fixedWidth /></button>;

    const content = media.map((image, imageIndex) => {
      // Large timelines may have many loaded pictures. Only mount nearby
      // image widgets while preserving the swipeable view's slide indices.
      if (timelineSequence && Math.abs(imageIndex - index) > 2) {
        return <div key={`${image.get('id') || 'media'}:${imageIndex}`} />;
      }

      const attributedId = this.statusIdForIndex(imageIndex);
      const fromTimeline = this.props.timelineStatuses && this.props.timelineStatuses.get(attributedId);
      const reblog = fromTimeline && fromTimeline.get('reblog');
      const displayed = reblog && this.props.timelineStatuses
        ? (this.props.timelineStatuses.get(reblog) || fromTimeline) : fromTimeline;
      const translationView = displayed ? statusTranslationView(displayed) : this.props.translationView;
      const width  = image.getIn(['meta', 'original', 'width']) || null;
      const height = image.getIn(['meta', 'original', 'height']) || null;
      const accessible = attachmentAccessibility(image, translationView || {
        mode: image.getIn(['translation', 'description']) ? 'translated' : 'original',
        sourceLang: this.props.lang || '',
        targetLang: this.props.lang || '',
      });
      const description = accessible.text;
      const lang = accessible.lang || this.props.lang;

      if (image.get('type') === 'image') {
        return (
          <ImageLoader
            previewSrc={image.get('preview_url')}
            src={image.get('url')}
            width={width}
            height={height}
            alt={description}
            lang={lang}
            key={`${image.get('url')}:${imageIndex}`}
            onClick={this.toggleNavigation}
            zoomButtonHidden={this.state.zoomButtonHidden}
          />
        );
      } else if (image.get('type') === 'video') {
        const { currentTime, autoPlay, volume } = this.props;

        return (
          <Video
            preview={image.get('preview_url')}
            thumbhash={image.get('thumbhash')}
            blurhash={image.get('blurhash')}
            src={image.get('url')}
            width={image.get('width')}
            height={image.get('height')}
            frameRate={image.getIn(['meta', 'original', 'frame_rate'])}
            currentTime={currentTime || 0}
            autoPlay={autoPlay || false}
            volume={volume || 1}
            onCloseVideo={onClose}
            detailed
            alt={description}
            lang={lang}
            key={`${image.get('url')}:${imageIndex}`}
          />
        );
      } else if (image.get('type') === 'gifv') {
        return (
          <GIFV
            src={image.get('url')}
            width={width}
            height={height}
            key={`${image.get('preview_url')}:${imageIndex}`}
            alt={description}
            lang={lang}
            onClick={this.toggleNavigation}
          />
        );
      }

      return null;
    }).toArray();

    // you can't use 100vh, because the viewport height is taller
    // than the visible part of the document in some mobile
    // browsers when it's address bar is visible.
    // https://developers.google.com/web/updates/2016/12/url-bar-resizing
    const swipeableViewsStyle = {
      width: '100%',
      height: '100%',
    };

    const containerStyle = {
      alignItems: 'center', // center vertically
    };

    const navigationClassName = classNames('media-modal__navigation', {
      'media-modal__navigation--hidden': navigationHidden,
    });

    let pagination;

    if (media.size > 1) {
      pagination = timelineSequence ? (
        <li className='media-modal__timeline-counter'>{index + 1} / {media.size}</li>
      ) : media.map((item, i) => (
        <button key={i} className={classNames('media-modal__page-dot', { active: i === index })} data-index={i} onClick={this.handleChangeIndex}>
          {i + 1}
        </button>
      ));
    }

    return (
      <div className='modal-root__modal media-modal'>
        <div className='media-modal__closer' role='presentation' onClick={onClose} >
          <ReactSwipeableViews
            style={swipeableViewsStyle}
            containerStyle={containerStyle}
            onChangeIndex={this.handleSwipe}
            onTransitionEnd={this.handleTransitionEnd}
            index={index}
            disabled={disableSwiping}
          >
            {content}
          </ReactSwipeableViews>
        </div>

        <div className={navigationClassName}>
          <IconButton className='media-modal__close' title={intl.formatMessage(messages.close)} icon='times' onClick={onClose} size={40} />

          {leftNav}
          {rightNav}

          <div className='media-modal__overlay'>
            {pagination && <ul className='media-modal__pagination'>{pagination}</ul>}
            {statusId && <Footer statusId={statusId} withOpenButton onClose={onClose} />}
          </div>
        </div>
      </div>
    );
  }

}

// Public status pages mount this without a Redux store. The logged-in WebUI
// keeps the connected default export so translation state still comes from status.
export const PublicMediaModal = injectIntl(MediaModal);

export default connect(mapStateToProps)(PublicMediaModal);
