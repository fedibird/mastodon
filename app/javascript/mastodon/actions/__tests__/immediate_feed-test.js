import { fromJS, Map as ImmutableMap } from 'immutable';
import api from '../../api';
import { captureImmediateFeedSnapshot, cancelImmediateFeedTimersForStatuses, IMMEDIATE_FEED_CONFIRM, IMMEDIATE_FEED_INSERT, IMMEDIATE_FEED_REMOVE, IMMEDIATE_FEED_TTL_MS, publishImmediateStatus, reconcileImmediateEntry, registerImmediateFeedView } from '../immediate_feed';
import { clearTimeline, deleteFromTimelines } from '../timelines';
import immediateFeed from '../../reducers/immediate_feed';
import { buildGroupImmediateView, buildHashtagImmediateView } from '../../immediate_feed/eligibility';
import { groupPostingContext } from '../../posting_context/fixtures/group_context_fixture';

jest.mock('../importer', () => ({
  importFetchedStatus: jest.fn((status, options) => ({ type: 'STATUS_IMPORT', status, options })),
}));

jest.mock('../../api', () => ({
  __esModule: true,
  default: jest.fn(),
}));

import { importFetchedStatus } from '../importer';

const hashtagView = buildHashtagImmediateView({
  viewKey: 'portable:hashtag-column:news',
  timelineId: 'hashtag:News',
  primary: 'News',
  tags: {},
});

const composer = (overrides = {}) => fromJS({
  id: null,
  text: 'Hello #News',
  idempotencyKey: 'idem-1',
  surfaceEpoch: 3,
  surface: { kind: 'hashtag', key: 'news' },
  context: { key: 'builtin:hashtag:news', source: { revision: 1 } },
  senderIdentity: { id: 'local:1' },
  ...overrides,
});

const stateWith = (views, extra = {}) => {
  let immediate = immediateFeed(undefined, { type: '@@INIT' });

  views.forEach(view => {
    immediate = immediateFeed(immediate, registerImmediateFeedView(view));
  });

  return fromJS({
    timelines: extra.timelines || {},
    relationships: extra.relationships || {},
  }).set('immediate_feed', immediate);
};

const run = (thunk, state) => {
  const actions = [];
  const dispatch = (action) => {
    if (typeof action === 'function') {
      return action(dispatch, () => state);
    }

    actions.push(action);
    return action;
  };

  thunk(dispatch, () => state);

  return actions;
};

const posted = (overrides = {}) => ({
  id: '77',
  visibility: 'public',
  scheduled_at: null,
  tags: [{ name: 'news' }],
  mentions: [],
  media_attachments: [],
  account: { id: '1', bot: false },
  ...overrides,
});

describe('captureImmediateFeedSnapshot', () => {
  const state = stateWith([hashtagView]);

  it('records the sending view instead of the composer fields that can change later', () => {
    const snapshot = captureImmediateFeedSnapshot(state, hashtagView.viewKey, composer());

    expect(snapshot).toMatchObject({
      composerId: hashtagView.viewKey,
      requestId: 'idem-1',
      surfaceEpoch: 3,
      surface: { kind: 'hashtag', key: 'news' },
      postingContextKey: 'builtin:hashtag:news',
      senderIdentityId: 'local:1',
      timelineId: 'hashtag:News',
      filterSignature: hashtagView.filterSignature,
      kind: 'hashtag',
    });
  });

  it('does not snapshot edits, schedules, lists, or a missing view', () => {
    expect(captureImmediateFeedSnapshot(state, hashtagView.viewKey, composer({ id: 'status-1' }))).toBeNull();
    expect(captureImmediateFeedSnapshot(state, hashtagView.viewKey, composer({
      surface: { kind: 'list', key: '4' },
    }))).toBeNull();
    expect(captureImmediateFeedSnapshot(state, 'portable:hashtag-column:missing', composer())).toBeNull();
  });
});

describe('publishImmediateStatus', () => {
  beforeEach(() => {
    jest.useFakeTimers();
    importFetchedStatus.mockClear();
  });

  afterEach(() => {
    jest.clearAllTimers();
    jest.useRealTimers();
  });

  it('imports the POST body without replacing an official copy and starts the expiry timer', () => {
    const state = stateWith([hashtagView]);
    const snapshot = captureImmediateFeedSnapshot(state, hashtagView.viewKey, composer());
    const actions = run(publishImmediateStatus(snapshot, posted()), state);

    expect(importFetchedStatus).toHaveBeenCalledWith(expect.objectContaining({ id: '77' }), { acceptPresentationChange: false });
    expect(actions).toEqual(expect.arrayContaining([
      expect.objectContaining({ type: 'STATUS_IMPORT' }),
      expect.objectContaining({
        type: IMMEDIATE_FEED_INSERT,
        viewKey: hashtagView.viewKey,
        timelineId: 'hashtag:News',
        statusId: '77',
        phase: 'immediate',
        requestId: 'idem-1',
      }),
    ]));

    const inserted = actions.find(action => action.type === IMMEDIATE_FEED_INSERT);
    const immediate = immediateFeed(state.get('immediate_feed'), inserted);

    jest.advanceTimersByTime(IMMEDIATE_FEED_TTL_MS - 1);
    expect(immediate.getIn(['entries', `${hashtagView.viewKey}\u000077`, 'phase'])).toBe('immediate');
    expect(api).not.toHaveBeenCalled();
  });

  it('does not open an overlay when streaming already listed the same id', () => {
    const base = stateWith([hashtagView], {
      timelines: {
        'hashtag:News': {
          items: ['77'],
          pendingItems: [],
        },
      },
    });
    const snapshot = captureImmediateFeedSnapshot(base, hashtagView.viewKey, composer());
    const actions = run(publishImmediateStatus(snapshot, posted()), base);

    expect(actions.find(action => action.type === IMMEDIATE_FEED_INSERT)).toBeUndefined();
    expect(importFetchedStatus).toHaveBeenCalledWith(expect.objectContaining({ id: '77' }), { acceptPresentationChange: false });
    jest.advanceTimersByTime(IMMEDIATE_FEED_TTL_MS);
    expect(api).not.toHaveBeenCalled();
  });

  it('does not insert when the column filters change while the request is in flight', () => {
    const original = stateWith([hashtagView]);
    const snapshot = captureImmediateFeedSnapshot(original, hashtagView.viewKey, composer());
    const changed = buildHashtagImmediateView({
      viewKey: hashtagView.viewKey,
      timelineId: hashtagView.timelineId,
      primary: 'News',
      tags: { none: [{ value: 'news' }] },
    });
    const actions = run(publishImmediateStatus(snapshot, posted()), stateWith([changed]));

    expect(actions).toEqual([]);
    expect(importFetchedStatus).not.toHaveBeenCalled();
  });

  it('does not insert an ineligible, scheduled, failed, or partial result', () => {
    const ready = stateWith([hashtagView]);
    const snapshot = captureImmediateFeedSnapshot(ready, hashtagView.viewKey, composer());

    expect(run(publishImmediateStatus(snapshot, posted({ visibility: 'unlisted' })), ready)).toEqual([]);
    expect(run(publishImmediateStatus(snapshot, posted({ scheduled_at: '2099-01-01T00:00:00Z' })), ready)).toEqual([]);
    expect(run(publishImmediateStatus(null, posted()), ready)).toEqual([]);

    const partial = ready.setIn(['timelines', 'hashtag:News', 'isPartial'], true);

    expect(run(publishImmediateStatus(snapshot, posted()), partial)).toEqual([]);
  });

  it('keeps a group post on the snapshotted local group when another group is current', () => {
    const groupView = buildGroupImmediateView({
      viewKey: 'portable:group-route:123',
      timelineId: 'group:123',
      groupId: '123',
      postingContext: groupPostingContext,
    });
    const other = buildGroupImmediateView({
      viewKey: 'portable:group-route:9',
      timelineId: 'group:9',
      groupId: '9',
      postingContext: groupPostingContext,
    });
    const base = stateWith([groupView, other]);
    const snapshot = captureImmediateFeedSnapshot(base, groupView.viewKey, composer({
      surface: { kind: 'group', key: '123' },
      context: { key: 'builtin:fedibird-group:123', source: { revision: 1 } },
      posting_context_account_id: '123',
      senderIdentity: { id: 'delegated:other' },
    }));
    const actions = run(publishImmediateStatus(snapshot, posted({
      visibility: 'unlisted',
      mentions: [{ id: '123' }],
    })), base);
    const inserted = actions.find(action => action.type === IMMEDIATE_FEED_INSERT);

    expect(snapshot.senderIdentityId).toBe('delegated:other');
    expect(snapshot.timelineId).toBe('group:123');
    expect(inserted).toMatchObject({
      viewKey: groupView.viewKey,
      timelineId: 'group:123',
      phase: 'immediate',
    });
    expect(actions.find(action => action.timelineId === 'group:9')).toBeUndefined();
  });

  it('skips a group post when the viewer was blocked at send time', () => {
    const groupView = buildGroupImmediateView({
      viewKey: 'portable:group-route:123',
      timelineId: 'group:123',
      groupId: '123',
      postingContext: groupPostingContext,
    });
    const blocked = stateWith([groupView], {
      relationships: { '123': { blocked_by: true } },
    });
    const snapshot = captureImmediateFeedSnapshot(blocked, groupView.viewKey, composer({
      surface: { kind: 'group', key: '123' },
    }));

    expect(snapshot.blockedByGroup).toBe(true);
    expect(run(publishImmediateStatus(snapshot, posted({ mentions: [{ id: '123' }] })), blocked)).toEqual([]);
  });
});

const applyDispatch = (initial) => {
  let state = initial;
  const actions = [];
  const dispatch = (action) => {
    if (typeof action === 'function') {
      return action(dispatch, () => state);
    }

    actions.push(action);

    if (action.type && String(action.type).indexOf('IMMEDIATE_FEED') === 0) {
      state = state.set('immediate_feed', immediateFeed(state.get('immediate_feed'), action));
    }

    return action;
  };

  return {
    dispatch,
    actions,
    getState: () => state,
  };
};

describe('view registration generation', () => {
  it('does not insert when the column returns to the original filters in a new session', () => {
    const original = stateWith([hashtagView]);
    const snapshot = captureImmediateFeedSnapshot(original, hashtagView.viewKey, composer());
    const narrowed = buildHashtagImmediateView({
      viewKey: hashtagView.viewKey,
      timelineId: hashtagView.timelineId,
      primary: 'News',
      tags: { all: [{ value: 'dev' }] },
    });
    const restored = buildHashtagImmediateView({
      viewKey: hashtagView.viewKey,
      timelineId: hashtagView.timelineId,
      primary: 'News',
      tags: {},
    });
    let immediate = original.get('immediate_feed');

    immediate = immediateFeed(immediate, registerImmediateFeedView(narrowed));
    immediate = immediateFeed(immediate, registerImmediateFeedView(restored));

    const actions = run(publishImmediateStatus(snapshot, posted()), original.set('immediate_feed', immediate));

    expect(restored.filterSignature).toBe(snapshot.filterSignature);
    expect(immediate.getIn(['views', hashtagView.viewKey, 'registrationGeneration'])).not.toBe(snapshot.registrationGeneration);
    expect(actions).toEqual([]);
    expect(importFetchedStatus).not.toHaveBeenCalled();
  });
});

describe('timeline reconcile', () => {
  beforeEach(() => {
    jest.useFakeTimers();
  });

  afterEach(() => {
    jest.clearAllTimers();
    jest.useRealTimers();
  });

  const harnessForPosted = () => {
    const state = stateWith([hashtagView]);
    const snapshot = captureImmediateFeedSnapshot(state, hashtagView.viewKey, composer());
    const harness = applyDispatch(state);

    harness.dispatch(publishImmediateStatus(snapshot, posted()));
    importFetchedStatus.mockClear();
    api.mockReset();

    const inserted = harness.actions.find(action => action.type === IMMEDIATE_FEED_INSERT);

    return { harness, inserted };
  };

  it('does not treat the latest page alone as exclusion, then confirms from a later page', async () => {
    const { harness, inserted } = harnessForPosted();
    const newestPage = Array.from({ length: 20 }, (_, index) => ({ id: String(5000 - index), content: '<p>other</p>' }));
    const get = jest.fn()
      .mockResolvedValueOnce({ data: newestPage })
      .mockResolvedValueOnce({ data: [{ id: '50', content: '<p>older</p>' }, { id: '77', content: '<p>official</p>', card: { url: 'https://example.test/post' }, media_attachments: [{ id: 'm', url: 'https://cdn.test/a.jpg' }] }] });

    api.mockImplementation(() => ({ get }));

    await harness.dispatch(reconcileImmediateEntry(hashtagView.viewKey, '77', inserted.generation));

    expect(get).toHaveBeenCalledTimes(2);
    expect(String(get.mock.calls[0][0])).toContain('/api/v1/timelines/tag/');
    expect(get.mock.calls[1][1].params.max_id).toBe('4981');
    expect(get.mock.calls.some(call => String(call[0]).indexOf('/api/v1/statuses/') === 0)).toBe(false);
    expect(harness.actions.find(action => action.type === IMMEDIATE_FEED_CONFIRM)).toMatchObject({ statusId: '77' });
    expect(importFetchedStatus).toHaveBeenCalledWith(expect.objectContaining({
      id: '77',
      content: '<p>official</p>',
    }));
    expect(harness.getState().getIn(['immediate_feed', 'entries', `${hashtagView.viewKey}\u000077`, 'phase'])).toBe('confirmed');
  });

  it('removes the overlay when a covered page omits a filtered status', async () => {
    const { harness, inserted } = harnessForPosted();
    const get = jest.fn().mockResolvedValue({
      data: [
        { id: '90', language: 'en', content: '<p>kept</p>' },
        { id: '70', language: 'ja', content: '<p>kept too</p>' },
      ],
    });

    api.mockImplementation(() => ({ get }));

    await harness.dispatch(reconcileImmediateEntry(hashtagView.viewKey, '77', inserted.generation));

    expect(harness.actions.find(action => action.type === IMMEDIATE_FEED_REMOVE)).toMatchObject({ statusId: '77' });
    expect(harness.getState().getIn(['immediate_feed', 'entries', `${hashtagView.viewKey}\u000077`])).toBeUndefined();
    expect(importFetchedStatus).not.toHaveBeenCalled();
  });

  it('removes the overlay when a covered page omits a muted account', async () => {
    const { harness, inserted } = harnessForPosted();
    const get = jest.fn().mockResolvedValue({
      data: [
        { id: '90', account: { id: '2' }, content: '<p>visible</p>' },
        { id: '70', account: { id: '3' }, content: '<p>visible</p>' },
      ],
    });

    api.mockImplementation(() => ({ get }));

    await harness.dispatch(reconcileImmediateEntry(hashtagView.viewKey, '77', inserted.generation));

    expect(harness.actions.find(action => action.type === IMMEDIATE_FEED_REMOVE)).toBeTruthy();
    expect(String(get.mock.calls[0][0])).not.toContain('/api/v1/statuses/77');
  });

  it('keeps a group post that is still newer than the group feed and retries after a network failure', async () => {
    const groupView = buildGroupImmediateView({
      viewKey: 'portable:group-route:123',
      timelineId: 'group:123',
      groupId: '123',
      postingContext: groupPostingContext,
    });
    const state = stateWith([groupView]);
    const snapshot = captureImmediateFeedSnapshot(state, groupView.viewKey, composer({
      surface: { kind: 'group', key: '123' },
    }));
    const harness = applyDispatch(state);

    harness.dispatch(publishImmediateStatus(snapshot, posted({ mentions: [{ id: '123' }] })));
    const inserted = harness.actions.find(action => action.type === IMMEDIATE_FEED_INSERT);
    const get = jest.fn()
      .mockResolvedValueOnce({ data: [{ id: '40', content: '<p>older group post</p>' }] })
      .mockRejectedValueOnce(new Error('offline'));

    api.mockImplementation(() => ({ get }));

    await harness.dispatch(reconcileImmediateEntry(groupView.viewKey, '77', inserted.generation));

    expect(harness.actions.find(action => action.type === IMMEDIATE_FEED_REMOVE)).toBeUndefined();
    expect(harness.actions.find(action => action.type === IMMEDIATE_FEED_CONFIRM)).toBeUndefined();
    expect(harness.getState().getIn(['immediate_feed', 'entries', `${groupView.viewKey}\u000077`, 'phase'])).toBe('recheck');

    jest.advanceTimersByTime(60000);
    await Promise.resolve();
    await Promise.resolve();

    expect(harness.getState().getIn(['immediate_feed', 'entries', `${groupView.viewKey}\u000077`])).toBeTruthy();
    expect(harness.actions.find(action => action.type === IMMEDIATE_FEED_REMOVE)).toBeUndefined();
    expect(get).toHaveBeenCalledTimes(2);
  });

  it('stops retrying an empty feed and a permanent API error within five minutes', async () => {
    const empty = harnessForPosted();
    const get = jest.fn().mockResolvedValue({ data: [] });

    api.mockImplementation(() => ({ get }));

    const flush = async () => {
      for (let step = 0; step < 20; step += 1) {
        await Promise.resolve();
      }
    };

    jest.advanceTimersByTime(30000);
    await flush();
    jest.advanceTimersByTime(60000);
    await flush();
    jest.advanceTimersByTime(120000);
    await flush();
    jest.advanceTimersByTime(90000);
    await flush();

    expect(get).toHaveBeenCalledTimes(3);
    expect(empty.harness.getState().getIn(['immediate_feed', 'entries', `${hashtagView.viewKey}\u000077`])).toBeUndefined();
    expect(empty.harness.actions.find(action => action.type === 'COMPOSE_SUBMIT_FAIL')).toBeUndefined();

    const failing = harnessForPosted();
    const rejectGet = jest.fn().mockRejectedValue(new Error('offline'));

    api.mockImplementation(() => ({ get: rejectGet }));

    jest.advanceTimersByTime(30000);
    await flush();
    jest.advanceTimersByTime(60000);
    await flush();
    jest.advanceTimersByTime(120000);
    await flush();
    jest.advanceTimersByTime(90000);
    await flush();

    expect(rejectGet).toHaveBeenCalledTimes(3);
    expect(failing.harness.getState().getIn(['immediate_feed', 'entries', `${hashtagView.viewKey}\u000077`])).toBeUndefined();
    expect(failing.harness.actions.find(action => action.type === 'COMPOSE_SUBMIT_FAIL')).toBeUndefined();
  });

  it('drops a reconcile-confirmed overlay after its short lifetime', async () => {
    const { harness, inserted } = harnessForPosted();
    const get = jest.fn().mockResolvedValue({
      data: [{ id: '77', content: '<p>official</p>' }],
    });

    api.mockImplementation(() => ({ get }));
    await harness.dispatch(reconcileImmediateEntry(hashtagView.viewKey, '77', inserted.generation));

    expect(harness.getState().getIn(['immediate_feed', 'entries', `${hashtagView.viewKey}\u000077`, 'phase'])).toBe('confirmed');

    jest.advanceTimersByTime(30000);
    expect(harness.getState().getIn(['immediate_feed', 'entries', `${hashtagView.viewKey}\u000077`])).toBeUndefined();
    expect(harness.actions.find(action => action.type === 'TIMELINE_DELETE')).toBeUndefined();
  });

  it('ignores a late response after the column filters change or the generation is replaced', async () => {
    const { harness, inserted } = harnessForPosted();
    let resolvePage;
    const get = jest.fn().mockReturnValue(new Promise(resolve => {
      resolvePage = resolve;
    }));

    api.mockImplementation(() => ({ get }));
    const pending = harness.dispatch(reconcileImmediateEntry(hashtagView.viewKey, '77', inserted.generation));
    const narrowed = buildHashtagImmediateView({
      viewKey: hashtagView.viewKey,
      timelineId: hashtagView.timelineId,
      primary: 'News',
      tags: { all: [{ value: 'dev' }] },
    });

    harness.dispatch(registerImmediateFeedView(narrowed));
    resolvePage({ data: [{ id: '77', content: '<p>late</p>' }] });
    await pending;

    expect(harness.actions.find(action => action.type === IMMEDIATE_FEED_CONFIRM)).toBeUndefined();
    expect(harness.getState().getIn(['immediate_feed', 'entries', `${hashtagView.viewKey}\u000077`])).toBeUndefined();

    const replaced = harnessForPosted();
    let resolveReplaced;
    const replacedGet = jest.fn().mockReturnValue(new Promise(resolve => {
      resolveReplaced = resolve;
    }));

    api.mockImplementation(() => ({ get: replacedGet }));
    const late = replaced.harness.dispatch(reconcileImmediateEntry(hashtagView.viewKey, '77', replaced.inserted.generation));

    replaced.harness.dispatch({
      type: IMMEDIATE_FEED_REMOVE,
      viewKey: hashtagView.viewKey,
      statusId: '77',
      generation: replaced.inserted.generation,
    });
    replaced.harness.dispatch({
      type: IMMEDIATE_FEED_INSERT,
      viewKey: hashtagView.viewKey,
      timelineId: hashtagView.timelineId,
      statusId: '77',
      phase: 'immediate',
      generation: replaced.inserted.generation + 1,
      registrationGeneration: replaced.harness.getState().getIn(['immediate_feed', 'views', hashtagView.viewKey, 'registrationGeneration']),
    });
    resolveReplaced({ data: [{ id: '77', content: '<p>stale</p>' }] });
    await late;

    expect(replaced.harness.getState().getIn(['immediate_feed', 'entries', `${hashtagView.viewKey}\u000077`, 'generation'])).toBe(replaced.inserted.generation + 1);
    expect(replaced.harness.getState().getIn(['immediate_feed', 'entries', `${hashtagView.viewKey}\u000077`, 'phase'])).toBe('immediate');
  });
});

describe('immediate feed timers', () => {
  beforeEach(() => {
    jest.useFakeTimers();
  });

  afterEach(() => {
    jest.clearAllTimers();
    jest.useRealTimers();
  });

  it('drops timers when the status is deleted or the timeline is cleared', () => {
    const state = stateWith([hashtagView]).set('statuses', ImmutableMap());
    const snapshot = captureImmediateFeedSnapshot(state, hashtagView.viewKey, composer());
    const harness = applyDispatch(state);

    harness.dispatch(publishImmediateStatus(snapshot, posted()));
    api.mockReset();

    harness.dispatch(deleteFromTimelines('77'));
    jest.advanceTimersByTime(IMMEDIATE_FEED_TTL_MS);
    expect(api).not.toHaveBeenCalled();

    const again = stateWith([hashtagView]);
    const againSnapshot = captureImmediateFeedSnapshot(again, hashtagView.viewKey, composer());
    const second = applyDispatch(again);

    second.dispatch(publishImmediateStatus(againSnapshot, posted()));
    api.mockReset();
    second.dispatch(clearTimeline(hashtagView.timelineId));
    jest.advanceTimersByTime(IMMEDIATE_FEED_TTL_MS);
    expect(api).not.toHaveBeenCalled();
    cancelImmediateFeedTimersForStatuses(['77']);
  });
});

describe('pending items already count as receipt', () => {
  it('confirms a status that is waiting in pendingItems', () => {
    jest.useFakeTimers();
    const base = stateWith([hashtagView], {
      timelines: {
        'hashtag:News': {
          items: [],
          pendingItems: ['77'],
        },
      },
    });
    const snapshot = captureImmediateFeedSnapshot(base, hashtagView.viewKey, composer());
    const actions = run(publishImmediateStatus(snapshot, posted()), base);

    expect(actions.find(action => action.type === IMMEDIATE_FEED_INSERT)).toBeUndefined();
    jest.useRealTimers();
  });
});
