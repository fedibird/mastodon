import { connect } from 'react-redux';
import PollButton from '../components/poll_button';
import { addPoll, removePoll } from '../../../actions/compose';
import { targetComposerAction } from '../../../actions/composer';
import { allowPollImage } from '../../../initial_state';
import { selectComposer } from '../../../selectors/composer';
import { withComposerId } from '../composer_id_context';

const mapStateToProps = (state, { composerId }) => {
  const composer = selectComposer(state, composerId);

  return {
    unavailable: !allowPollImage && (composer.get('is_uploading') || (composer.get('media_attachments').size > 0)),
    active: composer.get('poll') !== null,
  };
};

const mapDispatchToProps = (dispatch, { composerId }) => ({

  onClick () {
    dispatch((_, getState) => {
      const composer = selectComposer(getState(), composerId);

      if (composer.get('poll')) {
        dispatch(targetComposerAction(removePoll(), composerId));
      } else {
        dispatch(targetComposerAction(addPoll(), composerId));
      }
    });
  },

});

export default withComposerId(connect(mapStateToProps, mapDispatchToProps)(PollButton));
