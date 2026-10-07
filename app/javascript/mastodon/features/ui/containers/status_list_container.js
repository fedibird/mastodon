import { connect } from 'react-redux';
import StatusList from '../../../components/status_list';
import { scrollTopTimeline, loadPending } from '../../../actions/timelines';
import { getHomeVisibilities, getLimitedVisibilities } from 'mastodon/selectors';
import { Map as ImmutableMap, List as ImmutableList } from 'immutable';
import { createSelector } from 'reselect';
import { debounce } from 'lodash';
import { me } from '../../../initial_state';
import { uniqWithoutNull } from '../../../utils/uniq';

const visibilitiesByType = (state, type) => {
  if (type === 'home') {
    return getHomeVisibilities(state);
  } else if (type === 'limited') {
    return getLimitedVisibilities(state);
  } else {
    return [];
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
  (state, { statusLimit }) => statusLimit,
], (columnSettings, visibilities, pendingItems, items, statuses, statusLimit) => {
  let statusIds = filterStatusIds(columnSettings, visibilities, uniqWithoutNull(pendingItems.concat(items)), statuses);

  if (Number.isFinite(statusLimit)) {
    statusIds = statusIds.take(statusLimit);
  }

  return statusIds;
});

const makeMapStateToProps = () => {
  const getStatusIds = makeGetStatusIds();
  const getPendingStatusIds = makeGetStatusIds(true);
  const getLiveStatusIds = makeGetLiveStatusIds();

  const mapStateToProps = (state, { timelineId, dataTimelineId, includePendingItems, statusLimit }) => {
    const dataId = dataTimelineId || timelineId;
    const selectorProps = { type: timelineId, dataTimelineId: dataId, statusLimit };

    if (includePendingItems) {
      return {
        statusIds: getLiveStatusIds(state, selectorProps),
        isLoading: state.getIn(['timelines', dataId, 'isLoading'], true),
        isPartial: state.getIn(['timelines', dataId, 'isPartial'], false),
        hasMore: state.getIn(['timelines', dataId, 'hasMore']),
        numPending: 0,
      };
    }

    return {
      statusIds: getStatusIds(state, selectorProps),
      isLoading: state.getIn(['timelines', dataId, 'isLoading'], true),
      isPartial: state.getIn(['timelines', dataId, 'isPartial'], false),
      hasMore: state.getIn(['timelines', dataId, 'hasMore']),
      numPending: getPendingStatusIds(state, selectorProps).size,
    };
  };

  return mapStateToProps;
};

const mapDispatchToProps = (dispatch, { timelineId, dataTimelineId, manageTimelineScrollState = true }) => {
  const scrollTimeline = dataTimelineId || timelineId;

  if (!manageTimelineScrollState) {
    return {
      onLoadPending: () => dispatch(loadPending(scrollTimeline)),
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
  };
};

export default connect(makeMapStateToProps, mapDispatchToProps)(StatusList);
