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
  get me () {
    return '1';
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
  const sent = [];
  const dispatch = (action) => {
    if (typeof action === 'function') {
      return action(dispatch, () => state);
    }

    sent.push(action);

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
    sent,
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
      payload: JSON.stringify({ id: '300', visibility: 'public', account: { id: '2' }, tags: [{ name: 'ruby' }, { name: 'web' }] }),
    });
    hashtag.handlers.onReceive({
      event: 'status.update',
      payload: JSON.stringify({ id: '300', visibility: 'public', account: { id: '2' }, tags: [{ name: 'python' }] }),
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

  it('does not grant list membership from a public status.update, and ignores a private post', () => {
    const { dispatch, getState } = harness();
    const sources = [
      { type: 'public', params: {} },
      { type: 'list', id: '4', params: {} },
    ];
    const resolved = openColumn(dispatch, 'column:a', 1, sources);

    dispatch(openMixStream('column:a', mix));
    const publicStream = connections.find(row => row.channel === 'public:bot');

    publicStream.handlers.onReceive({
      event: 'status.update',
      payload: JSON.stringify({ id: '300', visibility: 'public', account: { id: '2' } }),
    });
    expect(getState().getIn(['mix_timelines', 'column:a', 'live', resolved[0].key, 'statusIds']).toArray()).toEqual(['300']);
    expect(getState().getIn(['mix_timelines', 'column:a', 'live', resolved[1].key, 'statusIds']).toArray()).toEqual([]);

    publicStream.handlers.onReceive({
      event: 'update',
      payload: JSON.stringify({ id: '200', visibility: 'private', account: { id: '2' } }),
    });
    expect(getState().getIn(['mix_timelines', 'column:a', 'live', resolved[0].key, 'statusIds']).toArray()).not.toContain('200');
  });

  it('does not accept an unknown payload from a supported channel', () => {
    const mediaMix = fromJS({
      id: 'mix-1',
      version: 1,
      title: 'Desk',
      sources: [
        { type: 'public', params: { onlyMedia: true } },
        { type: 'list', id: '4', params: {} },
      ],
    });
    const { dispatch, getState } = harness();
    const resolved = openColumn(dispatch, 'column:media', 1, mediaMix.get('sources').toJS());

    dispatch(openMixStream('column:media', mediaMix));
    const mediaStream = connections.find(row => row.channel === 'public:bot:media');

    mediaStream.handlers.onReceive({
      event: 'update',
      payload: JSON.stringify({ id: '300', visibility: 'public', account: { id: '2' } }),
    });
    expect(getState().getIn(['mix_timelines', 'column:media', 'live', resolved[0].key, 'statusIds']).toArray()).toEqual([]);
  });

  it('imports filter definitions from the raw streaming payload and keeps hide or warn', () => {
    const { dispatch, getState, sent } = harness();
    const resolved = openColumn(dispatch, 'column:a', 1, [
      { type: 'public', params: {} },
      { type: 'list', id: '4', params: {} },
    ]);

    dispatch(openMixStream('column:a', mix));
    connections.find(row => row.channel === 'public:bot').handlers.onReceive({
      event: 'update',
      payload: JSON.stringify({
        id: '300',
        visibility: 'public',
        account: { id: '2' },
        filtered: [{ filter: { id: '9', title: 'Spoilers', filter_action: 'warn', context: ['public'] }, keyword_matches: ['x'] }],
      }),
    });

    const imported = sent.filter(action => action.type === 'FILTERS_IMPORT');

    expect(imported[0].filters[0]).toMatchObject({ id: '9', title: 'Spoilers', filter_action: 'warn' });
    const warned = mixTimelineView(getState().getIn(['mix_timelines', 'column:a']), fromJS({}), fromJS({
      '9': { id: '9', title: 'Spoilers', filter_action: 'warn', context: ['public'] },
    }), '1');

    expect(warned.warningsById['300']).toEqual(['Spoilers']);

    connections.find(row => row.channel === 'public:bot').handlers.onReceive({
      event: 'update',
      payload: JSON.stringify({
        id: '200',
        visibility: 'public',
        account: { id: '2' },
        filtered: [{ filter: { id: '2', title: 'spam', filter_action: 'hide', context: ['public'] }, keyword_matches: ['y'] }],
      }),
    });
    const hidden = mixTimelineView(getState().getIn(['mix_timelines', 'column:a']), fromJS({}), fromJS({
      '2': { id: '2', title: 'spam', filter_action: 'hide', context: ['public'] },
    }), '1');

    expect(hidden.statusIds.toArray()).not.toContain('200');
    expect(getState().getIn(['mix_timelines', 'column:a', 'live', resolved[0].key, 'filterResults', '200', 0, 'filter'])).toBe('2');
  });

  it('drops a changed tag from REST history without moving the cursor, and keeps another source', () => {
    const tagged = fromJS({
      id: 'mix-1',
      version: 1,
      title: 'Desk',
      sources: [
        { type: 'hashtag', id: 'ruby', params: {} },
        { type: 'public', params: {} },
      ],
    });
    const { dispatch, getState } = harness();
    const resolved = openColumn(dispatch, 'column:tag', 1, tagged.get('sources').toJS());
    const fingerprint = resolved.map(source => source.key).join('\n');

    [0, 1].forEach(index => {
      dispatch({
        type: MIX_SOURCE_SUCCESS,
        columnKey: 'column:tag',
        sourceKey: resolved[index].key,
        sessionId: 1,
        definitionFingerprint: fingerprint,
        ids: ['500'],
        cursor: '500',
        frontier: '500',
        hasMore: true,
        partial: false,
        requestedCursor: '600',
      });
    });
    dispatch(openMixStream('column:tag', tagged));
    const hashtag = connections.find(row => row.channel === 'hashtag' && row.params.tag === 'ruby');

    hashtag.handlers.onReceive({
      event: 'status.update',
      payload: JSON.stringify({ id: '500', visibility: 'public', account: { id: '2' }, tags: [{ name: 'python' }] }),
    });

    expect(getState().getIn(['mix_timelines', 'column:tag', 'sources', resolved[0].key, 'ids']).toArray()).toEqual([]);
    expect(getState().getIn(['mix_timelines', 'column:tag', 'sources', resolved[0].key, 'cursor'])).toBe('500');
    expect(getState().getIn(['mix_timelines', 'column:tag', 'sources', resolved[0].key, 'frontier'])).toBe('500');
    expect(getState().getIn(['mix_timelines', 'column:tag', 'sources', resolved[0].key, 'gap'])).toBe(false);
    expect(getState().getIn(['mix_timelines', 'column:tag', 'sources', resolved[1].key, 'ids']).toArray()).toEqual(['500']);
    const view = mixTimelineView(getState().getIn(['mix_timelines', 'column:tag']), fromJS({}), null, '1');

    expect(view.statusIds.toArray()).toContain('500');
    expect(view.sourceKeysById['500']).toEqual([resolved[1].key]);
  });

  it('unsubscribes every hashtag channel when the definition changes', () => {
    const tagged = fromJS({
      id: 'mix-1',
      version: 1,
      title: 'Desk',
      sources: [
        { type: 'hashtag', id: 'ruby', params: { any: ['web'] } },
        { type: 'public', params: {} },
      ],
    });
    const { dispatch } = harness();

    openColumn(dispatch, 'column:tag', 1, tagged.get('sources').toJS());
    dispatch(openMixStream('column:tag', tagged));
    const hashtags = connections.filter(row => row.channel === 'hashtag');

    expect(hashtags.map(row => row.params.tag).sort()).toEqual(['ruby', 'web']);
    hashtags.forEach(row => row.handlers.onConnect());
    hashtags[0].handlers.onDisconnect();
    const replaced = fromJS({
      id: 'mix-1',
      version: 1,
      title: 'Desk',
      sources: [
        { type: 'hashtag', id: 'python', params: {} },
        { type: 'public', params: {} },
      ],
    });

    openColumn(dispatch, 'column:tag', 2, replaced.get('sources').toJS());
    dispatch(openMixStream('column:tag', replaced));
    expect(hashtags.every(row => row.stopped)).toBe(true);
    expect(connections.filter(row => row.channel === 'hashtag' && !row.stopped).map(row => row.params.tag)).toEqual(['python']);
  });

  it('keeps since_id while paging a long reconnect gap and advances the reconciled boundary', async () => {
    const { dispatch, getState } = harness();
    const resolved = openColumn(dispatch, 'column:a', 1, [
      { type: 'public', params: {} },
      { type: 'list', id: '4', params: {} },
    ]);
    const fingerprint = resolved.map(source => source.key).join('\n');
    const descending = (start, end) => {
      const ids = [];

      for (let value = start; value >= end; value -= 1) {
        ids.push(String(value));
      }

      return ids;
    };

    dispatch({
      type: MIX_SOURCE_SUCCESS,
      columnKey: 'column:a',
      sourceKey: resolved[0].key,
      sessionId: 1,
      definitionFingerprint: fingerprint,
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
      definitionFingerprint: fingerprint,
      ids: [],
      cursor: null,
      frontier: null,
      hasMore: false,
      partial: false,
      requestedCursor: null,
    });
    dispatch(openMixStream('column:a', mix));
    const calls = [];

    mockGet.mockImplementation((path, config) => {
      const sinceId = config.params.since_id;
      const maxId = config.params.max_id;

      calls.push({ sinceId, maxId });

      if (!maxId) {
        return Promise.resolve({
          status: 200,
          data: descending(90, 51).map(id => ({ id, visibility: 'public', account: { id: '2' } })),
          links: { refs: [{ rel: 'next', uri: `${window.location.origin}${path}?max_id=51` }] },
        });
      }

      return Promise.resolve({
        status: 200,
        data: descending(50, 9).map(id => ({ id, visibility: 'public', account: { id: '2' } })),
        headers: {},
      });
    });

    await reconcileMixSource('column:a', resolved[0].key)(dispatch, getState);

    const liveIds = getState().getIn(['mix_timelines', 'column:a', 'live', resolved[0].key, 'statusIds']).toArray();

    expect(calls.map(call => call.sinceId)).toEqual(['10', '10']);
    expect(calls[1].maxId).toBe('51');
    expect(liveIds).toContain('90');
    expect(liveIds).toContain('11');
    expect(liveIds).not.toContain('10');
    expect(liveIds).not.toContain('9');
    expect(getState().getIn(['mix_timelines', 'column:a', 'live', resolved[0].key, 'syncState'])).toBe('connected');
    expect(getState().getIn(['mix_timelines', 'column:a', 'live', resolved[0].key, 'lastReconciledId'])).toBe('90');
    expect(getState().getIn(['mix_timelines', 'column:a', 'sources', resolved[0].key, 'frontier'])).toBe('10');

    mockGet.mockClear();
    mockGet.mockResolvedValue({ status: 200, data: [], headers: {} });
    await reconcileMixSource('column:a', resolved[0].key)(dispatch, getState);
    expect(mockGet).toHaveBeenCalledTimes(1);
    expect(mockGet.mock.calls[0][1].params.since_id).toBe('90');
  });

  it('ignores an older reconcile after a newer one starts', async () => {
    const { dispatch, getState } = harness();
    const resolved = openColumn(dispatch, 'column:a', 1, [
      { type: 'public', params: {} },
      { type: 'list', id: '4', params: {} },
    ]);

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

    let rejectFirst;
    const first = new Promise((resolve, reject) => {
      rejectFirst = reject;
    });
    let started = 0;

    mockGet.mockImplementation(() => {
      started += 1;

      if (started === 1) {
        return first;
      }

      return Promise.resolve({
        status: 200,
        data: [{ id: '30', visibility: 'public', account: { id: '2' } }],
        headers: {},
      });
    });

    const older = reconcileMixSource('column:a', resolved[0].key)(dispatch, getState);
    const newer = reconcileMixSource('column:a', resolved[0].key)(dispatch, getState);

    await newer;
    rejectFirst({ response: { status: 500 } });
    await older;

    const ids = getState().getIn(['mix_timelines', 'column:a', 'live', resolved[0].key, 'statusIds']).toArray();

    expect(ids).toEqual(['30']);
    expect(ids).not.toContain('99');
    expect(getState().getIn(['mix_timelines', 'column:a', 'live', resolved[0].key, 'syncState'])).toBe('connected');
    expect(getState().getIn(['mix_timelines', 'column:a', 'live', resolved[0].key, 'lastReconciledId'])).toBe('30');
  });

  it('hides and warns a history-only post from the edited filter result', () => {
    const { dispatch, getState } = harness();
    const resolved = openColumn(dispatch, 'column:a', 1, [
      { type: 'public', params: {} },
      { type: 'list', id: '4', params: {} },
    ]);
    const fingerprint = resolved.map(source => source.key).join('\n');

    dispatch({
      type: MIX_SOURCE_SUCCESS,
      columnKey: 'column:a',
      sourceKey: resolved[0].key,
      sessionId: 1,
      definitionFingerprint: fingerprint,
      ids: ['500'],
      cursor: '400',
      frontier: '400',
      hasMore: true,
      partial: false,
      requestedCursor: '600',
    });
    dispatch({
      type: MIX_SOURCE_SUCCESS,
      columnKey: 'column:a',
      sourceKey: resolved[1].key,
      sessionId: 1,
      definitionFingerprint: fingerprint,
      ids: [],
      cursor: null,
      frontier: null,
      hasMore: false,
      partial: false,
      requestedCursor: null,
    });
    dispatch(openMixStream('column:a', mix));
    const filtersFor = (id, title, action) => fromJS({
      [id]: { id, title, filter_action: action, context: ['public'] },
    });
    const receive = (id, title, action) => {
      connections.find(row => row.channel === 'public:bot').handlers.onReceive({
        event: 'status.update',
        payload: JSON.stringify({
          id: '500',
          visibility: 'public',
          account: { id: '2' },
          filtered: [{ filter: { id, title, filter_action: action, context: ['public'] }, keyword_matches: ['x'] }],
        }),
      });
    };

    receive('2', 'spam', 'hide');

    const hidden = mixTimelineView(getState().getIn(['mix_timelines', 'column:a']), fromJS({}), filtersFor('2', 'spam', 'hide'), '1');

    expect(hidden.statusIds.toArray()).not.toContain('500');
    expect(getState().getIn(['mix_timelines', 'column:a', 'sources', resolved[0].key, 'ids']).toArray()).toEqual(['500']);
    expect(getState().getIn(['mix_timelines', 'column:a', 'sources', resolved[0].key, 'cursor'])).toBe('400');
    expect(getState().getIn(['mix_timelines', 'column:a', 'sources', resolved[0].key, 'frontier'])).toBe('400');
    expect(getState().getIn(['mix_timelines', 'column:a', 'sources', resolved[0].key, 'filterResults', '500', 0, 'filter'])).toBe('2');

    receive('9', 'Spoilers', 'warn');

    const warned = mixTimelineView(getState().getIn(['mix_timelines', 'column:a']), fromJS({}), filtersFor('9', 'Spoilers', 'warn'), '1');

    expect(warned.statusIds.toArray()).toContain('500');
    expect(warned.warningsById['500']).toEqual(['Spoilers']);
  });

  it('keeps home and public filter results separate and blocks a revoked id from a late page', () => {
    const homeMix = fromJS({
      id: 'mix-1',
      version: 1,
      title: 'Desk',
      sources: [
        { type: 'home', params: { shows: { reblog: true, reply: true, private: true, limited: true, direct: true, personal: true } } },
        { type: 'public', params: {} },
      ],
    });
    const { dispatch, getState } = harness();
    const resolved = openColumn(dispatch, 'column:home', 1, homeMix.get('sources').toJS());
    const fingerprint = resolved.map(source => source.key).join('\n');

    resolved.forEach(source => {
      dispatch({
        type: MIX_SOURCE_SUCCESS,
        columnKey: 'column:home',
        sourceKey: source.key,
        sessionId: 1,
        definitionFingerprint: fingerprint,
        ids: ['500'],
        cursor: '500',
        frontier: '500',
        hasMore: false,
        partial: false,
        requestedCursor: null,
      });
    });
    dispatch(openMixStream('column:home', homeMix));
    const homeStream = connections.find(row => row.channel === 'user');

    homeStream.handlers.onReceive({
      event: 'status.update',
      payload: JSON.stringify({
        id: '500',
        visibility: 'public',
        account: { id: '2' },
        filtered: [{ filter: { id: '2', title: 'home-only', filter_action: 'hide', context: ['home'] }, keyword_matches: ['x'] }],
      }),
    });

    expect(getState().getIn(['mix_timelines', 'column:home', 'sources', resolved[0].key, 'filterResults', '500', 0, 'filter'])).toBe('2');
    expect(getState().getIn(['mix_timelines', 'column:home', 'sources', resolved[1].key, 'filterResults', '500'])).toBeUndefined();

    const shown = mixTimelineView(getState().getIn(['mix_timelines', 'column:home']), fromJS({}), fromJS({
      '2': { id: '2', title: 'home-only', filter_action: 'hide', context: ['home'] },
    }), '1');

    expect(shown.statusIds.toArray()).toContain('500');
    expect(shown.contextById['500']).toBe('public');

    const hashtagMix = fromJS({
      id: 'mix-2',
      version: 1,
      title: 'Tags',
      sources: [
        { type: 'hashtag', id: 'ruby', params: {} },
        { type: 'public', params: {} },
      ],
    });
    const tagResolved = openColumn(dispatch, 'column:tag', 1, hashtagMix.get('sources').toJS());
    const tagFingerprint = tagResolved.map(source => source.key).join('\n');

    dispatch({
      type: MIX_SOURCE_SUCCESS,
      columnKey: 'column:tag',
      sourceKey: tagResolved[0].key,
      sessionId: 1,
      definitionFingerprint: tagFingerprint,
      ids: ['500'],
      cursor: '400',
      frontier: '400',
      hasMore: true,
      partial: false,
      requestedCursor: '600',
    });
    dispatch(openMixStream('column:tag', hashtagMix));
    connections.find(row => row.channel === 'hashtag' && row.params.tag === 'ruby').handlers.onReceive({
      event: 'status.update',
      payload: JSON.stringify({ id: '500', visibility: 'public', account: { id: '2' }, tags: [{ name: 'python' }] }),
    });
    dispatch({
      type: MIX_SOURCE_SUCCESS,
      columnKey: 'column:tag',
      sourceKey: tagResolved[0].key,
      sessionId: 1,
      definitionFingerprint: tagFingerprint,
      ids: ['500', '300'],
      cursor: '300',
      frontier: '300',
      hasMore: true,
      partial: false,
      requestedCursor: '400',
    });

    expect(getState().getIn(['mix_timelines', 'column:tag', 'sources', tagResolved[0].key, 'ids']).toArray()).toEqual(['300']);
    expect(getState().getIn(['mix_timelines', 'column:tag', 'sources', tagResolved[0].key, 'cursor'])).toBe('300');
    expect(getState().getIn(['timelines', 'home', 'items']).toArray()).toEqual(['existing']);
  });

  const readyHistory = (dispatch, columnKey, sourceKey, fingerprint) => {
    dispatch({
      type: MIX_SOURCE_SUCCESS,
      columnKey,
      sourceKey,
      sessionId: 1,
      definitionFingerprint: fingerprint,
      ids: ['10'],
      cursor: null,
      frontier: '10',
      hasMore: false,
      partial: false,
      requestedCursor: null,
    });
  };

  it('keeps the confirmed boundary when a later reconcile page is rate limited', async () => {
    const { dispatch, getState } = harness();
    const resolved = openColumn(dispatch, 'column:a', 1, [
      { type: 'public', params: {} },
      { type: 'list', id: '4', params: {} },
    ]);
    const fingerprint = resolved.map(source => source.key).join('\n');
    const descending = (start, end) => {
      const ids = [];

      for (let value = start; value >= end; value -= 1) {
        ids.push(String(value));
      }

      return ids;
    };

    readyHistory(dispatch, 'column:a', resolved[0].key, fingerprint);
    dispatch({
      type: MIX_SOURCE_SUCCESS,
      columnKey: 'column:a',
      sourceKey: resolved[1].key,
      sessionId: 1,
      definitionFingerprint: fingerprint,
      ids: [],
      cursor: null,
      frontier: null,
      hasMore: false,
      partial: false,
      requestedCursor: null,
    });
    dispatch(openMixStream('column:a', mix));

    let attempt = 0;

    mockGet.mockImplementation((path, config) => {
      attempt += 1;
      expect(config.params.since_id).toBe('10');

      if (attempt === 1) {
        return Promise.resolve({
          status: 200,
          data: descending(90, 51).map(id => ({ id, visibility: 'public', account: { id: '2' } })),
          links: { refs: [{ rel: 'next', uri: `${window.location.origin}${path}?max_id=51` }] },
        });
      }

      if (attempt === 2) {
        return Promise.reject({ response: { status: 429, headers: { 'retry-after': '30' } } });
      }

      return Promise.resolve({
        status: 200,
        data: descending(90, 11).map(id => ({ id, visibility: 'public', account: { id: '2' } })),
        headers: {},
      });
    });

    await reconcileMixSource('column:a', resolved[0].key)(dispatch, getState);

    const live = () => getState().getIn(['mix_timelines', 'column:a', 'live', resolved[0].key]);

    expect(live().get('syncState')).toBe('degraded');
    expect(live().get('lastReconciledId')).toBe(null);
    expect(live().get('statusIds').toArray()).toContain('90');
    expect(getState().getIn(['mix_timelines', 'column:a', 'sources', resolved[0].key, 'frontier'])).toBe('10');

    dispatch({
      type: 'MIX_STREAM_SYNC',
      columnKey: 'column:a',
      sourceKey: resolved[0].key,
      sessionId: 1,
      definitionFingerprint: fingerprint,
      syncState: 'degraded',
      retryAt: null,
    });
    await reconcileMixSource('column:a', resolved[0].key)(dispatch, getState);

    expect(live().get('syncState')).toBe('connected');
    expect(live().get('lastReconciledId')).toBe('90');
    expect(attempt).toBe(3);
  });

  it('shows a partial reconcile page without moving the confirmed boundary', async () => {
    const { dispatch, getState } = harness();
    const resolved = openColumn(dispatch, 'column:a', 1, [
      { type: 'public', params: {} },
      { type: 'list', id: '4', params: {} },
    ]);
    const fingerprint = resolved.map(source => source.key).join('\n');

    readyHistory(dispatch, 'column:a', resolved[0].key, fingerprint);
    dispatch({
      type: MIX_SOURCE_SUCCESS,
      columnKey: 'column:a',
      sourceKey: resolved[1].key,
      sessionId: 1,
      definitionFingerprint: fingerprint,
      ids: [],
      cursor: null,
      frontier: null,
      hasMore: false,
      partial: false,
      requestedCursor: null,
    });
    dispatch(openMixStream('column:a', mix));
    mockGet.mockResolvedValueOnce({
      status: 206,
      data: [
        { id: '90', visibility: 'public', account: { id: '2' } },
        { id: '80', visibility: 'public', account: { id: '2' } },
      ],
      headers: {},
    });
    await reconcileMixSource('column:a', resolved[0].key)(dispatch, getState);

    const live = getState().getIn(['mix_timelines', 'column:a', 'live', resolved[0].key]);

    expect(live.get('statusIds').toArray()).toEqual(['90', '80']);
    expect(live.get('syncState')).toBe('degraded');
    expect(live.get('lastReconciledId')).toBe(null);

    mockGet.mockResolvedValueOnce({ status: 200, data: [], headers: {} });
    await reconcileMixSource('column:a', resolved[0].key)(dispatch, getState);
    expect(mockGet.mock.calls[mockGet.mock.calls.length - 1][1].params.since_id).toBe('10');
    expect(getState().getIn(['mix_timelines', 'column:a', 'sources', resolved[0].key, 'gap'])).toBe(false);
  });

  it('does not let a streamed id skip a failed reconcile gap', async () => {
    const { dispatch, getState } = harness();
    const resolved = openColumn(dispatch, 'column:a', 1, [
      { type: 'public', params: {} },
      { type: 'list', id: '4', params: {} },
    ]);
    const fingerprint = resolved.map(source => source.key).join('\n');

    readyHistory(dispatch, 'column:a', resolved[0].key, fingerprint);
    dispatch({
      type: MIX_SOURCE_SUCCESS,
      columnKey: 'column:a',
      sourceKey: resolved[1].key,
      sessionId: 1,
      definitionFingerprint: fingerprint,
      ids: [],
      cursor: null,
      frontier: null,
      hasMore: false,
      partial: false,
      requestedCursor: null,
    });
    dispatch(openMixStream('column:a', mix));
    mockGet.mockRejectedValueOnce({ response: { status: 500 } });
    await reconcileMixSource('column:a', resolved[0].key)(dispatch, getState);
    connections.find(row => row.channel === 'public:bot').handlers.onReceive({
      event: 'update',
      payload: JSON.stringify({ id: '100', visibility: 'public', account: { id: '2' } }),
    });

    expect(getState().getIn(['mix_timelines', 'column:a', 'live', resolved[0].key, 'lastReceivedId'])).toBe('100');
    expect(getState().getIn(['mix_timelines', 'column:a', 'live', resolved[0].key, 'lastReconciledId'])).toBe(null);

    mockGet.mockResolvedValueOnce({ status: 200, data: [{ id: '20', visibility: 'public', account: { id: '2' } }], headers: {} });
    await reconcileMixSource('column:a', resolved[0].key)(dispatch, getState);
    expect(mockGet.mock.calls[mockGet.mock.calls.length - 1][1].params.since_id).toBe('10');
    expect(getState().getIn(['mix_timelines', 'column:a', 'live', resolved[0].key, 'statusIds']).toArray()).toEqual(expect.arrayContaining(['100', '20']));
  });

  it('does not reconcile a rest-only source until its history boundary exists', async () => {
    const accountMix = fromJS({
      id: 'mix-1',
      version: 1,
      title: 'Desk',
      sources: [
        { type: 'account', id: '42', params: {} },
        { type: 'public', params: {} },
      ],
    });
    const { dispatch, getState } = harness();
    const resolved = openColumn(dispatch, 'column:account', 1, accountMix.get('sources').toJS());

    mockGet.mockClear();
    dispatch(openMixStream('column:account', accountMix));
    await Promise.resolve();
    expect(mockGet).not.toHaveBeenCalled();

    await reconcileMixSource('column:account', resolved[0].key)(dispatch, getState);
    expect(mockGet).not.toHaveBeenCalled();

    dispatch({
      type: MIX_SOURCE_SUCCESS,
      columnKey: 'column:account',
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
    mockGet.mockResolvedValue({ status: 200, data: [], headers: {} });
    await reconcileMixSource('column:account', resolved[0].key)(dispatch, getState);
    expect(mockGet).toHaveBeenCalledTimes(1);
    expect(mockGet.mock.calls[0][1].params.since_id).toBe('10');
    expect(getState().getIn(['timelines', 'home', 'items']).toArray()).toEqual(['existing']);
  });
});
