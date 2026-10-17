import { timelineSourceIdentity, timelineViewIdentity } from '../timeline_navigation';
import { seekSourceFromContract } from '../timeline_seek/query';

export const historySourceIdentity = (sourceTimelineId, contract) => {
  const parsed = seekSourceFromContract(contract);

  if (!parsed) {
    return null;
  }

  const context = {};

  Object.keys(parsed.context).forEach(key => {
    if (parsed.context[key] !== undefined) {
      context[key] = parsed.context[key];
    }
  });

  return timelineSourceIdentity(sourceTimelineId, context);
};

// Stable across split sessions. location.key is stored and not compared, so
// reopening History in the same column does not look like a different view.
// A single-column route has no column id; `document` is that host.
export const historyViewIdentity = ({
  columnId,
  sourceTimelineId,
  locationKey,
  scrollKey,
} = {}) => {
  if (typeof sourceTimelineId !== 'string' || sourceTimelineId.length === 0) {
    return null;
  }

  const column = typeof columnId === 'string' && columnId.length > 0 ? columnId : null;
  const surface = column || 'document';

  return timelineViewIdentity({
    columnId: column,
    scrollKey: scrollKey || `${sourceTimelineId}:history:${surface}`,
    locationKey: locationKey || null,
    pane: 'history',
    dataTimelineId: `${sourceTimelineId}:split:${surface}`,
    sessionId: null,
  });
};

export const historyLayout = (multiColumn) => (multiColumn ? 'columns' : 'single');
