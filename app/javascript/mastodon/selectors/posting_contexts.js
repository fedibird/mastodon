export const selectPostingContextDiscovery = (state, accountId) => {
  if (!state || accountId === undefined || accountId === null) {
    return null;
  }

  return state.getIn(['posting_contexts', String(accountId)], null);
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
