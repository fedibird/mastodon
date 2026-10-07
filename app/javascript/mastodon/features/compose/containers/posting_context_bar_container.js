import { connect } from 'react-redux';
import { List as ImmutableList, Set as ImmutableSet } from 'immutable';
import { toggleComposerManagedHashtag } from '../../../actions/composer';
import { selectComposerPostingContextCompliance } from '../../../posting_context/compliance';
import { selectComposer } from '../../../selectors/composer';
import { withComposerId } from '../composer_id_context';
import PostingContextBar from '../components/posting_context_bar';

const mapStateToProps = (state, { composerId }) => {
  const composer = selectComposer(state, composerId);

  if (!composer) {
    return {
      hashtags: ImmutableList(),
      suppressedHashtags: ImmutableSet(),
      mentions: ImmutableList(),
      audience: null,
      visibility: null,
      followingAccounts: [],
    };
  }

  const compliance = selectComposerPostingContextCompliance(state, composerId);

  return {
    hashtags: composer.getIn(['context', 'managed', 'hashtags'], ImmutableList()),
    suppressedHashtags: composer.getIn(['context', 'suppressions', 'hashtags'], ImmutableSet()),
    mentions: composer.getIn(['context', 'managed', 'mentions'], ImmutableList()),
    audience: composer.getIn(['context', 'protocol', 'activityPub', 'audience']),
    visibility: compliance.visibility,
    followingAccounts: compliance.followingAccounts,
  };
};

const mapDispatchToProps = (dispatch, { composerId }) => ({

  onToggle (normalizedName) {
    dispatch(toggleComposerManagedHashtag(composerId, normalizedName));
  },

});

export default withComposerId(connect(mapStateToProps, mapDispatchToProps)(PostingContextBar));
