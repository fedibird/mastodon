import React from 'react';
import ImmutablePropTypes from 'react-immutable-proptypes';
import PropTypes from 'prop-types';
import Audio from 'mastodon/features/audio';
import { connect } from 'react-redux';
import ImmutablePureComponent from 'react-immutable-pure-component';
import Footer from 'mastodon/features/picture_in_picture/components/footer';
import { addReference, removeReference } from 'mastodon/actions/compose';
import { makeGetStatus } from 'mastodon/selectors';

const makeMapStateToProps = () => {
  const getStatus = makeGetStatus();
  const getProper = (status) => status.get('reblog', null) !== null && typeof status.get('reblog') === 'object' ? status.get('reblog') : status;

  const mapStateToProps = (state, props) => {
    const status         = getStatus(state, { id: props.statusId });
    const id             = status ? getProper(status).get('id') : null;

    const proper = status ? getProper(status) : null;

    return {
      referenced: state.getIn(['compose', 'references']).has(id),
      contextReferenced: state.getIn(['compose', 'context_references']).has(id),
      accountStaticAvatar: state.getIn(['accounts', state.getIn(['statuses', props.statusId, 'account']), 'avatar_static']),
      lang: props.lang || (proper ? (proper.getIn(['translation', 'language']) || proper.get('language')) : undefined),
    };
  };

  return mapStateToProps;
};

export default @connect(makeMapStateToProps)
class AudioModal extends ImmutablePureComponent {

  static propTypes = {
    media: ImmutablePropTypes.map.isRequired,
    statusId: PropTypes.string.isRequired,
    lang: PropTypes.string,
    accountStaticAvatar: PropTypes.string.isRequired,
    options: PropTypes.shape({
      autoPlay: PropTypes.bool,
    }),
    onClose: PropTypes.func.isRequired,
    onChangeBackgroundColor: PropTypes.func.isRequired,
  };

  handleAddReference = (id, change) => {
    this.props.dispatch(addReference(id, change));
  }

  handleRemoveReference = (id) => {
    this.props.dispatch(removeReference(id));
  }

  render () {
    const { media, accountStaticAvatar, statusId, onClose, lang } = this.props;
    const options = this.props.options || {};
    const description = media.getIn(['translation', 'description']) || media.get('description');

    return (
      <div className='modal-root__modal audio-modal'>
        <div className='audio-modal__container'>
          <Audio
            src={media.get('url')}
            alt={description}
            lang={lang}
            duration={media.getIn(['meta', 'original', 'duration'], 0)}
            height={150}
            poster={media.get('preview_url') || accountStaticAvatar}
            backgroundColor={media.getIn(['meta', 'colors', 'background'])}
            foregroundColor={media.getIn(['meta', 'colors', 'foreground'])}
            accentColor={media.getIn(['meta', 'colors', 'accent'])}
            autoPlay={options.autoPlay}
          />
        </div>

        <div className='media-modal__overlay'>
          {statusId && <Footer statusId={statusId} withOpenButton onClose={onClose} />}
        </div>
      </div>
    );
  }

}
