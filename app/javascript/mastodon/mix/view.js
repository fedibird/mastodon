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
  const live = [];
  const statusesById = {};
  const rememberStatus = (id) => {
    const status = statuses && statuses.get(id);

    if (status && !statusesById[id]) {
      statusesById[id] = status.toJS();
    }
  };

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
    source.get('ids').forEach(rememberStatus);
  });

  const liveState = timeline.get('live');

  if (liveState && liveState.forEach) {
    liveState.forEach((entry, key) => {
      const descriptor = timeline.getIn(['sources', key, 'descriptor']);
      const plain = descriptor && descriptor.toJS ? descriptor.toJS() : null;
      const results = entry.get('filterResults');

      live.push({
        key,
        ids: entry.get('statusIds').toArray(),
        filterResults: results && results.toJS ? results.toJS() : {},
        source: plain,
        syncState: entry.get('syncState'),
        mode: entry.get('mode'),
      });
      contexts[key] = contexts[key] || filterContextForSource(plain);
      entry.get('statusIds').forEach(rememberStatus);
    });
  }

  const pending = timeline.get('pendingStatusIds');
  const tombstones = timeline.get('deletedStatusIds');
  const view = buildMixView(sources, statusesById, {
    me,
    filters: plainFilters(filters),
    contexts,
    live,
    pending: pending && pending.toArray ? pending.toArray() : [],
    tombstones: tombstones && tombstones.toArray ? tombstones.toArray() : [],
  });

  return {
    ...view,
    statusIds: ImmutableList(view.ids),
    running: timeline.get('running'),
    pendingCount: pending && pending.size ? pending.size : 0,
    degraded: live.filter(source => source.syncState === 'degraded').map(source => source.key),
    restOnly: live.filter(source => source.mode === 'rest_only').map(source => ({
      key: source.key,
      label: source.source ? (source.source.title || source.source.acct || source.source.id || source.source.type) : source.key,
    })),
  };
};
