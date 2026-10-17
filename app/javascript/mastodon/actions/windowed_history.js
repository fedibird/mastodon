import { isCancel } from 'axios';

import { fetchRelationshipsFromStatuses, fetchRelationshipsSuccess } from './accounts';
import { importFetchedAccounts, importFetchedStatuses } from './importer';
import api from '../api';
import { WINDOW_PAGE_LIMIT } from '../windowed_history/constants';
import {
  cancelWindowedHistory,
  claimWindowedHistoryFlight,
  releaseWindowedHistoryFlight,
} from '../windowed_history/flights';
import { beginHistoryRequest, resolveCursor, responseIsCurrent } from '../windowed_history/model';
import { historyRequestParams } from '../windowed_history/sources';
import { plainItems, plainWindow } from '../windowed_history/timeline_state';
import {
  WINDOW_HISTORY_ANCHOR,
  WINDOW_HISTORY_FAIL,
  WINDOW_HISTORY_REQUEST,
  WINDOW_HISTORY_SUCCESS,
} from '../windowed_history/types';

export { cancelWindowedHistory };

let requestSerial = 0;

const nextRequestId = () => {
  requestSerial += 1;
  return `window-history-${requestSerial}`;
};

const activeSplit = (state, sourceTimelineId, splitTimelineId) => (
  !!splitTimelineId && state.getIn(['timelines', sourceTimelineId, 'splitTimelineId']) === splitTimelineId
);

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

export function commitWindowedHistoryAnchor(timeline, anchorId) {
  return {
    type: WINDOW_HISTORY_ANCHOR,
    timeline,
    anchorId,
  };
}

export function expandWindowedHistory({
  sourceTimelineId,
  splitTimelineId,
  contract,
  direction,
  gapCursor = null,
  anchorId = null,
} = {}) {
  return (dispatch, getState) => {
    if (!activeSplit(getState(), sourceTimelineId, splitTimelineId) || !contract || !contract.path) {
      return Promise.resolve();
    }

    const timeline = getState().getIn(['timelines', splitTimelineId]);
    const windowState = plainWindow(timeline && timeline.get('window'));

    if (!windowState) {
      return Promise.resolve();
    }

    const items = plainItems(timeline.get('items'));
    const cursor = resolveCursor(items, windowState, direction, gapCursor);
    const gap = direction === 'older' && !!gapCursor && cursor === gapCursor && cursor !== windowState.oldestId;
    const requestId = nextRequestId();
    const generation = windowState.generation;
    const decision = beginHistoryRequest(windowState, { direction, cursor, requestId, anchorId, gap });

    if (!decision.accepted) {
      return Promise.resolve();
    }

    const flight = claimWindowedHistoryFlight(splitTimelineId, direction);

    dispatch({
      type: WINDOW_HISTORY_REQUEST,
      timeline: splitTimelineId,
      sourceTimeline: sourceTimelineId,
      direction,
      cursor,
      requestId,
      generation,
      anchorId,
      gap,
    });

    const started = plainWindow(getState().getIn(['timelines', splitTimelineId, 'window']));

    if (!started || started[direction].requestId !== requestId) {
      releaseWindowedHistoryFlight(splitTimelineId, direction, flight);
      flight.cancel();
      return Promise.resolve();
    }

    const params = historyRequestParams(contract, direction, cursor, WINDOW_PAGE_LIMIT);

    return api(getState).get(contract.path, { params, cancelToken: flight.cancelToken }).then(response => {
      releaseWindowedHistoryFlight(splitTimelineId, direction, flight);

      if (!activeSplit(getState(), sourceTimelineId, splitTimelineId)) {
        return;
      }

      const current = plainWindow(getState().getIn(['timelines', splitTimelineId, 'window']));

      if (!responseIsCurrent(current, { generation, requestId, direction })) {
        return;
      }

      const data = response.data;

      if (data && data.statuses && data.accounts) {
        dispatch(importFetchedAccounts(data.accounts));
        dispatch(importFetchedStatuses(statusList(data).concat(data.referenced_statuses || [])));
        dispatch(fetchRelationshipsSuccess(data.relationships));
      } else if (data) {
        const statuses = statusList(data);
        dispatch(importFetchedStatuses(statuses));
        dispatch(fetchRelationshipsFromStatuses(statuses));
      }

      dispatch({
        type: WINDOW_HISTORY_SUCCESS,
        timeline: splitTimelineId,
        sourceTimeline: sourceTimelineId,
        statuses: statusList(data),
        partial: response.status === 206,
        direction,
        requestId,
        generation,
        capability: contract.capability,
        limit: WINDOW_PAGE_LIMIT,
        anchorId,
        cursor,
        gap,
      });
    }).catch(error => {
      releaseWindowedHistoryFlight(splitTimelineId, direction, flight);

      if (!activeSplit(getState(), sourceTimelineId, splitTimelineId)) {
        return;
      }

      dispatch({
        type: WINDOW_HISTORY_FAIL,
        timeline: splitTimelineId,
        sourceTimeline: sourceTimelineId,
        direction,
        requestId,
        generation,
        error,
        cancelled: isCancel(error),
      });
    });
  };
}
