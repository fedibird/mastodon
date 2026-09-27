import React from 'react';
import ImmutablePropTypes from 'react-immutable-proptypes';
import PropTypes from 'prop-types';
import Video from 'mastodon/features/video';
import ImmutablePureComponent from 'react-immutable-pure-component';
import Footer from 'mastodon/features/picture_in_picture/components/footer';
import { getAverageFromBlurhash } from 'mastodon/blurhash';
import { connect } from 'react-redux';
import { attachmentAccessibility, statusTranslationView } from 'mastodon/utils/translation_view';

const mapStateToProps = (state, props) => {
  const status = props.statusId ? state.getIn(['statuses', props.statusId]) : null;

  const translationView = status ? statusTranslationView(status) : null;

  return {
    translationView,
    lang: translationView ? translationView.mediaLang : props.lang,
  };
};

export default @connect(mapStateToProps)
class VideoModal extends ImmutablePureComponent {

  static propTypes = {
    media: ImmutablePropTypes.map.isRequired,
    statusId: PropTypes.string,
    lang: PropTypes.string,
    translationView: PropTypes.object,
    options: PropTypes.shape({
      startTime: PropTypes.number,
      autoPlay: PropTypes.bool,
      defaultVolume: PropTypes.number,
    }),
    onClose: PropTypes.func.isRequired,
    onChangeBackgroundColor: PropTypes.func.isRequired,
  };

  componentDidMount () {
    const { media, onChangeBackgroundColor } = this.props;

    const backgroundColor = getAverageFromBlurhash(media.get('blurhash'));

    if (backgroundColor) {
      onChangeBackgroundColor(backgroundColor);
    }
  }

  render () {
    const { media, statusId, onClose, translationView } = this.props;
    const options = this.props.options || {};
    const accessible = attachmentAccessibility(media, translationView || {
      mode: media.getIn(['translation', 'description']) ? 'translated' : 'original',
      sourceLang: this.props.lang || '',
      targetLang: this.props.lang || '',
    });
    const description = accessible.text;
    const lang = accessible.lang || this.props.lang;

    return (
      <div className='modal-root__modal video-modal'>
        <div className='video-modal__container'>
          <Video
            preview={media.get('preview_url')}
            frameRate={media.getIn(['meta', 'original', 'frame_rate'])}
            thumbhash={media.get('thumbhash')}
            blurhash={media.get('blurhash')}
            src={media.get('url')}
            currentTime={options.startTime}
            autoPlay={options.autoPlay}
            volume={options.defaultVolume}
            onCloseVideo={onClose}
            detailed
            alt={description}
            lang={lang}
          />
        </div>

        <div className='media-modal__overlay'>
          {statusId && <Footer statusId={statusId} withOpenButton onClose={onClose} />}
        </div>
      </div>
    );
  }

}
