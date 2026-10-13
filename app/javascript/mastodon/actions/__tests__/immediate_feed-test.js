import { fromJS } from 'immutable';
import { captureImmediateFeedSnapshot, IMMEDIATE_FEED_INSERT, IMMEDIATE_FEED_TTL_MS, publishImmediateStatus, registerImmediateFeedView } from '../immediate_feed';
import immediateFeed from '../../reducers/immediate_feed';
import { buildGroupImmediateView, buildHashtagImmediateView } from '../../immediate_feed/eligibility';
import { groupPostingContext } from '../../posting_context/fixtures/group_context_fixture';

jest.mock('../importer', () => ({
  importFetchedStatus: jest.fn((status, options) => ({ type: 'STATUS_IMPORT', status, options })),
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
    const snapshot = captureImmediateFeedSnapshot(stateWith([hashtagView]), hashtagView.viewKey, composer());
    const actions = run(publishImmediateStatus(snapshot, posted()), stateWith([hashtagView]));

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

    const generation = actions.find(action => action.type === IMMEDIATE_FEED_INSERT).generation;
    const inserted = actions.find(action => action.type === IMMEDIATE_FEED_INSERT);
    let immediate = immediateFeed(stateWith([hashtagView]).get('immediate_feed'), inserted);

    jest.advanceTimersByTime(IMMEDIATE_FEED_TTL_MS - 1);
    expect(immediate.getIn(['entries', `${hashtagView.viewKey}\u000077`, 'phase'])).toBe('immediate');
    expect(actions.find(action => action.type === 'IMMEDIATE_FEED_EXPIRE')).toBeUndefined();

    jest.advanceTimersByTime(1);

    const expire = actions.find(action => action.type === 'IMMEDIATE_FEED_EXPIRE');

    expect(expire).toMatchObject({
      viewKey: hashtagView.viewKey,
      statusId: '77',
      generation,
    });
    immediate = immediateFeed(immediate, expire);
    expect(immediate.getIn(['entries', `${hashtagView.viewKey}\u000077`, 'phase'])).toBe('expired');
    immediate = immediateFeed(immediate, { ...expire, generation: generation - 1 });
    expect(immediate.getIn(['entries', `${hashtagView.viewKey}\u000077`, 'phase'])).toBe('expired');
  });

  it('confirms immediately when streaming already listed the same id', () => {
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
    const inserted = actions.find(action => action.type === IMMEDIATE_FEED_INSERT);

    expect(inserted.phase).toBe('confirmed');
    jest.advanceTimersByTime(IMMEDIATE_FEED_TTL_MS);
    expect(actions.find(action => action.type === 'IMMEDIATE_FEED_EXPIRE')).toBeUndefined();
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

    expect(actions.find(action => action.type === IMMEDIATE_FEED_INSERT).phase).toBe('confirmed');
    jest.useRealTimers();
  });
});
