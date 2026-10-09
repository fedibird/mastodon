// Posting style is applied only after the sender and the destination have
// had their say. UserPostingContext stays owned by the user. M1 does not
// store a per-identity default; that scope is separate from
// UserPostingContextAssignment.

const OWNED_FIELDS = ['authorization', 'capabilities', 'accountId'];

export function applyPostingStylePrecedence({
  identity,
  postingContext,
  userPostingContext,
  manual,
} = {}) {
  const chosen = {
    ...(userPostingContext || {}),
    ...(manual || {}),
  };
  const locks = postingContext && postingContext.locks || {};
  const values = { ...chosen };
  const overridden = [];

  Object.keys(locks).forEach(field => {
    if (Object.prototype.hasOwnProperty.call(values, field) && values[field] !== locks[field]) {
      overridden.push({
        field,
        from: 'posting_context',
        value: locks[field],
      });
    }

    values[field] = locks[field];
  });

  OWNED_FIELDS.forEach(field => {
    if (Object.prototype.hasOwnProperty.call(values, field)) {
      overridden.push({
        field,
        from: 'identity',
        value: null,
      });
      delete values[field];
    }
  });

  const capabilities = identity && identity.capabilities || {};

  return {
    values,
    overridden,
    canPost: Boolean(identity) && identity.authorization === 'ready' && capabilities.post === 'supported',
    order: ['identity', 'posting_context', 'user_posting_context', 'manual'],
  };
}
