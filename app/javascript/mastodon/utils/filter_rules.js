import { Map as ImmutableMap, fromJS } from 'immutable';

// Only adopted complete GET snapshots call this. Keep bigint IDs as strings.
// Keyword row identity matters; status-rule row identity does not change its
// target. Sorting removes response-order differences without numeric coercion.
export const filterRules = filters => ImmutableMap(filters.map(filter => {
  const keywords = (filter.keywords || []).map(rule => [String(rule.id ?? ''), rule.keyword, !!rule.whole_word]);
  const statuses = Array.from(new Set((filter.statuses || []).map(rule => String(rule.status_id)))).sort();
  keywords.sort((a, b) => {
    const left = JSON.stringify(a);
    const right = JSON.stringify(b);
    return left < right ? -1 : Number(left > right);
  });
  return [String(filter.id), fromJS({ keywords, statuses })];
}).filter(([, rules]) => !rules.get('keywords').isEmpty() || !rules.get('statuses').isEmpty()));

export const isStatusId = id => typeof id === 'string' && id.length > 0 && id[0] !== '0' && !/[^0-9]/.test(id) && (id.length < 19 || (id.length === 19 && id <= '9223372036854775807'));

export const filterExpirations = filters => ImmutableMap(filters.map(filter => [String(filter.id), filter.expires_at ? Date.parse(filter.expires_at) : null]));

// A full GET can reactivate rules omitted by the API while expired. Compare
// the old absolute deadline at receipt time, not at the previous GET's time:
// that also catches a filter which expired naturally between snapshots.
export const hasReactivatedRules = (previous, next, rules, receivedAt) => rules.keySeq().some(id => {
  const before = previous.get(id);
  const after = next.get(id);
  return previous.has(id) && before !== null && before <= receivedAt && (after === null || after > receivedAt);
});
