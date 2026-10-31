import React from 'react';
import IconButton from '../../../components/icon_button';
import Icon from 'mastodon/components/icon';
import PropTypes from 'prop-types';
import { defineMessages, injectIntl } from 'react-intl';
import ImmutablePureComponent from 'react-immutable-pure-component';
import ImmutablePropTypes from 'react-immutable-proptypes';

const messages = defineMessages({
  upload: { id: 'upload_button.label', defaultMessage: 'Add images, a video or an audio file' },
  stillImage: { id: 'upload_button.still_image', defaultMessage: 'Add a still image' },
  stillImageOnly: { id: 'upload_button.still_image_only', defaultMessage: 'Still images only.' },
  mediaUnavailable: { id: 'upload_button.media_unavailable', defaultMessage: 'Image upload needs posting and media permission for this account.' },
  mediaType: { id: 'upload_button.media_type', defaultMessage: 'Video and audio cannot be posted as this account.' },
  mediaOwner: { id: 'compose_form.media_owner', defaultMessage: 'These images belong to a different posting account. They stay attached, and this post cannot be sent until they match the selected account.' },
});

const iconStyle = {
  height: null,
  lineHeight: '27px',
};

export default @injectIntl
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
    presentation: PropTypes.oneOf(['menu']),
    onMenuClose: PropTypes.func,
  };

  handleChange = (e) => {
    if (e.target.files.length > 0) {
      this.props.onSelectFile(e.target.files);
    }
  }

  handleClick = () => {
    if (this.fileElement) {
      this.fileElement.click();
    }

    if (this.props.onMenuClose) {
      this.props.onMenuClose();
    }
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
    const menu = this.props.presentation === 'menu';
    let notice = null;

    if (stillImagesOnly && !disabled) {
      notice = intl.formatMessage(messages.stillImageOnly);
    } else if (uploadReason === 'media') {
      notice = intl.formatMessage(messages.mediaUnavailable);
    } else if (uploadReason === 'media_type') {
      notice = intl.formatMessage(messages.mediaType);
    } else if (uploadReason === 'media_owner') {
      notice = intl.formatMessage(messages.mediaOwner);
    }

    const fileInput = (
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
    );

    if (menu) {
      return (
        <div className='compose-form__upload-button'>
          <button type='button' className='compose-form__menu-row' disabled={disabled} onClick={this.handleClick}>
            <Icon id='paperclip' fixedWidth aria-hidden='true' />
            <span>{message}</span>
          </button>
          {notice ? <p className='compose-form__upload-notice' role='status'>{notice}</p> : null}
          {fileInput}
        </div>
      );
    }

    return (
      <div className='compose-form__upload-button'>
        <IconButton icon='paperclip' title={message} disabled={disabled} onClick={this.handleClick} className='compose-form__upload-button-icon' size={18} inverted style={iconStyle} />
        {notice ? <p className='compose-form__upload-notice' role='status'>{notice}</p> : null}
        {fileInput}
      </div>
    );
  }

}
