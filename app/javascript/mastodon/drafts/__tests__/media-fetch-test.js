import { Map as ImmutableMap } from 'immutable';
import { applyMiddleware, createStore } from 'redux';
import thunk from 'redux-thunk';
import { COMPOSE_RESET } from '../../actions/compose';
import { COMPOSER_DRAFT_RESTORE, createComposer, destroyComposer, targetComposerAction } from '../../actions/composer';
import compose from '../../reducers/compose';
import composers from '../../reducers/composers';
import { resolveDraftMedia } from '../media';

jest.mock('../../api', () => {
  const requests = [];
  const api = jest.fn(() => ({
    get: (url, config) => new Promise((resolve, reject) => {
      requests.push({ url: String(url), config: config || {}, resolve, reject });
    }),
  }));

  api.requests = requests;

  return api;
});

import api from '../../api';

const serverMedia = {
  id: '501',
  type: 'image',
  url: 'https://example.test/501.jpg',
  preview_url: 'https://example.test/501-small.jpg',
  description: 'server alt',
  meta: { focus: { x: 0.1, y: 0.2 } },
};

function draftSnapshot (senderId) {
  const input = {
    text: 'Hello',
    media: [
      { id: '501', order: 0, description: 'draft alt', focus: { x: 0.2, y: -0.4 } },
    ],
  };

  if (senderId) {
    input.sender = { id: senderId, selection_origin: 'explicit' };
  }

  return {
    schema_version: 1,
    account_id: '42',
    client_draft_uuid: '11111111-1111-4111-8111-111111111111',
    input,
  };
}

function makeStore () {
  return createStore(
    (state = ImmutableMap(), action) => state
      .set('compose', compose(state.get('compose'), action))
      .set('composers', composers(state.get('composers'), action)),
    applyMiddleware(thunk),
  );
}

function restore (store, composerId, snapshot, restoreToken) {
  store.dispatch(targetComposerAction({
    type: COMPOSER_DRAFT_RESTORE,
    snapshot,
    restoreToken,
  }, composerId));
}

describe('resolveDraftMedia', () => {
  beforeEach(() => {
    api.requests.length = 0;
  });

  it('loads the signed-in account file when the draft has no sender', async () => {
    const store = makeStore();
    const snapshot = draftSnapshot(null);

    restore(store, 'primary', snapshot, 'restore-1');
    const pending = store.dispatch(resolveDraftMedia('primary', snapshot, 'restore-1'));

    expect(api.requests.map(request => [request.url, request.config.params])).toEqual([
      ['/api/v1/media/501', undefined],
    ]);
    api.requests[0].resolve({ status: 200, data: serverMedia });
    await pending;

    const media = store.getState().getIn(['compose', 'media_attachments', 0]);

    expect(media.get('unresolved')).toBe(false);
    expect(media.get('description')).toBe('draft alt');
    expect(media.getIn(['meta', 'focus', 'x'])).toBe(0.2);
  });

  it('asks for the saved delegated sender and keeps the draft alt', async () => {
    const store = makeStore();
    const snapshot = draftSnapshot('delegated:9');

    restore(store, 'primary', snapshot, 'restore-1');
    const pending = store.dispatch(resolveDraftMedia('primary', snapshot, 'restore-1'));

    expect(api.requests[0].config.params).toEqual({ posting_identity_id: 'delegated:9' });
    api.requests[0].resolve({ status: 200, data: serverMedia });
    await pending;

    const media = store.getState().getIn(['compose', 'media_attachments', 0]);

    expect(media.get('unresolved')).toBe(false);
    expect(media.get('description')).toBe('draft alt');
    expect(media.get('url')).toBe('https://example.test/501.jpg');
  });

  it('passes a saved local sender through the same parameter', async () => {
    const store = makeStore();
    const snapshot = draftSnapshot('local:42');

    restore(store, 'primary', snapshot, 'restore-1');
    store.dispatch(resolveDraftMedia('primary', snapshot, 'restore-1'));

    expect(api.requests[0].config.params).toEqual({ posting_identity_id: 'local:42' });
  });

  it('leaves the file unresolved when the media request is forbidden or missing', async () => {
    const forbidden = makeStore();
    const missing = makeStore();
    const snapshot = draftSnapshot('delegated:9');

    restore(forbidden, 'primary', snapshot, 'restore-1');
    restore(missing, 'primary', snapshot, 'restore-1');
    const forbiddenPending = forbidden.dispatch(resolveDraftMedia('primary', snapshot, 'restore-1'));
    const missingPending = missing.dispatch(resolveDraftMedia('primary', snapshot, 'restore-1'));

    api.requests[0].reject({ response: { status: 403 } });
    api.requests[1].reject({ response: { status: 404 } });
    await Promise.all([forbiddenPending, missingPending]);

    expect(forbidden.getState().getIn(['compose', 'media_attachments', 0, 'unresolved'])).toBe(true);
    expect(missing.getState().getIn(['compose', 'media_attachments', 0, 'unresolved'])).toBe(true);
  });

  it('ignores a late file after discard and does not restore another composer', async () => {
    const store = makeStore();
    const snapshot = draftSnapshot('delegated:9');

    store.dispatch(createComposer('column-a'));
    store.dispatch(createComposer('column-b'));
    restore(store, 'column-a', snapshot, 'restore-a');
    const pending = store.dispatch(resolveDraftMedia('column-a', snapshot, 'restore-a'));

    store.dispatch(targetComposerAction({ type: COMPOSE_RESET }, 'column-a'));
    api.requests[0].resolve({ status: 200, data: serverMedia });
    await pending;

    expect(store.getState().getIn(['composers', 'byId', 'column-a', 'media_attachments']).some(item => item.get('id') === '501')).toBe(false);
    expect(store.getState().getIn(['composers', 'byId', 'column-b', 'media_attachments']).size).toBe(0);

    store.dispatch(destroyComposer('column-a'));
    store.dispatch(createComposer('column-a'));
    restore(store, 'column-a', snapshot, 'restore-b');
    const other = store.dispatch(resolveDraftMedia('column-b', snapshot, 'restore-b'));

    api.requests[1].resolve({ status: 200, data: serverMedia });
    await other;

    expect(store.getState().getIn(['composers', 'byId', 'column-a', 'media_attachments', 0, 'unresolved'])).toBe(true);
    expect(store.getState().getIn(['composers', 'byId', 'column-b', 'media_attachments']).size).toBe(0);
  });
});
