import {
  TIMELINE_UPDATE,
  TIMELINE_DELETE,
  TIMELINE_EXPIRE,
  TIMELINE_CLEAR,
  TIMELINE_EXPAND_SUCCESS,
  TIMELINE_EXPAND_REQUEST,
  TIMELINE_EXPAND_FAIL,
  TIMELINE_SCROLL_TOP,
  TIMELINE_CONNECT,
  TIMELINE_DISCONNECT,
  TIMELINE_LOAD_PENDING,
  TIMELINE_MARK_AS_PARTIAL,
  TIMELINE_SPLIT_CREATE,
  TIMELINE_SPLIT_DESTROY,
  TIMELINE_SPLIT_KEEP_LIVE,
  TIMELINE_SPLIT_SAVE_RETURN_ANCHOR,
  TIMELINE_SPLIT_CLEAR_RETURN_ANCHOR,
} from '../actions/timelines';
import {
  ACCOUNT_BLOCK_SUCCESS,
  ACCOUNT_MUTE_SUCCESS,
  ACCOUNT_UNFOLLOW_SUCCESS,
  ACCOUNT_UNSUBSCRIBE_SUCCESS,
} from '../actions/accounts';
import { Map as ImmutableMap, List as ImmutableList, fromJS } from 'immutable';
import compareId from '../compare_id';
import { uniqWithoutNull } from '../utils/uniq';


const initialState = ImmutableMap();

const initialTimeline = ImmutableMap({
  unread: 0,
  online: false,
  top: true,
  isLoading: false,
  hasMore: true,
  pendingItems: ImmutableList(),
  items: ImmutableList(),
});

const expandNormalizedTimeline = (state, timeline, statuses, next, isPartial, isLoadingRecent, usePendingItems) => {
  return state.update(timeline, initialTimeline, map => map.withMutations(mMap => {
    mMap.set('isLoading', false);
    mMap.set('isPartial', isPartial);

    if (!next && !isLoadingRecent) mMap.set('hasMore', false);

    if (timeline.endsWith(':pinned')) {
      mMap.set('items', statuses.map(status => status.get('id')));
    } else if (!statuses.isEmpty()) {
      usePendingItems = isLoadingRecent && (usePendingItems || !mMap.get('pendingItems').isEmpty());

      mMap.update(usePendingItems ? 'pendingItems' : 'items', ImmutableList(), oldIds => {
        const newIds = statuses.map(status => status.get('id'));

        const lastIndex = oldIds.findLastIndex(id => id !== null && compareId(id, newIds.last()) >= 0) + 1;
        const firstIndex = oldIds.take(lastIndex).findLastIndex(id => id !== null && compareId(id, newIds.first()) > 0);

        if (firstIndex < 0) {
          return uniqWithoutNull(isPartial ? newIds.unshift(null) : newIds).concat(oldIds.skip(lastIndex));
        }

        return uniqWithoutNull(oldIds.take(firstIndex + 1).concat(
          isPartial && oldIds.get(firstIndex) !== null ? newIds.unshift(null) : newIds,
          oldIds.skip(lastIndex),
        ));
      });
    }
  }));
};

const updateTimeline = (state, timeline, status, usePendingItems) => {
  const top = state.getIn([timeline, 'top']);
  // While a split is active, keep new ids out of items so the top-of-timeline
  // trim cannot drop arrivals before they are restored as pending.
  const queueAsPending = !!state.getIn([timeline, 'splitTimelineId']) || usePendingItems || !state.getIn([timeline, 'pendingItems'], ImmutableList()).isEmpty();

  if (queueAsPending) {
    if (state.getIn([timeline, 'pendingItems'], ImmutableList()).includes(status.get('id')) || state.getIn([timeline, 'items'], ImmutableList()).includes(status.get('id'))) {
      return state;
    }

    return state.update(timeline, initialTimeline, map => map.update('pendingItems', list => list.unshift(status.get('id'))).update('unread', unread => unread + 1));
  }

  const ids        = state.getIn([timeline, 'items'], ImmutableList());
  const includesId = ids.includes(status.get('id'));
  const unread     = state.getIn([timeline, 'unread'], 0);

  if (includesId) {
    return state;
  }

  let newIds = ids;

  return state.update(timeline, initialTimeline, map => map.withMutations(mMap => {
    if (!top) mMap.set('unread', unread + 1);
    if (top && ids.size > 40) newIds = newIds.take(20);
    mMap.set('items', newIds.unshift(status.get('id')));
  }));
};

const deleteStatus = (state, id, references, exclude_account = null) => {
  state.keySeq().forEach(timeline => {
    if (exclude_account === null || (timeline !== `account:${exclude_account}` && !timeline.startsWith(`account:${exclude_account}:`))) {
      const helper = list => list.filterNot(item => item === id);
      state = state.updateIn([timeline, 'items'], helper).updateIn([timeline, 'pendingItems'], helper);
    }
  });

  // Remove reblogs of deleted status
  references?.forEach(ref => {
    state = deleteStatus(state, ref, [], exclude_account);
  });

  return state;
};

const expireStatus = (state, id, references, exclude_account) => {
  state.keySeq().forEach(timeline => {
    if (exclude_account === null || (timeline !== `account:${exclude_account}` && !timeline.startsWith(`account:${exclude_account}:`))) {
      const helper = list => list.filterNot(item => item === id);
      state = state.updateIn([timeline, 'items'], helper).updateIn([timeline, 'pendingItems'], helper);
    }
  });

  // Remove reblogs of deleted status
  references.forEach(ref => {
    state = deleteStatus(state, ref, []);
  });

  return state;
};

const clearTimeline = (state, timeline) => {
  return state.set(timeline, initialTimeline);
};

const filterTimelines = (state, relationship, statuses) => {
  let references;

  statuses.forEach(status => {
    if (status.get('account') !== relationship.id) {
      return;
    }

    references = statuses.filter(item => item.get('reblog') === status.get('id')).map(item => item.get('id'));
    state      = deleteStatus(state, status.get('id'), references, relationship.id);
  });

  return state;
};

const filterTimeline = (timeline, state, relationship, statuses) => {
  const helper = list => list.filterNot(statusId => statuses.getIn([statusId, 'account']) === relationship.id);
  return state.updateIn([timeline, 'items'], ImmutableList(), helper).updateIn([timeline, 'pendingItems'], ImmutableList(), helper);
};

const updateTop = (state, timeline, top) => {
  return state.update(timeline, initialTimeline, map => map.withMutations(mMap => {
    if (top) mMap.set('unread', mMap.get('pendingItems').size);
    mMap.set('top', top);
  }));
};

const SPLIT_TIMELINE_MARKER = ':split:';

const splitSourceTimeline = (timeline) => {
  if (typeof timeline !== 'string') {
    return null;
  }

  const index = timeline.indexOf(SPLIT_TIMELINE_MARKER);

  if (index <= 0) {
    return null;
  }

  return timeline.slice(0, index);
};

const isStaleSplitTimeline = (state, timeline) => {
  const sourceTimeline = splitSourceTimeline(timeline);

  if (!sourceTimeline) {
    return false;
  }

  return state.getIn([sourceTimeline, 'splitTimelineId']) !== timeline;
};

const firstStatusId = (ids) => {
  const id = (ids || ImmutableList()).find(item => item !== null);

  return id === undefined ? null : id;
};

const createTimelineSplit = (state, sourceTimeline, splitTimeline) => {
  if (!sourceTimeline || !splitTimeline || state.getIn([sourceTimeline, 'splitTimelineId'])) {
    return state;
  }

  const source = state.get(sourceTimeline, initialTimeline);
  const items = source.get('items', ImmutableList());

  const history = initialTimeline.merge({
    items,
    pendingItems: ImmutableList(),
    unread: 0,
    online: false,
    isLoading: false,
    hasMore: source.get('hasMore', true),
    isPartial: source.get('isPartial', false),
    top: false,
    splitBoundaryId: firstStatusId(items),
  });

  return state
    .set(splitTimeline, history)
    .setIn([sourceTimeline, 'splitTimelineId'], splitTimeline)
    .deleteIn([sourceTimeline, 'splitReturnAnchor']);
};

const freshStatusIds = (source, history) => {
  const boundaryId = history.get('splitBoundaryId', null);
  const historyIds = new Set(history.get('items', ImmutableList()).filter(id => id !== null).toArray());
  const seen = new Set();
  const fresh = [];

  source.get('pendingItems', ImmutableList()).concat(source.get('items', ImmutableList())).forEach(id => {
    if (id === null || seen.has(id) || historyIds.has(id)) {
      return;
    }

    if (boundaryId === null || compareId(id, boundaryId) > 0) {
      seen.add(id);
      fresh.push(id);
    }
  });

  return ImmutableList(fresh);
};

const keepLiveTimeline = (source, liveAtTop) => {
  const items = uniqWithoutNull(
    source.get('pendingItems', ImmutableList())
      .concat(source.get('items', ImmutableList())),
  );

  return source.withMutations(map => {
    map.set('items', items);
    map.set('pendingItems', ImmutableList());
    map.set('unread', 0);
    map.set('top', !!liveAtTop);
    map.delete('splitTimelineId');
  });
};

const destroyTimelineSplit = (state, action) => {
  const { sourceTimeline, splitTimeline, keep, liveAtTop } = action;
  const source = state.get(sourceTimeline, initialTimeline);
  const history = state.get(splitTimeline);
  const active = source.get('splitTimelineId') === splitTimeline;

  if (!history || !active) {
    let next = state;

    if (active) {
      next = next.update(sourceTimeline, initialTimeline, map => map.delete('splitTimelineId'));
    }

    return next.delete(splitTimeline);
  }

  if (source.get('isPartial')) {
    return state.withMutations(mutable => {
      mutable.update(sourceTimeline, initialTimeline, map => map.delete('splitTimelineId'));
      mutable.delete(splitTimeline);
    });
  }

  if (keep === TIMELINE_SPLIT_KEEP_LIVE) {
    return state.withMutations(mutable => {
      mutable.update(sourceTimeline, initialTimeline, map => keepLiveTimeline(map, liveAtTop));
      mutable.delete(splitTimeline);
    });
  }

  const pendingItems = freshStatusIds(source, history);

  return state.withMutations(mutable => {
    mutable.update(sourceTimeline, initialTimeline, map => map.withMutations(inner => {
      inner.set('items', history.get('items', ImmutableList()));
      inner.set('pendingItems', pendingItems);
      inner.set('unread', pendingItems.size);
      inner.set('hasMore', history.get('hasMore', true));
      inner.set('isPartial', history.get('isPartial', false));
      inner.set('online', source.get('online', false));
      inner.delete('splitTimelineId');

      if (pendingItems.size > 0) {
        inner.set('top', false);
      }
    }));

    mutable.delete(splitTimeline);
  });
};

export default function timelines(state = initialState, action) {
  switch(action.type) {
  case TIMELINE_LOAD_PENDING:
    return isStaleSplitTimeline(state, action.timeline) ? state : state.update(action.timeline, initialTimeline, map =>
      map.update('items', list => map.get('pendingItems').concat(list.take(40))).set('pendingItems', ImmutableList()).set('unread', 0));
  case TIMELINE_EXPAND_REQUEST:
    return isStaleSplitTimeline(state, action.timeline) ? state : state.update(action.timeline, initialTimeline, map => map.set('isLoading', true));
  case TIMELINE_EXPAND_FAIL:
    return isStaleSplitTimeline(state, action.timeline) ? state : state.update(action.timeline, initialTimeline, map => map.set('isLoading', false));
  case TIMELINE_EXPAND_SUCCESS:
    return isStaleSplitTimeline(state, action.timeline) ? state : expandNormalizedTimeline(state, action.timeline, fromJS(action.statuses), action.next, action.partial, action.isLoadingRecent, action.usePendingItems);
  case TIMELINE_UPDATE:
    return isStaleSplitTimeline(state, action.timeline) ? state : updateTimeline(state, action.timeline, fromJS(action.status), action.usePendingItems);
  case TIMELINE_DELETE:
    return deleteStatus(state, action.id, action.references);
  case TIMELINE_EXPIRE:
    return expireStatus(state, action.id, action.references, action.accountId);
  case TIMELINE_CLEAR:
    return clearTimeline(state, action.timeline);
  case ACCOUNT_BLOCK_SUCCESS:
  case ACCOUNT_MUTE_SUCCESS:
    return filterTimelines(state, action.relationship, action.statuses);
  case ACCOUNT_UNFOLLOW_SUCCESS:
  case ACCOUNT_UNSUBSCRIBE_SUCCESS:
    state = filterTimeline('home', state, action.relationship, action.statuses);
    state = filterTimeline('limited', state, action.relationship, action.statuses);

    ['home', 'limited'].forEach(sourceTimeline => {
      const splitTimelineId = state.getIn([sourceTimeline, 'splitTimelineId']);

      if (splitTimelineId) {
        state = filterTimeline(splitTimelineId, state, action.relationship, action.statuses);
      }
    });

    return state;
  case TIMELINE_SPLIT_CREATE:
    return createTimelineSplit(state, action.sourceTimeline, action.splitTimeline);
  case TIMELINE_SPLIT_DESTROY:
    return destroyTimelineSplit(state, action);
  case TIMELINE_SPLIT_SAVE_RETURN_ANCHOR:
    return state.update(action.timeline, initialTimeline, map => map.set('splitReturnAnchor', ImmutableMap(action.anchor)));
  case TIMELINE_SPLIT_CLEAR_RETURN_ANCHOR:
    return state.update(action.timeline, initialTimeline, map => map.delete('splitReturnAnchor'));
  case TIMELINE_SCROLL_TOP:
    return isStaleSplitTimeline(state, action.timeline) ? state : updateTop(state, action.timeline, action.top);
  case TIMELINE_CONNECT:
    return isStaleSplitTimeline(state, action.timeline) ? state : state.update(action.timeline, initialTimeline, map => map.set('online', true));
  case TIMELINE_DISCONNECT:
    return isStaleSplitTimeline(state, action.timeline) ? state : state.update(
      action.timeline,
      initialTimeline,
      map => map.set('online', false).update(action.usePendingItems ? 'pendingItems' : 'items', items => items.first() ? items.unshift(null) : items),
    );
  case TIMELINE_MARK_AS_PARTIAL:
    return isStaleSplitTimeline(state, action.timeline) ? state : state.update(
      action.timeline,
      initialTimeline,
      map => map.set('isPartial', true).set('items', ImmutableList()).set('pendingItems', ImmutableList()).set('unread', 0).delete('splitReturnAnchor'),
    );
  default:
    return state;
  }
};
