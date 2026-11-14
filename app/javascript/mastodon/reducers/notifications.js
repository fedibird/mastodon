import {
  NOTIFICATIONS_RELOAD_SUCCESS,
  NOTIFICATIONS_FEED_MERGE,
  NOTIFICATIONS_UPDATE,
  NOTIFICATIONS_EXPAND_SUCCESS,
  NOTIFICATIONS_EXPAND_REQUEST,
  NOTIFICATIONS_EXPAND_FAIL,
  NOTIFICATIONS_FILTER_SET,
  NOTIFICATIONS_CLEAR,
  NOTIFICATIONS_SCROLL_TOP,
  NOTIFICATIONS_LOAD_PENDING,
  NOTIFICATIONS_MOUNT,
  NOTIFICATIONS_UNMOUNT,
  NOTIFICATIONS_MARK_AS_READ,
  NOTIFICATIONS_SET_BROWSER_SUPPORT,
  NOTIFICATIONS_SET_BROWSER_PERMISSION,
} from '../actions/notifications';
import {
  ACCOUNT_BLOCK_SUCCESS,
  ACCOUNT_MUTE_SUCCESS,
  FOLLOW_REQUEST_AUTHORIZE_SUCCESS,
  FOLLOW_REQUEST_REJECT_SUCCESS,
} from '../actions/accounts';
import {
  MARKERS_FETCH_SUCCESS,
} from '../actions/markers';
import {
  APP_FOCUS,
  APP_UNFOCUS,
} from '../actions/app';
import { DOMAIN_BLOCK_SUCCESS } from 'mastodon/actions/domain_blocks';
import { TIMELINE_DELETE, TIMELINE_DISCONNECT } from '../actions/timelines';
import { Map as ImmutableMap, List as ImmutableList, fromJS } from 'immutable';
import compareId from '../compare_id';
import { EMOJI_MUTES_APPLY } from '../actions/emoji_mutes';
import { storedReactionHidden } from '../features/emoji/emoji_mute_projection';
import { currentEmojiMutes, emojiReactionEventsAccepted, invalidateEmojiMuteNotificationFetches } from '../features/emoji/emoji_mute_store';

const initialState = ImmutableMap({
  pendingItems: ImmutableList(),
  items: ImmutableList(),
  hasMore: true,
  top: false,
  mounted: 0,
  unread: 0,
  lastReadId: '0',
  readMarkerId: '0',
  isTabVisible: true,
  isLoading: false,
  browserSupport: false,
  browserPermission: 'default',
});

const notificationToMap = notification => ImmutableMap({
  id: notification.id,
  type: notification.type,
  account: notification.account.id,
  target_account: notification.target_account ? notification.target_account.id : null,
  created_at: notification.created_at,
  status: notification.status ? notification.status.id : null,
  report: notification.report ? fromJS(notification.report) : null,
  emoji_reaction: ImmutableMap(notification.emoji_reaction),
  reblogVisibility: notification.reblog_visibility,
});

const normalizeNotification = (state, notification, usePendingItems) => {
  const top = state.get('top');

  if (usePendingItems || !state.get('pendingItems').isEmpty()) {
    return state.update('pendingItems', list => list.unshift(notificationToMap(notification))).update('unread', unread => unread + 1);
  }

  if (shouldCountUnreadNotifications(state)) {
    state = state.update('unread', unread => unread + 1);
  } else {
    state = state.set('lastReadId', notification.id);
  }

  return state.update('items', list => {
    if (top && list.size > 40) {
      list = list.take(20);
    }

    return list.unshift(notificationToMap(notification));
  });
};

const expandNormalizedNotifications = (state, notifications, next, isLoadingRecent, usePendingItems) => {
  const lastReadId = state.get('lastReadId');
  let items = ImmutableList();

  notifications.forEach((n, i) => {
    items = items.set(i, notificationToMap(n));
  });

  return state.withMutations(mutable => {
    if (!items.isEmpty()) {
      usePendingItems = isLoadingRecent && (usePendingItems || !mutable.get('pendingItems').isEmpty());

      mutable.update(usePendingItems ? 'pendingItems' : 'items', list => {
        const lastIndex = 1 + list.findLastIndex(
          item => item !== null && (compareId(item.get('id'), items.last().get('id')) > 0 || item.get('id') === items.last().get('id')),
        );

        const firstIndex = 1 + list.take(lastIndex).findLastIndex(
          item => item !== null && compareId(item.get('id'), items.first().get('id')) > 0,
        );

        return list.take(firstIndex).concat(items, list.skip(lastIndex));
      });
    }

    if (!next) {
      mutable.set('hasMore', false);
    }

    if (shouldCountUnreadNotifications(state)) {
      mutable.set('unread', mutable.get('pendingItems').count(item => item !== null) + mutable.get('items').count(item => item && compareId(item.get('id'), lastReadId) > 0));
    } else {
      const mostRecent = items.find(item => item !== null);
      if (mostRecent && compareId(lastReadId, mostRecent.get('id')) < 0) {
        mutable.set('lastReadId', mostRecent.get('id'));
      }
    }

    mutable.set('isLoading', false);
  });
};

const emojiReactionHidden = (item, rules) => {
  if (!item || item.get('type') !== 'emoji_reaction') {
    return false;
  }

  // A newer mute document is still in flight. Hold every reaction notification
  // until that document is applied, instead of flashing the old one.
  if (!emojiReactionEventsAccepted()) {
    return true;
  }

  return storedReactionHidden(item.get('emoji_reaction'), rules);
};

const rememberWithheld = (state, item, bucket) => {
  const withheld = state.get('emojiMuteWithheld', ImmutableList());

  if (withheld.some(entry => entry.get('notification') && entry.get('notification').get('id') === item.get('id'))) {
    return state;
  }

  return state.set('emojiMuteWithheld', withheld.push(ImmutableMap({ bucket, notification: item })));
};

const withoutHiddenReactions = (notifications, rules) => {
  const visible = [];
  const hidden = [];

  (notifications || []).forEach(notification => {
    if (!notification || !notification.account) {
      return;
    }

    const mapped = notificationToMap(notification);

    if (emojiReactionHidden(mapped, rules)) {
      hidden.push(mapped);
    } else {
      visible.push(notification);
    }
  });

  return { visible, hidden };
};

const insertByNewestId = (list, item) => {
  const id = item.get('id');

  if (list.some(existing => existing && existing.get('id') === id)) {
    return list;
  }

  const index = list.findIndex(existing => existing && compareId(existing.get('id'), id) < 0);

  return index === -1 ? list.push(item) : list.insert(index, item);
};

// Hidden reactions leave the loaded pages but stay withheld, so removing the
// rule can put the same row back without asking for every older page again.
const reconcileEmojiReactionNotifications = (state, rules) => {
  const withheld = [];

  const keepBucket = bucket => {
    let kept = ImmutableList();

    state.get(bucket, ImmutableList()).forEach(item => {
      if (!item) {
        return;
      }

      if (emojiReactionHidden(item, rules)) {
        withheld.push(ImmutableMap({ bucket, notification: item }));
      } else {
        kept = kept.push(item);
      }
    });

    return kept;
  };

  const uniqueById = list => {
    const seen = new Set();

    return list.filter(item => {
      const id = item && item.get('id');

      if (seen.has(id)) {
        return false;
      }

      seen.add(id);
      return true;
    });
  };

  let items = uniqueById(keepBucket('items'));
  let pendingItems = uniqueById(keepBucket('pendingItems'));

  state.get('emojiMuteWithheld', ImmutableList()).forEach(entry => {
    const item = entry && entry.get('notification');
    const bucket = entry && entry.get('bucket');

    if (!item) {
      return;
    }

    if (emojiReactionHidden(item, rules)) {
      withheld.push(entry);
    } else if (bucket === 'pendingItems') {
      pendingItems = insertByNewestId(pendingItems, item);
    } else {
      items = insertByNewestId(items, item);
    }
  });

  return state
    .set('items', items)
    .set('pendingItems', pendingItems)
    .set('emojiMuteWithheld', ImmutableList(withheld));
};

const notificationMatches = (item, accountIds, type) => (
  item !== null
  && item !== undefined
  && accountIds.includes(item.get('account'))
  && (type === undefined || type === item.get('type'))
);

const forgetWithheld = (state, predicate) => state.update(
  'emojiMuteWithheld',
  ImmutableList(),
  list => list.filter(entry => !predicate(entry && entry.get('notification'))),
);

const filterNotifications = (state, accountIds, type) => {
  const helper = list => list.filterNot(item => notificationMatches(item, accountIds, type));

  return forgetWithheld(
    state.update('items', helper).update('pendingItems', helper),
    item => notificationMatches(item, accountIds, type),
  );
};

const clearUnread = (state) => {
  state = state.set('unread', state.get('pendingItems').size);
  const lastNotification = state.get('items').find(item => item !== null);
  return state.set('lastReadId', lastNotification ? lastNotification.get('id') : '0');
};

const updateTop = (state, top) => {
  state = state.set('top', top);

  if (!shouldCountUnreadNotifications(state)) {
    state = clearUnread(state);
  }

  return state;
};

const deleteByStatus = (state, statusId) => {
  const lastReadId = state.get('lastReadId');

  if (shouldCountUnreadNotifications(state)) {
    const deletedUnread = state.get('items').filter(item => item !== null && item.get('status') === statusId && compareId(item.get('id'), lastReadId) > 0);
    state = state.update('unread', unread => unread - deletedUnread.size);
  }

  const helper = list => list.filterNot(item => item !== null && item.get('status') === statusId);
  const deletedUnread = state.get('pendingItems').filter(item => item !== null && item.get('status') === statusId && compareId(item.get('id'), lastReadId) > 0);
  state = state.update('unread', unread => unread - deletedUnread.size);
  return forgetWithheld(
    state.update('items', helper).update('pendingItems', helper),
    item => item !== null && item !== undefined && item.get('status') === statusId,
  );
};

const updateMounted = (state) => {
  state = state.update('mounted', count => count + 1);
  if (!shouldCountUnreadNotifications(state, state.get('mounted') === 1)) {
    state = state.set('readMarkerId', state.get('lastReadId'));
    state = clearUnread(state);
  }
  return state;
};

const updateVisibility = (state, visibility) => {
  state = state.set('isTabVisible', visibility);
  if (!shouldCountUnreadNotifications(state)) {
    state = state.set('readMarkerId', state.get('lastReadId'));
    state = clearUnread(state);
  }
  return state;
};

const shouldCountUnreadNotifications = (state, ignoreScroll = false) => {
  const isTabVisible   = state.get('isTabVisible');
  const isOnTop        = state.get('top');
  const isMounted      = state.get('mounted') > 0;
  const lastReadId     = state.get('lastReadId');
  const lastItem       = state.get('items').findLast(item => item !== null);
  const lastItemReached = !state.get('hasMore') || lastReadId === '0' || (lastItem && compareId(lastItem.get('id'), lastReadId) <= 0);

  return !(isTabVisible && (ignoreScroll || isOnTop) && isMounted && lastItemReached);
};

const recountUnread = (state, last_read_id) => {
  // A late markers response must never move the effective read position
  // backwards when the user has already read newer notifications locally.
  const currentReadId = state.get('lastReadId');
  const effectiveReadId = compareId(last_read_id, currentReadId) > 0 ? last_read_id : currentReadId;

  return state.withMutations(mutable => {
    if (compareId(last_read_id, mutable.get('lastReadId')) > 0) {
      mutable.set('lastReadId', last_read_id);
    }

    if (compareId(last_read_id, mutable.get('readMarkerId')) > 0) {
      mutable.set('readMarkerId', last_read_id);
    }

    if (state.get('unread') > 0 || shouldCountUnreadNotifications(state)) {
      mutable.set('unread', mutable.get('pendingItems').count(item => item !== null) + mutable.get('items').count(item => item && compareId(item.get('id'), effectiveReadId) > 0));
    }
  });
};

export default function notifications(state = initialState, action) {
  switch(action.type) {
  case MARKERS_FETCH_SUCCESS:
    return action.markers.notifications ? recountUnread(state, action.markers.notifications.last_read_id) : state;
  case NOTIFICATIONS_MOUNT:
    return updateMounted(state);
  case NOTIFICATIONS_UNMOUNT:
    return state.update('mounted', count => count - 1);
  case APP_FOCUS:
    return updateVisibility(state, true);
  case APP_UNFOCUS:
    return updateVisibility(state, false);
  case NOTIFICATIONS_LOAD_PENDING:
    return state.update('items', list => state.get('pendingItems').concat(list.take(40))).set('pendingItems', ImmutableList()).set('unread', 0);
  case NOTIFICATIONS_EXPAND_REQUEST:
    return state.set('isLoading', true);
  case NOTIFICATIONS_EXPAND_FAIL:
    return state.set('isLoading', false);
  case NOTIFICATIONS_FILTER_SET:
    invalidateEmojiMuteNotificationFetches();
    return state.set('items', ImmutableList()).set('pendingItems', ImmutableList()).set('emojiMuteWithheld', ImmutableList()).set('hasMore', true);
  case NOTIFICATIONS_SCROLL_TOP:
    return updateTop(state, action.top);
  case EMOJI_MUTES_APPLY:
    return reconcileEmojiReactionNotifications(state, action.mutes || currentEmojiMutes());
  case NOTIFICATIONS_FEED_MERGE: {
    const hasMore = state.get('hasMore');
    const pendingItems = state.get('pendingItems');
    const rules = action.rules || currentEmojiMutes();
    const { visible, hidden } = withoutHiddenReactions(action.notifications, rules);
    let next = expandNormalizedNotifications(state, visible, 'keep', false, false);

    next = next.set('hasMore', hasMore).set('pendingItems', pendingItems);
    hidden.forEach(item => {
      next = rememberWithheld(next, item, 'items');
    });
    next = reconcileEmojiReactionNotifications(next, rules);
    // Browsing the notifications column at the top marks them as read.
    // A delayed count response must not reintroduce the badge.
    if (typeof action.unread === 'number' && shouldCountUnreadNotifications(next)) {
      next = next.set('unread', action.unread);
    }
    return next;
  }
  case NOTIFICATIONS_RELOAD_SUCCESS: {
    const items = ImmutableList((action.notifications || []).filter(item => item && item.account).map(notificationToMap));
    let next = state.set('items', items).set('pendingItems', ImmutableList()).set('isLoading', false);
    if (typeof action.unread === 'number') {
      next = next.set('unread', action.unread);
    }
    return next;
  }
  case NOTIFICATIONS_UPDATE: {
    const mapped = notificationToMap(action.notification);
    const rules = currentEmojiMutes();

    if (emojiReactionHidden(mapped, rules)) {
      const bucket = action.usePendingItems || !state.get('pendingItems', ImmutableList()).isEmpty() ? 'pendingItems' : 'items';
      return rememberWithheld(state, mapped, bucket);
    }

    return normalizeNotification(state, action.notification, action.usePendingItems);
  }
  case NOTIFICATIONS_EXPAND_SUCCESS: {
    const rules = currentEmojiMutes();
    const { visible, hidden } = withoutHiddenReactions(action.notifications, rules);
    let next = expandNormalizedNotifications(state, visible, action.next, action.isLoadingRecent, action.usePendingItems);

    hidden.forEach(item => {
      next = rememberWithheld(next, item, 'items');
    });
    return next;
  }
  case ACCOUNT_BLOCK_SUCCESS:
    invalidateEmojiMuteNotificationFetches();
    return filterNotifications(state, [action.relationship.id]);
  case ACCOUNT_MUTE_SUCCESS:
    if (action.relationship.muting_notifications) {
      invalidateEmojiMuteNotificationFetches();
    }
    return action.relationship.muting_notifications ? filterNotifications(state, [action.relationship.id]) : state;
  case DOMAIN_BLOCK_SUCCESS:
    invalidateEmojiMuteNotificationFetches();
    return filterNotifications(state, action.accounts);
  case FOLLOW_REQUEST_AUTHORIZE_SUCCESS:
  case FOLLOW_REQUEST_REJECT_SUCCESS:
    return filterNotifications(state, [action.id], 'follow_request');
  case NOTIFICATIONS_CLEAR:
    invalidateEmojiMuteNotificationFetches();
    return state.set('items', ImmutableList()).set('pendingItems', ImmutableList()).set('emojiMuteWithheld', ImmutableList()).set('hasMore', false);
  case TIMELINE_DELETE:
    return deleteByStatus(state, action.id);
  case TIMELINE_DISCONNECT:
    return action.timeline === 'home' ?
      state.update(action.usePendingItems ? 'pendingItems' : 'items', items => items.first() ? items.unshift(null) : items) :
      state;
  case NOTIFICATIONS_MARK_AS_READ:
    const lastNotification = state.get('items').find(item => item !== null);
    return lastNotification ? recountUnread(state, lastNotification.get('id')) : state;
  case NOTIFICATIONS_SET_BROWSER_SUPPORT:
    return state.set('browserSupport', action.value);
  case NOTIFICATIONS_SET_BROWSER_PERMISSION:
    return state.set('browserPermission', action.value);
  default:
    return state;
  }
};
