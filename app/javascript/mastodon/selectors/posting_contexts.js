export const selectPostingContextDiscovery = (state, accountId) => {
  if (!state || accountId === undefined || accountId === null) {
    return null;
  }

  return state.getIn(['posting_contexts', String(accountId)], null);
};

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
