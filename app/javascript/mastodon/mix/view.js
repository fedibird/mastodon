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

export const MIX_LIVE_LIMIT = 40;

const loadedSourcesForLive = (sources) => {
  if (!sources || !sources.map) {
    return ImmutableMap();
  }

  return sources.map(source => source.merge({
    loaded: true,
    hasMore: false,
    gap: false,
    partial: false,
    error: null,
    suspended: false,
    loading: false,
  }));
};

const unionLive = (current, seed) => {
  const merged = ImmutableMap().asMutable();

  const put = (map) => {
    if (!map || !map.forEach) {
      return;
    }

    map.forEach((entry, key) => {
      const existing = merged.get(key);
      const incoming = entry.get('statusIds') || entry.get('ids') || ImmutableList();
      const ids = (existing ? existing.get('ids') : ImmutableList()).concat(incoming);
      const unique = ids.filter((id, index) => ids.indexOf(id) === index);

      merged.set(key, ImmutableMap({
        statusIds: unique,
        ids: unique,
        filterResults: (existing ? existing.get('filterResults') : ImmutableMap()).merge(entry.get('filterResults') || ImmutableMap()),
        mode: entry.get('mode') || (existing && existing.get('mode')),
        syncState: entry.get('syncState') || (existing && existing.get('syncState')),
      }));
    });
  };

  put(seed);
  put(current);
  return merged.asImmutable();
};

export const mixTimelineView = (timeline, statuses, filters, me, pane) => {
  if (!timeline) {
    return null;
  }

  const split = timeline.get('split');
  let sourceMap = timeline.get('sources');
  let liveMap = timeline.get('live');
  let pending = timeline.get('pendingStatusIds');
  let limit = null;

  if (pane === 'history' && split) {
    sourceMap = split.getIn(['history', 'sources']);
    liveMap = split.getIn(['history', 'frozenLive']);
    pending = ImmutableList();
  } else if (pane === 'live' || (!pane && timeline.get('displayMode') === 'live')) {
    sourceMap = loadedSourcesForLive(timeline.get('sources'));
    liveMap = unionLive(timeline.get('live'), split && split.getIn(['history', 'frozenLive']));
    pending = ImmutableList();
    limit = MIX_LIVE_LIMIT;
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

  sourceMap.forEach((source, key) => {
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

  const liveState = liveMap;

  if (liveState && liveState.forEach) {
    liveState.forEach((entry, key) => {
      const descriptor = timeline.getIn(['sources', key, 'descriptor']);
      const plain = descriptor && descriptor.toJS ? descriptor.toJS() : null;
      const results = entry.get('filterResults');

      const liveIds = entry.get('statusIds') || entry.get('ids') || ImmutableList();

      live.push({
        key,
        ids: liveIds.toArray(),
        filterResults: results && results.toJS ? results.toJS() : {},
        source: plain,
        syncState: entry.get('syncState'),
        mode: entry.get('mode'),
      });
      contexts[key] = contexts[key] || filterContextForSource(plain);
      liveIds.forEach(rememberStatus);
    });
  }

  const tombstones = timeline.get('deletedStatusIds');
  const view = buildMixView(sources, statusesById, {
    me,
    filters: plainFilters(filters),
    contexts,
    live,
    pending: pending && pending.toArray ? pending.toArray() : [],
    tombstones: tombstones && tombstones.toArray ? tombstones.toArray() : [],
  });

  const labelFor = (source) => {
    if (!source) {
      return null;
    }

    return source.title || source.acct || source.id || source.type || null;
  };

  const historyRunning = pane === 'history' && split ? !!split.getIn(['history', 'running']) : timeline.get('running');

  return {
    ...view,
    statusIds: ImmutableList(limit ? view.ids.slice(0, limit) : view.ids),
    running: historyRunning,
    pendingCount: pending && pending.size ? pending.size : 0,
    incomplete: sources.filter(source => source.suspended || source.gap).map(source => ({
      key: source.key,
      label: labelFor(source.source) || source.key,
    })),
    degraded: live.filter(source => source.syncState === 'degraded').map(source => source.key),
    offline: live.filter(source => source.syncState === 'disconnected' || source.syncState === 'reconnecting').map(source => ({
      key: source.key,
      label: labelFor(source.source) || source.key,
    })),
    restOnly: live.filter(source => source.mode === 'rest_only').map(source => ({
      key: source.key,
      label: labelFor(source.source) || source.key,
    })),
  };
};
