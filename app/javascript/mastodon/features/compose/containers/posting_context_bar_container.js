import { connect } from 'react-redux';
import { List as ImmutableList, Set as ImmutableSet } from 'immutable';
import { toggleComposerManagedHashtag } from '../../../actions/composer';
import { selectComposer } from '../../../selectors/composer';
import { withComposerId } from '../composer_id_context';
import PostingContextBar from '../components/posting_context_bar';

const mapStateToProps = (state, { composerId }) => {
  const composer = selectComposer(state, composerId);

  if (!composer) {
    return {
      hashtags: ImmutableList(),
      suppressedHashtags: ImmutableSet(),
    };
  }

  return {
    hashtags: composer.getIn(['context', 'managed', 'hashtags'], ImmutableList()),
    suppressedHashtags: composer.getIn(['context', 'suppressions', 'hashtags'], ImmutableSet()),
  };
};

const mapDispatchToProps = (dispatch, { composerId }) => ({

  onToggle (normalizedName) {
    dispatch(toggleComposerManagedHashtag(composerId, normalizedName));
  },

});

export default withComposerId(connect(mapStateToProps, mapDispatchToProps)(PostingContextBar));
