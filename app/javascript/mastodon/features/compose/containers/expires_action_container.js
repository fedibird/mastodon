import { connect } from 'react-redux';
import ExpiresAction from '../components/expires_action';
import { changeExpiresAction } from '../../../actions/compose';
import { targetComposerAction } from '../../../actions/composer';
import { selectComposer } from '../../../selectors/composer';
import { withComposerId } from '../composer_id_context';

const mapStateToProps = (state, { composerId }) => ({
  value: selectComposer(state, composerId).get('expires_action') ?? '',
});

const mapDispatchToProps = (dispatch, { composerId }) => ({

  onChange (value) {
    dispatch(targetComposerAction(changeExpiresAction(value), composerId));
  },

});

export default withComposerId(connect(mapStateToProps, mapDispatchToProps)(ExpiresAction));
