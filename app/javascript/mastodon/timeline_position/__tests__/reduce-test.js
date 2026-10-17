import { List as ImmutableList, Map as ImmutableMap } from 'immutable';

import { TIMELINE_SPLIT_CREATE } from '../../actions/timelines';
import timelines from '../../reducers/timelines';
import {
  WINDOW_SEEK_BEGIN,
  WINDOW_SEEK_COMMIT,
  WINDOW_SEEK_FAIL,
  WINDOW_SEEK_SCROLL,
} from '../../timeline_seek/constants';
import {
  HISTORY_RESUME_BEGIN,
  HISTORY_RESUME_CANCEL,
  HISTORY_RESUME_SETTLE,
} from '../constants';

const source = 'home';
const splitId = 'home:split:column-a:session-1';

const stateWithSplit = () => timelines(ImmutableMap({
  home: ImmutableMap({
    items: ImmutableList(['300', '200', '100']),
    pendingItems: ImmutableList(),
    hasMore: true,
  }),
}), {
  type: TIMELINE_SPLIT_CREATE,
  sourceTimeline: source,
  splitTimeline: splitId,
  anchorId: '200',
});

const begin = (state, requestId, mode) => timelines(state, {
  type: HISTORY_RESUME_BEGIN,
  timeline: splitId,
  requestId,
  mode,
  reason: mode === 'seek' ? 'outside_window' : 'in_window',
  anchorStatusId: '100',
  offsetPx: 4,
  alignment: 'top',
  routeEntryKey: 'entry-a',
  splitSessionId: splitId,
  sourceKey: 'home?',
});

describe('history resume reducer', () => {
  it('keeps seek resolved and scroll restored as different phases', () => {
    let state = begin(stateWithSplit(), 'resume-1', 'seek');
    const itemsBefore = state.getIn([splitId, 'items']);

    state = timelines(state, {
      type: WINDOW_SEEK_BEGIN,
      timeline: splitId,
      sourceTimeline: source,
      sessionId: 'seek-1',
      source: 'home?',
    });
    expect(state.getIn([splitId, 'historyResume', 'phase'])).toBe('seek_pending');

    state = timelines(state, {
      type: WINDOW_SEEK_FAIL,
      timeline: splitId,
      sessionId: 'seek-1',
      outcome: 'not_found',
      reason: 'not_found',
    });

    expect(state.getIn([splitId, 'historyResume', 'phase'])).toBe('failed');
    expect(state.getIn([splitId, 'historyResume', 'reason'])).toBe('not_found');
    expect(state.getIn([splitId, 'items'])).toEqual(itemsBefore);

    state = begin(stateWithSplit(), 'resume-2', 'seek');
    state = timelines(state, {
      type: WINDOW_SEEK_BEGIN,
      timeline: splitId,
      sessionId: 'seek-2',
      source: 'home?',
    });
    state = timelines(state, {
      type: WINDOW_SEEK_COMMIT,
      timeline: splitId,
      sessionId: 'seek-2',
      source: 'home?',
      anchorId: '100',
      newerIds: ['200'],
      olderIds: ['50'],
      limit: 40,
      capability: 'redis',
    });

    expect(state.getIn([splitId, 'historyResume', 'phase'])).toBe('scroll_pending');
    expect(state.getIn([splitId, 'historyResume', 'reason'])).toBe('seek_resolved');
    expect(state.getIn([splitId, 'seek', 'scrollStatus'])).toBe('pending');

    const ignored = timelines(state, {
      type: WINDOW_SEEK_SCROLL,
      timeline: splitId,
      sessionId: 'seek-old',
      revision: state.getIn([splitId, 'seek', 'scrollRevision']),
      scrolled: true,
      reason: 'loaded',
    });

    expect(ignored.getIn([splitId, 'historyResume', 'phase'])).toBe('scroll_pending');

    state = timelines(state, {
      type: WINDOW_SEEK_SCROLL,
      timeline: splitId,
      sessionId: 'seek-2',
      revision: state.getIn([splitId, 'seek', 'scrollRevision']),
      scrolled: true,
      reason: 'loaded',
    });

    expect(state.getIn([splitId, 'historyResume', 'phase'])).toBe('restored');
    expect(state.getIn([splitId, 'seek', 'scrollStatus'])).toBe('loaded');
  });

  it('ignores a settle or cancel from an older request', () => {
    let state = begin(stateWithSplit(), 'resume-1', 'scroll');

    state = begin(state, 'resume-2', 'scroll');
    state = timelines(state, {
      type: HISTORY_RESUME_SETTLE,
      timeline: splitId,
      requestId: 'resume-1',
      scrolled: true,
      reason: 'loaded',
    });
    expect(state.getIn([splitId, 'historyResume', 'requestId'])).toBe('resume-2');
    expect(state.getIn([splitId, 'historyResume', 'phase'])).toBe('restoring');

    state = timelines(state, {
      type: HISTORY_RESUME_CANCEL,
      timeline: splitId,
      requestId: 'resume-2',
      reason: 'user_scroll',
    });
    expect(state.getIn([splitId, 'historyResume', 'phase'])).toBe('cancelled');

    const again = timelines(state, {
      type: HISTORY_RESUME_CANCEL,
      timeline: splitId,
      requestId: 'resume-2',
      reason: 'unmount',
    });

    expect(again.getIn([splitId, 'historyResume', 'reason'])).toBe('user_scroll');
  });
});
