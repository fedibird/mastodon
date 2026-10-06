import { connect } from 'react-redux';
import UploadProgress from '../components/upload_progress';
import { selectComposer } from '../../../selectors/composer';
import { withComposerId } from '../composer_id_context';

const mapStateToProps = (state, { composerId }) => {
  const composer = selectComposer(state, composerId);

  return {
    active: composer.get('is_uploading'),
    progress: composer.get('progress'),
    isProcessing: composer.get('is_processing'),
  };
};

export default withComposerId(connect(mapStateToProps)(UploadProgress));
