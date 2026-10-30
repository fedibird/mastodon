import { isAdministrator } from 'mastodon/initial_state';

import { isPublicFedibirdGroupTimeline, isResolvedFedibirdGroupDiscovery } from '../../posting_context/fedibird_group_discovery';

const present = value => value !== null && value !== undefined && value !== '';

const discoveryStatus = discoveryRecord => (
  discoveryRecord && discoveryRecord.get ? discoveryRecord.get('status') : null
);

const discoveryInFlight = discoveryRecord => (
  discoveryStatus(discoveryRecord) === 'loading'
  || (discoveryRecord && discoveryRecord.get && discoveryRecord.get('refreshing') === true)
);

export function hashtagPortableComposerEligible () {
  return true;
}

export function listPortableComposerEligible () {
  return isAdministrator;
}

export function groupPortableComposerToggleEligible ({ discoveryRecord, account }) {
  if (isAdministrator) {
    return true;
  }

  return isPublicFedibirdGroupTimeline(discoveryRecord, account);
}

export function groupPortableComposerMounted ({ composerVisible, postingContext, discoveryRecord, account }) {
  if (!composerVisible || !postingContext) {
    return false;
  }

  if (isAdministrator) {
    return true;
  }

  return isPublicFedibirdGroupTimeline(discoveryRecord, account);
}

export function shouldFetchGroupPostingContext ({ composerVisible, discoveryRecord, account, groupId }) {
  if (isAdministrator) {
    return composerVisible;
  }

  if (!present(groupId)) {
    return false;
  }

  if (isPublicFedibirdGroupTimeline(discoveryRecord, account)) {
    return false;
  }

  if (discoveryInFlight(discoveryRecord)) {
    return false;
  }

  // A resolved Fedibird payload is enough; cache TTL and unsupported/not_applicable
  // freshness stay in fetchPostingContext, not here.
  if (discoveryStatus(discoveryRecord) === 'resolved'
    && isResolvedFedibirdGroupDiscovery(discoveryRecord, groupId)) {
    return false;
  }

  return true;
}

export function groupAccountBecameAvailable (previousAccount, account) {
  return !previousAccount && Boolean(account);
}

export function shouldApplyGroupComposerSurface ({ discoveryRecord, account, idChanged, postingContextCleared }) {
  if (!idChanged && !postingContextCleared) {
    return false;
  }

  if (isAdministrator) {
    return true;
  }

  return isPublicFedibirdGroupTimeline(discoveryRecord, account);
}
