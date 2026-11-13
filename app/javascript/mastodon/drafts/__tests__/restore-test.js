import { Map as ImmutableMap } from 'immutable';
import { applyMiddleware, createStore } from 'redux';
import thunk from 'redux-thunk';
import { COMPOSER_DRAFT_TARGET } from '../../actions/composer';
import composer from '../../reducers/composer';
import { resolveDraftTargets } from '../restore';

jest.mock('../../api', () => jest.fn(() => ({
  get: (url) => {
    if (String(url).indexOf('missing') !== -1) {
      return Promise.reject(new Error('not found'));
    }

    return Promise.resolve({
      data: {
        id: 'reply-1',
        visibility: 'public',
        url: 'https://example.test/reply-1',
      },
    });
  },
})));

jest.mock('../../actions/importer', () => ({
  importFetchedStatus: (status) => ({ type: 'IMPORT_FETCHED_STATUS', status }),
}));

function storeFor (composeState) {
  const actions = [];
  const store = createStore(
    (state = ImmutableMap({ compose: composeState }), action) => {
      actions.push(action);

      if (action.type === COMPOSER_DRAFT_TARGET || action.type === 'COMPOSER_DRAFT_RESTORE') {
        return state.set('compose', composer(state.get('compose'), action));
      }

      return state;
    },
    applyMiddleware(thunk),
  );

  return { store, actions };
}

describe('resolveDraftTargets', () => {
  it('loads a reply and records a failure without clearing a newer restore', async () => {
    const composeState = composer(undefined, { type: '@@INIT' }).merge({
      idempotencyKey: 'restore-1',
      in_reply_to: 'reply-1',
      quote_from: 'missing',
      draftReplyHold: 'pending',
      draftQuoteHold: 'pending',
    });
    const { store, actions } = storeFor(composeState);

    store.dispatch(resolveDraftTargets('primary', {
      input: { in_reply_to_id: 'reply-1', quote_id: 'missing' },
    }, 'restore-1'));
    await new Promise((resolve) => {
      setTimeout(resolve, 0);
    });

    const next = store.getState().get('compose');
    const imported = actions.filter(action => action.type === 'IMPORT_FETCHED_STATUS');

    expect(imported.map(action => action.status.id)).toEqual(['reply-1']);
    expect(next.get('draftReplyHold')).toBeNull();
    expect(next.getIn(['reply_status', 'id'])).toBe('reply-1');
    expect(next.get('draftQuoteHold')).toBe('failed');
  });
});
