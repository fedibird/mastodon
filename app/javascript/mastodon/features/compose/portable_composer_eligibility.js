import { isAdministrator } from 'mastodon/initial_state';

import { isPublicFedibirdGroupTimeline } from '../../posting_context/fedibird_group_discovery';

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

export function shouldFetchGroupPostingContext ({ composerVisible, discoveryRecord, account }) {
  if (isAdministrator) {
    return composerVisible;
  }

  if (!account || !account.get) {
    return false;
  }

  if (isPublicFedibirdGroupTimeline(discoveryRecord, account)) {
    return false;
  }

  return true;
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
