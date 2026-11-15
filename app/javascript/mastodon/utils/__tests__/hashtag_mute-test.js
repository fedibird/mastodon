import { fromJS } from 'immutable';

import { filterRules } from '../filter_rules';
import { findHashtagMute, normalizeHashtagName } from '../hashtag_mute';
import { nextFilterExpiryAt } from '../../actions/filter_expiry';

describe('hashtag mute identity', () => {
  it('folds case and a leading fullwidth hash without trimming the rest of the name', () => {
    expect(normalizeHashtagName('＃AbC')).toBe('abc');
    expect(normalizeHashtagName('番組実況')).toBe('番組実況');
    expect(normalizeHashtagName('番組')).not.toBe(normalizeHashtagName('番組実況'));
  });

  it('finds the saved tag mute and keeps a keyword-only filter out of that lookup', () => {
    const filters = fromJS({
      1: { id: '1', title: '番組', keywords: [{ keyword: '番組' }] },
      2: { id: '2', title: '#番組', tags: [{ id: '9', name: '番組' }], context: ['home'] },
    });

    expect(findHashtagMute(filters, '＃番組').get('id')).toBe('2');
  });

  it('includes exact tag names in the reconciliation signature', () => {
    const rules = filterRules([
      { id: '4', keywords: [], statuses: [], tags: [{ id: '1', name: 'ABC' }] },
      { id: '5', keywords: [], statuses: [], tags: [] },
    ]);

    expect(rules.getIn(['4', 'tags']).toJS()).toEqual(['abc']);
    expect(rules.has('5')).toBe(false);
  });

  it('chooses the soonest future expiry', () => {
    const now = 1_000_000;

    expect(nextFilterExpiryAt([
      { expires_at: now + 5000 },
      { expires_at: new Date(now + 2000).toISOString() },
      { expires_at: null },
      { expires_at: now - 10 },
    ], now)).toBe(now + 2000);
    expect(nextFilterExpiryAt([{ expires_at: null }], now)).toBeNull();
  });
});
