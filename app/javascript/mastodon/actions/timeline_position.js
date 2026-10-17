import { cancelWindowedHistory } from '../windowed_history/flights';
import { plainItems } from '../windowed_history/timeline_state';
import { seekWindowedTimeline, settleWindowSeekScroll } from './timeline_seek';
import { createSeekQuery, seekSourceKey } from '../timeline_seek/query';
import { SEEK_KIND, WINDOW_SEEK_FAIL } from '../timeline_seek/constants';
import {
  HISTORY_RESUME_BEGIN,
  HISTORY_RESUME_CANCEL,
  HISTORY_RESUME_IN_FLIGHT,
  HISTORY_RESUME_SETTLE,
} from '../timeline_position/constants';
import { isNondestructiveSeekOutcome, resumeModeForWindow, routeResumeDecision, sameHostLayout } from '../timeline_position/policy';
import { getPositionRegistry, positionAccountId } from '../timeline_position/session';
import {
  armSurfaceResume,
  clearSurfaceResume,
  restoreHistorySurface,
  subscribeResumeCompletion,
} from '../timeline_position/surface';

let resumeSerial = 0;

const nextRequestId = () => {
  resumeSerial += 1;
  return `history-resume-${resumeSerial}`;
};

const activeSplit = (state, sourceTimelineId, splitTimelineId) => (
  !!splitTimelineId
  && state.getIn(['timelines', sourceTimelineId, 'splitTimelineId']) === splitTimelineId
);

const resumeState = (state, splitTimelineId) => (
  splitTimelineId ? state.getIn(['timelines', splitTimelineId, 'historyResume']) : null
);

export function captureHistoryPosition(input = {}) {
  const accountId = positionAccountId(input.accountId);

  return getPositionRegistry().record({
    ...input,
    accountId,
    hostKind: 'history',
  });
}

export function cancelHistoryResume({
  splitTimelineId,
  requestId,
  reason = 'cancelled',
} = {}) {
  return (dispatch, getState) => {
    const resume = resumeState(getState(), splitTimelineId);
    const activeRequestId = resume && resume.get('requestId');

    // The scroll listener can run before React has rendered HISTORY_RESUME_BEGIN.
    // The store already has the request, so a gesture may omit requestId.
    if (!resume || !activeRequestId || (requestId && requestId !== activeRequestId)) {
      return { ok: false, reason: 'stale' };
    }

    const phase = resume.get('phase');

    if (HISTORY_RESUME_IN_FLIGHT.indexOf(phase) === -1) {
      return { ok: false, reason: 'stale' };
    }

    clearSurfaceResume(splitTimelineId, activeRequestId);
    getPositionRegistry().releaseHoldByRequest(activeRequestId);

    if (phase === 'scroll_pending' && resume.get('seekSessionId')) {
      const revision = getState().getIn(['timelines', splitTimelineId, 'seek', 'scrollRevision']);

      dispatch(settleWindowSeekScroll(splitTimelineId, {
        sessionId: resume.get('seekSessionId'),
        revision,
        scrolled: false,
        reason,
      }));
    } else if (phase === 'seek_pending' || phase === 'restoring') {
      cancelWindowedHistory(splitTimelineId);

      const seek = getState().getIn(['timelines', splitTimelineId, 'seek']);

      if (seek && seek.get('phase') === 'pending' && resume.get('seekSessionId') && seek.get('id') === resume.get('seekSessionId')) {
        dispatch({
          type: WINDOW_SEEK_FAIL,
          timeline: splitTimelineId,
          sessionId: seek.get('id'),
          outcome: 'cancelled',
          reason,
        });
      }

      dispatch({
        type: HISTORY_RESUME_CANCEL,
        timeline: splitTimelineId,
        requestId: activeRequestId,
        reason,
      });
    }

    return { ok: true, reason };
  };
}

export function resumeHistoryPosition({
  accountId,
  sourceTimelineId,
  splitTimelineId,
  contract,
  source,
  view,
  locationKey,
  historyAction,
  explicit = false,
  multiColumn = false,
} = {}) {
  return (dispatch, getState) => {
    const registry = getPositionRegistry();
    const account = positionAccountId(accountId);
    const saved = account ? registry.find(account, source, view) : null;
    const decision = routeResumeDecision({
      saved,
      locationKey,
      historyAction,
      explicit,
    });

    if (!decision.apply) {
      return Promise.resolve({ ok: false, reason: decision.reason, preserved: true });
    }

    if (!activeSplit(getState(), sourceTimelineId, splitTimelineId)) {
      return Promise.resolve({ ok: false, reason: 'split_inactive', preserved: true });
    }

    const anchor = saved.position.anchor;
    const items = plainItems(getState().getIn(['timelines', splitTimelineId, 'items']));
    const mode = resumeModeForWindow({ statusId: anchor.statusId, items });
    const requestId = nextRequestId();

    if (mode.mode === 'unavailable') {
      return Promise.resolve({ ok: false, reason: mode.reason, preserved: true });
    }

    const held = registry.hold(account, source, view, requestId);

    if (!held.ok) {
      return Promise.resolve({ ok: false, reason: held.reason, preserved: true });
    }

    const layout = multiColumn ? 'columns' : 'single';
    const allowFallback = sameHostLayout(saved, { hostKind: 'history', layout });

    dispatch({
      type: HISTORY_RESUME_BEGIN,
      timeline: splitTimelineId,
      sourceTimeline: sourceTimelineId,
      requestId,
      mode: mode.mode,
      reason: mode.reason,
      anchorStatusId: anchor.statusId,
      anchorDisplayRowId: anchor.displayRowId || null,
      offsetPx: anchor.offsetPx,
      alignment: anchor.alignment,
      routeEntryKey: locationKey || null,
      splitSessionId: splitTimelineId,
      sourceKey: seekSourceKey(contract),
    });

    const currentResume = () => resumeState(getState(), splitTimelineId);
    const stillThisRequest = () => {
      const resume = currentResume();

      return !!resume && resume.get('requestId') === requestId;
    };
    const release = () => {
      registry.releaseHold(account, source, view, requestId);
    };
    const preserved = () => {
      const again = registry.find(account, source, view);

      return !!(again && again.position && again.position.anchor && again.position.anchor.statusId === anchor.statusId);
    };

    if (mode.mode === 'scroll') {
      const restored = restoreHistorySurface(splitTimelineId, anchor, {
        allowProvisionalFallback: allowFallback,
      });
      const scrolled = !!restored.ok;
      const reason = restored.reason || (scrolled ? 'loaded' : 'not_loaded');

      if (stillThisRequest() && currentResume().get('phase') !== 'cancelled') {
        dispatch({
          type: HISTORY_RESUME_SETTLE,
          timeline: splitTimelineId,
          requestId,
          scrolled,
          reason,
        });
      }

      release();

      return Promise.resolve({
        ok: scrolled,
        reason,
        preserved: preserved(),
        mode: 'scroll',
      });
    }

    armSurfaceResume(splitTimelineId, {
      requestId,
      anchor,
      allowFallback,
    });

    const unsubscribe = subscribeResumeCompletion(splitTimelineId, requestId, () => {
      registry.releaseHoldByRequest(requestId);
    });

    return dispatch(seekWindowedTimeline({
      sourceTimelineId,
      splitTimelineId,
      contract,
      query: createSeekQuery({
        kind: SEEK_KIND.STATUS,
        target: { id: anchor.statusId },
      }),
    })).then((result) => {
      const outcome = result && result.outcome;

      if (!stillThisRequest() || currentResume().get('phase') === 'cancelled') {
        clearSurfaceResume(splitTimelineId, requestId);
        unsubscribe();
        release();
        return { ok: false, reason: 'stale', preserved: preserved(), mode: 'seek' };
      }

      if (outcome !== 'resolved') {
        clearSurfaceResume(splitTimelineId, requestId);
        unsubscribe();

        const phase = currentResume() && currentResume().get('phase');

        if (phase === 'seek_pending' || phase === 'restoring') {
          dispatch({
            type: HISTORY_RESUME_SETTLE,
            timeline: splitTimelineId,
            requestId,
            scrolled: false,
            reason: outcome || 'unavailable',
          });
        }

        release();

        return {
          ok: false,
          reason: outcome || 'unavailable',
          preserved: preserved(),
          nondestructive: isNondestructiveSeekOutcome(outcome) || outcome === 'stale' || outcome === 'cancelled',
          mode: 'seek',
        };
      }

      return {
        ok: true,
        reason: 'seek_resolved',
        scrollPending: true,
        preserved: preserved(),
        mode: 'seek',
      };
    }).catch(() => {
      clearSurfaceResume(splitTimelineId, requestId);
      unsubscribe();

      if (stillThisRequest() && currentResume().get('phase') !== 'cancelled') {
        dispatch({
          type: HISTORY_RESUME_SETTLE,
          timeline: splitTimelineId,
          requestId,
          scrolled: false,
          reason: 'unavailable',
        });
      }

      release();

      return {
        ok: false,
        reason: 'unavailable',
        preserved: preserved(),
        nondestructive: true,
        mode: 'seek',
      };
    });
  };
}
