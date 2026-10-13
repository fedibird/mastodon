import { Map as ImmutableMap } from 'immutable';
import {
  IMMEDIATE_FEED_REGISTER_VIEW,
  IMMEDIATE_FEED_UNREGISTER_VIEW,
  IMMEDIATE_FEED_INSERT,
  IMMEDIATE_FEED_EXPIRE,
  IMMEDIATE_FEED_RECHECK,
  IMMEDIATE_FEED_REMOVE,
  IMMEDIATE_FEED_CONFIRM,
  immediateFeedEntryKey,
  immediateFeedViewFromAction,
} from '../actions/immediate_feed';
import {
  TIMELINE_UPDATE,
  TIMELINE_DELETE,
  TIMELINE_EXPIRE,
  TIMELINE_CLEAR,
  TIMELINE_EXPAND_SUCCESS,
} from '../actions/timelines';
import { statusMatchesImmediateView } from '../immediate_feed/eligibility';

const initialState = ImmutableMap({
  views: ImmutableMap(),
  entries: ImmutableMap(),
});

const dropViewEntries = (state, viewKey) => state.update('entries', ImmutableMap(), entries => (
  entries.filter(entry => entry.get('viewKey') !== viewKey)
));

const registerView = (state, action) => {
  const view = immediateFeedViewFromAction(action);

  if (!view || !view.get('viewKey') || !view.get('timelineId') || !view.get('filterSignature')) {
    return state;
  }

  const viewKey = view.get('viewKey');
  const previous = state.getIn(['views', viewKey]);
  let next = state.setIn(['views', viewKey], view);

  if (!previous || previous.get('filterSignature') !== view.get('filterSignature') || previous.get('timelineId') !== view.get('timelineId')) {
    next = dropViewEntries(next, viewKey);
  }

  return next;
};

const removeStatusIds = (state, ids) => {
  if (!ids || ids.size === 0) {
    return state;
  }

  return state.update('entries', ImmutableMap(), entries => (
    entries.filter(entry => !ids.has(String(entry.get('statusId'))))
  ));
};

const statusIdOf = (status) => {
  if (!status) {
    return null;
  }

  const id = typeof status.get === 'function' ? status.get('id') : status.id;

  return id === undefined || id === null ? null : String(id);
};

const confirmEntries = (state, timelineId, statuses) => {
  if (!timelineId || !statuses || statuses.length === 0) {
    return state;
  }

  const byId = new Map();

  statuses.forEach(status => {
    const id = statusIdOf(status);

    if (id) {
      byId.set(id, status);
    }
  });

  if (byId.size === 0) {
    return state;
  }

  return state.update('entries', ImmutableMap(), entries => entries.map(entry => {
    if (entry.get('timelineId') !== timelineId || entry.get('phase') === 'confirmed') {
      return entry;
    }

    const status = byId.get(statusIdOf(entry.get('statusId')) || String(entry.get('statusId')));
    const view = state.getIn(['views', entry.get('viewKey')]);

    if (!status || !view || view.get('timelineId') !== timelineId) {
      return entry;
    }

    if (!statusMatchesImmediateView(view, status)) {
      return entry;
    }

    return entry.set('phase', 'confirmed');
  }));
};

const insertEntry = (state, action) => {
  if (!action.viewKey || !action.timelineId || !action.statusId || action.generation === undefined) {
    return state;
  }

  const key = immediateFeedEntryKey(action.viewKey, action.statusId);
  const existing = state.getIn(['entries', key]);

  if (existing && existing.get('phase') === 'confirmed' && action.phase !== 'confirmed') {
    return state;
  }

  return state.setIn(['entries', key], ImmutableMap({
    statusId: String(action.statusId),
    viewKey: action.viewKey,
    timelineId: action.timelineId,
    phase: action.phase || 'immediate',
    generation: action.generation,
    registrationGeneration: action.registrationGeneration === undefined ? null : action.registrationGeneration,
    requestId: action.requestId || null,
  }));
};

const entryMatchesGeneration = (state, action) => {
  const entry = state.getIn(['entries', immediateFeedEntryKey(action.viewKey, action.statusId)]);

  if (!entry || entry.get('generation') !== action.generation) {
    return null;
  }

  return entry;
};

const expireEntry = (state, action) => {
  const entry = entryMatchesGeneration(state, action);

  if (!entry || entry.get('phase') !== 'immediate') {
    return state;
  }

  return state.setIn(['entries', immediateFeedEntryKey(action.viewKey, action.statusId), 'phase'], 'recheck');
};

const recheckEntry = (state, action) => {
  const entry = entryMatchesGeneration(state, action);

  if (!entry || (entry.get('phase') !== 'immediate' && entry.get('phase') !== 'recheck')) {
    return state;
  }

  return state.setIn(['entries', immediateFeedEntryKey(action.viewKey, action.statusId), 'phase'], 'recheck');
};

const confirmEntry = (state, action) => {
  const entry = entryMatchesGeneration(state, action);

  if (!entry || entry.get('phase') === 'confirmed') {
    return state;
  }

  return state.setIn(['entries', immediateFeedEntryKey(action.viewKey, action.statusId), 'phase'], 'confirmed');
};

const removeEntry = (state, action) => {
  const key = immediateFeedEntryKey(action.viewKey, action.statusId);
  const entry = state.getIn(['entries', key]);

  if (!entry || entry.get('generation') !== action.generation) {
    return state;
  }

  return state.deleteIn(['entries', key]);
};

const statusesFromExpand = (statuses) => {
  if (!statuses) {
    return [];
  }

  if (typeof statuses.toArray === 'function') {
    return statuses.toArray();
  }

  return statuses;
};

export default function immediateFeed (state = initialState, action) {
  switch (action.type) {
  case IMMEDIATE_FEED_REGISTER_VIEW:
    return registerView(state, action);
  case IMMEDIATE_FEED_UNREGISTER_VIEW:
    return dropViewEntries(state, action.viewKey).deleteIn(['views', action.viewKey]);
  case IMMEDIATE_FEED_INSERT:
    return insertEntry(state, action);
  case IMMEDIATE_FEED_EXPIRE:
    return expireEntry(state, action);
  case IMMEDIATE_FEED_RECHECK:
    return recheckEntry(state, action);
  case IMMEDIATE_FEED_CONFIRM:
    return confirmEntry(state, action);
  case IMMEDIATE_FEED_REMOVE:
    return removeEntry(state, action);
  case TIMELINE_UPDATE:
    return confirmEntries(state, action.timeline, action.status ? [action.status] : []);
  case TIMELINE_EXPAND_SUCCESS:
    return confirmEntries(state, action.timeline, statusesFromExpand(action.statuses));
  case TIMELINE_DELETE:
  case TIMELINE_EXPIRE:
    return removeStatusIds(state, new Set([action.id, ...(action.references || [])].filter(id => id !== undefined && id !== null).map(id => String(id))));
  case TIMELINE_CLEAR:
    return state.update('entries', ImmutableMap(), entries => (
      entries.filter(entry => entry.get('timelineId') !== action.timeline)
    ));
  default:
    return state;
  }
}
