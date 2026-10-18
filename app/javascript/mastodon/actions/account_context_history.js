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

export function openAccountContextHost({ hostTimelineId, contract, preserveItems = false } = {}) {
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

    // Keep the posts on screen until the new seek commits. The source key
    // still changes so the request is the active one; a failure restores it.
    if (preserveItems && existing && existing.get('contextHost') === true && existing.get('window')) {
      dispatch({
        type: ACCOUNT_CONTEXT_OPEN,
        timeline: timelineId,
        source,
        preserveItems: true,
      });

      return timelineId;
    }

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
export function seekAccountContext({ hostTimelineId, contract, statusId, preserveItems = false } = {}) {
  return (dispatch, getState) => {
    const timelineId = dispatch(openAccountContextHost({ hostTimelineId, contract, preserveItems }));

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
  return (dispatch, getState) => {
    const timelineId = accountContextHostId(hostTimelineId);
    const sourceKey = seekSourceKey(contract);

    if (!timelineId || !sourceKey || getState().getIn(['timelines', timelineId, 'contextSource']) !== sourceKey) {
      return Promise.resolve();
    }

    return dispatch(expandWindowedHistory({
      sourceTimelineId: timelineId,
      splitTimelineId: timelineId,
      contract,
      direction,
      sourceKey,
    }));
  };
}

const settleMatchesSeek = (timeline, seek, { sessionId, scrollRevision, source }) => (
  typeof sessionId === 'string'
  && sessionId.length > 0
  && seek.get('id') === sessionId
  && scrollRevision !== undefined
  && scrollRevision !== null
  && seek.get('scrollRevision') === scrollRevision
  && typeof source === 'string'
  && source.length > 0
  && seek.get('source') === source
  && timeline.get('contextSource') === source
);

// Same decision StatusList makes one frame after the window renders.
// The caller names the seek it rendered. A later seek on this host is left
// alone, including its session id and window.
export function settleAccountContextScroll({
  hostTimelineId,
  renderedIds,
  articlePresent,
  previous,
  sessionId,
  scrollRevision,
  source,
} = {}) {
  return (dispatch, getState) => {
    const timelineId = accountContextHostId(hostTimelineId);
    const timeline = timelineId && getState().getIn(['timelines', timelineId]);
    const seek = timeline && timeline.get('seek');

    if (!seek || seek.get('scrollStatus') !== 'pending') {
      return { scroll: false, reason: 'missing' };
    }

    if (!settleMatchesSeek(timeline, seek, { sessionId, scrollRevision, source })) {
      return { scroll: false, reason: 'stale' };
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
        sessionId,
        items: previous.items,
        windowState: previous.windowState,
        reason: plan.reason,
      });
      return plan;
    }

    dispatch(settleWindowSeekScroll(timelineId, {
      sessionId,
      revision: scrollRevision,
      reason: plan.reason,
      scrolled: plan.scroll,
    }));

    return plan;
  };
}
