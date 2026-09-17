import { Map as ImmutableMap, is, fromJS } from 'immutable';

import { FILTERS_IMPORT } from '../actions/importer';

const normalizeFilterAction = filterAction => {
  if (filterAction === 1 || filterAction === 'hide') {
    return 'hide';
  }

  return 'warn';
};

const normalizeFilter = (state, filter) => {
  if (!filter || !filter.id) {
    return state;
  }

  const filterId = String(filter.id);
  const normalized = {
    id: filterId,
    title: filter.title,
    context: filter.context,
    filter_action: normalizeFilterAction(filter.filter_action),
    expires_at: filter.expires_at ? Date.parse(filter.expires_at) : null,
  };

  if (Object.prototype.hasOwnProperty.call(filter, 'keywords')) {
    normalized.keywords = filter.keywords;
  }

  if (Object.prototype.hasOwnProperty.call(filter, 'statuses')) {
    normalized.statuses = filter.statuses;
  }

  const normalizedFilter = fromJS(normalized);

  if (is(state.get(filterId), normalizedFilter)) {
    return state;
  }

  return state.update(filterId, ImmutableMap(), old => (
    old.mergeWith((oldValue, newValue) => (newValue === undefined ? oldValue : newValue), normalizedFilter)
  ));
};

const normalizeFilters = (state, filters) => {
  filters.forEach(filter => {
    state = normalizeFilter(state, filter);
  });

  return state;
};

export default function filters(state = ImmutableMap(), action) {
  switch(action.type) {
  case FILTERS_IMPORT:
    return normalizeFilters(state, action.filters);
  default:
    return state;
  }
};
