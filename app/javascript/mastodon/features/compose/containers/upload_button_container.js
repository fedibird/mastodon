import { connect } from 'react-redux';
import UploadButton from '../components/upload_button';
import { uploadToComposer } from '../../../actions/compose';
import { allowPollImage, maxAttachments } from '../../../initial_state';
import { selectComposer } from '../../../selectors/composer';
import { withComposerId } from '../composer_id_context';

const mapStateToProps = (state, { composerId }) => {
  const composer = selectComposer(state, composerId);
  const media = composer.get('media_attachments');
  const hasImages = media.some(item => item.get('type') === 'image');
  let acceptContentTypes = state.getIn(['media_attachments', 'accept_content_types']);

  if (hasImages && acceptContentTypes) {
    const images = acceptContentTypes.filter(type => String(type).startsWith('image/'));

    if (images.size > 0) {
      acceptContentTypes = images;
    }
  }

  return {
    disabled: composer.get('is_uploading') || (media.size + composer.get('pending_media_attachments') >= maxAttachments || media.some(m => ['video', 'audio', 'gifv'].includes(m.get('type')))),
    unavailable: !allowPollImage && composer.get('poll') !== null,
    resetFileKey: composer.get('resetFileKey'),
    acceptContentTypes,
  };
};

const mapDispatchToProps = (dispatch, { composerId }) => ({

  onSelectFile (files) {
    dispatch(uploadToComposer(composerId, files));
  },

});

export default withComposerId(connect(mapStateToProps, mapDispatchToProps)(UploadButton));
