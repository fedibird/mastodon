export const POSTING_STYLE_LAYERS = Object.freeze([
  'identity',
  'posting_context',
  'user_posting_context',
  'manual',
]);

const requiredValue = (source, field) => (
  source && source.required && Object.prototype.hasOwnProperty.call(source.required, field)
    ? source.required[field]
    : undefined
);

// Identity grants and the destination's required conditions are applied
// before a user's saved style or a manual edit. Later layers fill gaps.
// They do not replace a required value.
export function resolvePostingStyleField(field, sources = {}) {
  const identityValue = requiredValue(sources.identity, field);

  if (identityValue !== undefined) {
    return { value: identityValue, layer: 'identity' };
  }

  const contextValue = requiredValue(sources.postingContext, field);

  if (contextValue !== undefined) {
    return { value: contextValue, layer: 'posting_context' };
  }

  if (sources.manual && Object.prototype.hasOwnProperty.call(sources.manual, field)) {
    return { value: sources.manual[field], layer: 'manual' };
  }

  if (sources.userPostingContext && Object.prototype.hasOwnProperty.call(sources.userPostingContext, field)) {
    return { value: sources.userPostingContext[field], layer: 'user_posting_context' };
  }

  return { value: undefined, layer: null };
}
