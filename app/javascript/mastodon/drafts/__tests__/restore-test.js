import { List as ImmutableList, Map as ImmutableMap } from 'immutable';
import { applyMiddleware, createStore } from 'redux';
import thunk from 'redux-thunk';
import { changeCompose } from '../../actions/compose';
import composer from '../../reducers/composer';
import { resolveDraftTargets } from '../restore';

jest.mock('../../api', () => {
  const requests = [];
  const api = jest.fn(() => ({
    get: (url) => new Promise((resolve, reject) => {
      requests.push({ url: String(url), resolve, reject });
    }),
  }));

  api.requests = requests;

  return api;
});

jest.mock('../../actions/importer', () => ({
  importFetchedStatus: (status) => ({ type: 'IMPORT_FETCHED_STATUS', status }),
}));

import api from '../../api';

function storeFor (composeState) {
  const actions = [];
  const store = createStore(
    (state = ImmutableMap({ compose: composeState }), action) => {
      actions.push(action);

      return state.set('compose', composer(state.get('compose'), action));
    },
    applyMiddleware(thunk),
  );

  return { store, actions };
}

function settle () {
  return new Promise((resolve) => {
    setTimeout(resolve, 0);
  });
}

describe('resolveDraftTargets', () => {
  beforeEach(() => {
    api.requests.length = 0;
  });

  it('loads a reply and records a failure without clearing a newer restore', async () => {
    const composeState = composer(undefined, { type: '@@INIT' }).merge({
      draftRestoreToken: 'restore-1',
      in_reply_to: 'reply-1',
      quote_from: 'missing',
      draftReplyHold: 'pending',
      draftQuoteHold: 'pending',
    });
    const { store, actions } = storeFor(composeState);

    store.dispatch(resolveDraftTargets('primary', {
      input: { in_reply_to_id: 'reply-1', quote_id: 'missing' },
    }, 'restore-1'));
    api.requests.find(request => request.url.indexOf('reply-1') !== -1).resolve({
      data: { id: 'reply-1', visibility: 'public', url: 'https://example.test/reply-1' },
    });
    api.requests.find(request => request.url.indexOf('missing') !== -1).reject(new Error('not found'));
    await settle();

    const next = store.getState().get('compose');
    const imported = actions.filter(action => action.type === 'IMPORT_FETCHED_STATUS');

    expect(imported.map(action => action.status.id)).toEqual(['reply-1']);
    expect(next.get('draftReplyHold')).toBeNull();
    expect(next.getIn(['reply_status', 'id'])).toBe('reply-1');
    expect(next.get('draftQuoteHold')).toBe('failed');
  });

  it('applies a reply result after the post idempotency key changes', async () => {
    const composeState = composer(undefined, { type: '@@INIT' }).merge({
      idempotencyKey: 'post-1',
      draftRestoreToken: 'restore-1',
      text: 'Hello',
      in_reply_to: 'reply-1',
      draftReplyHold: 'pending',
    });
    const { store } = storeFor(composeState);

    store.dispatch(resolveDraftTargets('primary', {
      input: { in_reply_to_id: 'reply-1' },
    }, 'restore-1'));
    store.dispatch(changeCompose('Hello!'));
    expect(store.getState().getIn(['compose', 'idempotencyKey'])).not.toBe('post-1');
    expect(store.getState().getIn(['compose', 'draftReplyHold'])).toBe('pending');

    api.requests.find(request => request.url.indexOf('reply-1') !== -1).resolve({
      data: { id: 'reply-1', visibility: 'public' },
    });
    await settle();

    expect(store.getState().getIn(['compose', 'text'])).toBe('Hello!');
    expect(store.getState().getIn(['compose', 'draftReplyHold'])).toBeNull();
    expect(store.getState().getIn(['compose', 'reply_status', 'id'])).toBe('reply-1');
  });

  it('ignores a reply result after the reply target changes', async () => {
    const composeState = composer(undefined, { type: '@@INIT' }).merge({
      draftRestoreToken: 'restore-1',
      text: 'Hello',
      in_reply_to: 'reply-1',
      draftReplyHold: 'pending',
    });
    const { store } = storeFor(composeState);

    store.dispatch(resolveDraftTargets('primary', {
      input: { in_reply_to_id: 'reply-1' },
    }, 'restore-1'));
    store.dispatch({
      type: 'COMPOSE_REPLY',
      status: ImmutableMap({
        id: 'reply-2',
        visibility: 'public',
        spoiler_text: '',
        language: 'en',
        mentions: ImmutableList(),
      }),
    });

    api.requests[0].resolve({
      data: { id: 'reply-1', visibility: 'public' },
    });
    await settle();

    const next = store.getState().get('compose');

    expect(next.get('in_reply_to')).toBe('reply-2');
    expect(next.get('draftReplyHold')).toBeNull();
    expect(next.get('draftRestoreToken')).toBeNull();
    expect(next.getIn(['reply_status', 'id'])).toBe('reply-2');
  });
});
