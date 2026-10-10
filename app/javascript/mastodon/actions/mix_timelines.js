import { List as ImmutableList, Map as ImmutableMap } from 'immutable';
import api, { getLinks } from '../api';
import { me } from '../initial_state';
import { mixTimelineView } from '../mix/view';
import { fetchRelationshipsSuccess } from './accounts';
import { importFetchedAccounts, importFetchedStatuses, importFilters } from './importer';
import { isMixEnabled } from '../mix/availability';
import { plainMix } from '../mix/definition';
import { resolveRequest, normalizePage, classifyFetchFailure, previousStatusesForImport, statusesForSharedImport } from '../mix/source_adapters';
import { MIX_FETCH_BUDGET, MIX_FETCH_CONCURRENCY, MIX_PAGE_SIZE, MIX_PAGE_TARGET, nextFetchKeys } from '../mix/merge';
import { idHiddenByRelationships, relationshipGeneration, relationshipsAfterGeneration, statusHiddenByRelationships } from '../mix/relationship_visibility';

export const MIX_TIMELINE_OPEN = 'MIX_TIMELINE_OPEN';
export const MIX_TIMELINE_CLOSE = 'MIX_TIMELINE_CLOSE';
export const MIX_TIMELINE_DONE = 'MIX_TIMELINE_DONE';
export const MIX_SOURCE_REQUEST = 'MIX_SOURCE_REQUEST';
export const MIX_SOURCE_SUCCESS = 'MIX_SOURCE_SUCCESS';
export const MIX_SOURCE_FAIL = 'MIX_SOURCE_FAIL';
export const MIX_STREAM_READY = 'MIX_STREAM_READY';
export const MIX_STREAM_CONNECT = 'MIX_STREAM_CONNECT';
export const MIX_STREAM_DISCONNECT = 'MIX_STREAM_DISCONNECT';
export const MIX_STREAM_STATUS = 'MIX_STREAM_STATUS';
export const MIX_STREAM_EDIT = 'MIX_STREAM_EDIT';
export const MIX_STREAM_REMOVE = 'MIX_STREAM_REMOVE';
export const MIX_STREAM_SYNC = 'MIX_STREAM_SYNC';
export const MIX_STREAM_PIN = 'MIX_STREAM_PIN';
export const MIX_STREAM_REVEAL = 'MIX_STREAM_REVEAL';
export const MIX_SPLIT_CREATE = 'MIX_SPLIT_CREATE';
export const MIX_SPLIT_DESTROY = 'MIX_SPLIT_DESTROY';
export const MIX_SPLIT_ANCHOR = 'MIX_SPLIT_ANCHOR';
export const MIX_SPLIT_CLEAR_ANCHOR = 'MIX_SPLIT_CLEAR_ANCHOR';
export const MIX_DISPLAY_HISTORY = 'MIX_DISPLAY_HISTORY';

let mixSessionSerial = 0;

export const issueMixSessionId = () => {
  mixSessionSerial += 1;
  return mixSessionSerial;
};

const readColumn = (getState, columnKey) => getState().getIn(['mix_timelines', columnKey]);

const sourcesIn = (column, scope) => {
  if (!column) {
    return null;
  }

  if (scope && scope.history) {
    return column.getIn(['split', 'history', 'sources']);
  }

  return column.get('sources');
};

const stamp = (action, scope) => {
  if (!scope || !scope.history) {
    return action;
  }

  return { ...action, scope: 'history', splitId: scope.splitId };
};

const sourceSnapshot = (column, scope) => sourcesIn(column, scope).entrySeq().map(([key, source]) => ({
  key,
  ids: source.get('ids').toArray(),
  hasMore: source.get('hasMore'),
  loaded: source.get('loaded'),
  loading: source.get('loading'),
  error: source.get('error'),
  cursor: source.get('cursor'),
  frontier: source.get('frontier'),
  partial: source.get('partial'),
  suspended: source.get('suspended'),
  retryAt: source.get('retryAt'),
})).toArray();

const stillCurrentScope = (getState, columnKey, sessionId, fingerprint, scope) => {
  const column = readColumn(getState, columnKey);

  if (!column || column.get('sessionId') !== sessionId || column.get('definitionFingerprint') !== fingerprint) {
    return false;
  }

  if (scope && scope.history) {
    return column.getIn(['split', 'id']) === scope.splitId;
  }

  return true;
};

const withoutHiddenStatuses = (getState, page) => {
  const relationships = getState().get('relationships');
  const statuses = getState().get('statuses');
  const pageStatuses = (page.statuses || []).concat(page.referencedStatuses || []);
  const hidden = new Set();

  pageStatuses.forEach(status => {
    if (status && statusHiddenByRelationships(relationships, status)) {
      hidden.add(String(status.id));
    }
  });

  (page.ids || []).forEach(id => {
    if (idHiddenByRelationships(relationships, statuses, id, page.statuses)) {
      hidden.add(String(id));
    }
  });

  if (!hidden.size) {
    return page;
  }

  return {
    ...page,
    ids: (page.ids || []).filter(id => !hidden.has(String(id))),
    statuses: (page.statuses || []).filter(status => status && !hidden.has(String(status.id))),
    referencedStatuses: (page.referencedStatuses || []).filter(status => status && !hidden.has(String(status.id))),
  };
};

const fetchPage = (resolved, cursor, getState) => {
  const request = resolveRequest(resolved.source, cursor);

  if (!request.ok) {
    return Promise.reject({ response: { status: 404 } });
  }

  return api(getState).get(request.path, { params: { ...request.params, limit: MIX_PAGE_SIZE } }).then(response => {
    const next = getLinks(response).refs.find(link => link.rel === 'next');

    return normalizePage({
      status: response.status,
      data: response.data,
      nextUri: next && next.uri,
      path: request.path,
    });
  });
};

const acceptPage = (dispatch, getState, columnKey, sessionId, fingerprint, key, cursor, page, scope, generation) => {
  if (!stillCurrentScope(getState, columnKey, sessionId, fingerprint, scope)) {
    return;
  }

  if (!page.ok) {
    dispatch({
      type: MIX_SOURCE_FAIL,
      columnKey,
      sourceKey: key,
      sessionId,
      definitionFingerprint: fingerprint,
      error: page.error,
      clear: false,
      ...stamp({}, scope),
    });
    return;
  }

  if (page.hasMore && cursor && page.cursor === cursor) {
    dispatch({
      type: MIX_SOURCE_FAIL,
      columnKey,
      sourceKey: key,
      sessionId,
      definitionFingerprint: fingerprint,
      error: 'stalled',
      clear: false,
      ...stamp({}, scope),
    });
    return;
  }

  const visiblePage = withoutHiddenStatuses(getState, page);

  if (!stillCurrentScope(getState, columnKey, sessionId, fingerprint, scope)) {
    return;
  }

  if (visiblePage.accounts && visiblePage.accounts.length) {
    dispatch(importFetchedAccounts(visiblePage.accounts));
  }

  if (!stillCurrentScope(getState, columnKey, sessionId, fingerprint, scope)) {
    return;
  }

  const relationships = relationshipsAfterGeneration(getState().get('relationships'), visiblePage.relationships, generation);

  if (relationships.length) {
    dispatch(fetchRelationshipsSuccess(relationships));
  }

  if (!stillCurrentScope(getState, columnKey, sessionId, fingerprint, scope)) {
    return;
  }

  if (visiblePage.filters && visiblePage.filters.length) {
    dispatch(importFilters(visiblePage.filters));
  }

  if (!stillCurrentScope(getState, columnKey, sessionId, fingerprint, scope)) {
    return;
  }

  const bodiesInPage = visiblePage.statuses.concat(visiblePage.referencedStatuses || []);
  const previousById = previousStatusesForImport(getState().get('statuses'), bodiesInPage);
  const bodies = statusesForSharedImport(bodiesInPage, previousById);

  dispatch(importFetchedStatuses(bodies));

  if (!stillCurrentScope(getState, columnKey, sessionId, fingerprint, scope)) {
    return;
  }

  dispatch({
    type: MIX_SOURCE_SUCCESS,
    columnKey,
    sourceKey: key,
    sessionId,
    definitionFingerprint: fingerprint,
    ids: visiblePage.ids,
    filterResults: visiblePage.filterResults,
    cursor: visiblePage.cursor,
    frontier: visiblePage.frontier,
    hasMore: visiblePage.hasMore,
    partial: visiblePage.partial,
    suspended: visiblePage.suspended,
    requestedCursor: cursor || null,
    extra: !!cursor,
    ...stamp({}, scope),
  });
};

const failPage = (dispatch, getState, columnKey, sessionId, fingerprint, key, error, scope) => {
  if (!stillCurrentScope(getState, columnKey, sessionId, fingerprint, scope)) {
    return;
  }

  const failure = classifyFetchFailure(error);

  dispatch({
    type: MIX_SOURCE_FAIL,
    columnKey,
    sourceKey: key,
    sessionId,
    definitionFingerprint: fingerprint,
    error: failure.kind,
    retryAt: failure.retryAt || null,
    clear: failure.kind === 'forbidden' || failure.kind === 'not_found',
    ...stamp({}, scope),
  });
};

const pump = async (dispatch, getState, columnKey, sessionId, fingerprint, resolvedByKey, scope) => {
  let budget = MIX_FETCH_BUDGET;

  try {
    while (budget > 0 && stillCurrentScope(getState, columnKey, sessionId, fingerprint, scope)) {
      const keys = nextFetchKeys(sourceSnapshot(readColumn(getState, columnKey), scope), {
        budget,
        target: MIX_PAGE_TARGET,
        extend: false,
      });

      if (!keys.length) {
        break;
      }

      const batch = keys.slice(0, MIX_FETCH_CONCURRENCY);

      batch.forEach(key => {
        dispatch({
          type: MIX_SOURCE_REQUEST,
          columnKey,
          sourceKey: key,
          sessionId,
          definitionFingerprint: fingerprint,
          ...stamp({}, scope),
        });
      });
      budget -= batch.length;

      await Promise.all(batch.map(async (key) => {
        const column = readColumn(getState, columnKey);
        const sources = sourcesIn(column, scope);
        const cursor = sources && sources.getIn([key, 'cursor']);

        try {
          const generation = relationshipGeneration(getState().get('relationships'));
          const page = await fetchPage(resolvedByKey[key], cursor, getState);

          acceptPage(dispatch, getState, columnKey, sessionId, fingerprint, key, cursor, page, scope, generation);
        } catch (error) {
          failPage(dispatch, getState, columnKey, sessionId, fingerprint, key, error, scope);
        }
      }));
    }
  } finally {
    if (stillCurrentScope(getState, columnKey, sessionId, fingerprint, scope)) {
      dispatch(stamp({
        type: MIX_TIMELINE_DONE,
        columnKey,
        sessionId,
        definitionFingerprint: fingerprint,
      }, scope));

      if (process.env.NODE_ENV === 'development') {
        const column = readColumn(getState, columnKey);

        if (column) {
          console.warn('mix fetch', {
            sources: column.get('sources').size,
            requests: column.getIn(['metrics', 'requests']),
            fetched: column.getIn(['metrics', 'fetched']),
            extraPages: column.getIn(['metrics', 'extraPages']),
          });
        }
      }
    }
  }
};

export const mixColumnKey = (columnId, mixId) => columnId ? `column:${columnId}` : `route:${mixId}`;

export function closeMixTimeline(columnKey) {
  return {
    type: MIX_TIMELINE_CLOSE,
    columnKey,
  };
}

export function loadMixTimeline(columnKey, mix, { extend = false, scope = null, splitId = null } = {}) {
  return (dispatch, getState) => {
    if (!isMixEnabled()) {
      return Promise.resolve();
    }

    const plain = plainMix(mix);

    if (!plain) {
      dispatch(closeMixTimeline(columnKey));
      return Promise.resolve();
    }

    const attempts = plain.sources.map(source => resolveRequest(source));
    const resolved = attempts.filter(source => source.ok && source.key);
    const fingerprint = resolved.map(source => source.key).join('\n');
    const current = readColumn(getState, columnKey);
    const same = current && current.get('definitionFingerprint') === fingerprint && current.get('mixId') === plain.id;
    let sessionId = current ? current.get('sessionId') : null;
    const historyScope = scope === 'history' ? { history: true, splitId } : null;

    if (historyScope) {
      if (!current || current.getIn(['split', 'id']) !== splitId || !same) {
        return Promise.resolve();
      }

      if (current.getIn(['split', 'history', 'running'])) {
        return Promise.resolve();
      }

      const resolvedByKey = resolved.reduce((map, source) => {
        map[source.key] = source;
        return map;
      }, {});

      return extendLoaded(dispatch, getState, columnKey, sessionId, fingerprint, resolvedByKey, historyScope);
    }

    if (!same) {
      sessionId = issueMixSessionId();
      dispatch({
        type: MIX_TIMELINE_OPEN,
        columnKey,
        mixId: plain.id,
        definitionFingerprint: fingerprint,
        sessionId,
        sources: resolved.map(source => ({
          key: source.key,
          descriptor: source.source,
        })),
      });
      attempts.filter(source => !source.ok && source.key).forEach(source => {
        dispatch({
          type: MIX_SOURCE_FAIL,
          columnKey,
          sourceKey: source.key,
          sessionId,
          definitionFingerprint: fingerprint,
          error: source.error,
          clear: true,
        });
      });
    } else if (!extend) {
      return Promise.resolve();
    } else if (current.get('running')) {
      return Promise.resolve();
    } else if (current.get('displayMode') === 'live') {
      dispatch({
        type: MIX_DISPLAY_HISTORY,
        columnKey,
        sessionId,
        definitionFingerprint: fingerprint,
      });
    }

    const resolvedByKey = resolved.reduce((map, source) => {
      map[source.key] = source;
      return map;
    }, {});

    if (extend && same) {
      return extendLoaded(dispatch, getState, columnKey, sessionId, fingerprint, resolvedByKey);
    }

    return pump(dispatch, getState, columnKey, sessionId, fingerprint, resolvedByKey);
  };
}

export function retryMixSource(columnKey, mix, sourceKey, { scope = null, splitId = null } = {}) {
  return async (dispatch, getState) => {
    const column = readColumn(getState, columnKey);
    const historyScope = scope === 'history' ? { history: true, splitId } : null;
    const source = historyScope ? column && column.getIn(['split', 'history', 'sources', sourceKey]) : column && column.getIn(['sources', sourceKey]);
    const running = historyScope ? column && column.getIn(['split', 'history', 'running']) : column && column.get('running');

    if (!column || !source || running || source.get('loading')) {
      return;
    }

    if (historyScope && column.getIn(['split', 'id']) !== splitId) {
      return;
    }

    const retryAt = source.get('retryAt');

    if (source.get('error') === 'rate_limit' && retryAt && retryAt > Date.now()) {
      return;
    }

    const plain = plainMix(mix);
    const resolved = plain && plain.sources.map(item => resolveRequest(item)).find(item => item.ok && item.key === sourceKey);

    if (!resolved) {
      return;
    }

    const sessionId = column.get('sessionId');
    const fingerprint = column.get('definitionFingerprint');

    dispatch(stamp({
      type: MIX_SOURCE_REQUEST,
      columnKey,
      sourceKey,
      sessionId,
      definitionFingerprint: fingerprint,
    }, historyScope));

    try {
      const generation = relationshipGeneration(getState().get('relationships'));
      const page = await fetchPage(resolved, source.get('cursor'), getState);

      acceptPage(dispatch, getState, columnKey, sessionId, fingerprint, sourceKey, source.get('cursor'), page, historyScope, generation);
    } catch (error) {
      failPage(dispatch, getState, columnKey, sessionId, fingerprint, sourceKey, error, historyScope);
    } finally {
      if (stillCurrentScope(getState, columnKey, sessionId, fingerprint, historyScope)) {
        dispatch(stamp({
          type: MIX_TIMELINE_DONE,
          columnKey,
          sessionId,
          definitionFingerprint: fingerprint,
        }, historyScope));
      }
    }
  };
}

const extendLoaded = async (dispatch, getState, columnKey, sessionId, fingerprint, resolvedByKey, scope) => {
  const keys = nextFetchKeys(sourceSnapshot(readColumn(getState, columnKey), scope), {
    budget: MIX_FETCH_BUDGET,
    target: MIX_PAGE_TARGET,
    extend: true,
    retry: true,
  }).slice(0, MIX_FETCH_CONCURRENCY);

  if (!keys.length || !stillCurrentScope(getState, columnKey, sessionId, fingerprint, scope)) {
    return;
  }

  keys.forEach(key => {
    dispatch(stamp({
      type: MIX_SOURCE_REQUEST,
      columnKey,
      sourceKey: key,
      sessionId,
      definitionFingerprint: fingerprint,
    }, scope));
  });

  try {
    await Promise.all(keys.map(async (key) => {
      const column = readColumn(getState, columnKey);
      const sources = sourcesIn(column, scope);
      const cursor = sources && sources.getIn([key, 'cursor']);

      try {
        const generation = relationshipGeneration(getState().get('relationships'));
        const page = await fetchPage(resolvedByKey[key], cursor, getState);

        acceptPage(dispatch, getState, columnKey, sessionId, fingerprint, key, cursor, page, scope, generation);
      } catch (error) {
        failPage(dispatch, getState, columnKey, sessionId, fingerprint, key, error, scope);
      }
    }));
  } finally {
    if (stillCurrentScope(getState, columnKey, sessionId, fingerprint, scope)) {
      dispatch(stamp({
        type: MIX_TIMELINE_DONE,
        columnKey,
        sessionId,
        definitionFingerprint: fingerprint,
      }, scope));
    }
  }
};

export function createMixSplit(columnKey, splitId) {
  return (dispatch, getState) => {
    const column = readColumn(getState, columnKey);

    if (!column || column.getIn(['split', 'id']) || !splitId) {
      return;
    }

    const view = mixTimelineView(column, getState().get('statuses'), getState().get('filters'), me);

    if (!view || view.waiting) {
      return;
    }

    const pending = new Set((column.get('pendingStatusIds') || ImmutableList()).toArray());
    const frozenLive = {};

    (column.get('live') || ImmutableMap()).forEach((entry, key) => {
      frozenLive[key] = {
        ids: entry.get('statusIds').filter(id => !pending.has(id)).toArray(),
        filterResults: entry.get('filterResults') && entry.get('filterResults').toJS ? entry.get('filterResults').toJS() : {},
      };
    });

    dispatch({
      type: MIX_SPLIT_CREATE,
      columnKey,
      splitId,
      sessionId: column.get('sessionId'),
      definitionFingerprint: column.get('definitionFingerprint'),
      frozenLive,
      boundaryId: view.statusIds.first() || null,
    });
  };
}

export function destroyMixSplit(columnKey, splitId, { keep = 'history', liveAtTop = false, historyAtTop = false } = {}) {
  return (dispatch, getState) => {
    const column = readColumn(getState, columnKey);

    if (!column || column.getIn(['split', 'id']) !== splitId) {
      return;
    }

    dispatch({
      type: MIX_SPLIT_DESTROY,
      columnKey,
      splitId,
      keep,
      liveAtTop,
      historyAtTop,
      sessionId: column.get('sessionId'),
      definitionFingerprint: column.get('definitionFingerprint'),
    });
  };
}

export function saveMixSplitAnchor(columnKey, anchor) {
  return {
    type: MIX_SPLIT_ANCHOR,
    columnKey,
    anchor,
  };
}

export function clearMixSplitAnchor(columnKey) {
  return {
    type: MIX_SPLIT_CLEAR_ANCHOR,
    columnKey,
  };
}
