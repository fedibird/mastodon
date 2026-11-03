import { fromJS, List as ImmutableList } from 'immutable';

jest.mock('mastodon/initial_state', () => ({ displayMedia: 'default' }));

import { mediaModalPagination } from '../media_modal_pagination';

const image = id => ({ id, type: 'image', preview_url: `/img/${id}` });

const initialMedia = fromJS([image('first')]);
const initialStatusIds = ImmutableList(['one']);

const timeline = {
  kind: 'timeline',
  timelineId: 'home:media',
  afterStatusId: 'one',
  visibility: 'hide_sensitive',
};

const account = {
  kind: 'account',
  timelineId: 'account:abc:media:cats',
  accountId: 'abc',
  afterStatusId: 'one',
  visibility: 'hide_sensitive',
};

const props = source => ({ media: initialMedia, timelineStatusIds: initialStatusIds, mediaSource: source });

describe('media modal append-only pagination', () => {
  it('preserves initial image indices while appending images from newer loaded pages of the same timeline', () => {
    const state = fromJS({
      timelines: {
        'home:media': { items: ['one', 'two', 'three'], hasMore: false, isLoading: false },
      },
      statuses: {
        one: { id: 'one', sensitive: false, media_attachments: [image('first')] },
        two: { id: 'two', sensitive: false, media_attachments: [{ id: 'video', type: 'video' }] },
        three: { id: 'three', sensitive: false, media_attachments: [image('next')] },
      },
    });

    const page = mediaModalPagination(state, props(timeline));
    expect(page.media.map(item => item.get('id')).toArray()).toEqual(['first', 'next']);
    expect(page.statusIds.toArray()).toEqual(['one', 'three']);
    expect(page.hasMore).toBe(false);
  });

  it('skips concealed sensitive images, respects page loading/errors, and keeps anchor ordering', () => {
    const state = fromJS({
      timelines: { 'home:media': { items: ['one', 'hidden', 'public'], isLoading: true, hasMore: true, paginationError: false } },
      statuses: {
        one: { id: 'one', media_attachments: [image('first')] },
        hidden: { id: 'hidden', sensitive: true, media_attachments: [image('private')] },
        public: { id: 'public', sensitive: false, spoiler_text: 'CW', hidden: true, media_attachments: [image('visible')] },
      },
    });
    const page = mediaModalPagination(state, props(timeline));
    expect(page.media.map(item => item.get('id')).toArray()).toEqual(['first', 'visible']);
    expect(page.isLoading).toBe(true);
    expect(page.error).toBe(false);
  });

  it('supports account media filtering as a distinct pagination key', () => {
    const state = fromJS({
      timelines: {
        'account:abc:media:cats': { items: ['one', 'two'], isLoading: false, hasMore: false },
        'account:abc:media': { items: ['one', 'other'], isLoading: false, hasMore: false },
      },
      accounts: { abc: { id: 'abc' } },
      statuses: {
        one: { id: 'one', media_attachments: [image('first')] },
        two: { id: 'two', media_attachments: [image('tagged-next')] },
        other: { id: 'other', media_attachments: [image('wrong-tag')] },
      },
    });
    const page = mediaModalPagination(state, props(account));
    expect(page.media.map(item => item.get('id')).toArray()).toEqual(['first', 'tagged-next']);
    expect(page.statusIds.toArray()).toEqual(['one', 'two']);
  });

  it('does not append if the original anchor vanished from the loaded timeline', () => {
    const state = fromJS({
      timelines: { 'home:media': { items: ['unrelated'], hasMore: false } },
      statuses: { unrelated: { media_attachments: [image('other')] } },
    });
    expect(mediaModalPagination(state, props(timeline)).media.map(item => item.get('id')).toArray()).toEqual(['first']);
  });

  it('retains static per-post media modal behavior', () => {
    const state = fromJS({ timelines: {}, statuses: {} });
    expect(mediaModalPagination(state, { media: initialMedia })).toBeNull();
  });
});
