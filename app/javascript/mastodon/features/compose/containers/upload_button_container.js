import { List as ImmutableList } from 'immutable';
import { connect } from 'react-redux';
import UploadButton from '../components/upload_button';
import { uploadToComposer } from '../../../actions/compose';
import { allowPollImage, maxAttachments } from '../../../initial_state';
import { STILL_IMAGE_CONTENT_TYPES } from '../../../posting_identity/still_image';
import { selectComposer } from '../../../selectors/composer';
import { selectComposerCanUploadAsIdentity } from '../../../selectors/posting_identities';
import { withComposerId } from '../composer_id_context';

const mapStateToProps = (state, { composerId }) => {
  const composer = selectComposer(state, composerId);
  const media = composer.get('media_attachments');
  const upload = selectComposerCanUploadAsIdentity(state, composerId);
  const atLimit = media.size + composer.get('pending_media_attachments') >= maxAttachments;
  const hasMovingMedia = media.some(item => ['video', 'audio', 'gifv'].includes(item.get('type')));

  return {
    disabled: !upload.canUpload || composer.get('is_uploading') || composer.get('is_processing') || atLimit || hasMovingMedia,
    unavailable: !allowPollImage && composer.get('poll') !== null,
    resetFileKey: composer.get('resetFileKey'),
    stillImagesOnly: upload.stillImagesOnly === true,
    uploadReason: upload.canUpload ? null : upload.reason,
    acceptContentTypes: upload.stillImagesOnly ? ImmutableList(STILL_IMAGE_CONTENT_TYPES) : undefined,
  };
};

const mapDispatchToProps = (dispatch, { composerId }) => ({

  onSelectFile (files) {
    dispatch(uploadToComposer(composerId, files));
  },

});

export default withComposerId(connect(mapStateToProps, mapDispatchToProps)(UploadButton));
