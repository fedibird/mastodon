import { List as ImmutableList, Map as ImmutableMap } from 'immutable';
import { filterContextForSource } from './filter_context';
import { buildMixView } from './merge';

const plainFilters = (filters) => {
  const list = [];

  (filters || ImmutableMap()).forEach(filter => {
    if (!filter || !filter.get) {
      return;
    }

    const context = filter.get('context');

    list.push({
      id: filter.get('id'),
      title: filter.get('title'),
      filter_action: filter.get('filter_action'),
      context: context && context.toArray ? context.toArray() : context,
    });
  });

  return list;
};

export const mixTimelineView = (timeline, statuses, filters, me) => {
  if (!timeline) {
    return null;
  }

  const contexts = {};
  const sources = [];
  const statusesById = {};

  timeline.get('sources').forEach((source, key) => {
    const descriptor = source.get('descriptor');
    const plain = descriptor && descriptor.toJS ? descriptor.toJS() : null;

    const results = source.get('filterResults');

    sources.push({
      key,
      ids: source.get('ids').toArray(),
      hasMore: source.get('hasMore'),
      loaded: source.get('loaded'),
      loading: source.get('loading'),
      error: source.get('error'),
      frontier: source.get('frontier'),
      partial: source.get('partial'),
      suspended: source.get('suspended'),
      gap: source.get('gap'),
      filterResults: results && results.toJS ? results.toJS() : {},
      source: plain,
    });
    contexts[key] = filterContextForSource(plain);
    source.get('ids').forEach(id => {
      const status = statuses && statuses.get(id);

      if (status && !statusesById[id]) {
        statusesById[id] = status.toJS();
      }
    });
  });

  const view = buildMixView(sources, statusesById, {
    me,
    filters: plainFilters(filters),
    contexts,
  });

  return {
    ...view,
    statusIds: ImmutableList(view.ids),
    running: timeline.get('running'),
  };
};
