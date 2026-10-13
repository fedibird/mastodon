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
  const hasImages = media.some(item => item.get('type') === 'image');
  const hasExclusive = media.some(item => ['video', 'audio', 'gifv'].includes(item.get('type'))) || (composer.get('pending_exclusive_attachments') || 0) > 0;
  let acceptContentTypes = state.getIn(['media_attachments', 'accept_content_types']) || ImmutableList();

  if (upload.stillImagesOnly) {
    acceptContentTypes = ImmutableList(STILL_IMAGE_CONTENT_TYPES);
  } else if (hasImages && !hasExclusive && acceptContentTypes.size > 0) {
    const images = acceptContentTypes.filter(type => String(type).startsWith('image/'));

    if (images.size > 0) {
      acceptContentTypes = images;
    }
  }

  return {
    disabled: composer.get('is_uploading') || composer.get('is_processing') || hasExclusive || (media.size + composer.get('pending_media_attachments') >= maxAttachments) || (upload.canUpload === false && ['media', 'media_type'].includes(upload.reason)),
    unavailable: !allowPollImage && composer.get('poll') !== null,
    resetFileKey: composer.get('resetFileKey'),
    stillImagesOnly: upload.stillImagesOnly === true,
    uploadReason: upload.canUpload ? null : upload.reason,
    acceptContentTypes,
  };
};

const mapDispatchToProps = (dispatch, { composerId }) => ({

  onSelectFile (files) {
    dispatch(uploadToComposer(composerId, files));
  },

});

export default withComposerId(connect(mapStateToProps, mapDispatchToProps)(UploadButton));
