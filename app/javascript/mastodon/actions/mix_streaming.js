import api, { getLinks } from '../api';
import { connectStream } from '../stream';
import { importFetchedAccounts, importFetchedStatuses, importFilters } from './importer';
import { normalizePage, previousStatusesForImport, statusesForSharedImport, classifyFetchFailure } from '../mix/source_adapters';
import compareId from '../compare_id';
import { resolveRequest } from '../mix/adapter';
import { classifyStreamStatus, resolveStream } from '../mix/stream_adapters';
import { plainMix } from '../mix/definition';
import { MIX_PAGE_SIZE, MIX_RECONCILE_BUDGET } from '../mix/merge';
import { normalizeFilterResult } from './importer/normalizer';
import {
  MIX_STREAM_READY,
  MIX_STREAM_CONNECT,
  MIX_STREAM_DISCONNECT,
  MIX_STREAM_STATUS,
  MIX_STREAM_EDIT,
  MIX_STREAM_REMOVE,
  MIX_STREAM_SYNC,
  MIX_STREAM_PIN,
  MIX_STREAM_REVEAL,
} from './mix_timelines';

const subscriptions = new Map();

const readColumn = (getState, columnKey) => getState().getIn(['mix_timelines', columnKey]);

const stillCurrent = (getState, columnKey, sessionId, fingerprint) => {
  const column = readColumn(getState, columnKey);

  return !!column && column.get('sessionId') === sessionId && column.get('definitionFingerprint') === fingerprint;
};

const filterResultsFor = (status) => (status.filtered || status.filter_results || []).map(normalizeFilterResult).filter(result => result && result.filter);

const importBodies = (dispatch, getState, columnKey, sessionId, fingerprint, bodies) => {
  if (!stillCurrent(getState, columnKey, sessionId, fingerprint)) {
    return false;
  }

  const previous = previousStatusesForImport(getState().get('statuses'), bodies);
  const safe = statusesForSharedImport(bodies, previous);
  const accounts = [];
  const filters = [];

  safe.forEach(status => {
    if (status && status.account && typeof status.account === 'object') {
      accounts.push(status.account);
    }

    (status && (status.filtered || status.filter_results) || []).forEach(result => {
      if (result && result.filter && typeof result.filter === 'object' && result.filter.id) {
        filters.push({ ...result.filter, id: String(result.filter.id) });
      }
    });
  });

  if (accounts.length) {
    dispatch(importFetchedAccounts(accounts));
  }

  if (filters.length) {
    dispatch(importFilters(filters));
  }

  if (!stillCurrent(getState, columnKey, sessionId, fingerprint)) {
    return false;
  }

  dispatch(importFetchedStatuses(safe));
  return stillCurrent(getState, columnKey, sessionId, fingerprint);
};

const relatedIds = (getState, id) => {
  const references = [];
  const quotes = [];

  const statuses = getState().get('statuses');

  if (statuses && statuses.forEach) {
    statuses.forEach(status => {
      if (!status || !status.get) {
        return;
      }

      if (status.get('reblog') === id) {
        references.push(status.get('id'));
      }

      if (status.get('quote_id') === id) {
        quotes.push(status.get('id'));
      }
    });
  }

  return { references, quotes };
};

const boundaryId = (column, sourceKey) => {
  const live = column.getIn(['live', sourceKey, 'lastReceivedId']) || column.getIn(['live', sourceKey, 'lastReconciledId']);

  if (live) {
    return live;
  }

  const history = column.getIn(['sources', sourceKey, 'ids']);

  if (!history || !history.size) {
    return null;
  }

  let newest = history.first();

  history.forEach(id => {
    if (id && compareId(id, newest) > 0) {
      newest = id;
    }
  });

  return newest;
};

const fetchReconcilePage = (resolved, { sinceId, maxId }, getState) => {
  const request = resolveRequest(resolved.source, maxId || null);

  if (!request.ok) {
    return Promise.reject({ response: { status: 404 } });
  }

  const params = { ...request.params, limit: MIX_PAGE_SIZE };

  if (sinceId && !maxId) {
    params.since_id = sinceId;
  }

  return api(getState).get(request.path, { params }).then(response => {
    const next = getLinks(response).refs.find(link => link.rel === 'next');

    return normalizePage({
      status: response.status,
      data: response.data,
      nextUri: next && next.uri,
      path: request.path,
    });
  });
};

export function reconcileMixSource(columnKey, sourceKey) {
  return async (dispatch, getState) => {
    const column = readColumn(getState, columnKey);
    const record = subscriptions.get(columnKey);

    if (!column || !record) {
      return;
    }

    const sessionId = column.get('sessionId');
    const fingerprint = column.get('definitionFingerprint');
    const descriptor = column.getIn(['sources', sourceKey, 'descriptor']);
    const source = descriptor && descriptor.toJS ? descriptor.toJS() : null;
    const resolved = source && resolveRequest(source);
    const retryAt = column.getIn(['live', sourceKey, 'retryAt']);

    if (!resolved || !resolved.ok || (retryAt && retryAt > Date.now())) {
      return;
    }

    const sinceId = boundaryId(column, sourceKey);
    let cursor = null;
    let pages = 0;
    const generation = record.generation;

    dispatch({
      type: MIX_STREAM_SYNC,
      columnKey,
      sourceKey,
      sessionId,
      definitionFingerprint: fingerprint,
      syncState: 'reconciling',
      connected: column.getIn(['live', sourceKey, 'connected']),
    });

    while (pages < MIX_RECONCILE_BUDGET) {
      if (record.generation !== generation || !stillCurrent(getState, columnKey, sessionId, fingerprint)) {
        return;
      }

      let page;

      try {
        page = await fetchReconcilePage(resolved, { sinceId, maxId: cursor }, getState);
      } catch (error) {
        if (record.generation !== generation || !stillCurrent(getState, columnKey, sessionId, fingerprint)) {
          return;
        }

        const failure = classifyFetchFailure(error);

        dispatch({
          type: MIX_STREAM_SYNC,
          columnKey,
          sourceKey,
          sessionId,
          definitionFingerprint: fingerprint,
          syncState: 'degraded',
          retryAt: failure.retryAt || null,
          connected: true,
        });
        return;
      }

      pages += 1;

      if (record.generation !== generation || !stillCurrent(getState, columnKey, sessionId, fingerprint)) {
        return;
      }

      if (!page.ok) {
        dispatch({
          type: MIX_STREAM_SYNC,
          columnKey,
          sourceKey,
          sessionId,
          definitionFingerprint: fingerprint,
          syncState: 'degraded',
          connected: true,
        });
        return;
      }

      if (page.partial) {
        if (page.statuses.length) {
          importBodies(dispatch, getState, columnKey, sessionId, fingerprint, page.statuses.concat(page.referencedStatuses || []));
          page.statuses.forEach(status => {
            dispatch({
              type: MIX_STREAM_STATUS,
              columnKey,
              sourceKey,
              sessionId,
              definitionFingerprint: fingerprint,
              id: status.id,
              decision: 'accept',
              filterResults: page.filterResults[status.id] || filterResultsFor(status),
            });
          });
        }

        dispatch({
          type: MIX_STREAM_SYNC,
          columnKey,
          sourceKey,
          sessionId,
          definitionFingerprint: fingerprint,
          syncState: 'degraded',
          connected: true,
        });
        return;
      }

      if (page.statuses.length && !importBodies(dispatch, getState, columnKey, sessionId, fingerprint, page.statuses.concat(page.referencedStatuses || []))) {
        return;
      }

      page.statuses.forEach(status => {
        dispatch({
          type: MIX_STREAM_STATUS,
          columnKey,
          sourceKey,
          sessionId,
          definitionFingerprint: fingerprint,
          id: status.id,
          decision: 'accept',
          filterResults: page.filterResults[status.id] || filterResultsFor(status),
        });
      });

      const reached = !sinceId || page.ids.some(id => id === sinceId) || !page.hasMore;

      if (reached || !page.cursor) {
        dispatch({
          type: MIX_STREAM_SYNC,
          columnKey,
          sourceKey,
          sessionId,
          definitionFingerprint: fingerprint,
          syncState: 'connected',
          connected: true,
          lastReconciledId: sinceId,
          retryAt: null,
        });
        return;
      }

      if (page.cursor === cursor) {
        dispatch({
          type: MIX_STREAM_SYNC,
          columnKey,
          sourceKey,
          sessionId,
          definitionFingerprint: fingerprint,
          syncState: 'degraded',
          connected: true,
        });
        return;
      }

      cursor = page.cursor;
    }

    if (stillCurrent(getState, columnKey, sessionId, fingerprint) && record.generation === generation) {
      dispatch({
        type: MIX_STREAM_SYNC,
        columnKey,
        sourceKey,
        sessionId,
        definitionFingerprint: fingerprint,
        syncState: 'degraded',
        connected: true,
      });
    }
  };
}

const handleStatus = (dispatch, getState, columnKey, sessionId, fingerprint, sourceKey, source, mode, status) => {
  const decision = mode === 'supported' && classifyStreamStatus(source, status) !== 'reject' ? 'accept' : classifyStreamStatus(source, status);

  if (decision === 'unknown') {
    return;
  }

  if (!importBodies(dispatch, getState, columnKey, sessionId, fingerprint, [status])) {
    return;
  }

  dispatch({
    type: MIX_STREAM_STATUS,
    columnKey,
    sourceKey,
    sessionId,
    definitionFingerprint: fingerprint,
    id: status.id,
    decision,
    filterResults: filterResultsFor(status),
  });
};

const handleEdit = (dispatch, getState, columnKey, sessionId, fingerprint, streams, status) => {
  if (!importBodies(dispatch, getState, columnKey, sessionId, fingerprint, [status])) {
    return;
  }

  const decisions = streams.map(item => {
    const classified = classifyStreamStatus(item.source, status);
    const decision = item.mode === 'supported' && classified !== 'reject' ? 'accept' : classified;

    return {
      sourceKey: item.key,
      decision,
      filterResults: filterResultsFor(status),
    };
  });

  dispatch({
    type: MIX_STREAM_EDIT,
    columnKey,
    sessionId,
    definitionFingerprint: fingerprint,
    id: status.id,
    decisions,
  });

  decisions.forEach(decision => {
    if (decision.decision === 'unknown') {
      dispatch(reconcileMixSource(columnKey, decision.sourceKey));
    }
  });
};

const handleRemove = (dispatch, getState, columnKey, sessionId, fingerprint, id, reason) => {
  if (!stillCurrent(getState, columnKey, sessionId, fingerprint)) {
    return;
  }

  const related = relatedIds(getState, id);

  dispatch({
    type: MIX_STREAM_REMOVE,
    columnKey,
    sourceKey: null,
    sessionId,
    definitionFingerprint: fingerprint,
    id,
    reason,
    references: related.references,
    quotes: related.quotes,
  });
};

export function closeMixStream(columnKey) {
  return () => {
    const record = subscriptions.get(columnKey);

    if (!record) {
      return;
    }

    record.generation += 1;
    record.stops.forEach(stop => {
      if (typeof stop === 'function') {
        stop();
      }
    });
    subscriptions.delete(columnKey);
  };
}

export function openMixStream(columnKey, mix) {
  return (dispatch, getState) => {
    const column = readColumn(getState, columnKey);
    const plain = plainMix(mix);

    if (!column || !plain) {
      return;
    }

    const sessionId = column.get('sessionId');
    const fingerprint = column.get('definitionFingerprint');
    const existing = subscriptions.get(columnKey);

    if (existing && existing.sessionId === sessionId && existing.fingerprint === fingerprint) {
      return;
    }

    dispatch(closeMixStream(columnKey));

    const streams = plain.sources.map(source => {
      const resolved = resolveStream(source);

      return resolved.ok ? resolved : null;
    }).filter(Boolean);

    dispatch({
      type: MIX_STREAM_READY,
      columnKey,
      sessionId,
      definitionFingerprint: fingerprint,
      sources: streams.map(stream => ({ key: stream.key, mode: stream.mode })),
    });

    const record = { sessionId, fingerprint, generation: 0, stops: [] };

    subscriptions.set(columnKey, record);

    streams.forEach(stream => {
      if (stream.mode === 'rest_only') {
        dispatch(reconcileMixSource(columnKey, stream.key));
        return;
      }

      const stop = dispatch(connectStream(stream.channel, stream.params, () => ({
        onConnect () {
          if (subscriptions.get(columnKey) !== record) {
            return;
          }

          const current = readColumn(getState, columnKey);
          const wasDown = current && current.getIn(['live', stream.key, 'syncState']) === 'disconnected';

          if (!stillCurrent(getState, columnKey, sessionId, fingerprint)) {
            return;
          }

          dispatch({
            type: MIX_STREAM_CONNECT,
            columnKey,
            sourceKey: stream.key,
            sessionId,
            definitionFingerprint: fingerprint,
            syncState: wasDown ? 'reconnecting' : 'connected',
          });

          if (wasDown) {
            dispatch(reconcileMixSource(columnKey, stream.key));
          }
        },

        onDisconnect () {
          if (subscriptions.get(columnKey) !== record || !stillCurrent(getState, columnKey, sessionId, fingerprint)) {
            return;
          }

          dispatch({
            type: MIX_STREAM_DISCONNECT,
            columnKey,
            sourceKey: stream.key,
            sessionId,
            definitionFingerprint: fingerprint,
            disconnectedAt: Date.now(),
            syncState: 'disconnected',
          });
        },

        onReceive (data) {
          if (subscriptions.get(columnKey) !== record || !stillCurrent(getState, columnKey, sessionId, fingerprint)) {
            return;
          }

          if (data.event === 'update') {
            handleStatus(dispatch, getState, columnKey, sessionId, fingerprint, stream.key, stream.source, stream.mode, JSON.parse(data.payload));
          } else if (data.event === 'status.update') {
            handleEdit(dispatch, getState, columnKey, sessionId, fingerprint, streams.filter(item => item.mode !== 'rest_only'), JSON.parse(data.payload));
          } else if (data.event === 'delete') {
            handleRemove(dispatch, getState, columnKey, sessionId, fingerprint, data.payload, 'delete');
          } else if (data.event === 'expire') {
            handleRemove(dispatch, getState, columnKey, sessionId, fingerprint, data.payload, 'expire');
          }
        },
      })));

      if (typeof stop === 'function') {
        record.stops.push(stop);
      }
    });
  };
}

export function pinMixStream(columnKey, pinned) {
  return (dispatch, getState) => {
    const column = readColumn(getState, columnKey);

    if (!column) {
      return;
    }

    dispatch({
      type: MIX_STREAM_PIN,
      columnKey,
      sessionId: column.get('sessionId'),
      definitionFingerprint: column.get('definitionFingerprint'),
      pinned,
    });
  };
}

export function revealMixStream(columnKey) {
  return (dispatch, getState) => {
    const column = readColumn(getState, columnKey);

    if (!column) {
      return;
    }

    dispatch({
      type: MIX_STREAM_REVEAL,
      columnKey,
      sessionId: column.get('sessionId'),
      definitionFingerprint: column.get('definitionFingerprint'),
      pinned: true,
    });
  };
}

// Tests reset module state between cases.
export const resetMixStreams = () => {
  subscriptions.forEach((record, columnKey) => {
    record.generation += 1;
    record.stops.forEach(stop => {
      if (typeof stop === 'function') {
        stop();
      }
    });
    subscriptions.delete(columnKey);
  });
};
