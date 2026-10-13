import { Map as ImmutableMap } from 'immutable';
import { applyMiddleware, createStore } from 'redux';
import { combineReducers } from 'redux-immutable';
import thunk from 'redux-thunk';

jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

jest.mock('mastodon/initial_state', () => ({
  ...jest.requireActual('mastodon/initial_state'),
  maxAttachments: 4,
  allowPollImage: true,
}));

jest.mock('../../api', () => ({
  __esModule: true,
  default: jest.fn(),
}));

import api from '../../api';
import { COMPOSE_UPLOAD_REQUEST, uploadToComposer } from '../compose';
import { createComposer, targetComposerAction } from '../composer';
import compose from '../../reducers/compose';
import composers from '../../reducers/composers';

const reducer = combineReducers({
  compose,
  composers,
  relationships: (state = ImmutableMap()) => state,
  timelines: (state = ImmutableMap()) => state,
  meta: (state = ImmutableMap()) => state,
  statuses: (state = ImmutableMap()) => state,
  accounts: (state = ImmutableMap()) => state,
});

const makeStore = () => {
  const actions = [];
  const store = createStore(reducer, undefined, applyMiddleware(
    () => next => action => {
      if (action && action.type) actions.push(action);

      return next(action);
    },
    thunk,
  ));

  return { store, actions };
};

const imageFile = (name) => new File(['x'], name, { type: 'image/png' });

const files = (count) => Array.from({ length: count }, (_, index) => imageFile(`photo-${index}.png`));

const attachImages = (store, composerId, count) => {
  for (let index = 0; index < count; index += 1) {
    store.dispatch(targetComposerAction({
      type: 'COMPOSE_UPLOAD_SUCCESS',
      media: { id: `${composerId}-${index}`, type: 'image' },
      file: { type: 'image/png' },
    }, composerId));
  }
};

describe('uploadToComposer batch limits', () => {
  beforeEach(() => {
    api.mockReset();
  });

  const attempt = (store, composerId, count) => {
    const post = jest.fn(() => Promise.resolve({ status: 200, data: { id: 'new', type: 'image' } }));

    api.mockReturnValue({ post });
    store.dispatch(uploadToComposer(composerId, files(count)));

    return post;
  };

  it('rejects a whole batch that does not fit and starts no uploads', () => {
    const { store, actions } = makeStore();

    store.dispatch(createComposer('composer-a'));
    attachImages(store, 'composer-a', 3);
    const post = attempt(store, 'composer-a', 2);

    expect(post).not.toHaveBeenCalled();
    expect(actions.some(action => action.type === COMPOSE_UPLOAD_REQUEST)).toBe(false);
    expect(actions.some(action => action.type === 'ALERT_SHOW' && action.message.id === 'upload_error.limit')).toBe(true);
    expect(store.getState().getIn(['composers', 'byId', 'composer-a', 'pending_media_attachments'])).toBe(0);
    expect(store.getState().getIn(['composers', 'byId', 'composer-a', 'media_attachments']).size).toBe(3);
  });

  it('rejects five files on an empty composer and accepts a batch that fits', () => {
    const empty = makeStore();

    empty.store.dispatch(createComposer('composer-a'));
    expect(attempt(empty.store, 'composer-a', 5)).not.toHaveBeenCalled();

    const open = makeStore();

    open.store.dispatch(createComposer('composer-a'));
    attachImages(open.store, 'composer-a', 2);
    const post = attempt(open.store, 'composer-a', 2);

    expect(post).toHaveBeenCalledTimes(2);
    expect(open.actions.filter(action => action.type === COMPOSE_UPLOAD_REQUEST)).toEqual([
      expect.objectContaining({ meta: { composerId: 'composer-a' }, count: 2 }),
    ]);
  });

  it('keeps another composer pending from blocking a batch that fits', () => {
    const { store, actions } = makeStore();

    store.dispatch(createComposer('composer-a'));
    store.dispatch(createComposer('composer-b'));
    attachImages(store, 'composer-a', 2);
    store.dispatch(targetComposerAction({
      type: COMPOSE_UPLOAD_REQUEST,
      count: 1,
      exclusiveCount: 0,
    }, 'composer-a'));
    attachImages(store, 'composer-b', 3);

    const blocked = attempt(store, 'composer-a', 2);
    const allowed = attempt(store, 'composer-b', 1);

    expect(blocked).not.toHaveBeenCalled();
    expect(allowed).toHaveBeenCalledTimes(1);
    expect(store.getState().getIn(['composers', 'byId', 'composer-a', 'pending_media_attachments'])).toBe(1);
    expect(store.getState().getIn(['composers', 'byId', 'composer-b', 'pending_media_attachments'])).toBe(1);
    expect(actions.filter(action => action.type === COMPOSE_UPLOAD_REQUEST && action.meta.composerId === 'composer-a').length).toBe(1);
    expect(actions.filter(action => action.type === COMPOSE_UPLOAD_REQUEST && action.meta.composerId === 'composer-b')).toEqual([
      expect.objectContaining({ count: 1 }),
    ]);
  });
});
