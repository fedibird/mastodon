import { Map as ImmutableMap } from 'immutable';

jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

import composer, { initialState } from '../composer';

const image = id => ({ id, type: 'image' });

const request = (state, ids) => composer(state, {
  type: 'COMPOSE_UPLOAD_REQUEST',
  count: ids.length,
  exclusiveCount: 0,
  requestIds: ids,
});

describe('tracked composer uploads', () => {
  it('keeps the remaining files in progress after one of three succeeds', () => {
    let state = request(initialState, ['a', 'b', 'c']);

    state = composer(state, {
      type: 'COMPOSE_UPLOAD_SUCCESS',
      requestId: 'a',
      media: image('a'),
      file: { type: 'image/png' },
      ownerIdentityId: 'delegated:99',
    });

    expect(state.get('pending_media_attachments')).toBe(2);
    expect(state.get('is_uploading')).toBe(true);
    expect(state.get('is_processing')).toBe(false);
    expect(state.get('media_attachments').map(item => item.get('id')).toArray()).toEqual(['a']);
    expect(state.getIn(['media_attachments', 0, 'ownerIdentityId'])).toEqual('delegated:99');

    state = composer(state, { type: 'COMPOSE_UPLOAD_FAIL', requestId: 'b', error: new Error('nope') });

    expect(state.get('pending_media_attachments')).toBe(1);
    expect(state.get('is_uploading')).toBe(true);

    state = composer(state, {
      type: 'COMPOSE_UPLOAD_SUCCESS',
      requestId: 'c',
      media: image('c'),
      file: { type: 'image/jpeg' },
    });

    expect(state.get('pending_media_attachments')).toBe(0);
    expect(state.get('is_uploading')).toBe(false);
    expect(state.get('is_processing')).toBe(false);
    expect(state.get('media_attachments').size).toBe(2);
  });

  it('distinguishes polling from the HTTP upload and ignores a stale response', () => {
    let state = request(initialState, ['http', 'poll']);

    state = composer(state, { type: 'COMPOSE_UPLOAD_PROCESSING', requestId: 'poll' });

    expect(state.get('is_uploading')).toBe(true);
    expect(state.get('is_processing')).toBe(true);
    expect(state.get('pending_media_attachments')).toBe(2);

    state = composer(state, {
      type: 'COMPOSE_UPLOAD_SUCCESS',
      requestId: 'http',
      media: image('http'),
      file: { type: 'image/png' },
    });

    expect(state.get('is_uploading')).toBe(false);
    expect(state.get('is_processing')).toBe(true);
    expect(state.get('pending_media_attachments')).toBe(1);

    const stale = composer(state, {
      type: 'COMPOSE_UPLOAD_SUCCESS',
      requestId: 'gone',
      media: image('gone'),
      file: { type: 'image/png' },
    });

    expect(stale.get('pending_media_attachments')).toBe(1);
    expect(stale.get('media_attachments').size).toBe(1);
    expect(stale.get('is_processing')).toBe(true);

    state = composer(state, {
      type: 'COMPOSE_UPLOAD_SUCCESS',
      requestId: 'poll',
      fromProcessing: true,
      media: image('poll'),
      file: { type: 'image/png' },
    });

    expect(state.get('pending_media_attachments')).toBe(0);
    expect(state.get('is_uploading')).toBe(false);
    expect(state.get('is_processing')).toBe(false);
  });

  it('ends cleanly when every tracked upload fails and does not go negative', () => {
    let state = request(initialState, ['a', 'b', 'c']);

    ['a', 'b', 'c'].forEach(id => {
      state = composer(state, { type: 'COMPOSE_UPLOAD_FAIL', requestId: id, error: new Error(id) });
    });

    expect(state.get('pending_media_attachments')).toBe(0);
    expect(state.get('is_uploading')).toBe(false);
    expect(state.get('is_processing')).toBe(false);
    expect(state.get('media_attachments').size).toBe(0);

    state = composer(state, { type: 'COMPOSE_UPLOAD_FAIL', requestId: 'a', error: new Error('late') });

    expect(state.get('pending_media_attachments')).toBe(0);
  });
});

describe('legacy upload counts stay available', () => {
  it('still settles a count-based batch that has no request ids', () => {
    let state = composer(initialState, { type: 'COMPOSE_UPLOAD_REQUEST', count: 2, exclusiveCount: 0 });

    state = composer(state, { type: 'COMPOSE_UPLOAD_SUCCESS', media: image('a'), file: { type: 'image/png' } });

    expect(state.get('pending_media_attachments')).toBe(1);
    expect(state.get('is_uploading')).toBe(true);
    expect(state.get('uploadRequests')).toEqual(ImmutableMap());
  });
});
