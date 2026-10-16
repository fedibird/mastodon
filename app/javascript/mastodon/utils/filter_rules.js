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
