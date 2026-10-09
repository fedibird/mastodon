const present = value => value !== null && value !== undefined && value !== '';

// A group destination is not only a group column. A posting style can
// address a group from the primary composer without setting surface.kind.
export function composerHasGroupDestination (composer) {
  if (!composer || !composer.get) {
    return false;
  }

  if (composer.getIn(['surface', 'kind']) === 'group') {
    return true;
  }

  if (present(composer.get('posting_context_account_id'))) {
    return true;
  }

  if (present(composer.getIn(['context', 'resolvedAccountId']))) {
    return true;
  }

  return Boolean(composer.getIn(['context', 'protocol', 'activityPub', 'audience']));
}

export function draftHasGroupDestination (draft) {
  const source = draft || {};

  return Boolean(
    source.groupId
    || present(source.postingContextAccountId)
    || present(source.resolvedAccountId)
    || source.activityPubAudience,
  );
}
