import { seekWindowedTimeline, settleWindowSeekScroll } from './timeline_seek';
import { expandWindowedHistory } from './windowed_history';
import {
  ACCOUNT_CONTEXT_CLOSE,
  ACCOUNT_CONTEXT_OPEN,
  accountContextHostId,
  emptyAccountContextWindow,
} from '../timeline_seek/account_context';
import { SEEK_KIND, WINDOW_SEEK_RESTORE } from '../timeline_seek/constants';
import { createSeekQuery, normalizeSeekResult, seekSourceKey } from '../timeline_seek/query';
import { planSeekScroll } from '../timeline_seek/window';
import { cancelWindowedHistory } from '../windowed_history/flights';

export { accountContextFilters, accountContextHostId, emptyAccountContextWindow } from '../timeline_seek/account_context';

const sameHost = (timeline, source) => (
  timeline
  && timeline.get('contextHost') === true
  && timeline.get('contextSource') === source
  && timeline.get('window')
);

export function openAccountContextHost({ hostTimelineId, contract } = {}) {
  return (dispatch, getState) => {
    const timelineId = accountContextHostId(hostTimelineId);

    if (!timelineId || !contract || contract.source !== 'account') {
      return null;
    }

    const source = seekSourceKey(contract);
    const existing = getState().getIn(['timelines', timelineId]);

    if (sameHost(existing, source)) {
      return timelineId;
    }

    cancelWindowedHistory(timelineId);
    dispatch({
      type: ACCOUNT_CONTEXT_OPEN,
      timeline: timelineId,
      source,
      window: emptyAccountContextWindow(),
    });

    return timelineId;
  };
}

export function closeAccountContextHost(hostTimelineId) {
  return (dispatch) => {
    const timelineId = accountContextHostId(hostTimelineId);

    if (!timelineId) {
      return;
    }

    cancelWindowedHistory(timelineId);
    dispatch({
      type: ACCOUNT_CONTEXT_CLOSE,
      timeline: timelineId,
    });
  };
}

// Status id → account context window. The profile timeline id is not the host.
export function seekAccountContext({ hostTimelineId, contract, statusId } = {}) {
  return (dispatch, getState) => {
    const timelineId = dispatch(openAccountContextHost({ hostTimelineId, contract }));

    if (!timelineId || typeof statusId !== 'string') {
      return Promise.resolve(normalizeSeekResult({
        outcome: 'unsupported',
        capability: 'unsupported',
        reason: 'invalid_host',
      }));
    }

    const before = getState().getIn(['timelines', timelineId]);
    const previous = before ? {
      items: before.get('items'),
      windowState: before.get('window'),
    } : null;

    return dispatch(seekWindowedTimeline({
      sourceTimelineId: timelineId,
      splitTimelineId: timelineId,
      contract,
      query: createSeekQuery({
        kind: SEEK_KIND.STATUS,
        source: 'account',
        target: { id: statusId },
      }),
    })).then(result => ({
      ...result,
      previous,
    }));
  };
}

export function expandAccountContext({ hostTimelineId, contract, direction } = {}) {
  return (dispatch) => {
    const timelineId = accountContextHostId(hostTimelineId);

    return dispatch(expandWindowedHistory({
      sourceTimelineId: timelineId,
      splitTimelineId: timelineId,
      contract,
      direction,
    }));
  };
}

// Same decision StatusList makes one frame after the window renders.
export function settleAccountContextScroll({ hostTimelineId, renderedIds, articlePresent, previous } = {}) {
  return (dispatch, getState) => {
    const timelineId = accountContextHostId(hostTimelineId);
    const seek = timelineId && getState().getIn(['timelines', timelineId, 'seek']);

    if (!seek || seek.get('scrollStatus') !== 'pending') {
      return { scroll: false, reason: 'missing' };
    }

    const plan = planSeekScroll({
      anchorId: seek.get('anchorId'),
      renderedIds,
      articlePresent,
    });
    const restore = !plan.scroll && (plan.reason === 'filtered' || plan.reason === 'not_loaded');

    if (restore && previous && previous.items && previous.windowState) {
      dispatch({
        type: WINDOW_SEEK_RESTORE,
        timeline: timelineId,
        sessionId: seek.get('id'),
        items: previous.items,
        windowState: previous.windowState,
        reason: plan.reason,
      });
      return plan;
    }

    dispatch(settleWindowSeekScroll(timelineId, {
      sessionId: seek.get('id'),
      revision: seek.get('scrollRevision'),
      reason: plan.reason,
      scrolled: plan.scroll,
    }));

    return plan;
  };
}
