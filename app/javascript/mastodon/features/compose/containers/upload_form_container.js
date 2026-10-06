import { connect } from 'react-redux';
import UploadForm from '../components/upload_form';
import { selectComposer } from '../../../selectors/composer';
import { withComposerId } from '../composer_id_context';

const mapStateToProps = (state, { composerId }) => ({
  mediaIds: selectComposer(state, composerId).get('media_attachments').map(item => item.get('id')),
});

export default withComposerId(connect(mapStateToProps)(UploadForm));
