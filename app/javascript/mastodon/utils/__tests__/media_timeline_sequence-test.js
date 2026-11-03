import { fromJS, List as ImmutableList } from 'immutable';

jest.mock('mastodon/initial_state', () => ({ displayMedia: 'default' }));

import { mediaRowsForStatuses } from '../timeline_layout';
import { mediaTimelineSequence } from '../media_timeline_sequence';

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

  it('handles missing Redux statuses and gap rows', () => {
    expect(mediaTimelineSequence(rows, null).media.size).toBe(0);
    const sequence = mediaTimelineSequence([{ kind: 'gap', position: 0 }], statuses);
    expect(sequence.media.size).toBe(0);
  });
});
