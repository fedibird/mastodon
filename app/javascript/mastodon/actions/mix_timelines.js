import api, { getLinks } from '../api';
import { importFetchedStatuses } from './importer';
import { isMixEnabled } from '../mix/availability';
import { plainMix } from '../mix/definition';
import { resolveSource, classifyFetchError, cursorFromNextLink } from '../mix/adapter';
import { MIX_FETCH_BUDGET, MIX_FETCH_CONCURRENCY, MIX_PAGE_TARGET, nextFetchKeys } from '../mix/merge';

export const MIX_TIMELINE_OPEN = 'MIX_TIMELINE_OPEN';
export const MIX_TIMELINE_CLOSE = 'MIX_TIMELINE_CLOSE';
export const MIX_TIMELINE_DONE = 'MIX_TIMELINE_DONE';
export const MIX_SOURCE_REQUEST = 'MIX_SOURCE_REQUEST';
export const MIX_SOURCE_SUCCESS = 'MIX_SOURCE_SUCCESS';
export const MIX_SOURCE_FAIL = 'MIX_SOURCE_FAIL';

const readColumn = (getState, columnKey) => getState().getIn(['mix_timelines', columnKey]);

const sourceSnapshot = (column) => column.get('sources').entrySeq().map(([key, source]) => ({
  key,
  ids: source.get('ids').toArray(),
  hasMore: source.get('hasMore'),
  loaded: source.get('loaded'),
  loading: source.get('loading'),
  error: source.get('error'),
  next: source.get('next'),
})).toArray();

const stillCurrent = (getState, columnKey, generation) => {
  const column = readColumn(getState, columnKey);

  return !!column && column.get('generation') === generation;
};

const fetchPage = (resolved, cursor, getState) => {
  const params = { ...resolved.params, limit: MIX_PAGE_TARGET };

  if (cursor) {
    params.max_id = cursor;
  }

  return api(getState).get(resolved.path, { params }).then(response => {
    const data = Array.isArray(response.data) ? response.data : [];
    const next = getLinks(response).refs.find(link => link.rel === 'next');
    const ids = data.map(status => status.id).filter(Boolean);

    return {
      statuses: data,
      ids,
      next: next ? cursorFromNextLink(next, ids[ids.length - 1]) : null,
      hasMore: !!next,
    };
  });
};

const pump = async (dispatch, getState, columnKey, generation, resolvedByKey) => {
  let budget = MIX_FETCH_BUDGET;

  try {
    while (budget > 0 && stillCurrent(getState, columnKey, generation)) {
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
          generation,
        });
      });
      budget -= batch.length;

      await Promise.all(batch.map(async (key) => {
        const column = readColumn(getState, columnKey);
        const cursor = column && column.getIn(['sources', key, 'next']);

        try {
          const page = await fetchPage(resolvedByKey[key], cursor, getState);

          if (!stillCurrent(getState, columnKey, generation)) {
            return;
          }

          dispatch(importFetchedStatuses(page.statuses));
          dispatch({
            type: MIX_SOURCE_SUCCESS,
            columnKey,
            sourceKey: key,
            generation,
            ids: page.ids,
            next: page.next,
            hasMore: page.hasMore,
          });
        } catch (error) {
          if (!stillCurrent(getState, columnKey, generation)) {
            return;
          }

          const kind = classifyFetchError(error);

          dispatch({
            type: MIX_SOURCE_FAIL,
            columnKey,
            sourceKey: key,
            generation,
            error: kind,
            clear: kind === 'forbidden' || kind === 'not_found',
          });
        }
      }));
    }
  } finally {
    if (stillCurrent(getState, columnKey, generation)) {
      dispatch({
        type: MIX_TIMELINE_DONE,
        columnKey,
        generation,
      });
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

    const resolved = plain.sources.map(resolveSource).filter(source => source.ok);
    const signature = resolved.map(source => source.key).join('\n');
    const current = readColumn(getState, columnKey);
    const same = current && current.get('signature') === signature && current.get('mixId') === plain.id;
    let generation = current ? current.get('generation') : 0;

    if (!same) {
      generation += 1;
      dispatch({
        type: MIX_TIMELINE_OPEN,
        columnKey,
        mixId: plain.id,
        signature,
        generation,
        sources: resolved.map(source => ({
          key: source.key,
          descriptor: source.source,
        })),
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
      return extendLoaded(dispatch, getState, columnKey, generation, resolvedByKey);
    }

    return pump(dispatch, getState, columnKey, generation, resolvedByKey);
  };
}

const extendLoaded = async (dispatch, getState, columnKey, generation, resolvedByKey) => {
  const keys = nextFetchKeys(sourceSnapshot(readColumn(getState, columnKey)), {
    budget: MIX_FETCH_CONCURRENCY,
    target: MIX_PAGE_TARGET,
    extend: true,
    retry: true,
  });

  if (!keys.length || !stillCurrent(getState, columnKey, generation)) {
    return;
  }

  keys.forEach(key => {
    dispatch({
      type: MIX_SOURCE_REQUEST,
      columnKey,
      sourceKey: key,
      generation,
    });
  });

  try {
    await Promise.all(keys.map(async (key) => {
      const column = readColumn(getState, columnKey);
      const cursor = column && column.getIn(['sources', key, 'next']);

      try {
        const page = await fetchPage(resolvedByKey[key], cursor, getState);

        if (!stillCurrent(getState, columnKey, generation)) {
          return;
        }

        dispatch(importFetchedStatuses(page.statuses));
        dispatch({
          type: MIX_SOURCE_SUCCESS,
          columnKey,
          sourceKey: key,
          generation,
          ids: page.ids,
          next: page.next,
          hasMore: page.hasMore,
        });
      } catch (error) {
        if (!stillCurrent(getState, columnKey, generation)) {
          return;
        }

        const kind = classifyFetchError(error);

        dispatch({
          type: MIX_SOURCE_FAIL,
          columnKey,
          sourceKey: key,
          generation,
          error: kind,
          clear: kind === 'forbidden' || kind === 'not_found',
        });
      }
    }));
  } finally {
    if (stillCurrent(getState, columnKey, generation)) {
      dispatch({
        type: MIX_TIMELINE_DONE,
        columnKey,
        generation,
      });
    }
  }
};
