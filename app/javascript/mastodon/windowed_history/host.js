const CONTEXT_PREFIX = 'account-context:';

// Split history is owned by the live column. An account context host is a
// separate timeline id and does not set splitTimelineId on the profile.
export const activeSplitTimeline = (state, sourceTimelineId, timelineId) => (
  !!timelineId && state.getIn(['timelines', sourceTimelineId, 'splitTimelineId']) === timelineId
);

export const isAccountContextTimeline = (timelineId) => (
  typeof timelineId === 'string' && timelineId.indexOf(CONTEXT_PREFIX) === 0
);

export const activeWindowedTimeline = (state, sourceTimelineId, timelineId, sourceKey) => {
  if (activeSplitTimeline(state, sourceTimelineId, timelineId)) {
    return true;
  }

  if (!isAccountContextTimeline(timelineId) || state.getIn(['timelines', timelineId, 'contextHost']) !== true) {
    return false;
  }

  // A context host names one source. Callers have to pass that key; a split
  // never reaches here, so omitting the key there stays a split check only.
  return typeof sourceKey === 'string'
    && sourceKey.length > 0
    && state.getIn(['timelines', timelineId, 'contextSource']) === sourceKey;
};
