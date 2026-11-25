import { COMPOSE_RESET } from '../../actions/compose';
import { COMPOSER_DRAFT_MEDIA, COMPOSER_DRAFT_RESTORE, createComposer, targetComposerAction } from '../../actions/composer';
import composer, { initialState } from '../../reducers/composer';
import composers from '../../reducers/composers';
import { applyResolvedDraftMedia, composerDraftRestoreBlocksSubmit, draftMediaResponseUsable } from '../snapshot';

const snapshot = {
  schema_version: 1,
  account_id: '42',
  client_draft_uuid: '11111111-1111-4111-8111-111111111111',
  input: {
    text: 'Hello',
    media: [
      { id: '501', order: 0, description: 'stale', focus: { x: 0.2, y: -0.4 } },
      { id: '502', order: 1, description: '', focus: { x: 0, y: 0 } },
    ],
  },
};

const serverMedia = {
  id: '501',
  type: 'image',
  url: 'https://example.test/501.jpg',
  preview_url: 'https://example.test/501-small.jpg',
  description: 'server alt',
  meta: { focus: { x: 0.1, y: 0.2 } },
};

function restored (token = 'restore-1') {
  return composer(initialState, {
    type: COMPOSER_DRAFT_RESTORE,
    snapshot,
    restoreToken: token,
  });
}

function resolve (state, media, mediaId = '501', token = 'restore-1') {
  return applyResolvedDraftMedia(state, {
    type: COMPOSER_DRAFT_MEDIA,
    restoreToken: token,
    mediaId,
    media,
  });
}

describe('draft media restore', () => {
  it('clears unresolved only for a finished file that belongs to this restore', () => {
    const state = restored();

    expect(state.getIn(['media_attachments', 0, 'unresolved'])).toBe(true);
    expect(composerDraftRestoreBlocksSubmit(state)).toBe(true);

    const next = resolve(state, serverMedia);

    expect(next.getIn(['media_attachments', 0, 'unresolved'])).toBe(false);
    expect(next.getIn(['media_attachments', 0, 'description'])).toBe('stale');
    expect(next.getIn(['media_attachments', 0, 'meta', 'focus', 'x'])).toBe(0.2);
    expect(next.getIn(['media_attachments', 0, 'meta', 'focus', 'y'])).toBe(-0.4);
    expect(next.getIn(['media_attachments', 0, 'type'])).toBe('image');
    expect(next.getIn(['media_attachments', 0, 'url'])).toBe('https://example.test/501.jpg');
    expect(next.getIn(['media_attachments', 0, 'preview_url'])).toBe('https://example.test/501-small.jpg');
    expect(next.getIn(['media_attachments', 0, 'order'])).toBe(0);
    expect(next.getIn(['media_attachments', 1, 'unresolved'])).toBe(true);
    expect(composerDraftRestoreBlocksSubmit(next)).toBe(true);
    expect(draftMediaResponseUsable({ id: '501', type: 'unknown', url: 'https://example.test/x' }, '501')).toBe(false);
    expect(draftMediaResponseUsable({ id: '501', type: 'image' }, '501')).toBe(false);
    expect(draftMediaResponseUsable({ ...serverMedia, processing: 'queued' }, '501')).toBe(false);
    expect(draftMediaResponseUsable({ ...serverMedia, processing: 'in_progress' }, '501')).toBe(false);
    expect(draftMediaResponseUsable({ ...serverMedia, processing: 'failed' }, '501')).toBe(false);
    expect(draftMediaResponseUsable({ ...serverMedia, processing: 1 }, '501')).toBe(false);
    expect(draftMediaResponseUsable({ ...serverMedia, processing: 'complete' }, '501')).toBe(true);
    expect(draftMediaResponseUsable({ error: 'Error processing thumbnail for uploaded media' }, '501')).toBe(false);
    expect(resolve(state, { ...serverMedia, processing: 'in_progress' }).getIn(['media_attachments', 0, 'unresolved'])).toBe(true);
    expect(resolve(state, { id: '501', type: 'image' }).getIn(['media_attachments', 0, 'unresolved'])).toBe(true);
    expect(resolve(state, { ...serverMedia, id: '999' }).getIn(['media_attachments', 0, 'unresolved'])).toBe(true);
  });

  it('ignores a late file after discard, removal, or another restore', () => {
    const state = restored();
    const discarded = composer(state, { type: COMPOSE_RESET });
    const removed = state.update('media_attachments', list => list.shift());
    const replaced = restored('restore-2');

    expect(resolve(discarded, serverMedia).get('media_attachments').some(item => item.get('id') === '501')).toBe(false);
    expect(resolve(removed, serverMedia).get('media_attachments').map(item => item.get('id')).toArray()).toEqual(['502']);
    expect(resolve(replaced, serverMedia).getIn(['media_attachments', 0, 'unresolved'])).toBe(true);
    expect(replaced.get('draftRestoreToken')).toBe('restore-2');
  });

  it('does not put one composer restore into another composer', () => {
    let state = composers(undefined, createComposer('column-a'));
    state = composers(state, createComposer('column-b'));
    state = composers(state, targetComposerAction({
      type: COMPOSER_DRAFT_RESTORE,
      snapshot,
      restoreToken: 'restore-a',
    }, 'column-a'));
    state = composers(state, targetComposerAction({
      type: COMPOSER_DRAFT_MEDIA,
      restoreToken: 'restore-a',
      mediaId: '501',
      media: serverMedia,
    }, 'column-b'));

    expect(state.getIn(['byId', 'column-a', 'media_attachments', 0, 'unresolved'])).toBe(true);
    expect(state.getIn(['byId', 'column-b', 'media_attachments']).size).toBe(0);

    state = composers(state, targetComposerAction({
      type: COMPOSER_DRAFT_MEDIA,
      restoreToken: 'restore-a',
      mediaId: '501',
      media: serverMedia,
    }, 'column-a'));

    expect(state.getIn(['byId', 'column-a', 'media_attachments', 0, 'unresolved'])).toBe(false);
    expect(state.getIn(['byId', 'column-a', 'media_attachments', 0, 'description'])).toBe('stale');
    expect(state.getIn(['byId', 'column-a', 'media_attachments', 0, 'meta', 'focus', 'x'])).toBe(0.2);
    expect(state.getIn(['byId', 'column-b', 'media_attachments']).size).toBe(0);
  });
});
