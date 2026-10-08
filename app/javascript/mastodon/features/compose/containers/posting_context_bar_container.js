import { connect } from 'react-redux';
import { List as ImmutableList, Set as ImmutableSet } from 'immutable';
import { isAdministrator } from 'mastodon/initial_state';
import { fetchPostingContextRevalidationStatus, requestPostingContextRevalidation, watchPostingContextRevalidation } from '../../../actions/posting_context_revalidations';
import { toggleComposerManagedHashtag } from '../../../actions/composer';
import { toggleUserPostingStyleHashtag } from '../../../actions/user_posting_styles';
import { createCapabilityNotice, selectComposerEffectiveCreateCapability } from '../../../posting_context/create_capability';
import { styleHashtagChips } from '../../../posting_context/materialize';
import { selectComposer } from '../../../selectors/composer';
import { selectPostingContextRevalidation } from '../../../selectors/posting_context_revalidations';
import { withComposerId } from '../composer_id_context';
import PostingContextBar from '../components/posting_context_bar';

const present = value => value !== null && value !== undefined && value !== '';

const revalidationNoticeFor = (revalidation, permission) => {
  const jobState = revalidation && revalidation.get('state');
  const polling = revalidation && revalidation.get('polling');

  if (polling === 'interrupted') {
    return 'interrupted';
  }

  if (polling === 'timed_out') {
    return 'timed_out';
  }

  if (jobState === 'queued' || jobState === 'running') {
    return 'running';
  }

  if (jobState === 'partial') {
    return 'partial';
  }

  if (jobState === 'failed' || (revalidation && revalidation.get('error') === 'failed')) {
    return 'failed';
  }

  if (revalidation && revalidation.get('error') === 'rate_limited') {
    return 'rate_limited';
  }

  if (permission && permission.freshness === 'stale') {
    return 'stale';
  }

  return null;
};

const canRecheckPermission = (composer, capability) => {
  if (!isAdministrator || !composer || !capability) {
    return false;
  }

  if (present(composer.get('id')) || present(composer.get('scheduled_status_id'))) {
    return false;
  }

  if (!present(composer.get('posting_context_account_id'))) {
    return false;
  }

  const delivery = capability.delivery || {};

  return !(delivery.adapter === 'fedibird_group' && delivery.authority === 'server');
};

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
      canRecheck: false,
      revalidationNotice: null,
    };
  }

  const capability = selectComposerEffectiveCreateCapability(state, composerId);
  const createNotice = createCapabilityNotice(capability);
  const confirmedNotice = createNotice === 'allowed' || createNotice === 'allowed_compatibility' || createNotice === 'allowed_unsupported';
  const accountId = composer.get('posting_context_account_id');
  const revalidation = present(accountId) ? selectPostingContextRevalidation(state, accountId) : null;

  return {
    hashtags: composer.getIn(['context', 'managed', 'hashtags'], ImmutableList()).concat(styleHashtagChips(composer)),
    suppressedHashtags: composer.getIn(['context', 'suppressions', 'hashtags'], ImmutableSet()),
    mentions: composer.getIn(['context', 'managed', 'mentions'], ImmutableList()),
    audience: composer.getIn(['context', 'protocol', 'activityPub', 'audience']),
    visibility: capability.compliance.visibility,
    followingAccounts: capability.compliance.followingAccounts,
    createNotice,
    viaRelationship: confirmedNotice ? capability.permission.viaRelationship : null,
    canRecheck: canRecheckPermission(composer, capability),
    revalidationNotice: revalidationNoticeFor(revalidation, capability.permission),
    revalidationActor: (revalidation && revalidation.get('actor')) || undefined,
    revalidationAffiliations: (revalidation && revalidation.get('affiliations')) || undefined,
    revalidationAccountId: present(accountId) ? String(accountId) : null,
    revalidationExplicit: Boolean(revalidation && revalidation.get('explicit')),
  };
};

const mapDispatchToProps = (dispatch, { composerId }) => ({

  onToggle (normalizedName, origin) {
    if (origin === 'style' || origin === 'destination') {
      dispatch(toggleUserPostingStyleHashtag(composerId, origin, normalizedName));
      return;
    }

    dispatch(toggleComposerManagedHashtag(composerId, normalizedName));
  },

  onRecheck () {
    dispatch((innerDispatch, getState) => {
      const composer = selectComposer(getState(), composerId);
      const accountId = composer && composer.get('posting_context_account_id');

      if (present(accountId)) {
        innerDispatch(requestPostingContextRevalidation(accountId));
      }
    });
  },

  onRefreshStatus () {
    dispatch((innerDispatch, getState) => {
      const composer = selectComposer(getState(), composerId);
      const accountId = composer && composer.get('posting_context_account_id');

      if (present(accountId)) {
        innerDispatch(fetchPostingContextRevalidationStatus(accountId));
      }
    });
  },

  onWatch () {
    let release = () => {};

    dispatch((innerDispatch, getState) => {
      const composer = selectComposer(getState(), composerId);
      const accountId = composer && composer.get('posting_context_account_id');

      if (present(accountId)) {
        release = innerDispatch(watchPostingContextRevalidation(accountId)) || release;
      }
    });

    return release;
  },

});

export default withComposerId(connect(mapStateToProps, mapDispatchToProps)(PostingContextBar));
