import { List as ImmutableList, Map as ImmutableMap } from 'immutable';
import { me } from 'mastodon/initial_state';
import { toServerSideType } from './filters';

// Keep the media viewer consistent with makeGetStatus: active filters are
// context-aware and reconciled filterMatches override stale API "filtered"
// results. Hidden statuses stay non-navigable; warning-masked statuses are
// excluded until the reader explicitly chooses to show that post.
export const mediaStatusFiltered = (status, reblog, statusId, contextType, filterInfo = {}) => {
  const { filters, matches, generation = 0, revealedFilterStatusIds } = filterInfo;
  if (!status || !filters || filters.isEmpty()) {
    return false;
  }

  const shown = reblog || status;
  const owner = shown.get('account');
  const ownerId = owner && typeof owner.get === 'function' ? owner.get('id') : owner;
  if (ownerId != null && me != null && ownerId === me) {
    return false;
  }

  const filterContext = toServerSideType(contextType || 'account');
  const now = Date.now();
  const active = filters.filter(filter => {
    const contexts = filter.get('context');
    const expires = filter.get('expires_at');
    return contexts && contexts.includes(filterContext) && (expires == null || expires > now);
  });
  if (active.isEmpty()) {
    return false;
  }

  let results = shown.get('filtered') || status.get('filtered') || ImmutableList();
  const match = matches && matches.getIn(['entries', statusId]);
  if (match && match.get('resultGeneration') === generation && match.has('filterIds')) {
    results = match.get('filterIds').map(id => ImmutableMap({ filter: id }));
  }

  // A manual "Show anyway" only overrides a warning. Hide actions must
  // never become navigable, even with an old temporary reveal in this view.
  const matching = results.filter(result => active.has(String(result.get('filter'))));
  if (matching.some(result => active.getIn([String(result.get('filter')), 'filter_action']) === 'hide')) {
    return true;
  }

  return !revealedFilterStatusIds?.has(statusId) && !matching.isEmpty();
};
