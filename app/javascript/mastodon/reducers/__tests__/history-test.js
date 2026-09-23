import { HISTORY_FETCH_FAIL, HISTORY_FETCH_REQUEST, HISTORY_FETCH_SUCCESS } from '../../actions/history';
import history from '../history';

const revision = (content, createdAt) => ({
  content,
  spoiler_text: 'cw',
  sensitive: true,
  created_at: createdAt,
  account: { id: 'a1' },
  media_attachments: [{ id: 'm1', description: 'alt' }],
});

describe('history reducer', () => {
  it('keeps the newest revision first and flags the original', () => {
    const requested = history(undefined, { type: HISTORY_FETCH_REQUEST, statusId: 's1' });
    expect(requested.getIn(['s1', 'loading'])).toBe(true);

    const loaded = history(requested, {
      type: HISTORY_FETCH_SUCCESS,
      statusId: 's1',
      history: [
        revision('<p>original</p>', '2026-01-01T00:00:00.000Z'),
        revision('<p>edited</p>', '2026-01-02T00:00:00.000Z'),
      ],
    });

    expect(loaded.getIn(['s1', 'loading'])).toBe(false);
    expect(loaded.getIn(['s1', 'items', 0, 'content'])).toEqual('<p>edited</p>');
    expect(loaded.getIn(['s1', 'items', 0, 'original'])).toBe(false);
    expect(loaded.getIn(['s1', 'items', 1, 'original'])).toBe(true);
    expect(loaded.getIn(['s1', 'items', 0, 'account'])).toEqual('a1');
    expect(loaded.getIn(['s1', 'items', 0, 'spoiler_text'])).toEqual('cw');
    expect(loaded.getIn(['s1', 'items', 0, 'sensitive'])).toBe(true);
    expect(loaded.getIn(['s1', 'items', 0, 'media_attachments', 0, 'description'])).toEqual('alt');
  });

  it('clears loading when history fetch fails', () => {
    const requested = history(undefined, { type: HISTORY_FETCH_REQUEST, statusId: 's1' });
    const failed = history(requested, { type: HISTORY_FETCH_FAIL, statusId: 's1', error: new Error('nope') });

    expect(failed.getIn(['s1', 'loading'])).toBe(false);
    expect(failed.getIn(['s1', 'items']).size).toEqual(0);
  });
});
