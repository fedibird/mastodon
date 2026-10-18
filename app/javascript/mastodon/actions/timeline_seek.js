import { isCancel } from 'axios';

import { fetchRelationshipsFromStatuses, fetchRelationshipsSuccess } from './accounts';
import { importFetchedAccounts, importFetchedStatus, importFetchedStatuses } from './importer';
import api from '../api';
import { capabilityFor } from '../timeline_seek/capability';
import {
  SEEK_PAGE_LIMIT,
  WINDOW_SEEK_BEGIN,
  WINDOW_SEEK_COMMIT,
  WINDOW_SEEK_FAIL,
  WINDOW_SEEK_POINT,
  WINDOW_SEEK_SCROLL,
} from '../timeline_seek/constants';
import {
  createSeekQuery,
  normalizeSeekResult,
  seekSourceFromContract,
  seekSourceKey,
  seekTargetPayload,
} from '../timeline_seek/query';
import { anchorBeyondSplitBoundary, seekIsCurrent } from '../timeline_seek/window';
import {
  cancelWindowedHistory,
  claimWindowedHistoryFlight,
  releaseWindowedHistoryFlight,
} from '../windowed_history/flights';
import { activeWindowedTimeline } from '../windowed_history/host';
import { historyRequestParams } from '../windowed_history/sources';
import { plainWindow } from '../windowed_history/timeline_state';

let seekSerial = 0;

const nextSessionId = () => {
  seekSerial += 1;
  return `timeline-seek-${seekSerial}`;
};

const statusList = (data) => {
  if (!data) {
    return [];
  }

  if (Array.isArray(data)) {
    return data;
  }

  if (Array.isArray(data.statuses)) {
    return data.statuses;
  }

  return [];
};

const statusIds = (data) => statusList(data).map(status => status && status.id).filter(id => typeof id === 'string');

const importPage = (dispatch, data) => {
  if (!data) {
    return;
  }

  if (data.statuses && data.accounts) {
    dispatch(importFetchedAccounts(data.accounts));
    dispatch(importFetchedStatuses(statusList(data).concat(data.referenced_statuses || [])));
    dispatch(fetchRelationshipsSuccess(data.relationships));
    return;
  }

  const statuses = statusList(data);
  dispatch(importFetchedStatuses(statuses));
  dispatch(fetchRelationshipsFromStatuses(statuses));
};

export function settleWindowSeekScroll(timeline, { sessionId, revision, reason, scrolled } = {}) {
  return {
    type: WINDOW_SEEK_SCROLL,
    timeline,
    sessionId,
    revision,
    reason,
    scrolled: !!scrolled,
  };
}

// Points the history scroller at a row already in the window. The snapshot is
// the pre-jump window, matching a seek, so a filtered scroll can restore it.
export function pointLoadedWindow({ splitTimelineId, anchorId, contract } = {}) {
  return (dispatch, getState) => {
    const before = getState().getIn(['timelines', splitTimelineId]);
    const snapshot = before ? {
      items: before.get('items'),
      windowState: before.get('window'),
    } : null;

    cancelWindowedHistory(splitTimelineId);

    const sessionId = nextSessionId();

    dispatch({
      type: WINDOW_SEEK_POINT,
      timeline: splitTimelineId,
      sessionId,
      anchorId,
      source: seekSourceKey(contract),
    });

    const seek = getState().getIn(['timelines', splitTimelineId, 'seek']);

    if (!seek || seek.get('id') !== sessionId || seek.get('scrollStatus') !== 'pending') {
      return { sessionId: null, snapshot };
    }

    return { sessionId, snapshot };
  };
}

export function seekWindowedTimeline({
  sourceTimelineId,
  splitTimelineId,
  contract,
  query,
} = {}) {
  return (dispatch, getState) => {
    const built = query && query.version ? query : createSeekQuery(query || {});
    const parsed = seekSourceFromContract(contract);
    const sourceKey = seekSourceKey(contract);
    const cap = capabilityFor(parsed && parsed.source, built.kind);

    if (!parsed || !activeWindowedTimeline(getState(), sourceTimelineId, splitTimelineId)) {
      return Promise.resolve(normalizeSeekResult({ outcome: 'stale', capability: 'unavailable', reason: 'split_inactive' }));
    }

    if (!getState().getIn(['timelines', splitTimelineId, 'window'])) {
      return Promise.resolve(normalizeSeekResult({ outcome: 'unsupported', capability: 'unsupported', reason: 'window_required' }));
    }

    if (built.target && built.target.rejected) {
      return Promise.resolve(normalizeSeekResult({ outcome: 'unsupported', capability: 'unsupported', reason: 'search_text_not_accepted' }));
    }

    if (cap.level === 'unsupported') {
      return Promise.resolve(normalizeSeekResult({ outcome: 'unsupported', capability: cap.level, reason: cap.reason }));
    }

    const sessionId = nextSessionId();

    cancelWindowedHistory(splitTimelineId);

    const flight = claimWindowedHistoryFlight(splitTimelineId, 'seek');

    dispatch({
      type: WINDOW_SEEK_BEGIN,
      timeline: splitTimelineId,
      sourceTimeline: sourceTimelineId,
      sessionId,
      source: sourceKey,
    });

    const snapshot = () => {
      const seek = getState().getIn(['timelines', splitTimelineId, 'seek']);
      const windowState = plainWindow(getState().getIn(['timelines', splitTimelineId, 'window']));

      return { seek, windowState };
    };

    const current = () => {
      const { seek, windowState } = snapshot();

      if (!seek || !windowState) {
        return false;
      }

      return seekIsCurrent({
        active: activeWindowedTimeline(getState(), sourceTimelineId, splitTimelineId),
        sessionId,
        phase: seek.get('phase'),
        generation: seek.get('generation'),
        windowGeneration: windowState.generation,
        recordedSource: seek.get('source'),
        source: sourceKey,
      });
    };

    const finishFailure = (outcome, reason, fields = {}) => {
      releaseWindowedHistoryFlight(splitTimelineId, 'seek', flight);

      const result = normalizeSeekResult({
        outcome,
        reason,
        capability: fields.capability || cap.level,
        precision: fields.precision,
        limitations: fields.limitations,
        anchor_id: fields.anchorId,
        display_row_id: fields.displayRowId,
      });

      if (current()) {
        dispatch({
          type: WINDOW_SEEK_FAIL,
          timeline: splitTimelineId,
          sourceTimeline: sourceTimelineId,
          sessionId,
          outcome: result.outcome,
          reason: result.reason,
          capability: result.capability,
          precision: result.precision,
          limitations: result.limitations,
        });
      }

      return result;
    };

    if (!current()) {
      releaseWindowedHistoryFlight(splitTimelineId, 'seek', flight);
      flight.cancel();
      return Promise.resolve(normalizeSeekResult({ outcome: 'stale', capability: cap.level, reason: 'session_replaced' }));
    }

    const client = api(getState);

    return client.post('/api/v1/timelines/seek', {
      version: built.version,
      kind: built.kind,
      preference: built.preference,
      source: parsed.source,
      context: parsed.context,
      seek_target: seekTargetPayload(built.target),
    }, { cancelToken: flight.cancelToken }).then(response => {
      if (!current()) {
        releaseWindowedHistoryFlight(splitTimelineId, 'seek', flight);
        return normalizeSeekResult({ outcome: 'stale', capability: cap.level, reason: 'stale_resolve' });
      }

      const resolved = normalizeSeekResult(response.data);

      if (resolved.outcome !== 'resolved' || !resolved.anchorId) {
        return finishFailure(resolved.outcome, resolved.reason, resolved);
      }

      const boundaryId = snapshot().windowState && snapshot().windowState.boundaryId;

      if (anchorBeyondSplitBoundary(resolved.anchorId, boundaryId)) {
        return finishFailure('unavailable', 'newer_than_split_boundary', {
          capability: resolved.capability,
          precision: resolved.precision,
          limitations: resolved.limitations.concat(['live_side']),
          anchorId: resolved.anchorId,
          displayRowId: resolved.displayRowId,
        });
      }

      const newer = client.get(contract.path, {
        params: historyRequestParams(contract, 'newer', resolved.anchorId, SEEK_PAGE_LIMIT),
        cancelToken: flight.cancelToken,
      });
      const older = client.get(contract.path, {
        params: historyRequestParams(contract, 'older', resolved.anchorId, SEEK_PAGE_LIMIT),
        cancelToken: flight.cancelToken,
      });
      const anchor = client.get(`/api/v1/statuses/${resolved.anchorId}`, { cancelToken: flight.cancelToken });

      return Promise.all([newer, older, anchor]).then(([newerResponse, olderResponse, anchorResponse]) => {
        releaseWindowedHistoryFlight(splitTimelineId, 'seek', flight);

        if (!current()) {
          return normalizeSeekResult({ outcome: 'stale', capability: resolved.capability, reason: 'stale_window' });
        }

        importPage(dispatch, newerResponse.data);
        importPage(dispatch, olderResponse.data);

        if (anchorResponse.data && anchorResponse.data.id) {
          dispatch(importFetchedStatus(anchorResponse.data));
          dispatch(fetchRelationshipsFromStatuses([anchorResponse.data]));
        }

        const newerIds = statusIds(newerResponse.data);
        const olderIds = statusIds(olderResponse.data);

        dispatch({
          type: WINDOW_SEEK_COMMIT,
          timeline: splitTimelineId,
          sourceTimeline: sourceTimelineId,
          sessionId,
          source: sourceKey,
          anchorId: resolved.anchorId,
          newerIds,
          olderIds,
          newerPartial: newerResponse.status === 206,
          olderPartial: olderResponse.status === 206,
          limit: SEEK_PAGE_LIMIT,
          capability: contract.capability,
          precision: resolved.precision,
          limitations: resolved.limitations,
        });

        const seek = getState().getIn(['timelines', splitTimelineId, 'seek']);

        if (!seek || seek.get('phase') !== 'resolved') {
          const recorded = seek && seek.get('limitations');

          return normalizeSeekResult({
            outcome: seek ? seek.get('phase') : 'unavailable',
            reason: seek ? seek.get('reason') : 'commit_rejected',
            capability: resolved.capability,
            limitations: recorded && typeof recorded.toArray === 'function' ? recorded.toArray() : resolved.limitations,
          });
        }

        return {
          ...resolved,
          scroll: {
            pending: true,
            scrolled: false,
            reason: 'pending',
            revision: seek.get('scrollRevision'),
            sessionId,
          },
        };
      });
    }).catch(error => {
      if (!current()) {
        releaseWindowedHistoryFlight(splitTimelineId, 'seek', flight);
        return normalizeSeekResult({ outcome: 'stale', capability: cap.level, reason: 'stale_resolve' });
      }

      if (isCancel(error)) {
        return finishFailure('cancelled', 'cancelled');
      }

      if (error && error.response && error.response.status === 404) {
        return finishFailure('not_found', 'not_found');
      }

      return finishFailure('unavailable', 'network');
    });
  };
}
