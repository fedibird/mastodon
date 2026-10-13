import { List as ImmutableList, Map as ImmutableMap } from 'immutable';
import { createSelector } from 'reselect';
import compareId from '../compare_id';
import { new_features_policy } from '../initial_state';

const EMPTY_LIST = ImmutableList();

export const EMPTY_IMMEDIATE_PRESENTATION = ImmutableMap({
  prependIds: EMPTY_LIST,
  fadeIds: EMPTY_LIST,
});

export function immediateFeedUsesFade (policy = new_features_policy) {
  return policy === 'tester';
}

const presentIds = (timeline) => {
  const present = new Set();

  if (!timeline || !timeline.get) {
    return present;
  }

  const mark = (id) => {
    if (id !== null && id !== undefined) {
      present.add(String(id));
    }
  };

  timeline.get('items', EMPTY_LIST).forEach(mark);
  timeline.get('pendingItems', EMPTY_LIST).forEach(mark);

  return present;
};

export function immediateFeedPresentationFrom (immediate, timeline, { viewKey, timelineId, dataTimelineId, includePendingItems }) {
  if (!viewKey || !immediate || !immediate.get) {
    return EMPTY_IMMEDIATE_PRESENTATION;
  }

  const dataId = dataTimelineId || timelineId;

  if (dataId !== timelineId && String(dataId).indexOf(':split:') !== -1) {
    return EMPTY_IMMEDIATE_PRESENTATION;
  }

  const atTop = !timeline || !timeline.get || timeline.get('top') !== false;

  if (!includePendingItems && !atTop) {
    return EMPTY_IMMEDIATE_PRESENTATION;
  }

  const entries = immediate.get('entries', ImmutableMap());

  if (!entries || entries.isEmpty()) {
    return EMPTY_IMMEDIATE_PRESENTATION;
  }

  const present = presentIds(timeline);
  const prepend = [];
  const fade = [];
  const fadeEnabled = immediateFeedUsesFade();

  entries.forEach(entry => {
    if (!entry || entry.get('viewKey') !== viewKey || entry.get('timelineId') !== timelineId) {
      return;
    }

    const phase = entry.get('phase');
    const statusId = entry.get('statusId');
    const listed = present.has(String(statusId));

    if (!statusId) {
      return;
    }

    if (phase === 'confirmed') {
      if (!listed) {
        prepend.push(statusId);
      }

      return;
    }

    if (phase !== 'immediate' && phase !== 'recheck') {
      return;
    }

    if (fadeEnabled) {
      fade.push(statusId);
    }

    if (!listed) {
      prepend.push(statusId);
    }
  });

  if (prepend.length === 0 && fade.length === 0) {
    return EMPTY_IMMEDIATE_PRESENTATION;
  }

  prepend.sort((left, right) => compareId(String(right), String(left)));

  return ImmutableMap({
    prependIds: ImmutableList(prepend),
    fadeIds: ImmutableList(fade),
  });
}

export const makeGetImmediatePresentation = () => createSelector(
  [
    state => state.get('immediate_feed'),
    (state, { timelineId, dataTimelineId }) => state.getIn(['timelines', dataTimelineId || timelineId]),
    (state, { immediateViewKey }) => immediateViewKey || null,
    (state, { timelineId }) => timelineId,
    (state, { dataTimelineId, timelineId }) => dataTimelineId || timelineId,
    (state, { includePendingItems }) => includePendingItems === true,
  ],
  (immediate, timeline, viewKey, timelineId, dataTimelineId, includePendingItems) => immediateFeedPresentationFrom(immediate, timeline, {
    viewKey,
    timelineId,
    dataTimelineId,
    includePendingItems,
  }),
);
