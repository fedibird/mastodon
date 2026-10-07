import { Map as ImmutableMap } from 'immutable';
import { applyMiddleware, createStore } from 'redux';
import thunk from 'redux-thunk';

import {
  domainTimelineId,
  groupTimelineId,
  hashtagSplitContextKey,
  hashtagTimelineId,
  personalTimelineId,
  publicTimelineId,
} from '../timeline_ids';

const mockGet = jest.fn(() => Promise.resolve({ data: [{ id: '50' }], status: 200 }));

jest.mock('mastodon/api', () => ({
  __esModule: true,
  default: jest.fn(() => ({ get: mockGet })),
  getLinks: () => ({ refs: [] }),
}));

jest.mock('../importer', () => ({
  importFetchedStatus: () => ({ type: 'IMPORT_STATUS' }),
  importFetchedStatuses: () => ({ type: 'IMPORT_STATUSES' }),
  importFetchedAccounts: () => ({ type: 'IMPORT_ACCOUNTS' }),
}));

jest.mock('../accounts', () => ({
  fetchRelationshipsSuccess: () => ({ type: 'REL_SUCCESS' }),
  fetchRelationshipsFromStatus: () => ({ type: 'REL_STATUS' }),
  fetchRelationshipsFromStatuses: () => ({ type: 'REL_STATUSES' }),
}));

jest.mock('../markers', () => ({
  submitMarkers: () => ({ type: 'MARKERS' }),
}));

import {
  expandDomainTimeline,
  expandGroupTimeline,
  expandHashtagTimeline,
  expandLimitedTimeline,
  expandPersonalTimeline,
  expandPublicTimeline,
  TIMELINE_EXPAND_REQUEST,
  TIMELINE_EXPAND_SUCCESS,
} from '../timelines';

const buildStore = (splits = {}) => {
  const actions = [];
  const timelines = ImmutableMap(Object.keys(splits).reduce((map, source) => {
    map[source] = ImmutableMap({ splitTimelineId: splits[source] });
    return map;
  }, {}));
  const reducer = (state = ImmutableMap({ timelines }), action) => {
    actions.push(action);

    if (action.type === TIMELINE_EXPAND_REQUEST) {
      return state.setIn(['timelines', action.timeline, 'isLoading'], true);
    }

    return state;
  };
  const store = createStore(reducer, ImmutableMap({ timelines }), applyMiddleware(thunk));

  store.recorded = actions;
  return store;
};

const ofType = (store, type) => store.recorded.filter(action => action.type === type);

describe('timeline canonical ids', () => {
  it('matches the stream and API keys', () => {
    expect(publicTimelineId()).toBe('public:bot');
    expect(publicTimelineId({ onlyRemote: true })).toBe('public:remote:bot');
    expect(publicTimelineId({ withoutBot: true, onlyMedia: true })).toBe('public:nobot:media');
    expect(publicTimelineId({ onlyRemote: true, withoutMedia: true })).toBe('public:remote:bot:nomedia');
    expect(domainTimelineId('example.com', {})).toBe('domain:bot:example.com');
    expect(domainTimelineId('example.com', { withoutBot: true, onlyMedia: true })).toBe('domain:nobot:media:example.com');
    expect(groupTimelineId('7', {})).toBe('group:7');
    expect(groupTimelineId('7', { onlyMedia: true, tagged: 'news' })).toBe('group:7:media:news');
    expect(groupTimelineId('7', { withoutMedia: true })).toBe('group:7:nomedia');
    expect(hashtagTimelineId('ruby')).toBe('hashtag:ruby');
    expect(personalTimelineId()).toBe('personal');
    expect(personalTimelineId({ onlyMedia: true })).toBe('personal:media');
    expect(personalTimelineId({ withoutMedia: true })).toBe('personal:nomedia');
    expect(hashtagSplitContextKey('ruby', {
      any: [{ value: 'a' }, { value: 'b' }],
      all: [{ value: 'c' }],
      none: [{ value: 'd' }],
    })).toBe('ruby|any:a,b|all:c|none:d');
  });
});

describe('expand timeline targets', () => {
  beforeEach(() => {
    mockGet.mockClear();
  });

  it.each([
    [
      'public',
      'public:remote:bot:split:col:uuid',
      { 'public:remote:bot': 'public:remote:bot:split:col:uuid' },
      () => expandPublicTimeline({ maxId: '9', onlyRemote: true, timelineId: 'public:remote:bot:split:col:uuid' }),
      '/api/v1/timelines/public',
      { remote: true, max_id: '9', only_media: false, without_media: false, without_bot: false },
    ],
    [
      'public canonical',
      'public:remote:bot',
      {},
      () => expandPublicTimeline({ maxId: '9', onlyRemote: true }),
      '/api/v1/timelines/public',
      { remote: true, max_id: '9' },
    ],
    [
      'domain',
      'domain:bot:example.com:split:col:uuid',
      { 'domain:bot:example.com': 'domain:bot:example.com:split:col:uuid' },
      () => expandDomainTimeline('example.com', { maxId: '9', timelineId: 'domain:bot:example.com:split:col:uuid' }),
      '/api/v1/timelines/public',
      { local: false, domain: 'example.com', max_id: '9', only_media: false, without_bot: false },
    ],
    [
      'domain canonical',
      'domain:bot:example.com',
      {},
      () => expandDomainTimeline('example.com', { maxId: '9' }),
      '/api/v1/timelines/public',
      { domain: 'example.com', max_id: '9' },
    ],
    [
      'group',
      'group:7:split:col:uuid',
      { 'group:7': 'group:7:split:col:uuid' },
      () => expandGroupTimeline('7', { maxId: '9', tagged: 'news', timelineId: 'group:7:split:col:uuid' }),
      '/api/v1/timelines/group/7',
      { max_id: '9', tagged: 'news', only_media: false, without_media: false },
    ],
    [
      'group canonical',
      'group:7:news',
      {},
      () => expandGroupTimeline('7', { maxId: '9', tagged: 'news' }),
      '/api/v1/timelines/group/7',
      { max_id: '9', tagged: 'news' },
    ],
    [
      'hashtag',
      'hashtag:ruby:split:col:uuid',
      { 'hashtag:ruby': 'hashtag:ruby:split:col:uuid' },
      () => expandHashtagTimeline('ruby', {
        maxId: '9',
        tags: { any: [{ value: 'a' }], all: [{ value: 'c' }], none: [{ value: 'd' }] },
        timelineId: 'hashtag:ruby:split:col:uuid',
      }),
      '/api/v1/timelines/tag/ruby',
      { max_id: '9', any: ['a'], all: ['c'], none: ['d'] },
    ],
    [
      'hashtag canonical',
      'hashtag:ruby',
      {},
      () => expandHashtagTimeline('ruby', { maxId: '9' }),
      '/api/v1/timelines/tag/ruby',
      { max_id: '9' },
    ],
    [
      'limited',
      'limited:split:col:uuid',
      { limited: 'limited:split:col:uuid' },
      () => expandLimitedTimeline({ maxId: '9', visibilities: ['limited'], timelineId: 'limited:split:col:uuid' }),
      '/api/v1/timelines/home',
      { max_id: '9', visibilities: ['limited'] },
    ],
    [
      'limited canonical',
      'limited',
      {},
      () => expandLimitedTimeline({ maxId: '9', visibilities: ['limited'] }),
      '/api/v1/timelines/home',
      { max_id: '9', visibilities: ['limited'] },
    ],
    [
      'personal',
      'personal:media:split:col:uuid',
      { 'personal:media': 'personal:media:split:col:uuid' },
      () => expandPersonalTimeline({ maxId: '9', onlyMedia: true, timelineId: 'personal:media:split:col:uuid' }),
      '/api/v1/timelines/personal',
      { max_id: '9', only_media: true, without_media: false },
    ],
    [
      'personal canonical',
      'personal:nomedia',
      {},
      () => expandPersonalTimeline({ maxId: '9', withoutMedia: true }),
      '/api/v1/timelines/personal',
      { max_id: '9', only_media: false, without_media: true },
    ],
  ])('writes %s history onto the requested timeline', async (_label, timelineId, splits, action, path, params) => {
    const store = buildStore(splits);

    await store.dispatch(action());

    const request = ofType(store, TIMELINE_EXPAND_REQUEST);
    const success = ofType(store, TIMELINE_EXPAND_SUCCESS);

    expect(request.map(item => item.timeline)).toEqual([timelineId]);
    expect(success.map(item => item.timeline)).toEqual([timelineId]);
    expect(mockGet).toHaveBeenLastCalledWith(path, expect.objectContaining({
      params: expect.objectContaining(params),
    }));
  });
});
