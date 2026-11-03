import { fromJS, List as ImmutableList } from 'immutable';

jest.mock('mastodon/initial_state', () => ({ displayMedia: 'default' }));

import { mediaRowsForStatuses } from '../timeline_layout';
import { accountMediaTimelineSequence, mediaTimelineSequence } from '../media_timeline_sequence';

const statuses = fromJS({
  '10': {
    id: '10',
    sensitive: false,
    media_attachments: [
      { id: 'a', type: 'image' },
      { id: 'v', type: 'video' },
      { id: 'b', type: 'gifv' },
    ],
  },
  '20': { id: '20', sensitive: true, media_attachments: [{ id: 'hidden', type: 'image' }] },
  '30': { id: '30', sensitive: false, spoiler_text: 'CW only', hidden: true, media_attachments: [{ id: 'cw', type: 'image' }] },
  '40': { id: '40', sensitive: false, media_attachments: [] },
  '50': { id: '50', reblog: '10', sensitive: false, media_attachments: [] },
});

const rows = mediaRowsForStatuses(ImmutableList(['10', '20', '30', '40', '50']), statuses);

describe('cross-post media navigation sequence', () => {
  it('follows image/GIF order across posts and boosts, but skips video and hidden sensitive media', () => {
    const sequence = mediaTimelineSequence(rows, statuses, 'hide_sensitive');

    expect(sequence.media.map(item => item.get('id')).toArray()).toEqual(['a', 'b', 'cw', 'a', 'b']);
    expect(sequence.statusIds.toArray()).toEqual(['10', '10', '30', '10', '10']);
    expect(sequence.positions[rows.find(row => row.id === '10' && row.mediaIndex === 0).key]).toBe(0);
    expect(sequence.positions[rows.find(row => row.id === '30').key]).toBe(2);
    expect(sequence.positions[rows.find(row => row.id === '20').key]).toBeUndefined();
  });

  it('includes sensitive images only when this view explicitly shows all media', () => {
    const sequence = mediaTimelineSequence(rows, statuses, 'show_all');
    expect(sequence.media.map(item => item.get('id')).toArray()).toEqual(['a', 'b', 'hidden', 'cw', 'a', 'b']);
    expect(sequence.statusIds.get(2)).toBe('20');
  });

  it('does not make concealed media accessible by arrow navigation in hide-all mode', () => {
    const sequence = mediaTimelineSequence(rows, statuses, 'hide_all');
    expect(sequence.media.size).toBe(0);
    expect(Object.keys(sequence.positions)).toHaveLength(0);
  });

  it('skips warning/hidden filtered statuses even when their media is not sensitive', () => {
    const filtered = statuses.setIn(['30', 'filtered'], fromJS([{ filter: 'hidden-filter' }]));
    const contextRows = rows.map(row => ({ ...row, contextType: 'public' }));
    const filterInfo = {
      filters: fromJS({ 'hidden-filter': { context: ['public'], filter_action: 'hide', expires_at: null } }),
    };

    const sequence = mediaTimelineSequence(contextRows, filtered, 'show_all', filterInfo);
    expect(sequence.media.map(item => item.get('id')).toArray()).toEqual(['a', 'b', 'hidden', 'a', 'b']);
    expect(sequence.statusIds.includes('30')).toBe(false);
  });

  it('handles missing Redux statuses and gap rows', () => {
    expect(mediaTimelineSequence(rows, null).media.size).toBe(0);
    const sequence = mediaTimelineSequence([{ kind: 'gap', position: 0 }], statuses);
    expect(sequence.media.size).toBe(0);
  });
});

describe('account media gallery cross-post navigation', () => {
  const items = fromJS([
    { id: 'photo-1', type: 'image', status: { id: '101', sensitive: false } },
    { id: 'private-photo', type: 'image', status: { id: '102', sensitive: true } },
    null,
    { id: 'gif', type: 'gifv', status: { id: '103', sensitive: false } },
    { id: 'movie', type: 'video', status: { id: '104', sensitive: false } },
    { id: 'cw-photo', type: 'image', status: { id: '105', sensitive: false, hidden: true, spoiler_text: 'CW' } },
  ]);

  it('navigates account images across posts but keeps sensitive images hidden', () => {
    const sequence = accountMediaTimelineSequence(items, 'hide_sensitive');
    expect(sequence.media.map(item => item.get('id')).toArray()).toEqual(['photo-1', 'gif', 'cw-photo']);
    expect(sequence.statusIds.toArray()).toEqual(['101', '103', '105']);
  });

  it('omits filtered account media from cross-post navigation', () => {
    const filteredItems = items.update(3, item => item.setIn(['status', 'filtered'], fromJS([{ filter: 'my-account-filter' }])));
    const filterInfo = {
      filters: fromJS({ 'my-account-filter': { context: ['account'], filter_action: 'warn', expires_at: null } }),
    };

    const sequence = accountMediaTimelineSequence(filteredItems, 'show_all', filterInfo);
    expect(sequence.media.map(item => item.get('id')).toArray()).toEqual(['photo-1', 'private-photo', 'cw-photo']);
  });

  it('show all includes sensitive images, while hide all has no navigable images', () => {
    expect(accountMediaTimelineSequence(items, 'show_all').media.map(item => item.get('id')).toArray())
      .toEqual(['photo-1', 'private-photo', 'gif', 'cw-photo']);
    expect(accountMediaTimelineSequence(items, 'hide_all').media.isEmpty()).toBe(true);
  });
});
