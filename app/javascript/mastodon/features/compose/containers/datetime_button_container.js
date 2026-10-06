import { connect } from 'react-redux';
import DateTimeButton from '../components/datetime_button';
import { addDateTime, removeDateTime } from '../../../actions/compose';
import { targetComposerAction } from '../../../actions/composer';
import { selectComposer } from '../../../selectors/composer';
import { withComposerId } from '../composer_id_context';

const mapStateToProps = (state, { composerId }) => ({
  active: selectComposer(state, composerId).get('datetime_form') !== null,
});

const mapDispatchToProps = (dispatch, { composerId }) => ({

  onClick () {
    dispatch((_, getState) => {
      const composer = selectComposer(getState(), composerId);

      if (composer.get('datetime_form')) {
        dispatch(targetComposerAction(removeDateTime(), composerId));
      } else {
        dispatch(targetComposerAction(addDateTime(), composerId));
      }
    });
  },

});

export default withComposerId(connect(mapStateToProps, mapDispatchToProps)(DateTimeButton));
