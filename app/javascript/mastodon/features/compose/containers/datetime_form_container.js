import { connect } from 'react-redux';
import DateTimeForm from '../components/datetime_form';
import { selectComposer } from '../../../selectors/composer';
import { withComposerId } from '../composer_id_context';

const mapStateToProps = (state, { composerId }) => ({
  form_enable: !!selectComposer(state, composerId).get('datetime_form'),
});

export default withComposerId(connect(mapStateToProps)(DateTimeForm));
