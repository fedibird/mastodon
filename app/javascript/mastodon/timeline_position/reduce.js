import { fromJS } from 'immutable';

import {
  WINDOW_SEEK_BEGIN,
  WINDOW_SEEK_COMMIT,
  WINDOW_SEEK_FAIL,
  WINDOW_SEEK_SCROLL,
} from '../timeline_seek/constants';
import { HISTORY_RESUME_IN_FLIGHT } from './constants';

const inFlight = (phase) => HISTORY_RESUME_IN_FLIGHT.indexOf(phase) !== -1;

export const beginHistoryResume = (timeline, action) => timeline.set('historyResume', fromJS({
  requestId: action.requestId,
  phase: action.mode === 'seek' ? 'seek_pending' : 'restoring',
  reason: action.reason || null,
  mode: action.mode,
  anchorStatusId: action.anchorStatusId,
  anchorDisplayRowId: action.anchorDisplayRowId || null,
  offsetPx: action.offsetPx,
  alignment: action.alignment,
  routeEntryKey: action.routeEntryKey || null,
  splitSessionId: action.splitSessionId || null,
  seekSessionId: null,
  sourceKey: action.sourceKey || null,
}));

export const settleHistoryResume = (timeline, action) => {
  const resume = timeline.get('historyResume');

  if (!resume || resume.get('requestId') !== action.requestId || !inFlight(resume.get('phase'))) {
    return timeline;
  }

  return timeline.set('historyResume', resume.merge({
    phase: action.scrolled ? 'restored' : 'failed',
    reason: action.reason || (action.scrolled ? 'loaded' : 'not_loaded'),
  }));
};

export const cancelHistoryResumeState = (timeline, action) => {
  const resume = timeline.get('historyResume');

  if (!resume || resume.get('requestId') !== action.requestId || !inFlight(resume.get('phase'))) {
    return timeline;
  }

  return timeline.set('historyResume', resume.merge({
    phase: 'cancelled',
    reason: action.reason || 'cancelled',
  }));
};

export const noteHistoryResumeOnSeek = (timeline, action) => {
  const resume = timeline.get('historyResume');

  if (!resume) {
    return timeline;
  }

  const phase = resume.get('phase');

  if (action.type === WINDOW_SEEK_BEGIN) {
    if (!inFlight(phase)) {
      return timeline;
    }

    if (resume.get('mode') !== 'seek') {
      return timeline.set('historyResume', resume.merge({
        phase: 'cancelled',
        reason: 'seek_replaced',
      }));
    }

    const linked = resume.get('seekSessionId');

    if (!linked) {
      return timeline.set('historyResume', resume.merge({
        seekSessionId: action.sessionId,
        phase: 'seek_pending',
      }));
    }

    if (linked !== action.sessionId) {
      return timeline.set('historyResume', resume.merge({
        phase: 'cancelled',
        reason: 'seek_replaced',
      }));
    }

    return timeline;
  }

  if (resume.get('seekSessionId') !== action.sessionId) {
    return timeline;
  }

  if (action.type === WINDOW_SEEK_COMMIT) {
    if (phase !== 'seek_pending') {
      return timeline;
    }

    return timeline.set('historyResume', resume.merge({
      phase: 'scroll_pending',
      reason: 'seek_resolved',
    }));
  }

  if (action.type === WINDOW_SEEK_FAIL) {
    if (phase !== 'seek_pending' && phase !== 'scroll_pending') {
      return timeline;
    }

    const outcome = action.outcome;
    const cancelled = outcome === 'cancelled' || outcome === 'stale';

    return timeline.set('historyResume', resume.merge({
      phase: cancelled ? 'cancelled' : 'failed',
      reason: outcome || 'unavailable',
    }));
  }

  if (action.type === WINDOW_SEEK_SCROLL) {
    if (phase !== 'scroll_pending') {
      return timeline;
    }

    return timeline.set('historyResume', resume.merge({
      phase: action.scrolled ? 'restored' : 'failed',
      reason: action.reason || (action.scrolled ? 'loaded' : 'not_loaded'),
    }));
  }

  return timeline;
};
