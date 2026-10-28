import { List as ImmutableList, Map as ImmutableMap, fromJS } from 'immutable';
import { applyMiddleware, createStore } from 'redux';
import { combineReducers } from 'redux-immutable';
import thunk from 'redux-thunk';

jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

jest.mock('../../api', () => ({
  __esModule: true,
  default: jest.fn(),
}));

import api from '../../api';
import { REDRAFT, deleteStatus } from '../statuses';
import { deleteFromTimelines } from '../timelines';
import { ACCOUNTS_IMPORT } from '../importer';
import { MIX_SOURCE_SUCCESS, MIX_STREAM_REMOVE, MIX_TIMELINE_OPEN } from '../mix_timelines';
import { changeCompose } from '../compose';
import errorsMiddleware from '../../middleware/errors';
import alerts from '../../reducers/alerts';
import compose from '../../reducers/composer';
import contexts from '../../reducers/contexts';
import immediateFeed from '../../reducers/immediate_feed';
import mixTimelines from '../../reducers/mix_timelines';
import notifications from '../../reducers/notifications';
import statuses from '../../reducers/statuses';
import timelines from '../../reducers/timelines';
import accounts from '../../reducers/accounts';

const fingerprint = 'home';

const accountPayload = {
  id: '1',
  username: 'owner',
  acct: 'owner',
  display_name: 'Owner',
  note: '',
  followed_message: '',
  url: 'https://example.test/@owner',
  emojis: [],
};

const externalStatus = fromJS({
  id: 'ext-1',
  text: 'Imported article',
  content: '<p>Imported article</p>',
  visibility: 'external',
  visibility_ex: 'external',
  spoiler_text: '',
  media_attachments: [{ id: 'm-ext', type: 'image', url: 'https://cdn.example/pixel.jpg' }],
  account: '1',
  fedibird_external: { protocol: 'rss' },
});

const ordinaryStatus = fromJS({
  id: 'status-1',
  text: 'Ordinary note',
  spoiler_text: '',
  visibility: 'public',
  status_reference_ids: [],
  media_attachments: [{ id: 'm1', type: 'image', description: 'old alt', url: 'https://cdn.example/pixel.jpg' }],
  account: '1',
});

const reducer = combineReducers({
  accounts,
  alerts,
  compose,
  contexts,
  immediate_feed: immediateFeed,
  mix_timelines: mixTimelines,
  notifications,
  statuses,
  timelines,
});

const recorded = () => {
  const actions = [];

  return {
    actions,
    middleware: () => next => action => {
      actions.push(action);
      return next(action);
    },
  };
};

const makeStore = (statusMap) => {
  const log = recorded();
  const store = createStore(
    reducer,
    ImmutableMap({
      statuses: statusMap,
      timelines: ImmutableMap({
        home: ImmutableMap({
          items: ImmutableList(['ext-1', 'status-1', 'keep']),
          pendingItems: ImmutableList(['ext-1']),
          unread: 0,
          online: false,
          top: true,
        }),
        'list:9': ImmutableMap({
          items: ImmutableList(['ext-1', 'keep']),
        }),
        weird: ImmutableMap({
          items: ImmutableList(['ext-1']),
          window: 'bad',
        }),
        broken: 'nope',
      }),
    }),
    applyMiddleware(thunk, errorsMiddleware(), log.middleware),
  );

  return { store, actions: log.actions };
};

const openColumn = (store, columnKey, ids) => {
  store.dispatch({
    type: MIX_TIMELINE_OPEN,
    columnKey,
    mixId: columnKey,
    definitionFingerprint: fingerprint,
    sessionId: 1,
    sources: [{ key: 'home', descriptor: { type: 'home', params: {} } }],
  });
  store.dispatch({
    type: MIX_SOURCE_SUCCESS,
    columnKey,
    sourceKey: 'home',
    sessionId: 1,
    definitionFingerprint: fingerprint,
    ids,
    cursor: ids[ids.length - 1] || null,
    frontier: ids[ids.length - 1] || null,
    hasMore: true,
    partial: false,
    requestedCursor: null,
  });
};

const columnIds = (store, columnKey) => store.getState().getIn(['mix_timelines', columnKey, 'sources', 'home', 'ids']).toArray();

describe('external projection delete', () => {
  let client;

  beforeEach(() => {
    client = {
      get: jest.fn(() => new Promise(() => {})),
      delete: jest.fn(),
    };
    api.mockImplementation(() => client);
    window.innerWidth = 1200;
  });

  it('treats an id-only delete as success and does not redraft the projection', async () => {
    const { store, actions } = makeStore(ImmutableMap({
      'ext-1': externalStatus,
      keep: fromJS({ id: 'keep', account: '1' }),
      quoted: fromJS({ id: 'quoted', quote_id: 'ext-1', account: '1' }),
    }));
    openColumn(store, 'column:a', ['ext-1', 'keep']);
    openColumn(store, 'column:b', ['ext-1']);
    client.delete.mockResolvedValue({ data: { id: 'ext-1' } });

    await store.dispatch(deleteStatus('ext-1', { push: jest.fn() }, true));
    store.dispatch(deleteFromTimelines('ext-1'));
    store.dispatch({
      type: MIX_STREAM_REMOVE,
      columnKey: 'column:a',
      sessionId: 1,
      definitionFingerprint: fingerprint,
      id: 'ext-1',
      references: [],
      quotes: [],
    });
    store.dispatch({
      type: MIX_STREAM_REMOVE,
      columnKey: 'column:b',
      sessionId: 1,
      definitionFingerprint: fingerprint,
      id: 'ext-1',
      references: [],
      quotes: [],
    });

    expect(client.delete).toHaveBeenCalledWith('/api/v1/statuses/ext-1');
    expect(actions.some(action => action.type === 'STATUS_DELETE_SUCCESS')).toBe(true);
    expect(actions.some(action => action.type === 'STATUS_DELETE_FAIL')).toBe(false);
    expect(actions.some(action => action.type === ACCOUNTS_IMPORT)).toBe(false);
    expect(actions.some(action => action.type === REDRAFT)).toBe(false);
    expect(store.getState().get('alerts').size).toBe(0);
    expect(store.getState().getIn(['compose', 'text'])).toBe('');
    expect(store.getState().getIn(['compose', 'media_attachments']).size).toBe(0);
    expect(store.getState().get('statuses').has('ext-1')).toBe(false);
    expect(store.getState().getIn(['timelines', 'home', 'items']).toArray()).toEqual(['status-1', 'keep']);
    expect(store.getState().getIn(['timelines', 'home', 'pendingItems']).toArray()).toEqual([]);
    expect(store.getState().getIn(['timelines', 'list:9', 'items']).toArray()).toEqual(['keep']);
    expect(store.getState().getIn(['timelines', 'broken'])).toBe('nope');
    expect(columnIds(store, 'column:a')).toEqual(['keep']);
    expect(columnIds(store, 'column:b')).toEqual([]);
  });

  it('accepts a stream delete that arrives before the id-only response, twice, without importing an account', async () => {
    const { store, actions } = makeStore(ImmutableMap({
      'ext-1': externalStatus,
      keep: fromJS({ id: 'keep', account: '1' }),
    }));
    openColumn(store, 'column:a', ['ext-1', 'keep']);
    openColumn(store, 'column:b', ['keep', 'ext-1']);
    let resolveDelete;
    client.delete.mockReturnValue(new Promise(resolve => {
      resolveDelete = resolve;
    }));

    const pending = store.dispatch(deleteStatus('ext-1', { push: jest.fn() }, true));
    store.dispatch(deleteFromTimelines('ext-1'));
    store.dispatch(deleteFromTimelines('ext-1'));
    store.dispatch({
      type: MIX_STREAM_REMOVE,
      columnKey: 'column:a',
      sessionId: 1,
      definitionFingerprint: fingerprint,
      id: 'ext-1',
      references: ['missing-reblog'],
      quotes: ['missing-quote'],
    });
    store.dispatch({
      type: MIX_STREAM_REMOVE,
      columnKey: 'column:b',
      sessionId: 1,
      definitionFingerprint: fingerprint,
      id: 'ext-1',
      references: [],
      quotes: [],
    });
    resolveDelete({ data: { id: 'ext-1' } });
    await pending;

    expect(actions.some(action => action.type === 'STATUS_DELETE_FAIL')).toBe(false);
    expect(actions.some(action => action.type === ACCOUNTS_IMPORT)).toBe(false);
    expect(actions.some(action => action.type === REDRAFT)).toBe(false);
    expect(store.getState().get('alerts').size).toBe(0);
    expect(store.getState().get('statuses').has('ext-1')).toBe(false);
    expect(store.getState().get('statuses').has('missing-reblog')).toBe(false);
    expect(store.getState().get('statuses').has('missing-quote')).toBe(false);
    expect(store.getState().getIn(['compose', 'text'])).toBe('');
    expect(store.getState().getIn(['timelines', 'home', 'items']).includes('ext-1')).toBe(false);
    expect(store.getState().getIn(['timelines', 'list:9', 'items']).includes('ext-1')).toBe(false);
    expect(columnIds(store, 'column:a')).toEqual(['keep']);
    expect(columnIds(store, 'column:b')).toEqual(['keep']);
  });

  it('deletes an already removed id without throwing or redrafting', async () => {
    const { store, actions } = makeStore(ImmutableMap({
      keep: fromJS({ id: 'keep', account: '1' }),
    }));
    client.delete.mockResolvedValue({ data: { id: 'missing' } });

    await expect(store.dispatch(deleteStatus('missing', { push: jest.fn() }, true))).resolves.toBeUndefined();

    expect(client.delete).toHaveBeenCalledWith('/api/v1/statuses/missing');
    expect(actions.some(action => action.type === 'STATUS_DELETE_SUCCESS')).toBe(true);
    expect(actions.some(action => action.type === 'STATUS_DELETE_FAIL')).toBe(false);
    expect(actions.some(action => action.type === REDRAFT)).toBe(false);
    expect(store.getState().get('alerts').size).toBe(0);
  });

  it('does not copy a direct redraft of an external or masked projection into the composer', () => {
    const { store } = makeStore(ImmutableMap());
    store.dispatch(changeCompose('kept draft'));

    store.dispatch({
      type: REDRAFT,
      status: externalStatus,
      raw_text: 'Imported article',
      replyStatus: null,
      context_references: ImmutableList(),
    });
    store.dispatch({
      type: REDRAFT,
      status: fromJS({
        id: 'masked',
        visibility: 'direct',
        visibility_ex: 'external',
        text: 'Imported article',
        media_attachments: [{ id: 'm-masked', type: 'image' }],
      }),
      raw_text: 'Imported article',
      replyStatus: null,
      context_references: ImmutableList(),
    });
    store.dispatch({
      type: REDRAFT,
      status: fromJS({
        id: 'extension',
        visibility: 'public',
        fedibird_external: { protocol: 'rss' },
        text: 'Imported article',
        media_attachments: [{ id: 'm-ext-2', type: 'image' }],
      }),
      raw_text: 'Imported article',
      replyStatus: null,
      context_references: ImmutableList(),
    });

    expect(store.getState().getIn(['compose', 'text'])).toBe('kept draft');
    expect(store.getState().getIn(['compose', 'media_attachments']).size).toBe(0);
  });

  it('still redrafts an ordinary status when the stream delete arrives first', async () => {
    const { store, actions } = makeStore(ImmutableMap({
      'status-1': ordinaryStatus,
      keep: fromJS({ id: 'keep', account: '1' }),
    }));
    let resolveDelete;
    client.delete.mockReturnValue(new Promise(resolve => {
      resolveDelete = resolve;
    }));

    const pending = store.dispatch(deleteStatus('status-1', { push: jest.fn() }, true));
    store.dispatch(deleteFromTimelines('status-1'));
    store.dispatch(deleteFromTimelines('status-1'));
    resolveDelete({
      data: {
        text: 'fresh body',
        account: accountPayload,
      },
    });
    await pending;

    expect(client.delete).toHaveBeenCalledWith('/api/v1/statuses/status-1', { params: { redraft: true } });
    expect(actions.some(action => action.type === ACCOUNTS_IMPORT)).toBe(true);
    expect(actions.some(action => action.type === 'STATUS_DELETE_FAIL')).toBe(false);
    expect(store.getState().get('alerts').size).toBe(0);
    expect(store.getState().getIn(['compose', 'text'])).toBe('fresh body');
    expect(store.getState().getIn(['compose', 'media_attachments']).size).toBe(1);
    expect(store.getState().getIn(['timelines', 'home', 'items']).includes('status-1')).toBe(false);
    expect(store.getState().get('statuses').has('status-1')).toBe(false);
  });

  it('clears an existing quote and ignores ids that are not in the state', () => {
    const { store } = makeStore(ImmutableMap({
      'ext-1': externalStatus,
      quoted: fromJS({ id: 'quoted', quote_id: 'ext-1', quote: 'ext-1', account: '1' }),
    }));

    expect(() => store.dispatch({
      type: 'TIMELINE_DELETE',
      id: 'ext-1',
      references: ['missing-reblog'],
      quotes: ['quoted', 'missing-quote'],
    })).not.toThrow();

    expect(store.getState().get('statuses').has('ext-1')).toBe(false);
    expect(store.getState().get('statuses').has('missing-reblog')).toBe(false);
    expect(store.getState().get('statuses').has('missing-quote')).toBe(false);
    expect(store.getState().getIn(['statuses', 'quoted', 'quote_id'])).toBeNull();
    expect(store.getState().getIn(['statuses', 'quoted', 'quote'])).toBeNull();
    expect(store.getState().getIn(['timelines', 'home', 'items']).includes('ext-1')).toBe(false);
    expect(store.getState().getIn(['timelines', 'list:9', 'items']).includes('ext-1')).toBe(false);
    expect(store.getState().getIn(['timelines', 'weird', 'items']).includes('ext-1')).toBe(false);
    expect(store.getState().getIn(['timelines', 'broken'])).toBe('nope');
  });
});
