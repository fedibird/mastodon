import { connect } from 'react-redux';
import { List as ImmutableList, Set as ImmutableSet } from 'immutable';
import { toggleComposerManagedHashtag } from '../../../actions/composer';
import { createCapabilityNotice, selectComposerEffectiveCreateCapability } from '../../../posting_context/create_capability';
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
      createNotice: null,
      viaRelationship: null,
    };
  }

  const capability = selectComposerEffectiveCreateCapability(state, composerId);
  const createNotice = createCapabilityNotice(capability);
  const confirmedNotice = createNotice === 'allowed' || createNotice === 'allowed_compatibility' || createNotice === 'allowed_unsupported';

  return {
    hashtags: composer.getIn(['context', 'managed', 'hashtags'], ImmutableList()),
    suppressedHashtags: composer.getIn(['context', 'suppressions', 'hashtags'], ImmutableSet()),
    mentions: composer.getIn(['context', 'managed', 'mentions'], ImmutableList()),
    audience: composer.getIn(['context', 'protocol', 'activityPub', 'audience']),
    visibility: capability.compliance.visibility,
    followingAccounts: capability.compliance.followingAccounts,
    createNotice,
    viaRelationship: confirmedNotice ? capability.permission.viaRelationship : null,
  };
};

const mapDispatchToProps = (dispatch, { composerId }) => ({

  onToggle (normalizedName) {
    dispatch(toggleComposerManagedHashtag(composerId, normalizedName));
  },

});

export default withComposerId(connect(mapStateToProps, mapDispatchToProps)(PostingContextBar));
