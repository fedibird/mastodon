import { connect } from 'react-redux';
import { List as ImmutableList } from 'immutable';
import UploadButton from '../components/upload_button';
import { uploadToComposer } from '../../../actions/compose';
import { allowPollImage, maxAttachments } from '../../../initial_state';
import { selectComposer } from '../../../selectors/composer';
import { withComposerId } from '../composer_id_context';

const mapStateToProps = (state, { composerId }) => {
  const composer = selectComposer(state, composerId);
  const media = composer.get('media_attachments');
  const hasImages = media.some(item => item.get('type') === 'image');
  const hasExclusive = media.some(item => ['video', 'audio', 'gifv'].includes(item.get('type'))) || (composer.get('pending_exclusive_attachments') || 0) > 0;
  let acceptContentTypes = state.getIn(['media_attachments', 'accept_content_types']) || ImmutableList();

  if (hasImages && !hasExclusive && acceptContentTypes.size > 0) {
    const images = acceptContentTypes.filter(type => String(type).startsWith('image/'));

    if (images.size > 0) {
      acceptContentTypes = images;
    }
  }

  return {
    disabled: composer.get('is_uploading') || hasExclusive || (media.size + composer.get('pending_media_attachments') >= maxAttachments),
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
