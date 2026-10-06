import { connect } from 'react-redux';
import Upload from '../components/upload';
import { undoUploadCompose, initComposerMediaEditModal, changeMediaOrder } from '../../../actions/compose';
import { submitComposerWithCheck } from '../../../actions/compose';
import { targetComposerAction } from '../../../actions/composer';
import { injectIntl } from 'react-intl';
import { selectComposer } from '../../../selectors/composer';
import { withComposerId } from '../composer_id_context';

const mapStateToProps = (state, { composerId, id, index, size }) => ({
  media: selectComposer(state, composerId).get('media_attachments').find(item => item.get('id') === id),
  showOrder: size > 1,
  canMoveBackward: index > 0,
  canMoveForward: index < size - 1,
});

const mapDispatchToProps = (dispatch, { intl, composerId }) => ({

  onUndo: id => {
    dispatch(targetComposerAction(undoUploadCompose(id), composerId));
  },

  onOpenFocalPoint: id => {
    dispatch(initComposerMediaEditModal(composerId, id));
  },

  onMoveBackward: id => {
    dispatch(targetComposerAction(changeMediaOrder(id, -1), composerId));
  },

  onMoveForward: id => {
    dispatch(targetComposerAction(changeMediaOrder(id, 1), composerId));
  },

  onSubmit (router) {
    dispatch(submitComposerWithCheck(composerId, router, intl));
  },

});

export default withComposerId(injectIntl(connect(mapStateToProps, mapDispatchToProps)(Upload)));
