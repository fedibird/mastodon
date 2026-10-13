// Session discovery stays keyed by the group account. A delegated sender
// keeps a separate record so one viewer's result cannot satisfy another.
export function postingContextCacheKey (accountId, identity) {
  const id = String(accountId);
  const identityId = identity && identity.identityId;

  if (!identityId || String(identityId).startsWith('local:')) {
    return id;
  }

  return `${id}\n${identityId}\n${identity.delegationId || ''}`;
}

export const selectPostingContextDiscovery = (state, accountId, identity = null) => {
  if (!state || accountId === undefined || accountId === null) {
    return null;
  }

  return state.getIn(['posting_contexts', postingContextCacheKey(accountId, identity)], null);
};

export const selectPostingContextViewerEvidence = (state, accountId) => {
  const discovery = selectPostingContextDiscovery(state, accountId);

  if (!discovery || !discovery.get) {
    return null;
  }

  return discovery.get('viewerEvidence', null);
};

const selectPermissionEvidence = (state, accountId, privilege) => {
  const evidence = selectPostingContextViewerEvidence(state, accountId);

  if (!evidence || !evidence.get) {
    return null;
  }

  return evidence.getIn(['permissions', privilege], null);
};

export const selectPostingContextCreatePermissionEvidence = (state, accountId) => (
  selectPermissionEvidence(state, accountId, 'create')
);

export const selectPostingContextViewPermissionEvidence = (state, accountId) => (
  selectPermissionEvidence(state, accountId, 'view')
);

export const selectPostingContextForAccount = (state, accountId) => {
  const discovery = selectPostingContextDiscovery(state, accountId);

  if (!discovery || discovery.get('status') !== 'resolved') {
    return null;
  }

  const context = discovery.get('context');

  if (!context || !context.toJS) {
    return null;
  }

  return context.toJS();
};
