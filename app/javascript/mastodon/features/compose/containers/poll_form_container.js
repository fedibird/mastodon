import { connect } from 'react-redux';
import PollForm from '../components/poll_form';
import { addPollOption, removePollOption, changePollOption, changePollSettings } from '../../../actions/compose';
import {
  clearComposerSuggestions,
  fetchComposerSuggestions,
  selectComposerSuggestion,
} from '../../../actions/compose';
import { targetComposerAction } from '../../../actions/composer';
import { selectComposer } from '../../../selectors/composer';
import { withComposerId } from '../composer_id_context';

const mapStateToProps = (state, { composerId }) => {
  const composer = selectComposer(state, composerId);

  return {
    suggestions: composer.get('suggestions'),
    options: composer.getIn(['poll', 'options']),
    expiresIn: composer.getIn(['poll', 'expires_in']),
    isMultiple: composer.getIn(['poll', 'multiple']),
    pollMaxOptions: composer.get('poll_max_options'),
    lang: composer.get('language'),
  };
};

const mapDispatchToProps = (dispatch, { composerId }) => ({
  onAddOption(title) {
    dispatch(targetComposerAction(addPollOption(title), composerId));
  },

  onRemoveOption(index) {
    dispatch(targetComposerAction(removePollOption(index), composerId));
  },

  onChangeOption(index, title) {
    dispatch(targetComposerAction(changePollOption(index, title), composerId));
  },

  onChangeSettings(expiresIn, isMultiple) {
    dispatch(targetComposerAction(changePollSettings(expiresIn, isMultiple), composerId));
  },

  onClearSuggestions () {
    dispatch(clearComposerSuggestions(composerId));
  },

  onFetchSuggestions (token) {
    dispatch(fetchComposerSuggestions(composerId, token));
  },

  onSuggestionSelected (position, token, accountId, path) {
    dispatch(selectComposerSuggestion(composerId, position, token, accountId, path));
  },

});

export default withComposerId(connect(mapStateToProps, mapDispatchToProps)(PollForm));
