import { connect } from 'react-redux';
import DateTimeForm from '../components/datetime_form';
import { removeDateTime } from '../../../actions/compose';
import { targetComposerAction } from '../../../actions/composer';
import { selectComposer } from '../../../selectors/composer';
import { withComposerId } from '../composer_id_context';

const mapStateToProps = (state, { composerId }) => ({
  form_enable: !!selectComposer(state, composerId).get('datetime_form'),
});

const mapDispatchToProps = (dispatch, { composerId }) => ({
  onClose () {
    dispatch(targetComposerAction(removeDateTime(), composerId));
  },
});

export default withComposerId(connect(mapStateToProps, mapDispatchToProps)(DateTimeForm));
