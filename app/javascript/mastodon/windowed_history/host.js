const CONTEXT_PREFIX = 'account-context:';

// Split history is owned by the live column. An account context host is a
// separate timeline id and does not set splitTimelineId on the profile.
export const activeSplitTimeline = (state, sourceTimelineId, timelineId) => (
  !!timelineId && state.getIn(['timelines', sourceTimelineId, 'splitTimelineId']) === timelineId
);

export const activeWindowedTimeline = (state, sourceTimelineId, timelineId) => {
  if (activeSplitTimeline(state, sourceTimelineId, timelineId)) {
    return true;
  }

  if (typeof timelineId !== 'string' || timelineId.indexOf(CONTEXT_PREFIX) !== 0) {
    return false;
  }

  return state.getIn(['timelines', timelineId, 'contextHost']) === true;
};
