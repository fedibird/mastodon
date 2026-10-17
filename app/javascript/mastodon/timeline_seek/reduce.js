import { fromJS } from 'immutable';

import { beginSeekSession } from '../windowed_history/model';
import { plainItems, plainWindow, writeWindow } from '../windowed_history/timeline_state';
import { commitSeekWindow } from './window';

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
    return timeline;
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
    scrollReason: action.scrollReason || null,
  }));
};
