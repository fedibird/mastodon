import { POSTING_CONTEXT_CACHE_TTL } from '../actions/posting_contexts';
import { selectComposer } from '../selectors/composer';
import { selectPostingIdentityDelegationId } from '../selectors/posting_identities';
import { selectPostingContextDiscovery } from '../selectors/posting_contexts';
import { composerActivityPubAudienceAllowedVisibilities } from './protocol';

const emptyCompliance = () => ({
  valid: true,
  visibility: {
    valid: true,
    allowed: null,
    available: null,
  },
  followingAccounts: [],
});

const relationshipRecord = (relationships, accountId) => {
  if (!relationships || typeof relationships.get !== 'function') {
    return null;
  }

  const relationship = relationships.get(accountId);

  if (!relationship || typeof relationship.get !== 'function') {
    return null;
  }

  return relationship;
};

const followStatus = relationship => {
  if (!relationship) {
    return 'unknown';
  }

  if (relationship.get('following') === true) {
    return 'satisfied';
  }

  if (relationship.get('requested') === true) {
    return 'requested';
  }

  return 'not_following';
};

const present = value => value !== null && value !== undefined;

const visibilityCompliance = (allowed, composer) => {
  if (allowed === null || allowed === undefined) {
    return {
      valid: true,
      allowed: null,
      available: null,
    };
  }

  const prohibited = composer.get('prohibited_visibilities');
  const privacy = composer.get('privacy');
  const privacyProhibited = Boolean(prohibited && prohibited.includes(privacy));

  return {
    valid: Boolean(allowed.includes(privacy)) && !privacyProhibited,
    allowed: allowed.toArray(),
    available: allowed.filter(visibility => !prohibited || !prohibited.includes(visibility)).toArray(),
  };
};

export function selectComposerPostingContextCompliance(state, composerId) {
  const composer = selectComposer(state, composerId);

  if (!composer || present(composer.get('id'))) {
    return emptyCompliance();
  }

  // A scheduled draft ignores the timeline Posting Context. Its own saved
  // audience target still limits visibility to public and unlisted.
  if (present(composer.get('scheduled_status_id'))) {
    const visibility = visibilityCompliance(
      composerActivityPubAudienceAllowedVisibilities(composer),
      composer,
    );

    return {
      valid: visibility.valid,
      visibility,
      followingAccounts: [],
    };
  }

  const allowed = composer.getIn(['context', 'constraints', 'allowedVisibilities'], null);
  const visibility = visibilityCompliance(allowed, composer);
  const { valid: visibilityValid } = visibility;

  const following = composer.getIn(['context', 'requirements', 'followingAccounts']);
  const relationships = state.get('relationships');
  const senderId = composer.getIn(['senderIdentity', 'id']);
  const delegatedSender = typeof senderId === 'string' && senderId.startsWith('delegated:');
  const delegatedDiscovery = delegatedSender ? selectPostingContextDiscovery(state, composer.get('posting_context_account_id'), {
    identityId: senderId,
    delegationId: selectPostingIdentityDelegationId(state, senderId),
  }) : null;
  const delegatedReceivedAt = delegatedDiscovery && delegatedDiscovery.get('receivedAt');
  const delegatedFresh = typeof delegatedReceivedAt === 'number' && (Date.now() - delegatedReceivedAt) < POSTING_CONTEXT_CACHE_TTL;
  const delegatedPosting = delegatedFresh ? delegatedDiscovery.get('senderPosting') : null;
  const followingAccounts = [];
  let followingValid = true;

  if (following && following.forEach) {
    following.forEach(requirement => {
      const accountId = requirement.get('accountId');
      let status;

      if (!delegatedSender) {
        status = followStatus(relationshipRecord(relationships, accountId));
      } else if (!delegatedPosting || String(accountId) !== String(composer.get('posting_context_account_id'))) {
        status = 'unknown';
      } else {
        status = delegatedPosting.get('following') === true ? 'satisfied' : 'not_following';
      }

      if (status !== 'satisfied') {
        followingValid = false;
      }

      followingAccounts.push({
        accountId,
        acct: requirement.get('acct'),
        status,
      });
    });
  }

  const mentions = composer.getIn(['context', 'managed', 'mentions']);
  let mentionsValid = true;

  if (mentions && mentions.forEach) {
    mentions.forEach(mention => {
      if (mention.get('enforcement') === 'required' && !mention.get('acct')) {
        mentionsValid = false;
      }
    });
  }

  const audience = composer.getIn(['context', 'protocol', 'activityPub', 'audience']);
  const audienceValid = !(audience && audience.get('enforcement') === 'required' && !audience.get('accountId'));
  const destinationStatus = composer.getIn(['userPostingStyle', 'destinationStatus']);
  const destinationValid = destinationStatus !== 'pending' && destinationStatus !== 'needs_resolve' && destinationStatus !== 'failed';

  return {
    valid: visibilityValid && followingValid && mentionsValid && audienceValid && destinationValid,
    visibility,
    followingAccounts,
    destination: {
      valid: destinationValid,
      status: destinationStatus || 'idle',
    },
  };
}
