import { connect } from 'react-redux';
import { undoUploadCompose, initComposerMediaEditModal, changeMediaOrder, moveComposerMediaToIndex } from '../../../actions/compose';
import { targetComposerAction } from '../../../actions/composer';
import { selectComposer } from '../../../selectors/composer';
import { withComposerId } from '../composer_id_context';
import UploadForm from '../components/upload_form';

const mapStateToProps = (state, { composerId }) => ({
  media: selectComposer(state, composerId).get('media_attachments'),
});

const mapDispatchToProps = (dispatch, { composerId }) => ({
  onRemove (id) {
    dispatch(targetComposerAction(undoUploadCompose(id), composerId));
  },

  onEdit (id) {
    dispatch(initComposerMediaEditModal(composerId, id));
  },

  onMoveBy (id, direction) {
    dispatch(targetComposerAction(changeMediaOrder(id, direction), composerId));
  },

  onMoveTo (id, toIndex) {
    dispatch(targetComposerAction(moveComposerMediaToIndex(id, toIndex), composerId));
  },
});

export default withComposerId(connect(mapStateToProps, mapDispatchToProps)(UploadForm));
