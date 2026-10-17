import { fromJS } from 'immutable';

import { beginSeekSession } from '../windowed_history/model';
import { plainItems, plainWindow, writeWindow } from '../windowed_history/timeline_state';
import { anchorBeyondSplitBoundary, commitSeekWindow } from './window';

const seekRecord = (fields) => fromJS(fields);

export const beginSeekState = (timeline, action) => {
  const current = plainWindow(timeline.get('window'));

  if (!current) {
    return timeline;
  }

  const next = beginSeekSession(current);

  return writeWindow(timeline, plainItems(timeline.get('items')), next).set('seek', seekRecord({
    id: action.sessionId,
    phase: 'pending',
    generation: next.generation,
    source: action.source,
  }));
};

export const failSeekState = (timeline, action) => {
  const seek = timeline.get('seek');

  if (!seek || seek.get('id') !== action.sessionId || seek.get('phase') !== 'pending') {
    return timeline;
  }

  const current = plainWindow(timeline.get('window'));
  const released = current ? { ...current, seeking: false } : null;
  const updated = released ? writeWindow(timeline, plainItems(timeline.get('items')), released) : timeline;

  return updated.set('seek', seekRecord({
    id: action.sessionId,
    phase: action.outcome,
    generation: seek.get('generation'),
    source: seek.get('source'),
    outcome: action.outcome,
    reason: action.reason || null,
    capability: action.capability || null,
    precision: action.precision || null,
    limitations: action.limitations || [],
  }));
};

export const commitSeekState = (timeline, action) => {
  const seek = timeline.get('seek');
  const current = plainWindow(timeline.get('window'));

  if (!seek || !current || seek.get('phase') !== 'pending' || seek.get('id') !== action.sessionId) {
    return timeline;
  }

  if (seek.get('generation') !== current.generation || (action.source && seek.get('source') !== action.source)) {
    return timeline;
  }

  const committed = commitSeekWindow(current, action);

  if (!committed.committed) {
    const beyond = anchorBeyondSplitBoundary(action.anchorId, current.boundaryId);

    return failSeekState(timeline, {
      sessionId: action.sessionId,
      outcome: 'unavailable',
      reason: beyond ? 'newer_than_split_boundary' : 'commit_rejected',
      capability: action.capability,
      limitations: beyond ? ['live_side'] : (action.limitations || []),
    });
  }

  return writeWindow(timeline, committed.items, committed.window).set('seek', seekRecord({
    id: action.sessionId,
    phase: 'resolved',
    generation: committed.window.generation,
    source: seek.get('source'),
    outcome: 'resolved',
    anchorId: action.anchorId,
    precision: action.precision || null,
    limitations: action.limitations || [],
    scrollStatus: 'pending',
    scrollRevision: committed.window.revision,
    scrollReason: null,
  }));
};

const RESTORE_REASONS = ['filtered', 'not_loaded'];

// Puts the pre-jump history window back when the row never became the
// visible anchor. A loaded scroll and a reader scroll are left alone.
export const restoreJumpWindow = (timeline, action) => {
  const seek = timeline.get('seek');

  if (!seek || seek.get('id') !== action.sessionId || seek.get('scrollStatus') === 'loaded') {
    return timeline;
  }

  if (RESTORE_REASONS.indexOf(action.reason) === -1 || !action.items || !action.windowState) {
    return timeline;
  }

  return timeline
    .set('items', action.items)
    .set('window', action.windowState)
    .set('seek', seek.merge({
      scrollStatus: action.reason,
      scrollReason: action.reason,
      restored: true,
    }));
};

export const settleSeekScroll = (timeline, action) => {
  const seek = timeline.get('seek');

  if (!seek || seek.get('id') !== action.sessionId || seek.get('scrollStatus') !== 'pending') {
    return timeline;
  }

  if (action.revision !== undefined && action.revision !== null && seek.get('scrollRevision') !== action.revision) {
    return timeline;
  }

  return timeline.set('seek', seek.merge({
    scrollStatus: action.scrolled ? 'loaded' : (action.reason || 'filtered'),
    scrollReason: action.reason || null,
  }));
};
