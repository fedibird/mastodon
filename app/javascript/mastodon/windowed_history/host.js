const CONTEXT_PREFIX = 'account-context:';

// Split history is owned by the live column. An account context host is a
// separate timeline id and does not set splitTimelineId on the profile.
export const activeSplitTimeline = (state, sourceTimelineId, timelineId) => (
  !!timelineId && state.getIn(['timelines', sourceTimelineId, 'splitTimelineId']) === timelineId
);

export const activeWindowedTimeline = (state, sourceTimelineId, timelineId, sourceKey) => {
  if (activeSplitTimeline(state, sourceTimelineId, timelineId)) {
    return true;
  }

  if (typeof timelineId !== 'string' || timelineId.indexOf(CONTEXT_PREFIX) !== 0) {
    return false;
  }

  if (state.getIn(['timelines', timelineId, 'contextHost']) !== true) {
    return false;
  }

  // Split callers omit the key. An account context page must name the source
  // stored on the host, so a contract from the previous source cannot write.
  if (typeof sourceKey !== 'string') {
    return true;
  }

  return state.getIn(['timelines', timelineId, 'contextSource']) === sourceKey;
};
