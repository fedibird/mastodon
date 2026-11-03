import { connect } from 'react-redux';
import StatusList from '../../../components/status_list';
import { scrollTopTimeline, loadPending } from '../../../actions/timelines';
import { commitWindowedHistoryAnchor } from '../../../actions/windowed_history';
import { settleWindowSeekScroll } from '../../../actions/timeline_seek';
import { getHomeVisibilities, getLimitedVisibilities } from 'mastodon/selectors';
import { Map as ImmutableMap, List as ImmutableList } from 'immutable';
import { createSelector } from 'reselect';
import { debounce } from 'lodash';
import { me } from '../../../initial_state';
import { uniqWithoutNull } from '../../../utils/uniq';
import { makeGetImmediatePresentation } from 'mastodon/selectors/immediate_feed';
import { readTimelineLayout, statusHasTimelineMedia } from 'mastodon/utils/timeline_layout';

const EMPTY_VISIBILITIES = [];

const visibilitiesByType = (state, type) => {
  if (type === 'home') {
    return getHomeVisibilities(state);
  } else if (type === 'limited') {
    return getLimitedVisibilities(state);
  } else {
    // A stable empty array lets the memoized selectors retain their results.
    return EMPTY_VISIBILITIES;
  }
};

const filterStatusIds = (columnSettings, visibilities, statusIds, statuses) => {
  return statusIds.filter(id => {
    if (id === null) return true;

    const statusForId = statuses.get(id);
    let showStatus    = true;

    if (visibilities.length) {
      showStatus = showStatus && visibilities.includes(statusForId.get('visibility'));
    }

    if (statusForId.get('account') === me) return showStatus;

    if (columnSettings.getIn(['shows', 'reblog']) === false) {
      showStatus = showStatus && statusForId.get('reblog') === null;
    }

    if (columnSettings.getIn(['shows', 'reply']) === false) {
      showStatus = showStatus && (statusForId.get('in_reply_to_id') === null || statusForId.get('in_reply_to_account_id') === me);
    }

    return showStatus;
  });
};

const settingSelectors = [
  (state, { type }) => state.getIn(['settings', type], ImmutableMap()),
  (state, { type }) => visibilitiesByType(state, type),
];

const makeGetStatusIds = (pending = false) => createSelector([
  ...settingSelectors,
  (state, { dataTimelineId }) => state.getIn(['timelines', dataTimelineId, pending ? 'pendingItems' : 'items'], ImmutableList()),
  (state) => state.get('statuses'),
], filterStatusIds);

const makeGetLiveStatusIds = () => createSelector([
  ...settingSelectors,
  (state, { dataTimelineId }) => state.getIn(['timelines', dataTimelineId, 'pendingItems'], ImmutableList()),
  (state, { dataTimelineId }) => state.getIn(['timelines', dataTimelineId, 'items'], ImmutableList()),
  (state) => state.get('statuses'),
  (state, { layoutMode }) => layoutMode,
  (state, { statusLimit }) => statusLimit,
], (columnSettings, visibilities, pendingItems, items, statuses, layoutMode, statusLimit) => {
  let statusIds = filterStatusIds(columnSettings, visibilities, uniqWithoutNull(pendingItems.concat(items)), statuses);

  // Count only attachment-bearing posts towards the short split Live cap.
  // Otherwise 40 text posts could hide media further down the loaded feed.
  if (layoutMode === 'media') {
    statusIds = statusIds.filter(id => statusHasTimelineMedia(id, statuses));
  }

  if (Number.isFinite(statusLimit)) {
    statusIds = statusIds.take(statusLimit);
  }

  return statusIds;
});

const seekScrollProps = (state, dataId) => {
  const seek = state.getIn(['timelines', dataId, 'seek']);
  const revision = state.getIn(['timelines', dataId, 'window', 'revision']) || 0;
  const pending = !!(
    seek
    && seek.get('phase') === 'resolved'
    && seek.get('scrollStatus') === 'pending'
    && seek.get('scrollRevision') === revision
    && seek.get('anchorId')
  );

  if (!pending) {
    return {
      seekScrollPending: false,
      seekSessionId: null,
      seekAnchorId: null,
      seekScrollRevision: 0,
    };
  }

  return {
    seekScrollPending: true,
    seekSessionId: seek.get('id'),
    seekAnchorId: seek.get('anchorId'),
    seekScrollRevision: revision,
  };
};

const windowHistoryProps = (state, dataId) => {
  const history = state.getIn(['timelines', dataId, 'window']);

  if (!history) {
    return {
      windowedHistory: false,
      hasNewer: false,
      newerLoading: false,
      newerStatus: null,
      olderStatus: null,
      anchorResolution: null,
      historyUnbounded: false,
      windowRevision: 0,
    };
  }

  return {
    windowedHistory: true,
    hasNewer: history.get('hasNewer'),
    newerLoading: history.getIn(['newer', 'status']) === 'loading',
    newerStatus: history.getIn(['newer', 'status']),
    olderStatus: history.getIn(['older', 'status']),
    anchorResolution: history.get('anchorResolution'),
    historyUnbounded: history.get('unbounded'),
    windowRevision: history.get('revision') || 0,
  };
};

const mergeImmediateStatusIds = (statusIds, prependIds) => {
  if (!prependIds || prependIds.isEmpty()) {
    return statusIds;
  }

  return uniqWithoutNull(prependIds.concat(statusIds));
};

export const makeMapStateToProps = () => {
  const getStatusIds = makeGetStatusIds();
  const getPendingStatusIds = makeGetStatusIds(true);
  const getLiveStatusIds = makeGetLiveStatusIds();
  // Use a separate memoized selector for the unfiltered reconciliation set,
  // so switching selector arguments does not reallocate Live rows each render.
  const getReconciliationLiveIds = makeGetLiveStatusIds();
  const getImmediatePresentation = makeGetImmediatePresentation();

  const mapStateToProps = (state, { timelineId, dataTimelineId, includePendingItems, statusLimit, immediateViewKey, layoutScope, columnId, disableLayout }) => {
    const dataId = dataTimelineId || timelineId;
    // Split panes use the saved column mode; an explicit opt-out keeps
    // conventional status rows for other consumers.
    const layoutMode = disableLayout ? 'normal' : readTimelineLayout(state, columnId, layoutScope);
    const layoutProps = {
      layoutMode,
      mediaStatuses: layoutMode === 'media' ? state.get('statuses') : null,
    };
    const selectorProps = { type: timelineId, dataTimelineId: dataId, statusLimit, layoutMode };
    const presentation = getImmediatePresentation(state, {
      timelineId,
      dataTimelineId: dataId,
      includePendingItems,
      immediateViewKey,
    });
    const prependIds = presentation.get('prependIds');
    const immediateStatusIds = presentation.get('fadeIds');

    if (includePendingItems) {
      return {
        statusIds: mergeImmediateStatusIds(getLiveStatusIds(state, selectorProps), prependIds),
        ...layoutProps,
        immediateStatusIds,
        // Reconciliation still tracks text-only statuses hidden by the view.
        filterStatusIds: getReconciliationLiveIds(state, { ...selectorProps, layoutMode: 'normal', statusLimit: undefined }),
        isLoading: state.getIn(['timelines', dataId, 'isLoading'], true),
        isPartial: state.getIn(['timelines', dataId, 'isPartial'], false),
        hasMore: state.getIn(['timelines', dataId, 'hasMore']),
        numPending: 0,
        ...windowHistoryProps(state, dataId),
        ...seekScrollProps(state, dataId),
        historySurfaceId: state.getIn(['timelines', dataId, 'window']) ? dataId : null,
      };
    }

    return {
      statusIds: mergeImmediateStatusIds(getStatusIds(state, selectorProps), prependIds),
      ...layoutProps,
      immediateStatusIds,
      filterStatusIds: getStatusIds(state, selectorProps).concat(getPendingStatusIds(state, selectorProps)),
      isLoading: state.getIn(['timelines', dataId, 'isLoading'], true),
      isPartial: state.getIn(['timelines', dataId, 'isPartial'], false),
      hasMore: state.getIn(['timelines', dataId, 'hasMore']),
      numPending: getPendingStatusIds(state, selectorProps).size,
      ...windowHistoryProps(state, dataId),
      ...seekScrollProps(state, dataId),
      historySurfaceId: state.getIn(['timelines', dataId, 'window']) ? dataId : null,
    };
  };

  return mapStateToProps;
};

const mapDispatchToProps = (dispatch, { timelineId, dataTimelineId, manageTimelineScrollState = true }) => {
  const scrollTimeline = dataTimelineId || timelineId;

  if (!manageTimelineScrollState) {
    return {
      onLoadPending: () => dispatch(loadPending(scrollTimeline)),
      onCommitWindowAnchor: (anchorId) => dispatch(commitWindowedHistoryAnchor(scrollTimeline, anchorId)),
      onSeekScroll: (result) => dispatch(settleWindowSeekScroll(scrollTimeline, result)),
    };
  }

  return {
    onScrollToTop: debounce(() => {
      dispatch(scrollTopTimeline(scrollTimeline, true));
    }, 100),

    onScroll: debounce(() => {
      dispatch(scrollTopTimeline(scrollTimeline, false));
    }, 100),

    onLoadPending: () => dispatch(loadPending(scrollTimeline)),
    onCommitWindowAnchor: (anchorId) => dispatch(commitWindowedHistoryAnchor(scrollTimeline, anchorId)),
    onSeekScroll: (result) => dispatch(settleWindowSeekScroll(scrollTimeline, result)),
  };
};

export default connect(makeMapStateToProps, mapDispatchToProps)(StatusList);
