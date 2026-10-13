import React from 'react';
import ImmutablePropTypes from 'react-immutable-proptypes';
import PropTypes from 'prop-types';
import UploadProgressContainer from '../containers/upload_progress_container';
import ImmutablePureComponent from 'react-immutable-pure-component';
import SensitiveButtonContainer from '../containers/sensitive_button_container';
import ComposerMediaGallery from './composer_media_gallery';

export default class UploadForm extends ImmutablePureComponent {

  static propTypes = {
    media: ImmutablePropTypes.list.isRequired,
    summary: PropTypes.bool,
    endAccessory: PropTypes.node,
    onEdit: PropTypes.func.isRequired,
    onRemove: PropTypes.func.isRequired,
    onMoveTo: PropTypes.func.isRequired,
    onMoveBy: PropTypes.func.isRequired,
  };

  render () {
    const { media, summary } = this.props;
    const hasMedia = media && !media.isEmpty();

    return (
      <div className='compose-form__upload-wrapper'>
        <UploadProgressContainer />

        {hasMedia && (
          <ComposerMediaGallery
            media={media}
            summary={summary}
            onEdit={this.props.onEdit}
            onRemove={this.props.onRemove}
            onMoveTo={this.props.onMoveTo}
            onMoveBy={this.props.onMoveBy}
          />
        )}

        {hasMedia && !summary && (
          <div className='compose-form__sensitive-row'>
            <SensitiveButtonContainer />
            {this.props.endAccessory}
          </div>
        )}
      </div>
    );
  }

}
