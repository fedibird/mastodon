const flags = { enableLimitedTimeline: true, hideDirectFromTimeline: false, hidePersonalFromTimeline: false };

jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

jest.mock('../../initial_state', () => ({
  get enableLimitedTimeline () {
    return flags.enableLimitedTimeline;
  },
  get hideDirectFromTimeline () {
    return flags.hideDirectFromTimeline;
  },
  get hidePersonalFromTimeline () {
    return flags.hidePersonalFromTimeline;
  },
  get isAdministrator () {
    return true;
  },
  get new_features_policy () {
    return 'tester';
  },
}));

jest.mock('../../stream', () => ({
  connectStream: (...args) => mockConnect(...args),
}));

jest.mock('../../api', () => ({
  __esModule: true,
  default: () => ({
    get: (...args) => mockGet(...args),
  }),
  getLinks: (response) => (response && response.links) || { refs: [] },
}));

jest.mock('../importer', () => ({
  importFetchedStatuses: (statuses) => ({ type: 'IMPORT_STATUSES', statuses }),
  importFetchedAccounts: (accounts) => ({ type: 'IMPORT_ACCOUNTS', accounts }),
  importFilters: (filters) => ({ type: 'FILTERS_IMPORT', filters }),
}));

const mockConnect = jest.fn();
const mockGet = jest.fn();

import { fromJS } from 'immutable';
import mixTimelines, { } from '../../reducers/mix_timelines';
import { MIX_SOURCE_SUCCESS, MIX_TIMELINE_OPEN } from '../mix_timelines';
import { closeMixStream, openMixStream, pinMixStream, reconcileMixSource, resetMixStreams, revealMixStream } from '../mix_streaming';
import { mixTimelineView } from '../../mix/view';
import { resolveStream } from '../../mix/stream_adapters';

const mix = fromJS({
  id: 'mix-1',
  version: 1,
  title: 'Desk',
  sources: [
    { type: 'public', params: {} },
    { type: 'list', id: '4', params: {} },
  ],
});

const harness = () => {
  let state = fromJS({
    settings: { mixes: [mix] },
    timelines: { home: { items: ['existing'] } },
    statuses: {},
    mix_timelines: {},
  });
  const dispatch = (action) => {
    if (typeof action === 'function') {
      return action(dispatch, () => state);
    }

    if (action.type && action.type.indexOf('MIX_') === 0) {
      state = state.set('mix_timelines', mixTimelines(state.get('mix_timelines'), action));
    }

    return action;
  };

  return {
    dispatch,
    getState: () => state,
    setStatuses (statuses) {
      state = state.set('statuses', statuses);
    },
  };
};

const openColumn = (dispatch, columnKey, sessionId, sources) => {
  const resolved = sources.map(source => resolveStream(source));

  dispatch({
    type: MIX_TIMELINE_OPEN,
    columnKey,
    mixId: 'mix-1',
    definitionFingerprint: resolved.map(source => source.key).join('\n'),
    sessionId,
    sources: resolved.map(source => ({ key: source.key, descriptor: source.source })),
  });
  return resolved;
};

describe('mix streaming', () => {
  const connections = [];

  beforeEach(() => {
    connections.length = 0;
    resetMixStreams();
    mockGet.mockReset();
    mockGet.mockResolvedValue({ status: 200, data: [], headers: {} });
    mockConnect.mockImplementation((channel, params, factory) => (dispatch, getState) => {
      const handlers = factory(dispatch, getState);
      const row = { channel, params, handlers, stopped: false };

      connections.push(row);
      return () => {
        row.stopped = true;
      };
    });
  });

  it('shares a channel across columns and drops a late event after close', () => {
    const { dispatch, getState } = harness();
    const sources = [
      { type: 'public', params: {} },
      { type: 'list', id: '4', params: {} },
    ];

    openColumn(dispatch, 'column:a', 1, sources);
    openColumn(dispatch, 'column:b', 2, sources);
    dispatch(openMixStream('column:a', mix));
    dispatch(openMixStream('column:b', mix));

    const publicStops = connections.filter(row => row.channel === 'public:bot');

    expect(publicStops).toHaveLength(2);
    connections.forEach(row => row.handlers.onConnect());
    dispatch(closeMixStream('column:a'));
    expect(publicStops[0].stopped).toBe(true);
    expect(publicStops[1].stopped).toBe(false);

    publicStops[0].handlers.onReceive({
      event: 'update',
      payload: JSON.stringify({ id: '900', account: { id: '2' }, visibility: 'public' }),
    });
    expect(getState().getIn(['mix_timelines', 'column:a'])).toBeTruthy();
    expect(getState().getIn(['mix_timelines', 'column:b', 'live']).valueSeq().flatMap(entry => entry.get('statusIds')).toArray()).not.toContain('900');

    dispatch({ type: 'MIX_TIMELINE_CLOSE', columnKey: 'column:a' });
    openColumn(dispatch, 'column:a', 3, sources);
    dispatch(openMixStream('column:a', mix));
    publicStops[0].handlers.onReceive({
      event: 'delete',
      payload: '900',
    });
    expect(getState().getIn(['mix_timelines', 'column:a', 'deletedStatusIds']).toArray()).toEqual([]);
    dispatch(closeMixStream('column:b'));
    expect(publicStops[1].stopped).toBe(true);
    expect(getState().getIn(['timelines', 'home', 'items']).toArray()).toEqual(['existing']);
  });

  it('keeps one card when two sources and a later REST page carry the same id', () => {
    const { dispatch, getState } = harness();
    const sources = [
      { type: 'public', params: {} },
      { type: 'list', id: '4', params: {} },
    ];
    const resolved = openColumn(dispatch, 'column:a', 1, sources);
    const history = getState().getIn(['mix_timelines', 'column:a', 'sources', resolved[0].key]);

    dispatch({
      type: MIX_SOURCE_SUCCESS,
      columnKey: 'column:a',
      sourceKey: resolved[0].key,
      sessionId: 1,
      definitionFingerprint: resolved.map(source => source.key).join('\n'),
      ids: ['100', '80'],
      cursor: '80',
      frontier: null,
      hasMore: true,
      partial: true,
      suspended: false,
      gap: false,
      requestedCursor: null,
    });
    dispatch(openMixStream('column:a', mix));
    const status = { id: '300', account: { id: '2' }, visibility: 'public', tags: [{ name: 'ruby' }] };
    const [publicStream, listStream] = connections;

    publicStream.handlers.onReceive({ event: 'update', payload: JSON.stringify(status) });
    listStream.handlers.onReceive({ event: 'update', payload: JSON.stringify(status) });

    const view = mixTimelineView(getState().getIn(['mix_timelines', 'column:a']), getState().get('statuses'), null, '1');

    expect(view.statusIds.toArray().filter(id => id === '300')).toHaveLength(1);
    expect(view.sourceKeysById['300'].length).toBe(2);
    expect(getState().getIn(['mix_timelines', 'column:a', 'sources', resolved[0].key, 'frontier'])).toBe(history.get('frontier'));
    expect(getState().getIn(['mix_timelines', 'column:a', 'sources', resolved[0].key, 'cursor'])).toBe('80');
    expect(getState().getIn(['mix_timelines', 'column:a', 'sources', resolved[0].key, 'gap'])).toBe(true);
    expect(view.orderGuaranteed).toBe(false);
  });

  it('holds live posts while the reader is scrolled down', () => {
    const { dispatch, getState } = harness();

    openColumn(dispatch, 'column:a', 1, [
      { type: 'public', params: {} },
      { type: 'list', id: '4', params: {} },
    ]);
    dispatch(openMixStream('column:a', mix));
    dispatch(pinMixStream('column:a', false));
    connections[0].handlers.onReceive({
      event: 'update',
      payload: JSON.stringify({ id: '300', account: { id: '2' }, visibility: 'public' }),
    });

    const hidden = mixTimelineView(getState().getIn(['mix_timelines', 'column:a']), getState().get('statuses'), null, '1');

    expect(hidden.pendingCount).toBe(1);
    expect(hidden.statusIds.toArray()).not.toContain('300');
    dispatch(revealMixStream('column:a'));
    const shown = mixTimelineView(getState().getIn(['mix_timelines', 'column:a']), getState().get('statuses'), null, '1');

    expect(shown.pendingCount).toBe(0);
    expect(shown.statusIds.toArray()).toContain('300');
  });

  it('drops a deleted id from both sources and ignores a late page', () => {
    const { dispatch, getState } = harness();
    const sources = [
      { type: 'public', params: {} },
      { type: 'list', id: '4', params: {} },
    ];
    const resolved = openColumn(dispatch, 'column:a', 1, sources);

    dispatch(openMixStream('column:a', mix));
    const column = getState().getIn(['mix_timelines', 'column:a']);

    expect(column).toBeTruthy();
    connections[0].handlers.onReceive({
      event: 'update',
      payload: JSON.stringify({ id: '300', account: { id: '2' }, reblog: { id: '200' }, visibility: 'public' }),
    });
    connections[1].handlers.onReceive({
      event: 'update',
      payload: JSON.stringify({ id: '300', account: { id: '2' }, visibility: 'public' }),
    });
    const liveBefore = () => getState().getIn(['mix_timelines', 'column:a', 'live']).valueSeq().flatMap(entry => entry.get('statusIds')).toArray();

    expect(liveBefore().filter(id => id === '300')).toHaveLength(2);
    connections[0].handlers.onReceive({ event: 'delete', payload: '300' });
    expect(liveBefore()).not.toContain('300');
    dispatch({
      type: MIX_SOURCE_SUCCESS,
      columnKey: 'column:a',
      sourceKey: resolved[0].key,
      sessionId: 1,
      definitionFingerprint: resolved.map(source => source.key).join('\n'),
      ids: ['300', '100'],
      cursor: '100',
      frontier: '100',
      hasMore: false,
      partial: false,
      requestedCursor: '400',
    });
    expect(getState().getIn(['mix_timelines', 'column:a', 'sources', resolved[0].key, 'ids']).toArray()).toEqual(['100']);
    connections[0].handlers.onReceive({ event: 'expire', payload: '100' });
    expect(getState().getIn(['mix_timelines', 'column:a', 'sources', resolved[0].key, 'ids']).toArray()).toEqual([]);
  });

  it('removes a hashtag post whose edit no longer matches', () => {
    const tagged = fromJS({
      id: 'mix-1',
      version: 1,
      title: 'Desk',
      sources: [
        { type: 'hashtag', id: 'ruby', params: { any: ['web'] } },
        { type: 'account', id: '42', params: {} },
      ],
    });
    const { dispatch, getState } = harness();

    openColumn(dispatch, 'column:tag', 1, tagged.get('sources').toJS());
    dispatch(openMixStream('column:tag', tagged));
    const hashtag = connections.find(row => row.channel === 'hashtag');

    hashtag.handlers.onReceive({
      event: 'update',
      payload: JSON.stringify({ id: '300', account: { id: '2' }, tags: [{ name: 'ruby' }, { name: 'web' }] }),
    });
    hashtag.handlers.onReceive({
      event: 'status.update',
      payload: JSON.stringify({ id: '300', account: { id: '2' }, tags: [{ name: 'python' }] }),
    });

    const ids = getState().getIn(['mix_timelines', 'column:tag', 'live']).valueSeq().flatMap(entry => entry.get('statusIds')).toArray();

    expect(ids).not.toContain('300');
  });

  it('fills three posts missed while disconnected without duplicating a streamed copy', async () => {
    const { dispatch, getState } = harness();
    const sources = [
      { type: 'public', params: {} },
      { type: 'list', id: '4', params: {} },
    ];
    const resolved = openColumn(dispatch, 'column:a', 1, sources);

    dispatch({
      type: MIX_SOURCE_SUCCESS,
      columnKey: 'column:a',
      sourceKey: resolved[0].key,
      sessionId: 1,
      definitionFingerprint: resolved.map(source => source.key).join('\n'),
      ids: ['10'],
      cursor: null,
      frontier: '10',
      hasMore: false,
      partial: false,
      requestedCursor: null,
    });
    dispatch({
      type: MIX_SOURCE_SUCCESS,
      columnKey: 'column:a',
      sourceKey: resolved[1].key,
      sessionId: 1,
      definitionFingerprint: resolved.map(source => source.key).join('\n'),
      ids: [],
      cursor: null,
      frontier: null,
      hasMore: false,
      partial: false,
      requestedCursor: null,
    });
    dispatch(openMixStream('column:a', mix));
    const publicStream = connections.find(row => row.channel === 'public:bot');

    publicStream.handlers.onConnect();
    publicStream.handlers.onDisconnect();
    mockGet.mockResolvedValue({
      status: 200,
      data: [
        { id: '40', account: { id: '2' }, visibility: 'public' },
        { id: '30', account: { id: '2' }, visibility: 'public' },
        { id: '20', account: { id: '2' }, visibility: 'public' },
      ],
      headers: {},
    });
    publicStream.handlers.onConnect();

    for (let attempt = 0; attempt < 10 && getState().getIn(['mix_timelines', 'column:a', 'live', resolved[0].key, 'statusIds']).size < 3; attempt += 1) {
      await Promise.resolve();
    }

    const ids = () => getState().getIn(['mix_timelines', 'column:a', 'live', resolved[0].key, 'statusIds']).toArray();

    expect(mockGet).toHaveBeenCalledTimes(1);
    expect(mockGet.mock.calls[0][1].params.since_id).toBe('10');
    expect(ids()).toEqual(['40', '30', '20']);
    expect(getState().getIn(['mix_timelines', 'column:a', 'sources', resolved[0].key, 'ids']).toArray()).toEqual(['10']);
    expect(getState().getIn(['mix_timelines', 'column:a', 'sources', resolved[0].key, 'frontier'])).toBe('10');
    publicStream.handlers.onReceive({
      event: 'update',
      payload: JSON.stringify({ id: '30', account: { id: '2' }, visibility: 'public' }),
    });
    expect(ids().filter(id => id === '30')).toHaveLength(1);

    const view = mixTimelineView(getState().getIn(['mix_timelines', 'column:a']), fromJS({}), null, '1');

    expect(view.statusIds.toArray()).toEqual(['40', '30', '20', '10']);
    expect(getState().getIn(['mix_timelines', 'column:a', 'live', resolved[0].key, 'syncState'])).toBe('connected');
  });

  it('stops a reconcile on 429 or 206 and when the column closes', async () => {
    const { dispatch, getState } = harness();
    const sources = [
      { type: 'public', params: {} },
      { type: 'list', id: '4', params: {} },
    ];
    const resolved = openColumn(dispatch, 'column:a', 1, sources);

    dispatch({
      type: MIX_SOURCE_SUCCESS,
      columnKey: 'column:a',
      sourceKey: resolved[0].key,
      sessionId: 1,
      definitionFingerprint: resolved.map(source => source.key).join('\n'),
      ids: ['10'],
      cursor: '80',
      frontier: null,
      hasMore: true,
      partial: true,
      requestedCursor: null,
    });
    dispatch(openMixStream('column:a', mix));
    mockGet.mockRejectedValueOnce({ response: { status: 429, headers: { 'retry-after': '120' } } });
    await reconcileMixSource('column:a', resolved[0].key)(dispatch, getState);
    const retryAt = getState().getIn(['mix_timelines', 'column:a', 'live', resolved[0].key, 'retryAt']);

    expect(retryAt).toBeGreaterThan(Date.now());
    mockGet.mockClear();
    await reconcileMixSource('column:a', resolved[0].key)(dispatch, getState);
    expect(mockGet).not.toHaveBeenCalled();
    expect(getState().getIn(['mix_timelines', 'column:a', 'sources', resolved[0].key, 'gap'])).toBe(true);
    expect(getState().getIn(['mix_timelines', 'column:a', 'sources', resolved[0].key, 'cursor'])).toBe('80');

    dispatch({
      type: 'MIX_STREAM_SYNC',
      columnKey: 'column:a',
      sourceKey: resolved[0].key,
      sessionId: 1,
      definitionFingerprint: resolved.map(source => source.key).join('\n'),
      syncState: 'connected',
      retryAt: null,
    });
    mockGet.mockResolvedValueOnce({
      status: 206,
      data: [{ id: '15', account: { id: '2' } }],
      headers: {},
    });
    await reconcileMixSource('column:a', resolved[0].key)(dispatch, getState);
    expect(getState().getIn(['mix_timelines', 'column:a', 'live', resolved[0].key, 'syncState'])).toBe('degraded');
    expect(getState().getIn(['mix_timelines', 'column:a', 'sources', resolved[0].key, 'gap'])).toBe(true);

    let release;
    const held = new Promise(resolve => {
      release = resolve;
    });

    mockGet.mockImplementation(() => held);
    const pending = reconcileMixSource('column:a', resolved[0].key)(dispatch, getState);

    dispatch(closeMixStream('column:a'));
    openColumn(dispatch, 'column:a', 2, sources);
    release({ status: 200, data: [{ id: '12', account: { id: '2' } }], headers: {} });
    await pending;
    expect(getState().getIn(['mix_timelines', 'column:a', 'live']).valueSeq().flatMap(entry => entry.get('statusIds')).toArray()).not.toContain('12');
  });
});
