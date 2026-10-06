import { connect } from 'react-redux';
import ExpiresIndicator from '../components/expires_indicator';
import { removeDateTime } from '../../../actions/compose';
import { targetComposerAction } from '../../../actions/composer';
import { selectComposer } from '../../../selectors/composer';
import { withComposerId } from '../composer_id_context';

const mapStateToProps = (state, { composerId }) => {
  const composer = selectComposer(state, composerId);

  return {
    default_expires: composer.get('default_expires'),
    expires: composer.get('expires'),
    expires_action: composer.get('expires_action'),
  };
};

const mapDispatchToProps = (dispatch, { composerId }) => ({

  onCancel () {
    dispatch(targetComposerAction(removeDateTime(), composerId));
  },

});

export default withComposerId(connect(mapStateToProps, mapDispatchToProps)(ExpiresIndicator));
