import { fromJS } from 'immutable';
import immediateFeed from '../immediate_feed';
import {
  IMMEDIATE_FEED_EXPIRE,
  IMMEDIATE_FEED_INSERT,
  IMMEDIATE_FEED_REGISTER_VIEW,
  IMMEDIATE_FEED_UNREGISTER_VIEW,
} from '../../actions/immediate_feed';
import {
  TIMELINE_CLEAR,
  TIMELINE_DELETE,
  TIMELINE_EXPAND_SUCCESS,
  TIMELINE_EXPIRE,
  TIMELINE_UPDATE,
} from '../../actions/timelines';
import { buildHashtagImmediateView, buildGroupImmediateView } from '../../immediate_feed/eligibility';
import { groupPostingContext } from '../../posting_context/fixtures/group_context_fixture';

const hashtagView = buildHashtagImmediateView({
  viewKey: 'portable:hashtag-column:news',
  timelineId: 'hashtag:News',
  primary: 'News',
  tags: { all: [{ value: 'fedibird' }] },
});

const otherHashtagView = buildHashtagImmediateView({
  viewKey: 'portable:hashtag-column:other',
  timelineId: 'hashtag:News',
  primary: 'News',
  tags: {},
});

const groupView = buildGroupImmediateView({
  viewKey: 'portable:group-route:123',
  timelineId: 'group:123',
  groupId: '123',
  postingContext: groupPostingContext,
});

const register = (state, view) => immediateFeed(state, { type: IMMEDIATE_FEED_REGISTER_VIEW, view });

const insert = (state, view, statusId, phase = 'immediate', generation = 1) => immediateFeed(state, {
  type: IMMEDIATE_FEED_INSERT,
  viewKey: view.viewKey,
  timelineId: view.timelineId,
  statusId,
  phase,
  generation,
  requestId: 'req-1',
});

const entry = (state, viewKey, statusId) => state.getIn(['entries', `${viewKey}\u0000${statusId}`]);

const posted = (overrides = {}) => ({
  id: '50',
  visibility: 'public',
  tags: [{ name: 'news' }, { name: 'fedibird' }],
  mentions: [{ id: '123' }],
  media_attachments: [],
  account: { id: '1' },
  ...overrides,
});

describe('immediate feed reducer', () => {
  it('keeps an immediate entry per view and does not treat another timeline as confirmation', () => {
    let state = register(undefined, hashtagView);
    state = register(state, groupView);
    state = insert(state, hashtagView, '50');
    state = insert(state, groupView, '50', 'immediate', 2);

    state = immediateFeed(state, {
      type: TIMELINE_UPDATE,
      timeline: 'home',
      status: posted(),
    });

    expect(entry(state, hashtagView.viewKey, '50').get('phase')).toBe('immediate');
    expect(entry(state, groupView.viewKey, '50').get('phase')).toBe('immediate');

    state = immediateFeed(state, {
      type: TIMELINE_UPDATE,
      timeline: 'hashtag:News',
      status: posted(),
    });

    expect(entry(state, hashtagView.viewKey, '50').get('phase')).toBe('confirmed');
    expect(entry(state, groupView.viewKey, '50').get('phase')).toBe('immediate');
  });

  it('confirms a hashtag view only when the received status matches that column', () => {
    let state = register(undefined, hashtagView);
    state = register(state, otherHashtagView);
    state = insert(state, hashtagView, '50');
    state = insert(state, otherHashtagView, '51', 'immediate', 2);

    state = immediateFeed(state, {
      type: TIMELINE_UPDATE,
      timeline: 'hashtag:News',
      status: posted({ id: '51', tags: [{ name: 'news' }] }),
    });

    expect(entry(state, hashtagView.viewKey, '50').get('phase')).toBe('immediate');
    expect(entry(state, otherHashtagView.viewKey, '51').get('phase')).toBe('confirmed');
  });

  it('confirms from a timeline refresh even when the id was already listed', () => {
    let state = register(undefined, hashtagView);
    state = insert(state, hashtagView, '50');

    state = immediateFeed(state, {
      type: TIMELINE_EXPAND_SUCCESS,
      timeline: 'hashtag:News',
      statuses: [posted()],
    });

    expect(entry(state, hashtagView.viewKey, '50').get('phase')).toBe('confirmed');
  });

  it('does not downgrade a confirmed entry when a later POST echo arrives', () => {
    let state = register(undefined, hashtagView);
    state = insert(state, hashtagView, '50', 'confirmed', 1);
    state = insert(state, hashtagView, '50', 'immediate', 2);

    expect(entry(state, hashtagView.viewKey, '50').get('phase')).toBe('confirmed');
    expect(entry(state, hashtagView.viewKey, '50').get('generation')).toBe(1);
  });

  it('expires only the matching generation and leaves the status id in place', () => {
    let state = register(undefined, hashtagView);
    state = insert(state, hashtagView, '50', 'immediate', 4);

    state = immediateFeed(state, {
      type: IMMEDIATE_FEED_EXPIRE,
      viewKey: hashtagView.viewKey,
      statusId: '50',
      generation: 3,
    });
    expect(entry(state, hashtagView.viewKey, '50').get('phase')).toBe('immediate');

    state = immediateFeed(state, {
      type: IMMEDIATE_FEED_EXPIRE,
      viewKey: hashtagView.viewKey,
      statusId: '50',
      generation: 4,
    });
    expect(entry(state, hashtagView.viewKey, '50').get('phase')).toBe('expired');

    state = immediateFeed(state, {
      type: IMMEDIATE_FEED_EXPIRE,
      viewKey: hashtagView.viewKey,
      statusId: '50',
      generation: 4,
    });
    expect(entry(state, hashtagView.viewKey, '50').get('phase')).toBe('expired');
  });

  it('drops entries on delete, expire, clear, unregister, and a filter change', () => {
    let state = register(undefined, hashtagView);
    state = insert(state, hashtagView, '50');
    state = insert(state, hashtagView, '51', 'immediate', 2);

    state = immediateFeed(state, { type: TIMELINE_DELETE, id: '50', references: [] });
    expect(entry(state, hashtagView.viewKey, '50')).toBeUndefined();
    expect(entry(state, hashtagView.viewKey, '51')).toBeTruthy();

    state = immediateFeed(state, { type: TIMELINE_EXPIRE, id: '51', references: ['52'] });
    expect(entry(state, hashtagView.viewKey, '51')).toBeUndefined();

    state = insert(state, hashtagView, '53', 'immediate', 3);
    state = immediateFeed(state, { type: TIMELINE_CLEAR, timeline: 'hashtag:News' });
    expect(state.get('entries').isEmpty()).toBe(true);
    expect(state.getIn(['views', hashtagView.viewKey])).toBeTruthy();

    state = insert(state, hashtagView, '54', 'immediate', 4);
    state = immediateFeed(state, { type: IMMEDIATE_FEED_UNREGISTER_VIEW, viewKey: hashtagView.viewKey });
    expect(state.get('entries').isEmpty()).toBe(true);
    expect(state.get('views').isEmpty()).toBe(true);

    state = register(state, hashtagView);
    state = insert(state, hashtagView, '55', 'immediate', 5);
    state = register(state, { ...hashtagView, filterSignature: `${hashtagView.filterSignature}|changed` });
    expect(entry(state, hashtagView.viewKey, '55')).toBeUndefined();
  });

  it('confirms an immutable expand payload', () => {
    let state = register(undefined, groupView);
    state = insert(state, groupView, '50');

    state = immediateFeed(state, {
      type: TIMELINE_EXPAND_SUCCESS,
      timeline: 'group:123',
      statuses: fromJS([posted({ visibility: 'unlisted' })]),
    });

    expect(entry(state, groupView.viewKey, '50').get('phase')).toBe('confirmed');
  });
});
