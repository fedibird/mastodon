import { connect } from 'react-redux';
import Upload from '../components/upload';
import { undoUploadCompose, initMediaEditModal, changeMediaOrder } from '../../../actions/compose';
import { submitComposeWithCheck } from '../../../actions/compose';
import { injectIntl } from 'react-intl';

const mapStateToProps = (state, { id, index, size }) => ({
  media: state.getIn(['compose', 'media_attachments']).find(item => item.get('id') === id),
  showOrder: size > 1,
  canMoveBackward: index > 0,
  canMoveForward: index < size - 1,
});

const mapDispatchToProps = (dispatch, { intl }) => ({

  onUndo: id => {
    dispatch(undoUploadCompose(id));
  },

  onOpenFocalPoint: id => {
    dispatch(initMediaEditModal(id));
  },

  onMoveBackward: id => {
    dispatch(changeMediaOrder(id, -1));
  },

  onMoveForward: id => {
    dispatch(changeMediaOrder(id, 1));
  },

  onSubmit (router) {
    dispatch(submitComposeWithCheck(router, intl));
  },

});

export default injectIntl(connect(mapStateToProps, mapDispatchToProps)(Upload));
