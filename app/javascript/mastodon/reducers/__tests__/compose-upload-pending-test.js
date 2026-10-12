import { Map as ImmutableMap } from 'immutable';

jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

import composer, { initialState } from '../composer';

const COMPOSE_UPLOAD_REQUEST = 'COMPOSE_UPLOAD_REQUEST';
const COMPOSE_UPLOAD_SUCCESS = 'COMPOSE_UPLOAD_SUCCESS';
const COMPOSE_UPLOAD_FAIL = 'COMPOSE_UPLOAD_FAIL';
const COMPOSE_UPLOAD_PROCESSING = 'COMPOSE_UPLOAD_PROCESSING';

const image = (id) => ImmutableMap({ id, type: 'image', order: 0 });

describe('composer upload pending counts', () => {
  it('keeps every file pending until each one settles', () => {
    let state = composer(initialState, { type: COMPOSE_UPLOAD_REQUEST, count: 3, exclusiveCount: 0 });

    expect(state.get('pending_media_attachments')).toBe(3);
    expect(state.get('is_uploading')).toBe(true);

    state = composer(state, { type: COMPOSE_UPLOAD_SUCCESS, media: image('a').toJS(), file: { type: 'image/png' } });

    expect(state.get('pending_media_attachments')).toBe(2);
    expect(state.get('is_uploading')).toBe(true);
    expect(state.get('media_attachments').size).toBe(1);

    state = composer(state, { type: COMPOSE_UPLOAD_FAIL, error: new Error('nope'), exclusive: false });

    expect(state.get('pending_media_attachments')).toBe(1);
    expect(state.get('is_uploading')).toBe(true);

    state = composer(state, { type: COMPOSE_UPLOAD_SUCCESS, media: image('c').toJS(), file: { type: 'image/jpeg' } });

    expect(state.get('pending_media_attachments')).toBe(0);
    expect(state.get('is_uploading')).toBe(false);
    expect(state.get('is_processing')).toBe(false);
  });

  it('keeps processing visible until the processed file finishes', () => {
    let state = composer(initialState, { type: COMPOSE_UPLOAD_REQUEST, count: 2, exclusiveCount: 1 });

    state = composer(state, { type: COMPOSE_UPLOAD_PROCESSING });
    state = composer(state, { type: COMPOSE_UPLOAD_SUCCESS, media: image('still').toJS(), file: { type: 'image/png' } });

    expect(state.get('is_uploading')).toBe(true);
    expect(state.get('is_processing')).toBe(true);
    expect(state.get('pending_exclusive_attachments')).toBe(1);

    state = composer(state, {
      type: COMPOSE_UPLOAD_SUCCESS,
      media: { id: 'clip', type: 'video' },
      file: { type: 'video/mp4' },
      fromProcessing: true,
    });

    expect(state.get('pending_media_attachments')).toBe(0);
    expect(state.get('pending_exclusive_attachments')).toBe(0);
    expect(state.get('is_uploading')).toBe(false);
    expect(state.get('is_processing')).toBe(false);
  });

  it('does not let pending counts become negative', () => {
    const state = composer(initialState, { type: COMPOSE_UPLOAD_FAIL, error: new Error('late') });

    expect(state.get('pending_media_attachments')).toBe(0);
    expect(state.get('is_uploading')).toBe(false);
  });
});
