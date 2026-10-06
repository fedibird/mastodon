import { connect } from 'react-redux';
import UploadButton from '../components/upload_button';
import { uploadToComposer } from '../../../actions/compose';
import { allowPollImage, maxAttachments } from '../../../initial_state';
import { selectComposer } from '../../../selectors/composer';
import { withComposerId } from '../composer_id_context';

const mapStateToProps = (state, { composerId }) => {
  const composer = selectComposer(state, composerId);
  const media = composer.get('media_attachments');

  return {
    disabled: composer.get('is_uploading') || (media.size + composer.get('pending_media_attachments') >= maxAttachments || media.some(m => ['video', 'audio'].includes(m.get('type')))),
    unavailable: !allowPollImage && composer.get('poll') !== null,
    resetFileKey: composer.get('resetFileKey'),
  };
};

const mapDispatchToProps = (dispatch, { composerId }) => ({

  onSelectFile (files) {
    dispatch(uploadToComposer(composerId, files));
  },

});

export default withComposerId(connect(mapStateToProps, mapDispatchToProps)(UploadButton));
