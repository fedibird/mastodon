import { Map as ImmutableMap, fromJS } from 'immutable';
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
import { COMPOSE_SET_STATUS, changeComposerUpload, submitComposer, uploadComposerThumbnail } from '../compose';
import { createComposer, destroyComposer, targetComposerAction } from '../composer';
import { COMPOSE_REDAFT_MEDIA_STATUS, composerRedraftBlocksSubmit, composerRedraftNotice, prepareRedraftMedia, resetRedraftMediaRuntime, retryRedraftMedia } from '../redraft_media';
import { REDRAFT, deleteStatus } from '../statuses';
import alerts from '../../reducers/alerts';
import compose from '../../reducers/compose';
import composers from '../../reducers/composers';

const flush = async () => {
  for (let i = 0; i < 20; i += 1) {
    await Promise.resolve();
  }
};

const media = (id, extra = {}) => fromJS({
  id,
  type: 'image',
  description: 'old alt',
  meta: { focus: { x: 0.1, y: -0.2 } },
  url: `https://example.test/${id}.jpg`,
  ...extra,
});

const statusWithMedia = (id = 'm1') => fromJS({
  id: 'status-1',
  text: 'body',
  spoiler_text: '',
  visibility: 'public',
  language: 'en',
  media_attachments: [media(id).toJS()],
  account: { id: '1' },
});

const reducer = combineReducers({
  compose,
  composers,
  statuses: (state = ImmutableMap()) => state,
  accounts: (state = ImmutableMap()) => state,
  timelines: (state = ImmutableMap()) => state,
  meta: (state = ImmutableMap()) => state,
  polls: (state = ImmutableMap()) => state,
});

const makeStore = () => createStore(reducer, applyMiddleware(thunk));

const primaryMedia = (store, id = 'm1') => (
  store.getState().getIn(['compose', 'media_attachments']).find(item => item.get('id') === id)
);

const composerRecord = (state, composerId = 'primary') => (
  composerId === 'primary' ? state.get('compose') : state.getIn(['composers', 'byId', composerId])
);

const redraftIdentity = (state, composerId = 'primary') => {
  const composer = composerRecord(state, composerId);

  return {
    epoch: composer.get('redraftEpoch'),
    generation: composer.get('redraftGeneration'),
  };
};

describe('redraft media reuse', () => {
  let store;
  let client;

  beforeEach(() => {
    jest.useFakeTimers('modern');
    store = makeStore();
    client = {
      get: jest.fn(),
      put: jest.fn(),
      delete: jest.fn(),
      request: jest.fn(),
    };
    api.mockImplementation(() => client);
    window.innerWidth = 1200;
  });

  afterEach(() => {
    resetRedraftMediaRuntime();
    jest.useRealTimers();
  });

  const redraft = (extra = {}) => {
    store.dispatch({
      type: REDRAFT,
      status: statusWithMedia(),
      raw_text: 'body',
      replyStatus: null,
      context_references: null,
      reuseMedia: true,
      ownerIdentityId: 'local:1',
      ...extra,
    });
  };

  it('marks redraft media unattached and waiting, and keeps edit media attached', () => {
    redraft();

    expect(primaryMedia(store).get('unattached')).toBe(true);
    expect(primaryMedia(store).get('redraftReuse')).toEqual('waiting');
    expect(primaryMedia(store).get('description')).toEqual('old alt');
    expect(primaryMedia(store).get('ownerIdentityId')).toEqual('local:1');
    expect(primaryMedia(store).get('order')).toEqual(0);

    const editing = compose(store.getState().get('compose'), {
      type: COMPOSE_SET_STATUS,
      text: 'edited',
      spoiler_text: '',
      status: statusWithMedia('edit-media'),
    });

    expect(editing.getIn(['media_attachments', 0, 'unattached'])).toBe(false);
    expect(editing.getIn(['media_attachments', 0, 'redraftReuse'])).toBeUndefined();
  });

  it('keeps a scheduled redraft unattached without the reuse wait', () => {
    store.dispatch({
      type: REDRAFT,
      status: statusWithMedia().set('scheduled_at', '2026-01-01T00:00:00Z'),
      raw_text: 'later',
      reuseMedia: false,
    });

    expect(primaryMedia(store).get('unattached')).toBe(true);
    expect(primaryMedia(store).get('redraftReuse')).toBeUndefined();
  });

  it('keeps ALT typed during a 404 and saves it once the media is free', async () => {
    client.get
      .mockRejectedValueOnce(Object.assign(new Error('missing'), { response: { status: 404 } }))
      .mockResolvedValueOnce({
        status: 200,
        data: { id: 'm1', type: 'image', description: 'old alt', meta: { focus: { x: 0.1, y: -0.2 } }, url: 'https://example.test/m1.jpg' },
      });
    client.put.mockResolvedValue({
      status: 200,
      data: { id: 'm1', type: 'image', description: 'new alt', meta: { focus: { x: 0.4, y: -0.5 } }, url: 'https://example.test/m1.jpg' },
    });

    redraft();
    store.dispatch(prepareRedraftMedia('primary'));
    await flush();

    store.dispatch(changeComposerUpload('primary', 'm1', { description: 'new alt', focus: '0.40,-0.50' }));

    expect(primaryMedia(store).get('description')).toEqual('new alt');
    expect(primaryMedia(store).get('redraftReuse')).toEqual('waiting');
    expect(client.put).not.toHaveBeenCalled();

    jest.advanceTimersByTime(500);
    await flush();

    expect(client.put).toHaveBeenCalledWith('/api/v1/media/m1', {
      description: 'new alt',
      focus: '0.40,-0.50',
    }, { timeout: 30_000 });
    expect(primaryMedia(store).get('description')).toEqual('new alt');
    expect(primaryMedia(store).get('redraftReuse')).toEqual('complete');
    expect(store.getState().getIn(['compose', 'text'])).toEqual('body');
  });

  it('saves the latest ALT when edits overlap an older response', async () => {
    let finishFirst;
    client.put
      .mockImplementationOnce(() => new Promise(resolve => {
        finishFirst = resolve;
      }))
      .mockResolvedValueOnce({
        status: 200,
        data: { id: 'm1', type: 'image', description: 'second', meta: { focus: { x: 0.3, y: 0.3 } } },
      });

    redraft();
    store.dispatch(targetComposerAction({
      type: COMPOSE_REDAFT_MEDIA_STATUS,
      mediaId: 'm1',
      reuse: 'complete',
      fetched: true,
      error: null,
      ...redraftIdentity(store.getState()),
    }, 'primary'));

    store.dispatch(changeComposerUpload('primary', 'm1', { description: 'first', focus: '0.10,-0.20' }));
    store.dispatch(changeComposerUpload('primary', 'm1', { description: 'second', focus: '0.30,0.30' }));
    expect(primaryMedia(store).get('description')).toEqual('second');

    finishFirst({ status: 200, data: { id: 'm1', type: 'image', description: 'first', meta: { focus: { x: 0.1, y: -0.2 } } } });
    await flush();

    expect(primaryMedia(store).get('description')).toEqual('second');
    expect(client.put).toHaveBeenLastCalledWith('/api/v1/media/m1', {
      description: 'second',
      focus: '0.30,0.30',
    }, { timeout: 30_000 });
    expect(primaryMedia(store).get('redraftReuse')).toEqual('complete');
  });

  it('blocks publishing until every redraft attachment is complete', async () => {
    client.get.mockImplementation(url => {
      if (url.endsWith('/m2')) {
        return Promise.reject(Object.assign(new Error('missing'), { response: { status: 404 } }));
      }

      return Promise.resolve({
        status: 200,
        data: { id: 'm1', type: 'image', description: 'old alt', meta: { focus: { x: 0.1, y: -0.2 } } },
      });
    });
    client.request.mockResolvedValue({ data: { id: 'new', visibility: 'public', in_reply_to_id: null, scheduled_at: null, tags: [], account: { id: '1' } } });

    store.dispatch({
      type: REDRAFT,
      status: fromJS({
        id: 'status-1',
        text: 'body',
        spoiler_text: '',
        visibility: 'public',
        media_attachments: [media('m1').toJS(), media('m2', { description: 'second' }).toJS()],
      }),
      raw_text: 'body',
      reuseMedia: true,
    });
    store.dispatch(prepareRedraftMedia('primary'));
    await flush();

    expect(primaryMedia(store, 'm1').get('redraftReuse')).toEqual('complete');
    expect(primaryMedia(store, 'm2').get('redraftReuse')).toEqual('waiting');
    expect(store.getState().getIn(['compose', 'media_attachments']).size).toEqual(2);

    await store.dispatch(submitComposer('primary', { push: jest.fn(), goBack: jest.fn() }));
    expect(client.request).not.toHaveBeenCalled();

    client.get.mockResolvedValue({
      status: 200,
      data: { id: 'm2', type: 'image', description: 'second', meta: { focus: { x: 0.1, y: -0.2 } } },
    });
    jest.advanceTimersByTime(500);
    await flush();

    expect(primaryMedia(store, 'm2').get('redraftReuse')).toEqual('complete');
    await store.dispatch(submitComposer('primary', { push: jest.fn(), goBack: jest.fn(), location: { pathname: '/home' } }));
    expect(client.request).toHaveBeenCalledWith(expect.objectContaining({
      method: 'post',
      data: expect.objectContaining({
        status: 'body',
        media_ids: expect.anything(),
      }),
    }));
    const sentIds = client.request.mock.calls[0][0].data.media_ids.toArray();
    expect(sentIds).toEqual(['m1', 'm2']);
  });

  it('keeps ALT when saving fails and refuses to publish', async () => {
    client.put.mockRejectedValue(Object.assign(new Error('nope'), { response: { status: 500, data: { error: 'nope' } } }));

    redraft();
    store.dispatch(targetComposerAction({
      type: COMPOSE_REDAFT_MEDIA_STATUS,
      mediaId: 'm1',
      reuse: 'complete',
      fetched: true,
      error: null,
      ...redraftIdentity(store.getState()),
    }, 'primary'));
    store.dispatch(changeComposerUpload('primary', 'm1', { description: 'kept alt', focus: '0.20,0.20' }));
    await flush();

    expect(primaryMedia(store).get('description')).toEqual('kept alt');
    expect(primaryMedia(store).get('redraftReuse')).toEqual('failed');
    expect(primaryMedia(store).get('redraftError')).toEqual('save');
    expect(store.getState().getIn(['compose', 'text'])).toEqual('body');

    await store.dispatch(submitComposer('primary', { push: jest.fn(), goBack: jest.fn() }));
    expect(client.request).not.toHaveBeenCalled();
  });

  it('does not treat 403 as a wait and stops after the prepare timeout', async () => {
    client.get.mockRejectedValue(Object.assign(new Error('denied'), { response: { status: 403 } }));
    redraft();
    store.dispatch(changeComposerUpload('primary', 'm1', { description: 'typed', focus: '0.20,0.20' }));
    store.dispatch(prepareRedraftMedia('primary'));
    await flush();

    expect(primaryMedia(store).get('redraftReuse')).toEqual('failed');
    expect(primaryMedia(store).get('redraftError')).toEqual('forbidden');
    expect(primaryMedia(store).get('description')).toEqual('typed');

    const calls = client.get.mock.calls.length;
    jest.advanceTimersByTime(60_000);
    await flush();
    expect(client.get).toHaveBeenCalledTimes(calls);
  });

  it('stops waiting when the limit is reached and can be retried', async () => {
    client.get.mockRejectedValue(Object.assign(new Error('missing'), { response: { status: 404 } }));
    redraft();
    store.dispatch(changeComposerUpload('primary', 'm1', { description: 'typed', focus: '0.20,0.20' }));
    store.dispatch(prepareRedraftMedia('primary'));
    await flush();
    jest.advanceTimersByTime(60_000);
    await flush();

    expect(primaryMedia(store).get('redraftReuse')).toEqual('failed');
    expect(primaryMedia(store).get('redraftError')).toEqual('prepare');
    expect(primaryMedia(store).get('description')).toEqual('typed');
    expect(client.get.mock.calls.length).toBeLessThan(20);

    client.get.mockResolvedValue({
      status: 200,
      data: { id: 'm1', type: 'image', description: 'old alt', meta: { focus: { x: 0.2, y: 0.2 } } },
    });
    client.put.mockResolvedValue({
      status: 200,
      data: { id: 'm1', type: 'image', description: 'typed', meta: { focus: { x: 0.2, y: 0.2 } } },
    });
    store.dispatch(retryRedraftMedia('primary'));
    await flush();

    expect(primaryMedia(store).get('description')).toEqual('typed');
    expect(primaryMedia(store).get('redraftReuse')).toEqual('complete');
  });

  it('stops a removed attachment and ignores a response after the composer is cleared', async () => {
    let finishGet;
    client.get.mockImplementation(() => new Promise(resolve => {
      finishGet = resolve;
    }));
    redraft();
    store.dispatch(prepareRedraftMedia('primary'));
    store.dispatch({ type: 'COMPOSE_UPLOAD_UNDO', media_id: 'm1' });

    finishGet({ status: 200, data: { id: 'm1', type: 'image', description: 'server', meta: {} } });
    await flush();

    expect(store.getState().getIn(['compose', 'media_attachments']).size).toEqual(0);
    expect(store.getState().getIn(['compose', 'text'])).toEqual('body');

    let finishLate;
    client.get.mockImplementation(() => new Promise(resolve => {
      finishLate = resolve;
    }));
    redraft();
    store.dispatch(prepareRedraftMedia('primary'));
    store.dispatch({ type: 'COMPOSE_SUBMIT_SUCCESS', status: { id: 'posted' } });

    finishLate({ status: 200, data: { id: 'm1', type: 'image', description: 'late', meta: {} } });
    await flush();

    expect(store.getState().getIn(['compose', 'media_attachments']).size).toEqual(0);
    expect(store.getState().getIn(['compose', 'text'])).toEqual('');
  });

  it('does not mix two composers', async () => {
    client.put.mockResolvedValue({
      status: 200,
      data: { id: 'm-a', type: 'image', description: 'from a', meta: { focus: { x: 0, y: 0 } } },
    });

    store.dispatch(createComposer('composer-a'));
    store.dispatch(createComposer('composer-b'));
    store.dispatch(targetComposerAction({
      type: REDRAFT,
      status: statusWithMedia('m-a'),
      raw_text: 'aaa',
      reuseMedia: true,
    }, 'composer-a'));
    store.dispatch(targetComposerAction({
      type: REDRAFT,
      status: statusWithMedia('m-b'),
      raw_text: 'bbb',
      reuseMedia: true,
    }, 'composer-b'));
    store.dispatch(targetComposerAction({
      type: COMPOSE_REDAFT_MEDIA_STATUS,
      mediaId: 'm-a',
      reuse: 'complete',
      fetched: true,
      error: null,
      ...redraftIdentity(store.getState(), 'composer-a'),
    }, 'composer-a'));

    store.dispatch(changeComposerUpload('composer-a', 'm-a', { description: 'from a', focus: '0.00,0.00' }));
    await flush();

    expect(store.getState().getIn(['composers', 'byId', 'composer-a', 'media_attachments', 0, 'description'])).toEqual('from a');
    expect(store.getState().getIn(['composers', 'byId', 'composer-b', 'media_attachments', 0, 'description'])).toEqual('old alt');
    expect(store.getState().getIn(['composers', 'byId', 'composer-b', 'text'])).toEqual('bbb');
  });

  it('asks for an explicit redraft and shows the reported-post error before removal', async () => {
    const posted = fromJS({
      id: 'status-9',
      text: 'body',
      spoiler_text: '',
      media_attachments: [media('m9').toJS()],
      account: '1',
    });
    const reportedStore = createStore(combineReducers({
      compose,
      composers,
      alerts,
      statuses: (state = ImmutableMap({ 'status-9': posted })) => state,
      accounts: (state = ImmutableMap({ 1: ImmutableMap({ id: '1' }) })) => state,
      timelines: (state = ImmutableMap()) => state,
      meta: (state = ImmutableMap()) => state,
      polls: (state = ImmutableMap()) => state,
    }), applyMiddleware(thunk));

    client.delete.mockRejectedValue({ response: { status: 409, data: { error: 'reported' } } });

    await reportedStore.dispatch(deleteStatus('status-9', { push: jest.fn() }, true));
    await flush();

    expect(client.delete).toHaveBeenCalledWith('/api/v1/statuses/status-9', { params: { redraft: true } });
    expect(reportedStore.getState().getIn(['compose', 'text'])).toEqual('');
    expect(reportedStore.getState().getIn(['alerts', 0]).get('message').id).toEqual('compose.redraft_media.reported');
    expect(reportedStore.getState().getIn(['statuses', 'status-9', 'text'])).toEqual('body');
  });

  const accountPayload = {
    id: '1',
    username: 'admin',
    acct: 'admin',
    display_name: 'Admin',
    note: '',
    followed_message: '',
    url: 'https://example.test/@admin',
    emojis: [],
  };

  const redraftStore = posted => createStore(combineReducers({
    compose,
    composers,
    alerts,
    statuses: (state = ImmutableMap({ 'status-1': posted, parent: fromJS({ id: 'parent', account: '1', status_reference_ids: [] }) })) => state,
    accounts: (state = ImmutableMap({ 1: ImmutableMap({ id: '1' }) })) => state,
    timelines: (state = ImmutableMap()) => state,
    meta: (state = ImmutableMap()) => state,
    polls: (state = ImmutableMap()) => state,
  }), applyMiddleware(thunk));

  it('restores ALT, focus, and order from the delete response instead of the cached status', async () => {
    const posted = fromJS({
      id: 'status-1',
      text: 'stale body',
      spoiler_text: '',
      in_reply_to_id: 'parent',
      quote: { id: 'q1', url: 'https://example.test/q/1' },
      status_reference_ids: [],
      media_attachments: [
        media('m1', { description: 'stale one' }).toJS(),
        media('m2', { description: 'stale two' }).toJS(),
      ],
      account: '1',
    });
    const freshStore = redraftStore(posted);

    client.delete.mockResolvedValue({
      data: {
        text: 'fresh body',
        account: accountPayload,
        media_attachments: [
          { id: 'm2', type: 'image', description: 'fresh two', meta: { focus: { x: 0.4, y: 0.2 } }, url: 'https://example.test/m2.jpg' },
          { id: 'm1', type: 'image', description: 'fresh one', meta: { focus: { x: -0.3, y: 0.1 } }, url: 'https://example.test/m1.jpg' },
        ],
      },
    });
    client.get.mockImplementation(() => new Promise(() => {}));

    await freshStore.dispatch(deleteStatus('status-1', { push: jest.fn() }, true));

    const attachments = freshStore.getState().getIn(['compose', 'media_attachments']);

    expect(freshStore.getState().getIn(['compose', 'text'])).toEqual('fresh body');
    expect(freshStore.getState().getIn(['compose', 'in_reply_to'])).toEqual('parent');
    expect(freshStore.getState().getIn(['compose', 'quote_from'])).toEqual('q1');
    expect(attachments.map(item => item.get('id')).toArray()).toEqual(['m2', 'm1']);
    expect(attachments.map(item => item.get('description')).toArray()).toEqual(['fresh two', 'fresh one']);
    expect(attachments.getIn([0, 'meta', 'focus', 'x'])).toEqual(0.4);
    expect(attachments.getIn([1, 'meta', 'focus', 'y'])).toEqual(0.1);
    expect(attachments.every(item => item.get('unattached') === true)).toBe(true);
  });

  it('keeps cached attachments visible and does not poll when the delete response has no media', async () => {
    const posted = fromJS({
      id: 'status-1',
      text: 'body',
      spoiler_text: '',
      status_reference_ids: [],
      media_attachments: [media('m1').toJS()],
      account: '1',
    });
    const freshStore = redraftStore(posted);

    client.delete.mockResolvedValue({
      data: { text: 'body', account: accountPayload },
    });

    await freshStore.dispatch(deleteStatus('status-1', { push: jest.fn() }, true));

    expect(freshStore.getState().getIn(['compose', 'media_attachments']).size).toEqual(1);
    expect(freshStore.getState().getIn(['compose', 'media_attachments', 0, 'description'])).toEqual('old alt');
    expect(freshStore.getState().getIn(['compose', 'media_attachments', 0, 'redraftReuse'])).toEqual('failed');
    expect(freshStore.getState().getIn(['compose', 'media_attachments', 0, 'redraftError'])).toEqual('prepare');
    expect(freshStore.getState().getIn(['compose', 'redraftMediaUnconfirmed'])).toBe(true);
    expect(composerRedraftNotice(freshStore.getState().get('compose'))).toEqual('prepare');
    expect(client.get).not.toHaveBeenCalled();

    await freshStore.dispatch(submitComposer('primary', { push: jest.fn(), goBack: jest.fn() }));
    expect(client.request).not.toHaveBeenCalled();
  });

  it('adopts the fetched ALT when the user has not edited and does not write the stale value back', async () => {
    client.get.mockResolvedValue({
      status: 200,
      data: { id: 'm1', type: 'image', description: 'server alt', meta: { focus: { x: 0.5, y: 0.5 } }, url: 'https://example.test/m1.jpg' },
    });

    redraft();
    store.dispatch(prepareRedraftMedia('primary'));
    await flush();

    expect(client.put).not.toHaveBeenCalled();
    expect(primaryMedia(store).get('description')).toEqual('server alt');
    expect(primaryMedia(store).getIn(['meta', 'focus', 'x'])).toEqual(0.5);
    expect(primaryMedia(store).get('redraftReuse')).toEqual('complete');
  });

  it('ignores an older redraft GET after the same attachment is redrafted again', async () => {
    let finishOld;
    client.get.mockImplementationOnce(() => new Promise(resolve => {
      finishOld = resolve;
    }));

    redraft();
    store.dispatch(prepareRedraftMedia('primary'));

    client.get.mockResolvedValue({
      status: 200,
      data: { id: 'm1', type: 'image', description: 'current alt', meta: { focus: { x: 0.1, y: -0.2 } } },
    });
    redraft();
    store.dispatch(prepareRedraftMedia('primary'));
    await flush();

    expect(primaryMedia(store).get('description')).toEqual('current alt');
    expect(primaryMedia(store).get('redraftReuse')).toEqual('complete');

    finishOld({ status: 200, data: { id: 'm1', type: 'image', description: 'from old get', meta: { focus: { x: 0, y: 0 } } } });
    await flush();

    expect(primaryMedia(store).get('description')).toEqual('current alt');
    expect(primaryMedia(store).get('redraftReuse')).toEqual('complete');
    expect(client.put).not.toHaveBeenCalled();
  });

  it('does not fail the new redraft when the previous prepare timer expires', async () => {
    client.get.mockImplementationOnce(() => new Promise(() => {}));
    redraft();
    store.dispatch(changeComposerUpload('primary', 'm1', { description: 'typed once', focus: '0.20,0.20' }));
    store.dispatch(prepareRedraftMedia('primary'));

    jest.advanceTimersByTime(20_000);
    await flush();

    client.get.mockResolvedValue({
      status: 200,
      data: { id: 'm1', type: 'image', description: 'second pass', meta: { focus: { x: 0.2, y: 0.2 } } },
    });
    redraft();
    store.dispatch(prepareRedraftMedia('primary'));
    await flush();

    expect(primaryMedia(store).get('description')).toEqual('second pass');
    expect(primaryMedia(store).get('redraftReuse')).toEqual('complete');

    jest.advanceTimersByTime(15_000);
    await flush();

    expect(primaryMedia(store).get('redraftReuse')).toEqual('complete');
    expect(primaryMedia(store).get('description')).toEqual('second pass');
    expect(primaryMedia(store).get('redraftError')).toBeNull();
  });

  it('keeps the new save in progress when an older PUT settles', async () => {
    let finishOld;
    client.put.mockImplementationOnce(() => new Promise(resolve => {
      finishOld = resolve;
    }));

    redraft();
    store.dispatch(targetComposerAction({
      type: COMPOSE_REDAFT_MEDIA_STATUS,
      mediaId: 'm1',
      reuse: 'complete',
      fetched: true,
      error: null,
      ...redraftIdentity(store.getState()),
    }, 'primary'));
    store.dispatch(changeComposerUpload('primary', 'm1', { description: 'old edit', focus: '0.10,-0.20' }));

    let finishNew;
    client.put.mockImplementationOnce(() => new Promise(resolve => {
      finishNew = resolve;
    }));
    redraft();
    store.dispatch(targetComposerAction({
      type: COMPOSE_REDAFT_MEDIA_STATUS,
      mediaId: 'm1',
      reuse: 'complete',
      fetched: true,
      error: null,
      ...redraftIdentity(store.getState()),
    }, 'primary'));
    store.dispatch(changeComposerUpload('primary', 'm1', { description: 'new edit', focus: '0.30,0.30' }));

    finishOld({ status: 200, data: { id: 'm1', type: 'image', description: 'old edit', meta: { focus: { x: 0.1, y: -0.2 } } } });
    await flush();

    expect(primaryMedia(store).get('description')).toEqual('new edit');
    expect(primaryMedia(store).get('redraftReuse')).toEqual('saving');

    finishNew({ status: 200, data: { id: 'm1', type: 'image', description: 'new edit', meta: { focus: { x: 0.3, y: 0.3 } } } });
    await flush();

    expect(primaryMedia(store).get('description')).toEqual('new edit');
    expect(primaryMedia(store).get('redraftReuse')).toEqual('complete');
  });

  it('fails a hung media lookup when the prepare limit elapses and ignores the late response', async () => {
    let finishLate;
    client.get.mockImplementation((url, config) => {
      expect(config.timeout).toBeGreaterThan(0);
      expect(config.timeout).toBeLessThanOrEqual(30_000);
      return new Promise(resolve => {
        finishLate = resolve;
      });
    });

    redraft();
    store.dispatch(changeComposerUpload('primary', 'm1', { description: 'typed', focus: '0.20,0.20' }));
    store.dispatch(prepareRedraftMedia('primary'));
    jest.advanceTimersByTime(30_000);
    await flush();

    expect(primaryMedia(store).get('redraftReuse')).toEqual('failed');
    expect(primaryMedia(store).get('redraftError')).toEqual('prepare');
    expect(primaryMedia(store).get('description')).toEqual('typed');

    finishLate({ status: 200, data: { id: 'm1', type: 'image', description: 'late', meta: { focus: { x: 0.2, y: 0.2 } } } });
    await flush();

    expect(primaryMedia(store).get('redraftReuse')).toEqual('failed');
    expect(primaryMedia(store).get('description')).toEqual('typed');
    expect(client.put).not.toHaveBeenCalled();
  });

  it('fails a hung description save after the request timeout and keeps the ALT', async () => {
    client.put.mockImplementation((url, params, config) => {
      expect(config.timeout).toEqual(30_000);
      return new Promise(() => {});
    });

    redraft();
    store.dispatch(targetComposerAction({
      type: COMPOSE_REDAFT_MEDIA_STATUS,
      mediaId: 'm1',
      reuse: 'complete',
      fetched: true,
      error: null,
      ...redraftIdentity(store.getState()),
    }, 'primary'));
    store.dispatch(changeComposerUpload('primary', 'm1', { description: 'kept alt', focus: '0.20,0.20' }));
    jest.advanceTimersByTime(30_000);
    await flush();

    expect(primaryMedia(store).get('description')).toEqual('kept alt');
    expect(primaryMedia(store).get('redraftReuse')).toEqual('failed');
    expect(primaryMedia(store).get('redraftError')).toEqual('save');
    expect(store.getState().getIn(['compose', 'text'])).toEqual('body');

    await store.dispatch(submitComposer('primary', { push: jest.fn(), goBack: jest.fn() }));
    expect(client.request).not.toHaveBeenCalled();
  });

  it('does not allow posting when the saved description does not match the composer', async () => {
    client.put.mockResolvedValue({
      status: 200,
      data: { id: 'm1', type: 'image', description: 'someone else', meta: { focus: { x: 0.2, y: 0.2 } } },
    });

    redraft();
    store.dispatch(targetComposerAction({
      type: COMPOSE_REDAFT_MEDIA_STATUS,
      mediaId: 'm1',
      reuse: 'complete',
      fetched: true,
      error: null,
      ...redraftIdentity(store.getState()),
    }, 'primary'));
    store.dispatch(changeComposerUpload('primary', 'm1', { description: 'mine', focus: '0.20,0.20' }));
    await flush();

    expect(primaryMedia(store).get('description')).toEqual('mine');
    expect(primaryMedia(store).get('redraftReuse')).toEqual('failed');
    expect(primaryMedia(store).get('redraftError')).toEqual('save');

    await store.dispatch(submitComposer('primary', { push: jest.fn(), goBack: jest.fn() }));
    expect(client.request).not.toHaveBeenCalled();
  });

  it('alerts when a thumbnail is chosen before the attachment is reusable', () => {
    redraft();
    store.dispatch(uploadComposerThumbnail('primary', 'm1', { size: 4, name: 'thumb.jpg' }));

    expect(client.put).not.toHaveBeenCalled();
    expect(store.getState().getIn(['compose', 'isUploadingThumbnail'])).not.toBe(true);
  });

  const postedStatus = mediaAttachments => fromJS({
    id: 'status-1',
    text: 'body',
    spoiler_text: '',
    status_reference_ids: [],
    media_attachments: mediaAttachments,
    account: '1',
  });

  const postedResponse = {
    data: { id: 'new', visibility: 'public', in_reply_to_id: null, scheduled_at: null, tags: [], account: { id: '1' } },
  };

  it('does not publish the one attachment returned when delete omits another cached image', async () => {
    const freshStore = redraftStore(postedStatus([
      media('m1', { description: 'cached one' }).toJS(),
      media('m2', { description: 'cached two' }).toJS(),
    ]));

    client.delete.mockResolvedValue({
      data: {
        text: 'body',
        account: accountPayload,
        media_attachments: [
          { id: 'm1', type: 'image', description: 'only this one', meta: {}, url: 'https://example.test/m1.jpg' },
        ],
      },
    });

    await freshStore.dispatch(deleteStatus('status-1', { push: jest.fn() }, true));

    const composer = freshStore.getState().get('compose');
    const attachments = composer.get('media_attachments');

    expect(attachments.map(item => item.get('id')).toArray()).toEqual(['m1', 'm2']);
    expect(attachments.map(item => item.get('description')).toArray()).toEqual(['cached one', 'cached two']);
    expect(attachments.every(item => item.get('redraftReuse') === 'failed' && item.get('redraftUnconfirmed') === true)).toBe(true);
    expect(composer.get('redraftMediaUnconfirmed')).toBe(true);
    expect(composerRedraftBlocksSubmit(composer)).toBe(true);
    expect(composerRedraftNotice(composer)).toEqual('prepare');
    expect(client.get).not.toHaveBeenCalled();

    await freshStore.dispatch(submitComposer('primary', { push: jest.fn(), goBack: jest.fn() }));
    expect(client.request).not.toHaveBeenCalled();
  });

  it('refuses a text post when delete omits the media list and the cache had no images', async () => {
    const freshStore = redraftStore(postedStatus([]));

    client.delete.mockResolvedValue({
      data: { text: 'body', account: accountPayload },
    });

    await freshStore.dispatch(deleteStatus('status-1', { push: jest.fn() }, true));

    const composer = freshStore.getState().get('compose');

    expect(composer.get('media_attachments').size).toEqual(0);
    expect(composer.get('text')).toEqual('body');
    expect(composer.get('redraftMediaUnconfirmed')).toBe(true);
    expect(composerRedraftBlocksSubmit(composer)).toBe(true);
    expect(composerRedraftNotice(composer)).toEqual('prepare');

    await freshStore.dispatch(submitComposer('primary', { push: jest.fn(), goBack: jest.fn() }));
    expect(client.request).not.toHaveBeenCalled();
  });

  it('treats a non-array or invalid delete media list as unconfirmed', async () => {
    const payloads = [
      { media_attachments: { id: 'm1' } },
      { media_attachments: [{ type: 'image', description: 'missing id' }] },
      { media_attachments: null },
    ];

    for (const mediaField of payloads) {
      const freshStore = redraftStore(postedStatus([media('m1', { description: 'cached' }).toJS()]));

      client.delete.mockResolvedValue({
        data: { text: 'body', account: accountPayload, ...mediaField },
      });

      await freshStore.dispatch(deleteStatus('status-1', { push: jest.fn() }, true));

      const composer = freshStore.getState().get('compose');

      expect(composer.get('media_attachments').map(item => item.get('description')).toArray()).toEqual(['cached']);
      expect(composer.get('redraftMediaUnconfirmed')).toBe(true);
      expect(composerRedraftBlocksSubmit(composer)).toBe(true);
      expect(client.get).not.toHaveBeenCalled();
      await freshStore.dispatch(submitComposer('primary', { push: jest.fn(), goBack: jest.fn() }));
    }

    expect(client.request).not.toHaveBeenCalled();
  });

  it('redrafts a text-only post when delete returns an empty media list', async () => {
    const freshStore = redraftStore(postedStatus([]));

    client.delete.mockResolvedValue({
      data: {
        text: 'only text',
        account: accountPayload,
        media_attachments: [],
      },
    });
    client.request.mockResolvedValue(postedResponse);

    await freshStore.dispatch(deleteStatus('status-1', { push: jest.fn() }, true));

    const composer = freshStore.getState().get('compose');

    expect(composer.get('media_attachments').size).toEqual(0);
    expect(composer.get('text')).toEqual('only text');
    expect(composer.get('redraftMediaUnconfirmed')).toBe(false);
    expect(composerRedraftBlocksSubmit(composer)).toBe(false);
    expect(composerRedraftNotice(composer)).toBeNull();

    await freshStore.dispatch(submitComposer('primary', { push: jest.fn(), goBack: jest.fn(), location: { pathname: '/home' } }));
    expect(client.request).toHaveBeenCalledWith(expect.objectContaining({
      method: 'post',
      data: expect.objectContaining({ status: 'only text' }),
    }));
  });

  it('keeps an unconfirmed redraft after explicit image removal until the composer is reset or redrafted from a complete list', async () => {
    const freshStore = redraftStore(postedStatus([
      media('m1').toJS(),
      media('m2').toJS(),
    ]));

    client.delete.mockResolvedValue({
      data: { text: 'body', account: accountPayload },
    });

    await freshStore.dispatch(deleteStatus('status-1', { push: jest.fn() }, true));
    freshStore.dispatch({ type: 'COMPOSE_UPLOAD_UNDO', media_id: 'm1' });

    expect(freshStore.getState().getIn(['compose', 'media_attachments']).size).toEqual(1);
    expect(freshStore.getState().getIn(['compose', 'redraftMediaUnconfirmed'])).toBe(true);
    expect(composerRedraftBlocksSubmit(freshStore.getState().get('compose'))).toBe(true);

    freshStore.dispatch({ type: 'COMPOSE_UPLOAD_UNDO', media_id: 'm2' });

    expect(freshStore.getState().getIn(['compose', 'media_attachments']).size).toEqual(0);
    expect(freshStore.getState().getIn(['compose', 'text'])).toEqual('body');
    expect(freshStore.getState().getIn(['compose', 'redraftMediaUnconfirmed'])).toBe(true);
    expect(composerRedraftNotice(freshStore.getState().get('compose'))).toEqual('prepare');

    await freshStore.dispatch(submitComposer('primary', { push: jest.fn(), goBack: jest.fn() }));
    expect(client.request).not.toHaveBeenCalled();

    freshStore.dispatch({ type: 'COMPOSE_SUBMIT_SUCCESS', status: { id: 'posted' } });

    expect(freshStore.getState().getIn(['compose', 'redraftMediaUnconfirmed'])).toBe(false);
    expect(freshStore.getState().getIn(['compose', 'media_attachments']).size).toEqual(0);
    expect(freshStore.getState().getIn(['compose', 'text'])).toEqual('');
    expect(composerRedraftBlocksSubmit(freshStore.getState().get('compose'))).toBe(false);

    freshStore.dispatch({
      type: REDRAFT,
      status: fromJS({
        id: 'status-2',
        text: 'held',
        spoiler_text: '',
        visibility: 'public',
        media_attachments: [media('m9').toJS()],
      }),
      raw_text: 'held',
      reuseMedia: true,
      mediaUnconfirmed: true,
    });
    freshStore.dispatch({ type: 'COMPOSE_UPLOAD_UNDO', media_id: 'm9' });

    expect(freshStore.getState().getIn(['compose', 'media_attachments']).size).toEqual(0);
    expect(freshStore.getState().getIn(['compose', 'redraftMediaUnconfirmed'])).toBe(true);

    client.request.mockResolvedValue(postedResponse);
    freshStore.dispatch({
      type: REDRAFT,
      status: fromJS({
        id: 'status-3',
        text: 'plain',
        spoiler_text: '',
        visibility: 'public',
        media_attachments: [],
      }),
      raw_text: 'plain',
      reuseMedia: true,
      mediaUnconfirmed: false,
    });

    expect(freshStore.getState().getIn(['compose', 'redraftMediaUnconfirmed'])).toBe(false);
    expect(composerRedraftBlocksSubmit(freshStore.getState().get('compose'))).toBe(false);

    await freshStore.dispatch(submitComposer('primary', { push: jest.fn(), goBack: jest.fn(), location: { pathname: '/home' } }));
    expect(client.request).toHaveBeenCalledWith(expect.objectContaining({
      method: 'post',
      data: expect.objectContaining({ status: 'plain' }),
    }));
  });

  it('ignores an older composer generation after the same composer id is recreated', async () => {
    let finishOldGet;
    client.get.mockImplementationOnce(() => new Promise(resolve => {
      finishOldGet = resolve;
    }));

    store.dispatch(createComposer('composer-a'));
    store.dispatch(targetComposerAction({
      type: REDRAFT,
      status: statusWithMedia('m1'),
      raw_text: 'old text',
      reuseMedia: true,
    }, 'composer-a'));
    store.dispatch(prepareRedraftMedia('composer-a'));

    const oldIdentity = redraftIdentity(store.getState(), 'composer-a');

    store.dispatch(targetComposerAction({
      type: COMPOSE_REDAFT_MEDIA_STATUS,
      mediaId: 'm1',
      reuse: 'complete',
      fetched: true,
      error: null,
      ...oldIdentity,
    }, 'composer-a'));

    let finishOldPut;
    client.put.mockImplementationOnce(() => new Promise(resolve => {
      finishOldPut = resolve;
    }));
    store.dispatch(changeComposerUpload('composer-a', 'm1', { description: 'old edit', focus: '0.10,-0.20' }));

    store.dispatch(destroyComposer('composer-a'));
    store.dispatch(createComposer('composer-a'));
    client.get.mockResolvedValue({
      status: 200,
      data: { id: 'm1', type: 'image', description: 'new alt', meta: { focus: { x: 0.5, y: 0.5 } }, url: 'https://example.test/m1.jpg' },
    });
    store.dispatch(targetComposerAction({
      type: REDRAFT,
      status: statusWithMedia('m1'),
      raw_text: 'new text',
      reuseMedia: true,
    }, 'composer-a'));

    const newIdentity = redraftIdentity(store.getState(), 'composer-a');

    expect(newIdentity.epoch).toEqual(oldIdentity.epoch);
    expect(newIdentity.generation).not.toEqual(oldIdentity.generation);

    store.dispatch(prepareRedraftMedia('composer-a'));
    await flush();

    const read = () => store.getState().getIn(['composers', 'byId', 'composer-a']);

    expect(read().get('text')).toEqual('new text');
    expect(read().getIn(['media_attachments', 0, 'description'])).toEqual('new alt');
    expect(read().getIn(['media_attachments', 0, 'redraftReuse'])).toEqual('complete');
    expect(read().getIn(['media_attachments', 0, 'redraftError'])).toBeNull();

    finishOldGet({ status: 200, data: { id: 'm1', type: 'image', description: 'from old get', meta: { focus: { x: 0, y: 0 } } } });
    finishOldPut({ status: 200, data: { id: 'm1', type: 'image', description: 'old edit', meta: { focus: { x: 0.1, y: -0.2 } } } });
    jest.advanceTimersByTime(30_000);
    await flush();

    expect(read().get('text')).toEqual('new text');
    expect(read().getIn(['media_attachments', 0, 'description'])).toEqual('new alt');
    expect(read().getIn(['media_attachments', 0, 'redraftReuse'])).toEqual('complete');
    expect(read().getIn(['media_attachments', 0, 'redraftError'])).toBeNull();
    expect(read().get('redraftGeneration')).toEqual(newIdentity.generation);
    expect(client.put).toHaveBeenCalledTimes(1);
  });
});
