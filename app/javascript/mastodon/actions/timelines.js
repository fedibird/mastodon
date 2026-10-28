import { fetchRelationshipsSuccess, fetchRelationshipsFromStatus, fetchRelationshipsFromStatuses } from './accounts';
import { cancelImmediateFeedTimersForStatuses, cancelImmediateFeedTimersForTimeline, syncImmediateFeedFlights } from './immediate_feed';
import { importFetchedStatus, importFetchedStatuses, importFetchedAccounts } from './importer';
import { submitMarkers } from './markers';
import api, { getLinks } from 'mastodon/api';
import { Map as ImmutableMap, List as ImmutableList } from 'immutable';
import compareId from 'mastodon/compare_id';
import { usePendingItems as preferPendingItems, show_follow_button_on_timeline, show_subscribe_button_on_timeline } from 'mastodon/initial_state';
import { externalFeedSession } from 'mastodon/external_feeds/session';
import { protectStatusBodies } from 'mastodon/external_feeds/reconcile';
import { getHomeVisibilities, getLimitedVisibilities } from 'mastodon/selectors';
import {
  domainTimelineId,
  groupTimelineId,
  hashtagTimelineId,
  personalTimelineId,
  publicTimelineId,
} from './timeline_ids';

export const TIMELINE_UPDATE  = 'TIMELINE_UPDATE';
export const TIMELINE_DELETE  = 'TIMELINE_DELETE';
export const TIMELINE_EXPIRE  = 'TIMELINE_EXPIRE';
export const TIMELINE_CLEAR   = 'TIMELINE_CLEAR';

export const TIMELINE_EXPAND_REQUEST = 'TIMELINE_EXPAND_REQUEST';
export const TIMELINE_EXPAND_SUCCESS = 'TIMELINE_EXPAND_SUCCESS';
export const TIMELINE_EXPAND_FAIL    = 'TIMELINE_EXPAND_FAIL';

export const TIMELINE_SCROLL_TOP   = 'TIMELINE_SCROLL_TOP';
export const TIMELINE_LOAD_PENDING = 'TIMELINE_LOAD_PENDING';
export const TIMELINE_DISCONNECT   = 'TIMELINE_DISCONNECT';
export const TIMELINE_CONNECT      = 'TIMELINE_CONNECT';
export const TIMELINE_EXTERNAL_RECONCILE = 'TIMELINE_EXTERNAL_RECONCILE';
export const TIMELINE_EXTERNAL_CLEAR_VIEW = 'TIMELINE_EXTERNAL_CLEAR_VIEW';

export const TIMELINE_MARK_AS_PARTIAL = 'TIMELINE_MARK_AS_PARTIAL';

export const TIMELINE_SPLIT_CREATE  = 'TIMELINE_SPLIT_CREATE';
export const TIMELINE_SPLIT_DESTROY = 'TIMELINE_SPLIT_DESTROY';
export const TIMELINE_SPLIT_SAVE_RETURN_ANCHOR = 'TIMELINE_SPLIT_SAVE_RETURN_ANCHOR';
export const TIMELINE_SPLIT_CLEAR_RETURN_ANCHOR = 'TIMELINE_SPLIT_CLEAR_RETURN_ANCHOR';

export const TIMELINE_SPLIT_KEEP_LIVE = 'live';
export const TIMELINE_SPLIT_KEEP_HISTORY = 'history';

export const loadPending = timeline => ({
  type: TIMELINE_LOAD_PENDING,
  timeline,
});

export function updateTimeline(timeline, status, accept, options = {}) {
  return (dispatch, getState) => {
    if (typeof accept === 'function' && !accept(status)) {
      return;
    }

    if (getState().getIn(['timelines', timeline, 'isPartial'])) {
      // Prevent new items from being added to a partial timeline,
      // since it will be reloaded anyway

      return;
    }

    dispatch(importFetchedStatus(status, {
      acceptPresentationChange: options.acceptPresentationChange !== false,
    }));
    if (show_follow_button_on_timeline || show_subscribe_button_on_timeline || status.quote_id) {
      dispatch(fetchRelationshipsFromStatus(status));
    }

    const insertTimeline = timeline => {
      dispatch({
        type: TIMELINE_UPDATE,
        timeline,
        status,
        usePendingItems: preferPendingItems,
      });
    };

    const visibility = status.visibility_ex || status.visibility;
    const homeVisibilities = getHomeVisibilities(getState());
    const limitedVisibilities = getLimitedVisibilities(getState());

    if (timeline === 'home') {
      if (homeVisibilities.includes(visibility)) {
        insertTimeline('home');
        dispatch(submitMarkers());
      }

      if (limitedVisibilities.includes(visibility)) {
        insertTimeline('limited');
      }

      if (visibility === 'personal') {
        insertTimeline('personal');

        const attachments = status.media_attachments;
        const variantTimelineId = Array.isArray(attachments) && attachments.length > 0 ? 'personal:media' : 'personal:nomedia';

        if (getState().hasIn(['timelines', variantTimelineId])) {
          insertTimeline(variantTimelineId);
        }
      }
    } else {
      insertTimeline(timeline);
    }

    syncImmediateFeedFlights(getState);
  };
};

const relatedStatusIds = (statuses, id, key) => {
  if (!statuses || typeof statuses.forEach !== 'function') {
    return [];
  }

  const related = [];

  statuses.forEach(status => {
    if (!status || typeof status.get !== 'function') {
      return;
    }

    if (status.get(key) !== id) {
      return;
    }

    const relatedId = status.get('id');

    if (relatedId !== undefined && relatedId !== null && relatedId !== '') {
      related.push(relatedId);
    }
  });

  return related;
};

export function deleteFromTimelines(id) {
  return (dispatch, getState) => {
    const statuses = getState().get('statuses');
    const accountId = statuses && typeof statuses.getIn === 'function' ? statuses.getIn([id, 'account']) : undefined;
    const references = relatedStatusIds(statuses, id, 'reblog');
    const quotes = relatedStatusIds(statuses, id, 'quote_id');

    dispatch({
      type: TIMELINE_DELETE,
      id,
      accountId,
      references,
      quotes,
    });
    cancelImmediateFeedTimersForStatuses([id].concat(references));
  };
};

export function expireFromTimelines(id) {
  return (dispatch, getState) => {
    const accountId  = getState().getIn(['statuses', id, 'account']);
    const references = getState().get('statuses').filter(status => status.get('reblog') === id).map(status => status.get('id'));
    const quotes     = getState().get('statuses').filter(status => status.get('quote_id') === id).map(status => status.get('id'));

    dispatch({
      type: TIMELINE_EXPIRE,
      id,
      accountId,
      references,
      quotes,
    });
    cancelImmediateFeedTimersForStatuses([id].concat(references ? references.toArray() : []));
  };
};

export function clearTimeline(timeline) {
  return (dispatch) => {
    cancelImmediateFeedTimersForTimeline(timeline);
    dispatch({ type: TIMELINE_CLEAR, timeline });
  };
};

const noOp = () => {};

const SPLIT_TIMELINE_MARKER = ':split:';

const isStaleSplitTimeline = (state, timelineId) => {
  if (typeof timelineId !== 'string') {
    return false;
  }

  if (state.getIn(['timelines', timelineId, 'contextHost']) === true) {
    return false;
  }

  const index = timelineId.indexOf(SPLIT_TIMELINE_MARKER);

  if (index <= 0) {
    return false;
  }

  const sourceTimeline = timelineId.slice(0, index);

  return state.getIn(['timelines', sourceTimeline, 'splitTimelineId']) !== timelineId;
};

const parseTags = (tags = {}, mode) => {
  return (tags[mode] || []).map((tag) => {
    return tag.value;
  });
};

const newestLoadedId = (list) => {
  if (!list || typeof list.find !== 'function') {
    return null;
  }

  return list.find(id => id !== null && id !== undefined) || null;
};

const externalReconnectKey = (timelineId) => {
  if (timelineId === 'home' || (typeof timelineId === 'string' && timelineId.indexOf('list:') === 0)) {
    return timelineId;
  }

  return null;
};

// One deferred catch-up per timeline. A newer reconnect replaces it. The slot
// is not a queue: the request that is already loading stays the only HTTP
// call until it settles, then one replacement starts.
const deferredExternalReconnects = new Set();

export function clearDeferredExternalReconnectsForTests () {
  deferredExternalReconnects.clear();
}

const reconnectMarkerFor = (timelineId) => {
  const feedKey = externalReconnectKey(timelineId);

  if (!feedKey) {
    return null;
  }

  externalFeedSession.noteReconnect(feedKey);
  const view = externalFeedSession.openViews().find(item => item.key === feedKey);

  return {
    feedKey,
    feedEpoch: externalFeedSession.feedEpoch(feedKey),
    capabilityEpoch: externalFeedSession.capabilityMarker(),
    streamClock: externalFeedSession.streamMarker(),
    snapshot: view ? externalFeedSession.snapshot(view.key, view.token, {}) : null,
  };
};

// A missing snapshot is not acceptance. The hidden cache is filled only when
// the feed and capability generations still match and no view has appeared.
const reconnectPageCurrent = (marker) => {
  if (!marker || !marker.feedKey) {
    return false;
  }

  if (marker.capabilityEpoch !== externalFeedSession.capabilityMarker()) {
    return false;
  }

  if (externalFeedSession.feedEpoch(marker.feedKey) !== marker.feedEpoch) {
    return false;
  }

  const view = externalFeedSession.openViews().find(item => item.key === marker.feedKey);

  if (view) {
    return !!(marker.snapshot && externalFeedSession.accept(marker.snapshot).ok);
  }

  return !marker.snapshot;
};

const heldTimelineIds = (state, timelineId) => {
  const held = new Set();
  const collect = (list) => {
    if (!list || typeof list.forEach !== 'function') {
      return;
    }

    list.forEach(id => {
      if (id !== null && id !== undefined) {
        held.add(String(id));
      }
    });
  };

  collect(state.getIn(['timelines', timelineId, 'items']));
  collect(state.getIn(['timelines', timelineId, 'pendingItems']));
  return held;
};

// Body rejection and list membership are separate. A clock-moved id that is
// still on screen stays in the range, without its old body. A deleted id does
// not come back.
const timelineMergeRows = (statuses, movedSince, held) => (statuses || []).reduce((rows, status) => {
  if (!status || status.id === undefined || status.id === null) {
    return rows;
  }

  if (!movedSince(status.id)) {
    rows.push(status);
    return rows;
  }

  if (held.has(String(status.id))) {
    rows.push({ id: status.id });
  }

  return rows;
}, []);

const dropReconnectPage = (dispatch, timelineId, isLoadingMore) => {
  dispatch(expandTimelineSuccess(timelineId, [], null, false, true, isLoadingMore, false));
};

const restartExternalReconnect = (dispatch, getState, timelineId) => {
  if (timelineId === 'home') {
    dispatch(expandHomeTimeline({
      visibilities: getHomeVisibilities(getState()),
      externalReconnect: true,
    }));
    return;
  }

  if (externalReconnectKey(timelineId)) {
    dispatch(expandListTimeline(timelineId.slice('list:'.length), {
      timelineId,
      externalReconnect: true,
    }));
  }
};

const finishExternalReconnect = (dispatch, getState, timelineId) => {
  if (!deferredExternalReconnects.has(timelineId)) {
    return;
  }

  if (getState().getIn(['timelines', timelineId, 'isLoading'])) {
    return;
  }

  deferredExternalReconnects.delete(timelineId);
  restartExternalReconnect(dispatch, getState, timelineId);
};

export function expandTimeline(timelineId, path, params = {}, done = noOp, options = {}) {
  return (dispatch, getState) => {
    const timeline = getState().getIn(['timelines', timelineId], ImmutableMap());
    const isLoadingMore = !!params.max_id;

    if (timeline.get('isLoading')) {
      // The loading request may belong to an older connection. Invalidate it
      // even though this reconnect cannot start its own HTTP call yet.
      if (options.externalReconnect === true && externalReconnectKey(timelineId)) {
        externalFeedSession.noteReconnect(externalReconnectKey(timelineId));
        deferredExternalReconnects.add(timelineId);
      }

      done();
      return;
    }

    if (!params.max_id && !params.pinned && (timeline.get('items', ImmutableList()).size + timeline.get('pendingItems', ImmutableList()).size) > 0) {
      const pendingId = newestLoadedId(timeline.get('pendingItems', ImmutableList()));
      const itemId = newestLoadedId(timeline.get('items', ImmutableList()));
      let sinceId = null;

      if (pendingId && itemId) {
        sinceId = compareId(pendingId, itemId) > 0 ? pendingId : itemId;
      } else {
        sinceId = itemId || pendingId;
      }

      if (sinceId) {
        params.since_id = sinceId;
      }
    }

    params.compact = true;

    const isLoadingRecent = !!params.since_id;
    const reconnectMarker = options.externalReconnect === true ? reconnectMarkerFor(timelineId) : null;

    dispatch(expandTimelineRequest(timelineId, isLoadingMore));

    api(getState).get(path, { params }).then(response => {
      if (isStaleSplitTimeline(getState(), timelineId)) {
        return;
      }

      if (reconnectMarker && !reconnectPageCurrent(reconnectMarker)) {
        dropReconnectPage(dispatch, timelineId, isLoadingMore);
        return;
      }

      const movedSince = reconnectMarker
        ? (id) => externalFeedSession.statusMovedSince(id, reconnectMarker.streamClock)
        : null;
      const held = movedSince ? heldTimelineIds(getState(), timelineId) : null;
      const next = getLinks(response).refs.find(link => link.rel === 'next');
      if (response.data) {
        if ('statuses' in response.data && 'accounts' in response.data) {
          const { statuses, referenced_statuses, accounts, relationships } = response.data;
          const kept = movedSince ? protectStatusBodies(statuses, movedSince) : statuses;
          const merged = movedSince ? timelineMergeRows(statuses, movedSince, held) : statuses;
          const references = movedSince ? protectStatusBodies(referenced_statuses, movedSince) : (referenced_statuses || []);
          dispatch(importFetchedAccounts(accounts));
          dispatch(importFetchedStatuses((kept || []).concat(references || [])));
          dispatch(fetchRelationshipsSuccess(relationships));
          dispatch(expandTimelineSuccess(timelineId, merged, next ? next.uri : null, response.status === 206, isLoadingRecent, isLoadingMore, isLoadingRecent && preferPendingItems));
          syncImmediateFeedFlights(getState);
        } else {
          const statuses = response.data;
          const kept = movedSince ? protectStatusBodies(statuses, movedSince) : statuses;
          const merged = movedSince ? timelineMergeRows(statuses, movedSince, held) : statuses;
          dispatch(importFetchedStatuses(kept));
          dispatch(fetchRelationshipsFromStatuses(kept));
          dispatch(expandTimelineSuccess(timelineId, merged, next ? next.uri : null, response.status === 206, isLoadingRecent, isLoadingMore, isLoadingRecent && preferPendingItems));
          syncImmediateFeedFlights(getState);
        }
      }

      if (timelineId === 'home') {
        dispatch(submitMarkers());
      }
    }).catch(error => {
      if (isStaleSplitTimeline(getState(), timelineId)) {
        return;
      }

      dispatch(expandTimelineFail(timelineId, error, isLoadingMore));
    }).finally(() => {
      done();
      finishExternalReconnect(dispatch, getState, timelineId);
    });
  };
};

export const expandHomeTimeline            = ({ maxId, visibilities, timelineId = 'home', externalReconnect = false } = {}, done = noOp) => expandTimeline(timelineId, '/api/v1/timelines/home', { max_id: maxId, visibilities: visibilities }, done, { externalReconnect });
export const expandLimitedTimeline         = ({ maxId, visibilities, timelineId = 'limited' } = {}, done = noOp) => expandTimeline(timelineId, '/api/v1/timelines/home', { max_id: maxId, visibilities: visibilities }, done);
export const expandPersonalTimeline        = ({ maxId, onlyMedia, withoutMedia, timelineId = personalTimelineId({ onlyMedia, withoutMedia }) } = {}, done = noOp) => expandTimeline(timelineId, '/api/v1/timelines/personal', { max_id: maxId, only_media: !!onlyMedia, without_media: !!withoutMedia }, done);
export const expandPublicTimeline          = ({ maxId, onlyMedia, withoutMedia, withoutBot, onlyRemote, timelineId = publicTimelineId({ onlyRemote, withoutBot, withoutMedia, onlyMedia }) } = {}, done = noOp) => expandTimeline(timelineId, '/api/v1/timelines/public', { remote: !!onlyRemote, max_id: maxId, only_media: !!onlyMedia, without_media: !!withoutMedia, without_bot: !!withoutBot }, done);
export const expandDomainTimeline          = (domain, { maxId, onlyMedia, withoutMedia, withoutBot, timelineId = domainTimelineId(domain, { withoutBot, withoutMedia, onlyMedia }) } = {}, done = noOp) => expandTimeline(timelineId, '/api/v1/timelines/public', { local: false, domain: domain, max_id: maxId, only_media: !!onlyMedia, without_media: !!withoutMedia, without_bot: !!withoutBot }, done);
export const expandGroupTimeline           = (id, { maxId, onlyMedia, withoutMedia, tagged, timelineId = groupTimelineId(id, { withoutMedia, onlyMedia, tagged }) } = {}, done = noOp) => expandTimeline(timelineId, `/api/v1/timelines/group/${id}`, { max_id: maxId, only_media: !!onlyMedia, without_media: !!withoutMedia, tagged: tagged }, done);
export const fetchAccountTimeline          = (accountId, { withReplies, withoutReblogs, tagged } = {}, done = noOp) => expandTimeline(`account:${accountId}${withReplies ? ':with_replies' : ''}${withoutReblogs ? ':without_reblogs' : ''}${tagged ? `:${tagged}` : ''}`, `/api/v1/accounts/${accountId}/statuses`, { fetch: true, exclude_replies: !withReplies, exclude_reblogs: withoutReblogs, tagged, limit: 5 }, done);
export const expandAccountTimeline         = (accountId, { maxId, withReplies, withoutReblogs, tagged } = {}) => expandTimeline(`account:${accountId}${withReplies ? ':with_replies' : ''}${withoutReblogs ? ':without_reblogs' : ''}${tagged ? `:${tagged}` : ''}`, `/api/v1/accounts/${accountId}/statuses`, { exclude_replies: !withReplies, exclude_reblogs: withoutReblogs, tagged, max_id: maxId });
export const expandAccountCoversations     = (accountId, { maxId } = {}) => expandTimeline(`account:${accountId}:conversations`, `/api/v1/accounts/${accountId}/conversations`, { max_id: maxId });
export const expandAccountFeaturedTimeline = (accountId, { tagged } = {}) => expandTimeline(`account:${accountId}:pinned${tagged ? `:${tagged}` : ''}`, `/api/v1/accounts/${accountId}/statuses`, { pinned: true, tagged });
export const expandAccountMediaTimeline    = (accountId, { maxId } = {}) => expandTimeline(`account:${accountId}:media`, `/api/v1/accounts/${accountId}/statuses`, { max_id: maxId, only_media: true, limit: 40 });
export const expandListTimeline            = (id, { maxId, timelineId = `list:${id}`, externalReconnect = false } = {}, done = noOp) => expandTimeline(timelineId, `/api/v1/timelines/list/${id}`, { max_id: maxId }, done, { externalReconnect });
export const expandHashtagTimeline         = (hashtag, { maxId, tags, timelineId = hashtagTimelineId(hashtag) } = {}, done = noOp) => {
  return expandTimeline(timelineId, `/api/v1/timelines/tag/${hashtag}`, {
    max_id: maxId,
    any:    parseTags(tags, 'any'),
    all:    parseTags(tags, 'all'),
    none:   parseTags(tags, 'none'),
  }, done);
};

export function expandTimelineRequest(timeline, isLoadingMore) {
  return {
    type: TIMELINE_EXPAND_REQUEST,
    timeline,
    skipLoading: !isLoadingMore,
  };
};

export function expandTimelineSuccess(timeline, statuses, next, partial, isLoadingRecent, isLoadingMore, usePendingItems) {
  return {
    type: TIMELINE_EXPAND_SUCCESS,
    timeline,
    statuses,
    next,
    partial,
    isLoadingRecent,
    usePendingItems,
    skipLoading: !isLoadingMore,
  };
};

export function expandTimelineFail(timeline, error, isLoadingMore) {
  return {
    type: TIMELINE_EXPAND_FAIL,
    timeline,
    error,
    skipLoading: !isLoadingMore,
    skipNotFound: timeline.startsWith('account:'),
  };
};

export function scrollTopTimeline(timeline, top) {
  return {
    type: TIMELINE_SCROLL_TOP,
    timeline,
    top,
  };
};

export function connectTimeline(timeline) {
  return {
    type: TIMELINE_CONNECT,
    timeline,
  };
};

export const disconnectTimeline = timeline => ({
  type: TIMELINE_DISCONNECT,
  timeline,
  usePendingItems: preferPendingItems,
});

export const markAsPartial = timeline => ({
  type: TIMELINE_MARK_AS_PARTIAL,
  timeline,
});

export function createTimelineSplit(sourceTimeline, splitTimeline, anchorId = null) {
  return {
    type: TIMELINE_SPLIT_CREATE,
    sourceTimeline,
    splitTimeline,
    anchorId,
  };
}

export function destroyTimelineSplit(
  sourceTimeline,
  splitTimeline,
  {
    keep = TIMELINE_SPLIT_KEEP_HISTORY,
    liveAtTop,
  } = {},
) {
  return {
    type: TIMELINE_SPLIT_DESTROY,
    sourceTimeline,
    splitTimeline,
    keep,
    liveAtTop,
  };
}

export function saveTimelineSplitReturnAnchor(timeline, anchor) {
  return {
    type: TIMELINE_SPLIT_SAVE_RETURN_ANCHOR,
    timeline,
    anchor,
  };
}

export function clearTimelineSplitReturnAnchor(timeline) {
  return {
    type: TIMELINE_SPLIT_CLEAR_RETURN_ANCHOR,
    timeline,
  };
}
