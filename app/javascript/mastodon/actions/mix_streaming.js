import api, { getLinks } from '../api';
import { connectStream } from '../stream';
import { importFetchedAccounts, importFetchedStatuses, importFilters } from './importer';
import { normalizePage, previousStatusesForImport, statusesForSharedImport, classifyFetchFailure } from '../mix/source_adapters';
import compareId from '../compare_id';
import { resolveRequest } from '../mix/adapter';
import { classifyStreamStatus, streamChannelId, streamSubscriptions } from '../mix/stream_adapters';
import { filterContextForSource } from '../mix/filter_context';
import { plainMix } from '../mix/definition';
import { MIX_PAGE_SIZE, MIX_RECONCILE_BUDGET } from '../mix/merge';
import { hiddenStatusIds, relationshipGeneration, relationshipsAfterGeneration, statusHiddenByRelationships } from '../mix/relationship_visibility';
import { fetchRelationshipsSuccess } from './accounts';
import { normalizeFilterResult } from './importer/normalizer';
import { me } from '../initial_state';
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

const applicableFilterResults = (status, source) => {
  const context = filterContextForSource(source);
  const raw = (status && (status.filtered || status.filter_results)) || [];

  if (!raw.length) {
    return { known: true, replace: true, results: [] };
  }

  let unknown = false;
  const results = [];

  raw.forEach(result => {
    if (!result || !result.filter) {
      return;
    }

    if (typeof result.filter !== 'object') {
      unknown = true;
      return;
    }

    const contexts = result.filter.context || [];

    if (context && contexts.indexOf(context) !== -1) {
      const normalized = normalizeFilterResult(result);

      if (normalized && normalized.filter) {
        results.push(normalized);
      }
    }
  });

  if (unknown) {
    return { known: false, replace: false, results: [] };
  }

  if (!results.length) {
    return { known: true, replace: false, results: [] };
  }

  return { known: true, replace: true, results };
};

const importBodies = (dispatch, getState, columnKey, sessionId, fingerprint, bodies) => {
  if (!stillCurrent(getState, columnKey, sessionId, fingerprint)) {
    return false;
  }

  const accounts = [];
  const filters = [];
  const collectFilters = (status) => {
    if (!status) {
      return;
    }

    (status.filtered || status.filter_results || []).forEach(result => {
      if (result && result.filter && typeof result.filter === 'object' && result.filter.id) {
        filters.push({ ...result.filter, id: String(result.filter.id) });
      }
    });

    if (status.reblog) {
      collectFilters(status.reblog);
    }

    if (status.quote) {
      collectFilters(status.quote);
    }
  };

  bodies.forEach(status => {
    if (status && status.account && typeof status.account === 'object') {
      accounts.push(status.account);
    }

    collectFilters(status);
  });

  const previous = previousStatusesForImport(getState().get('statuses'), bodies);
  const safe = statusesForSharedImport(bodies, previous);

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

// The confirmed boundary is the newest id whose newer range has been
// fully checked. lastReceivedId can sit above a gap, so it is not a since_id.
const boundaryId = (column, sourceKey) => {
  const reconciled = column.getIn(['live', sourceKey, 'lastReconciledId']);

  if (reconciled) {
    return reconciled;
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

  if (sinceId) {
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

    const historyLoaded = column.getIn(['sources', sourceKey, 'loaded']);
    const sinceId = boundaryId(column, sourceKey);

    // The opening REST load owns the first page. Do not start a gap fill
    // before that load has a boundary to continue from.
    if (!sinceId && !historyLoaded) {
      return;
    }
    let cursor = null;
    let pages = 0;
    let newestKept = null;
    const generation = record.generation;

    record.runs = record.runs || {};
    const run = (record.runs[sourceKey] || 0) + 1;

    record.runs[sourceKey] = run;

    const active = () => record.runs[sourceKey] === run && record.generation === generation && stillCurrent(getState, columnKey, sessionId, fingerprint);

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
      if (!active()) {
        return;
      }

      let page;

      const generation = relationshipGeneration(getState().get('relationships'));

      try {
        page = await fetchReconcilePage(resolved, { sinceId, maxId: cursor }, getState);
      } catch (error) {
        if (!active()) {
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

      if (!active()) {
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

      const hidden = hiddenStatusIds(getState().get('relationships'), getState().get('statuses'), [page.statuses, page.referencedStatuses]);
      const visibleStatus = (status) => status && !hidden.has(String(status.id));
      const relationships = relationshipsAfterGeneration(getState().get('relationships'), page.relationships, generation);

      if (relationships.length && active()) {
        dispatch(fetchRelationshipsSuccess(relationships));
      }

      if (page.partial) {
        const partialIds = sinceId ? page.ids.filter(id => compareId(id, sinceId) > 0) : page.ids;
        const partialStatuses = page.statuses.filter(status => partialIds.indexOf(status.id) !== -1 && visibleStatus(status));

        if (partialStatuses.length) {
          importBodies(dispatch, getState, columnKey, sessionId, fingerprint, partialStatuses.concat((page.referencedStatuses || []).filter(visibleStatus)));
          partialStatuses.forEach(status => {
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

      const keptIds = sinceId ? page.ids.filter(id => compareId(id, sinceId) > 0) : page.ids.slice();
      const kept = page.statuses.filter(status => keptIds.indexOf(status.id) !== -1 && visibleStatus(status));
      const referenced = (page.referencedStatuses || []).filter(visibleStatus);
      const sawBoundary = !!sinceId && page.ids.some(id => compareId(id, sinceId) <= 0);

      kept.forEach(status => {
        if (!newestKept || compareId(status.id, newestKept) > 0) {
          newestKept = status.id;
        }
      });

      if (kept.length && !importBodies(dispatch, getState, columnKey, sessionId, fingerprint, kept.concat(referenced))) {
        return;
      }

      kept.forEach(status => {
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

      const cursorAdvanced = !cursor || (page.cursor && compareId(String(page.cursor), String(cursor)) < 0);
      const finished = !page.hasMore || sawBoundary;

      if (finished) {
        dispatch({
          type: MIX_STREAM_SYNC,
          columnKey,
          sourceKey,
          sessionId,
          definitionFingerprint: fingerprint,
          syncState: 'connected',
          connected: true,
          lastReconciledId: newestKept || sinceId,
          retryAt: null,
        });
        return;
      }

      if (!page.cursor || !cursorAdvanced) {
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

    if (active()) {
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

const handleStatus = (dispatch, getState, columnKey, sessionId, fingerprint, sourceKey, source, status) => {
  if (statusHiddenByRelationships(getState().get('relationships'), status)) {
    return;
  }

  const decision = classifyStreamStatus(source, status, { me, delivered: true });

  if (decision !== 'accept') {
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

const memberOf = (column, sourceKey, id) => {
  const lists = [
    column && column.getIn(['sources', sourceKey, 'ids']),
    column && column.getIn(['live', sourceKey, 'statusIds']),
    column && column.getIn(['split', 'history', 'sources', sourceKey, 'ids']),
    column && column.getIn(['split', 'history', 'frozenLive', sourceKey, 'ids']),
  ];

  return lists.some(list => list && list.includes && list.includes(id));
};

const handleEdit = (dispatch, getState, columnKey, sessionId, fingerprint, streams, receivedKey, status) => {
  if (!importBodies(dispatch, getState, columnKey, sessionId, fingerprint, [status])) {
    return;
  }

  const column = readColumn(getState, columnKey);
  const decisions = [];
  const hidden = statusHiddenByRelationships(getState().get('relationships'), status);

  streams.forEach(item => {
    const existing = memberOf(column, item.key, status.id);
    const delivered = item.key === receivedKey;

    if (hidden) {
      if (!existing) {
        return;
      }

      decisions.push({
        sourceKey: item.key,
        decision: 'conceal',
        delivered: false,
        filterResults: null,
      });
      return;
    }

    if (!existing && !delivered) {
      return;
    }

    const decision = existing
      ? classifyStreamStatus(item.source, status, { me, delivered: item.source.type === 'list' || item.source.type === 'group' })
      : classifyStreamStatus(item.source, status, { me, delivered: true });
    const applicable = applicableFilterResults(status, item.source);

    decisions.push({
      sourceKey: item.key,
      decision,
      delivered: delivered && !existing,
      filterResults: applicable.known && applicable.replace ? applicable.results : null,
    });

    if (decision === 'unknown' || !applicable.known) {
      dispatch(reconcileMixSource(columnKey, item.key));
    }
  });

  dispatch({
    type: MIX_STREAM_EDIT,
    columnKey,
    sessionId,
    definitionFingerprint: fingerprint,
    id: status.id,
    decisions,
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
      const resolved = streamSubscriptions(source);

      return resolved.ok ? resolved : null;
    }).filter(Boolean);

    dispatch({
      type: MIX_STREAM_READY,
      columnKey,
      sessionId,
      definitionFingerprint: fingerprint,
      sources: streams.map(stream => ({
        key: stream.key,
        mode: stream.mode,
        channels: (stream.channels || []).map(item => streamChannelId(item.channel, item.params)),
      })),
    });

    const record = { sessionId, fingerprint, generation: 0, stops: [] };

    subscriptions.set(columnKey, record);

    streams.forEach(stream => {
      if (stream.mode === 'rest_only') {
        return;
      }

      (stream.channels || []).forEach(subscription => {
        const channelId = streamChannelId(subscription.channel, subscription.params);
        const stop = dispatch(connectStream(subscription.channel, subscription.params, () => ({
          onConnect () {
            if (subscriptions.get(columnKey) !== record || !stillCurrent(getState, columnKey, sessionId, fingerprint)) {
              return;
            }

            const current = readColumn(getState, columnKey);
            const wasDown = current && (current.getIn(['live', stream.key, 'syncState']) === 'disconnected' || current.getIn(['live', stream.key, 'syncState']) === 'reconnecting');

            dispatch({
              type: MIX_STREAM_CONNECT,
              columnKey,
              sourceKey: stream.key,
              channelId,
              sessionId,
              definitionFingerprint: fingerprint,
            });

            const after = readColumn(getState, columnKey);

            if (wasDown && after && after.getIn(['live', stream.key, 'syncState']) === 'connected') {
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
              channelId,
              sessionId,
              definitionFingerprint: fingerprint,
              disconnectedAt: Date.now(),
            });
          },

          onReceive (data) {
            if (subscriptions.get(columnKey) !== record || !stillCurrent(getState, columnKey, sessionId, fingerprint)) {
              return;
            }

            if (data.event === 'update') {
              handleStatus(dispatch, getState, columnKey, sessionId, fingerprint, stream.key, stream.source, JSON.parse(data.payload));
            } else if (data.event === 'status.update') {
              handleEdit(dispatch, getState, columnKey, sessionId, fingerprint, streams.filter(item => item.mode !== 'rest_only'), stream.key, JSON.parse(data.payload));
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
