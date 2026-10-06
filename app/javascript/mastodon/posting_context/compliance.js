import { isExistingPostEdit } from './materialize';
import { selectComposer } from '../selectors/composer';

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

export function selectComposerPostingContextCompliance(state, composerId) {
  const composer = selectComposer(state, composerId);

  if (!composer || isExistingPostEdit(composer)) {
    return emptyCompliance();
  }

  const allowed = composer.getIn(['context', 'constraints', 'allowedVisibilities'], null);
  const hasVisibilityConstraint = allowed !== null && allowed !== undefined;
  const prohibited = composer.get('prohibited_visibilities');
  const privacy = composer.get('privacy');
  let visibilityValid = true;
  let allowedList = null;
  let available = null;

  if (hasVisibilityConstraint) {
    const privacyProhibited = Boolean(prohibited && prohibited.includes(privacy));

    allowedList = allowed.toArray();
    available = allowed.filter(visibility => !prohibited || !prohibited.includes(visibility)).toArray();
    visibilityValid = Boolean(allowed.includes(privacy)) && !privacyProhibited;
  }

  const following = composer.getIn(['context', 'requirements', 'followingAccounts']);
  const relationships = state.get('relationships');
  const followingAccounts = [];
  let followingValid = true;

  if (following && following.forEach) {
    following.forEach(requirement => {
      const accountId = requirement.get('accountId');
      const status = followStatus(relationshipRecord(relationships, accountId));

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

  return {
    valid: visibilityValid && followingValid && mentionsValid,
    visibility: {
      valid: visibilityValid,
      allowed: allowedList,
      available,
    },
    followingAccounts,
  };
}
