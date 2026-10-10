import React from 'react';
import IconButton from '../../../components/icon_button';
import PropTypes from 'prop-types';
import { defineMessages, injectIntl } from 'react-intl';
import { connect } from 'react-redux';
import ImmutablePureComponent from 'react-immutable-pure-component';
import ImmutablePropTypes from 'react-immutable-proptypes';

const messages = defineMessages({
  upload: { id: 'upload_button.label', defaultMessage: 'Add images, a video or an audio file' },
  stillImage: { id: 'upload_button.still_image', defaultMessage: 'Add a still image' },
  stillImageOnly: { id: 'upload_button.still_image_only', defaultMessage: 'Still images only.' },
  mediaUnavailable: { id: 'upload_button.media_unavailable', defaultMessage: 'Image upload needs posting and media permission for this account.' },
  mediaType: { id: 'upload_button.media_type', defaultMessage: 'Video and audio cannot be posted as this account.' },
});

const makeMapStateToProps = () => {
  const mapStateToProps = (state, ownProps) => ({
    acceptContentTypes: ownProps.acceptContentTypes || state.getIn(['media_attachments', 'accept_content_types']),
  });

  return mapStateToProps;
};

const iconStyle = {
  height: null,
  lineHeight: '27px',
};

export default @connect(makeMapStateToProps)
@injectIntl
class UploadButton extends ImmutablePureComponent {

  static propTypes = {
    disabled: PropTypes.bool,
    unavailable: PropTypes.bool,
    onSelectFile: PropTypes.func.isRequired,
    style: PropTypes.object,
    resetFileKey: PropTypes.number,
    stillImagesOnly: PropTypes.bool,
    uploadReason: PropTypes.string,
    acceptContentTypes: ImmutablePropTypes.listOf(PropTypes.string).isRequired,
    intl: PropTypes.object.isRequired,
  };

  handleChange = (e) => {
    if (e.target.files.length > 0) {
      this.props.onSelectFile(e.target.files);
    }
  }

  handleClick = () => {
    this.fileElement.click();
  }

  setRef = (c) => {
    this.fileElement = c;
  }

  render () {
    const { intl, resetFileKey, unavailable, disabled, acceptContentTypes, stillImagesOnly, uploadReason } = this.props;

    if (unavailable) {
      return null;
    }

    const message = intl.formatMessage(stillImagesOnly ? messages.stillImage : messages.upload);
    let notice = null;

    if (stillImagesOnly && !disabled) {
      notice = intl.formatMessage(messages.stillImageOnly);
    } else if (uploadReason === 'media') {
      notice = intl.formatMessage(messages.mediaUnavailable);
    } else if (uploadReason === 'media_type') {
      notice = intl.formatMessage(messages.mediaType);
    }

    return (
      <div className='compose-form__upload-button'>
        <IconButton icon='paperclip' title={message} disabled={disabled} onClick={this.handleClick} className='compose-form__upload-button-icon' size={18} inverted style={iconStyle} />
        {notice ? <p className='compose-form__upload-notice' role='status'>{notice}</p> : null}
        <label>
          <span style={{ display: 'none' }}>{message}</span>
          <input
            key={resetFileKey}
            ref={this.setRef}
            type='file'
            multiple
            accept={acceptContentTypes.toArray().join(',')}
            onChange={this.handleChange}
            disabled={disabled}
            style={{ display: 'none' }}
          />
        </label>
      </div>
    );
  }

}
