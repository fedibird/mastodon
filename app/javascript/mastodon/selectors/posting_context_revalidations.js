export const selectPostingContextRevalidation = (state, accountId) => {
  if (!state || accountId === undefined || accountId === null) {
    return null;
  }

  return state.getIn(['posting_context_revalidations', String(accountId)], null);
};
