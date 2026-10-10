import api, { getLinks } from '../api';
import { fetchRelationshipsSuccess } from './accounts';
import { importFetchedAccounts, importFetchedStatuses, importFilters } from './importer';
import { isMixEnabled } from '../mix/availability';
import { plainMix } from '../mix/definition';
import { resolveRequest, normalizePage, classifyFetchFailure, previousStatusesForImport, statusesForSharedImport } from '../mix/source_adapters';
import { MIX_FETCH_BUDGET, MIX_FETCH_CONCURRENCY, MIX_PAGE_SIZE, MIX_PAGE_TARGET, nextFetchKeys } from '../mix/merge';

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

let mixSessionSerial = 0;

export const issueMixSessionId = () => {
  mixSessionSerial += 1;
  return mixSessionSerial;
};

const readColumn = (getState, columnKey) => getState().getIn(['mix_timelines', columnKey]);

const sourceSnapshot = (column) => column.get('sources').entrySeq().map(([key, source]) => ({
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

const stillCurrent = (getState, columnKey, sessionId, fingerprint) => {
  const column = readColumn(getState, columnKey);

  return !!column && column.get('sessionId') === sessionId && column.get('definitionFingerprint') === fingerprint;
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

const acceptPage = (dispatch, getState, columnKey, sessionId, fingerprint, key, cursor, page) => {
  if (!stillCurrent(getState, columnKey, sessionId, fingerprint)) {
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
    });
    return;
  }

  const bodiesInPage = page.statuses.concat(page.referencedStatuses || []);
  const previousById = previousStatusesForImport(getState().get('statuses'), bodiesInPage);
  const bodies = statusesForSharedImport(bodiesInPage, previousById);

  if (page.accounts && page.accounts.length) {
    dispatch(importFetchedAccounts(page.accounts));
  }

  if (page.relationships && page.relationships.length) {
    dispatch(fetchRelationshipsSuccess(page.relationships));
  }

  if (page.filters && page.filters.length) {
    dispatch(importFilters(page.filters));
  }

  if (!stillCurrent(getState, columnKey, sessionId, fingerprint)) {
    return;
  }

  dispatch(importFetchedStatuses(bodies));
  dispatch({
    type: MIX_SOURCE_SUCCESS,
    columnKey,
    sourceKey: key,
    sessionId,
    definitionFingerprint: fingerprint,
    ids: page.ids,
    filterResults: page.filterResults,
    cursor: page.cursor,
    frontier: page.frontier,
    hasMore: page.hasMore,
    partial: page.partial,
    suspended: page.suspended,
    requestedCursor: cursor || null,
    extra: !!cursor,
  });
};

const failPage = (dispatch, getState, columnKey, sessionId, fingerprint, key, error) => {
  if (!stillCurrent(getState, columnKey, sessionId, fingerprint)) {
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
  });
};

const pump = async (dispatch, getState, columnKey, sessionId, fingerprint, resolvedByKey) => {
  let budget = MIX_FETCH_BUDGET;

  try {
    while (budget > 0 && stillCurrent(getState, columnKey, sessionId, fingerprint)) {
      const keys = nextFetchKeys(sourceSnapshot(readColumn(getState, columnKey)), {
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
        });
      });
      budget -= batch.length;

      await Promise.all(batch.map(async (key) => {
        const column = readColumn(getState, columnKey);
        const cursor = column && column.getIn(['sources', key, 'cursor']);

        try {
          const page = await fetchPage(resolvedByKey[key], cursor, getState);

          acceptPage(dispatch, getState, columnKey, sessionId, fingerprint, key, cursor, page);
        } catch (error) {
          failPage(dispatch, getState, columnKey, sessionId, fingerprint, key, error);
        }
      }));
    }
  } finally {
    if (stillCurrent(getState, columnKey, sessionId, fingerprint)) {
      dispatch({
        type: MIX_TIMELINE_DONE,
        columnKey,
        sessionId,
        definitionFingerprint: fingerprint,
      });

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

export function loadMixTimeline(columnKey, mix, { extend = false } = {}) {
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

export function retryMixSource(columnKey, mix, sourceKey) {
  return async (dispatch, getState) => {
    const column = readColumn(getState, columnKey);
    const source = column && column.getIn(['sources', sourceKey]);

    if (!column || !source || column.get('running') || source.get('loading')) {
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

    dispatch({
      type: MIX_SOURCE_REQUEST,
      columnKey,
      sourceKey,
      sessionId,
      definitionFingerprint: fingerprint,
    });

    try {
      const page = await fetchPage(resolved, source.get('cursor'), getState);

      acceptPage(dispatch, getState, columnKey, sessionId, fingerprint, sourceKey, source.get('cursor'), page);
    } catch (error) {
      failPage(dispatch, getState, columnKey, sessionId, fingerprint, sourceKey, error);
    } finally {
      if (stillCurrent(getState, columnKey, sessionId, fingerprint)) {
        dispatch({
          type: MIX_TIMELINE_DONE,
          columnKey,
          sessionId,
          definitionFingerprint: fingerprint,
        });
      }
    }
  };
}

const extendLoaded = async (dispatch, getState, columnKey, sessionId, fingerprint, resolvedByKey) => {
  const keys = nextFetchKeys(sourceSnapshot(readColumn(getState, columnKey)), {
    budget: MIX_FETCH_BUDGET,
    target: MIX_PAGE_TARGET,
    extend: true,
    retry: true,
  }).slice(0, MIX_FETCH_CONCURRENCY);

  if (!keys.length || !stillCurrent(getState, columnKey, sessionId, fingerprint)) {
    return;
  }

  keys.forEach(key => {
    dispatch({
      type: MIX_SOURCE_REQUEST,
      columnKey,
      sourceKey: key,
      sessionId,
      definitionFingerprint: fingerprint,
    });
  });

  try {
    await Promise.all(keys.map(async (key) => {
      const column = readColumn(getState, columnKey);
      const cursor = column && column.getIn(['sources', key, 'cursor']);

      try {
        const page = await fetchPage(resolvedByKey[key], cursor, getState);

        acceptPage(dispatch, getState, columnKey, sessionId, fingerprint, key, cursor, page);
      } catch (error) {
        failPage(dispatch, getState, columnKey, sessionId, fingerprint, key, error);
      }
    }));
  } finally {
    if (stillCurrent(getState, columnKey, sessionId, fingerprint)) {
      dispatch({
        type: MIX_TIMELINE_DONE,
        columnKey,
        sessionId,
        definitionFingerprint: fingerprint,
      });
    }
  }
};
